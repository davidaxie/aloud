import Foundation
import Combine
import PDFKit
import UIKit

/// Owns the on-disk library: document files, extracted-content cache, thumbnails,
/// and the atomic metadata index. All mutations flow through here.
@MainActor
final class DocumentStore: ObservableObject {

    @Published private(set) var documents: [LibraryDocument] = []

    private let pipeline: ExtractionPipeline
    private var pendingSave: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private static let indexVersion = 1

    init(pipeline: ExtractionPipeline = ExtractionPipeline()) {
        self.pipeline = pipeline
        loadIndex()

        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.flushIndex() }
            .store(in: &cancellables)
    }

    // MARK: - Import

    /// Copies a PDF into the library, extracts its content, and persists metadata.
    func importPDF(from url: URL,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryDocument {
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).pdf")
        try await Self.copyFile(from: url, to: destination)

        do {
            let content = try await pipeline.extract(pdfURL: destination, progress: progress)
            try Self.writeContentCache(content, for: id)
            await Self.writeThumbnail(pdfURL: destination, id: id)

            let document = LibraryDocument(
                id: id,
                title: content.title,
                fileName: destination.lastPathComponent,
                addedAt: Date(),
                pageCount: content.pageCount,
                sentenceCount: content.sentences.count,
                contentHash: content.contentHash,
                kind: .pdf,
                wordCount: Self.wordCount(of: content))
            insert(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies a plain-text book into the library and extracts its content.
    func importText(title: String,
                    author: String? = nil,
                    from url: URL,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryDocument {
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).txt")
        try await Self.copyFile(from: url, to: destination)

        do {
            let content = try await pipeline.extractText(fileURL: destination, title: title, progress: progress)
            try Self.writeContentCache(content, for: id)

            let document = LibraryDocument(
                id: id,
                title: title,
                fileName: destination.lastPathComponent,
                addedAt: Date(),
                pageCount: content.pageCount,
                sentenceCount: content.sentences.count,
                contentHash: content.contentHash,
                kind: .text,
                author: author,
                wordCount: Self.wordCount(of: content))
            insert(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Adds a bundled classic to the library. Instant, offline; idempotent per book.
    func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
        if let existing = documents.first(where: {
            $0.kind == .text && $0.title == book.title && $0.author == book.author
        }) {
            return existing
        }
        guard let url = BookshelfCatalog.bundledURL(for: book) else {
            throw DocumentStoreError.bundledBookMissing(book.file)
        }
        var document = try await importText(title: book.title, author: book.author, from: url)
        // Catalog word counts are authoritative for shelf estimates.
        if book.words > 0 {
            document.wordCount = book.words
            update(document)
        }
        return document
    }

    // MARK: - Content

    /// Returns extracted content, from cache when valid, re-extracting otherwise.
    /// A content-hash mismatch resets stored progress rather than misplacing it.
    func content(for document: LibraryDocument) async throws -> DocContent {
        if let cached = Self.readContentCache(for: document.id) {
            reconcile(document, against: cached)
            return cached
        }

        let fileURL = Self.libraryDir.appendingPathComponent(document.fileName)
        let content: DocContent
        switch document.kind {
        case .pdf:
            content = try await pipeline.extract(pdfURL: fileURL, progress: nil)
        case .text:
            content = try await pipeline.extractText(fileURL: fileURL, title: document.title, progress: nil)
        }
        try Self.writeContentCache(content, for: document.id)
        reconcile(document, against: content)
        return content
    }

    // MARK: - Progress

    /// Updates in-memory progress immediately; disk write debounced 2 s
    /// (flushed on app background).
    func saveProgress(id: UUID, sentence: Int, fraction: Double) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].progressSentence = sentence
        documents[index].progressFraction = fraction
        documents[index].lastOpenedAt = Date()

        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistIndex()
        }
    }

    /// Marks a document as opened (drives last-listened sort on the shelf).
    func noteOpened(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].lastOpenedAt = Date()
        sortDocuments()
        persistIndex()
    }

    // MARK: - Mutation

    func delete(_ document: LibraryDocument) {
        documents.removeAll { $0.id == document.id }
        persistIndex()

        let fm = FileManager.default
        try? fm.removeItem(at: Self.libraryDir.appendingPathComponent(document.fileName))
        try? fm.removeItem(at: Self.contentCacheURL(for: document.id))
        try? fm.removeItem(at: Self.thumbnailURL(for: document.id))
    }

    func rename(_ document: LibraryDocument, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].title = title
        persistIndex()
    }

    // MARK: - Paths

    static var libraryDir: URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var thumbnailsDir: URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for document: LibraryDocument) -> URL {
        libraryDir.appendingPathComponent(document.fileName)
    }

    static func thumbnailURL(for id: UUID) -> URL {
        thumbnailsDir.appendingPathComponent("\(id.uuidString).png")
    }

    private static func contentCacheURL(for id: UUID) -> URL {
        libraryDir.appendingPathComponent("\(id.uuidString).content.json")
    }

    private static var indexURL: URL {
        libraryDir.appendingPathComponent("library.json")
    }

    // MARK: - Private

    private struct LibraryIndex: Codable {
        var version: Int
        var documents: [LibraryDocument]
    }

    private func insert(_ document: LibraryDocument) {
        documents.append(document)
        sortDocuments()
        persistIndex()
    }

    private func update(_ document: LibraryDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index] = document
        persistIndex()
    }

    private func sortDocuments() {
        documents.sort {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
    }

    private func reconcile(_ document: LibraryDocument, against content: DocContent) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }),
              documents[index].contentHash != content.contentHash else { return }
        documents[index].contentHash = content.contentHash
        documents[index].progressSentence = 0
        documents[index].progressFraction = 0
        documents[index].sentenceCount = content.sentences.count
        documents[index].pageCount = content.pageCount
        persistIndex()
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? Self.decoder.decode(LibraryIndex.self, from: data)
        else { return }
        documents = index.documents
        sortDocuments()
    }

    private func persistIndex() {
        let index = LibraryIndex(version: Self.indexVersion, documents: documents)
        guard let data = try? Self.encoder.encode(index) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    private func flushIndex() {
        pendingSave?.cancel()
        pendingSave = nil
        persistIndex()
    }

    // MARK: - File helpers (off-main)

    private static func copyFile(from source: URL, to destination: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    private static func writeContentCache(_ content: DocContent, for id: UUID) throws {
        let data = try encoder.encode(content)
        try data.write(to: contentCacheURL(for: id), options: .atomic)
    }

    private static func readContentCache(for id: UUID) -> DocContent? {
        guard let data = try? Data(contentsOf: contentCacheURL(for: id)) else { return nil }
        return try? decoder.decode(DocContent.self, from: data)
    }

    private static func writeThumbnail(pdfURL: URL, id: UUID) async {
        let destination = thumbnailURL(for: id)
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: pdfURL),
                  let page = document.page(at: 0) else { return }
            let bounds = page.bounds(for: .cropBox)
            let width: CGFloat = 480
            let height = bounds.width > 0 ? width * bounds.height / bounds.width : width * 4 / 3
            let image = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
            try? image.pngData()?.write(to: destination, options: .atomic)
        }.value
    }

    private static func wordCount(of content: DocContent) -> Int {
        content.sentences.reduce(0) {
            $0 + $1.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum DocumentStoreError: LocalizedError {
    case bundledBookMissing(String)

    var errorDescription: String? {
        switch self {
        case .bundledBookMissing(let file):
            return "This book is missing from the app bundle (\(file))."
        }
    }
}
