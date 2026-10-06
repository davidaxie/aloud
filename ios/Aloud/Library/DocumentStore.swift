import Foundation
import Combine
import CryptoKit
import PDFKit

/// Owns the on-disk library: document files, extracted-content cache, thumbnails,
/// and the atomic metadata index. All mutations flow through here.
@MainActor
final class DocumentStore: ObservableObject {

    @Published private(set) var documents: [LibraryDocument] = []

    private let pipeline: ExtractionPipeline
    /// library.json. The app's lives in `libraryDir`.
    private let indexURL: URL
    /// The most a progress tick waits before it reaches disk.
    private let saveInterval: TimeInterval
    private var pendingSave: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    // v2: classics carry gutenbergID; v1 libraries are backfilled once.
    private static let indexVersion = 2
    /// The version the loaded library.json carries, written back by every
    /// persist, so a v1 library is never stamped v2 before its backfill runs.
    private var schemaVersion = DocumentStore.indexVersion
    /// The launch backfill of sourceHash, while it runs. Imports wait for it,
    /// so an Open-in that launched the app still finds the old record.
    private var sourceHashBackfill: Task<Void, Never>?

    /// `indexURL`, `saveInterval` and `notifications` are for the unit
    /// tests: an index of their own, a short wait, and a private center, so
    /// no test touches the app's library or posts a notification the host
    /// app hears. Nil `notifications` is where the platform posts each
    /// lifecycle event.
    init(pipeline: ExtractionPipeline = ExtractionPipeline(),
         indexURL: URL? = nil,
         saveInterval: TimeInterval = 2,
         notifications: NotificationCenter? = nil) {
        self.pipeline = pipeline
        self.indexURL = indexURL ?? Self.libraryDir.appendingPathComponent("library.json")
        self.saveInterval = saveInterval
        loadIndex()

        // Synchronous too: it is posted on the main thread, and a suspended
        // app may never get another turn.
        PlatformLifecycle.publisher(for: .didEnterBackground, in: notifications)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushIndex() }
            }
            .store(in: &cancellables)
        // Synchronous, with no hop (it is posted on the main thread): the
        // process is going away, and a pending write would die with it. A
        // book still playing in the background has moved on since the flush
        // above, and swiping the app away reaches only this one.
        PlatformLifecycle.publisher(for: .willTerminate, in: notifications)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.flushIndex() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Import

    /// Copies a PDF into the library, extracts its content, and persists metadata.
    func importPDF(from url: URL,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryDocument {
        // Opening the same file twice (Open-in, Files) returns the book
        // already on the shelf instead of adding a second copy: by its bytes
        // here, before any copy or extraction.
        let sourceHash = try await Self.sourceHash(of: url)
        if let existing = await existingCopy(sourceHash: sourceHash, kind: .pdf) {
            return existing
        }
        // Cancelled while hashing: nothing to clean up yet.
        try Task.checkCancellation()
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).pdf")
        try await Self.copyFile(from: url, to: destination)

        do {
            // The library copy is named by UUID, so a PDF without Title
            // metadata is named after the file the user picked.
            let content = try await pipeline.extract(pdfURL: destination,
                                                     fallbackTitle: ExtractionPipeline.fileTitle(of: url),
                                                     progress: progress)
            // Different bytes, same text (a re-saved copy): still one book.
            if let existing = Self.existingCopy(sourceHash: sourceHash, contentHash: content.contentHash,
                                                kind: .pdf, in: documents) {
                try? FileManager.default.removeItem(at: destination)
                return adoptSourceHash(sourceHash, for: existing)
            }
            // A cancelled import never reaches the shelf.
            try Task.checkCancellation()
            try Self.writeContentCache(content, for: id)
            await Self.writeThumbnail(pdfURL: destination, id: id)
            // No await may sit between this check and insert(): the store is
            // @MainActor, so a Cancel tap cannot land between them
            // (DocumentImporter relies on this).
            try Task.checkCancellation()

            let document = LibraryDocument(
                id: id,
                title: content.title,
                fileName: destination.lastPathComponent,
                addedAt: Date(),
                pageCount: content.pageCount,
                sentenceCount: content.sentences.count,
                contentHash: content.contentHash,
                kind: .pdf,
                wordCount: content.wordCount,
                sourceHash: sourceHash)
            insert(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Self.removeArtifacts(for: id)
            throw error
        }
    }

    /// Copies a plain-text book into the library and extracts its content.
    func importText(title: String,
                    author: String? = nil,
                    from url: URL,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryDocument {
        // Same file bytes as a book on the shelf: that book, before any copy
        // or extraction (see importPDF).
        let sourceHash = try await Self.sourceHash(of: url)
        if let existing = await existingCopy(sourceHash: sourceHash, kind: .text) {
            return existing
        }
        try Task.checkCancellation()
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).txt")
        try await Self.copyFile(from: url, to: destination)

        do {
            let content = try await pipeline.extractText(fileURL: destination, title: title, progress: progress)
            if let existing = Self.existingCopy(sourceHash: sourceHash, contentHash: content.contentHash,
                                                kind: .text, in: documents) {
                try? FileManager.default.removeItem(at: destination)
                return adoptSourceHash(sourceHash, for: existing)
            }
            // A cancelled import never reaches the shelf; no await follows
            // before insert(), so a Cancel tap cannot land after this check.
            try Task.checkCancellation()
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
                wordCount: content.wordCount,
                sourceHash: sourceHash)
            insert(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Self.removeArtifacts(for: id)
            throw error
        }
    }

    /// The shelf's copy of a document with this extracted content, if any.
    /// Same kind only: a PDF and a text file are never merged.
    static func duplicate(of contentHash: String, kind: DocKind,
                          in documents: [LibraryDocument]) -> LibraryDocument? {
        guard !contentHash.isEmpty else { return nil }
        return documents.first { $0.kind == kind && $0.contentHash == contentHash }
    }

    /// The shelf's copy of a file: by its bytes first, which no extractor
    /// change can alter, then (once extraction has run) by its text. A
    /// record's stored contentHash goes stale when the extractor changes,
    /// because its cached content is reused, so the text match alone would
    /// miss every book added before such a release. Same kind only.
    static func existingCopy(sourceHash: String?, contentHash: String?, kind: DocKind,
                             in documents: [LibraryDocument]) -> LibraryDocument? {
        if let sourceHash, !sourceHash.isEmpty,
           let match = documents.first(where: { $0.kind == kind && $0.sourceHash == sourceHash }) {
            return match
        }
        return contentHash.flatMap { duplicate(of: $0, kind: kind, in: documents) }
    }

    /// The pre-extraction check. Waits out the launch backfill first, so a
    /// record still being hashed is not missed.
    private func existingCopy(sourceHash: String, kind: DocKind) async -> LibraryDocument? {
        await sourceHashBackfill?.value
        return Self.existingCopy(sourceHash: sourceHash, contentHash: nil, kind: kind, in: documents)
    }

    /// A text match whose record has no sourceHash yet learns this file's,
    /// so the next re-open dedupes before extraction. A record that already
    /// has one keeps it: it names the file that was added.
    private func adoptSourceHash(_ hash: String, for document: LibraryDocument) -> LibraryDocument {
        guard document.sourceHash == nil,
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return document }
        documents[index].sourceHash = hash
        persistIndex()
        return documents[index]
    }

    /// Adds a bundled classic to the library. Offline; never adds a second
    /// copy. The record already linked by gutenbergID wins (so a renamed
    /// classic still opens); otherwise the bundled text is imported, and a
    /// duplicate already on the shelf (same bytes or same text) is linked
    /// instead of added.
    func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
        if let existing = document(forGutenbergID: book.gutenbergID) {
            return existing
        }
        guard let url = BookshelfCatalog.bundledURL(for: book) else {
            throw DocumentStoreError.bundledBookMissing(book.file)
        }
        let record = try await importText(title: book.title, author: book.author, from: url, progress: nil)
        return link(record.id, to: book) ?? record
    }

    /// The record added from this bundled classic, if any.
    func document(forGutenbergID id: Int) -> LibraryDocument? {
        Self.existingClassic(gutenbergID: id, in: documents)
    }

    /// First match in store order (most recent first). Pure, so it's
    /// unit-testable without a store.
    nonisolated static func existingClassic(gutenbergID: Int,
                                            in documents: [LibraryDocument]) -> LibraryDocument? {
        documents.first { $0.gutenbergID == gutenbergID }
    }

    /// Stamps the live record with its classic's id and the catalog word count
    /// (authoritative for shelf estimates). Never touches the title or the
    /// progress: a content-hash duplicate may be a renamed, half-read copy.
    private func link(_ id: UUID, to book: BookshelfBook) -> LibraryDocument? {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return nil }
        documents[index].gutenbergID = book.gutenbergID
        if book.words > 0 { documents[index].wordCount = book.words }
        persistIndex()
        return documents[index]
    }

    // MARK: - Gutenberg backfill (library.json v1 → v2)

    /// One-shot migration: links classics added before v2 to their catalog
    /// entry, then stamps the library v2. A no-op on v2, and with an empty
    /// catalog (the library stays v1 and is retried next launch).
    func backfillGutenbergIDsIfNeeded(catalog: [BookshelfBook]) {
        guard schemaVersion < 2, !catalog.isEmpty else { return }
        documents = Self.backfillingGutenbergIDs(in: documents, catalog: catalog)
        schemaVersion = 2
        persistIndex()
    }

    /// Links each unlinked text record with an author to the first catalog
    /// book whose author matches (catalog or Gutenberg-header spelling) and
    /// whose title matches either spelling, or, for a renamed record, whose
    /// word count matches. Only records still carrying the header spelling
    /// get the normalized title or author; a user's rename is kept.
    nonisolated static func backfillingGutenbergIDs(in documents: [LibraryDocument],
                                                    catalog: [BookshelfBook]) -> [LibraryDocument] {
        documents.map { document in
            guard document.kind == .text, document.gutenbergID == nil,
                  let author = document.author else { return document }
            let match = catalog.first { book in
                (author == book.author || author == book.headerAuthor)
                    && (document.title == book.title
                        || document.title == book.headerTitle
                        || (document.wordCount > 0 && document.wordCount == book.words))
            }
            guard let book = match else { return document }
            var linked = document
            linked.gutenbergID = book.gutenbergID
            if document.title == book.headerTitle { linked.title = book.title }
            if author == book.headerAuthor { linked.author = book.author }
            return linked
        }
    }

    // MARK: - sourceHash backfill

    /// Gives records from before sourceHash the hash of their library copy,
    /// so re-opening the same file dedupes even though this release's
    /// extractor rewrite changed the text, and so the stored content hash,
    /// of many books. Text imports
    /// keep their copy too: importText copies the picked file to `<id>.txt`
    /// byte for byte and re-extracts from it, so both kinds are covered (a
    /// classic's copy is the bundled file as it was when added). A record
    /// whose copy is missing stays nil and dedupes on its text alone. Only
    /// nil records are read, so once every record has a hash this is free.
    func backfillSourceHashesIfNeeded() {
        let pending = documents.filter { $0.sourceHash == nil }
            .map { (id: $0.id, url: Self.fileURL(for: $0)) }
        guard !pending.isEmpty, sourceHashBackfill == nil else { return }
        sourceHashBackfill = Task { [weak self] in
            var hashes: [UUID: String] = [:]
            for file in pending {
                hashes[file.id] = try? await Self.sourceHash(of: file.url)
            }
            guard let self, !hashes.isEmpty else { return }
            // Re-read after the await: records added, opened or deleted
            // meanwhile are kept as they are now.
            documents = Self.fillingSourceHashes(in: documents, from: hashes)
            persistIndex()
        }
    }

    /// Sets each record's sourceHash from `hashes` where it has none yet.
    nonisolated static func fillingSourceHashes(in documents: [LibraryDocument],
                                                from hashes: [UUID: String]) -> [LibraryDocument] {
        documents.map { document in
            guard document.sourceHash == nil, let hash = hashes[document.id] else { return document }
            var filled = document
            filled.sourceHash = hash
            return filled
        }
    }

    /// SHA-256 of a file's bytes, lowercase hex. Streamed in 1 MiB reads so
    /// a large PDF never sits in memory, off the main actor, and through the
    /// security scope a Files pick carries.
    nonisolated static func sourceHash(of url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: - Content

    /// Returns extracted content, from cache when valid, re-extracting otherwise.
    /// A content-hash mismatch resets stored progress rather than misplacing it.
    func content(for document: LibraryDocument) async throws -> DocContent {
        if var cached = Self.readContentCache(for: document.id) {
            if Self.needsChapterMap(cached, kind: document.kind) {
                cached = await backfillChapters(cached, for: document)
            }
            reconcile(document, against: cached)
            return cached
        }

        let fileURL = Self.libraryDir.appendingPathComponent(document.fileName)
        let content: DocContent
        switch document.kind {
        case .pdf:
            // The library copy is named by UUID: a PDF without Title
            // metadata keeps the name it was shelved under.
            content = try await pipeline.extract(pdfURL: fileURL, fallbackTitle: document.title, progress: nil)
        case .text:
            content = try await pipeline.extractText(fileURL: fileURL, title: document.title, progress: nil)
        }
        try Self.writeContentCache(content, for: document.id)
        reconcile(document, against: content)
        return content
    }

    /// A PDF whose cached content has no chapter map, or one from an older
    /// detector: imported before chapters, so it gets one on its next open.
    nonisolated static func needsChapterMap(_ content: DocContent, kind: DocKind) -> Bool {
        kind == .pdf && (content.chapterMap?.version ?? 0) < ChapterMap.currentVersion
    }

    /// Works out the cached PDF content's chapter map off the main actor (the
    /// outline from the stored PDF, the detectors on the cached text) and
    /// saves it into the cache. The text and its hash don't change, so the
    /// reconcile after keeps progress. A book deleted meanwhile keeps no
    /// cache; two loads at once write the same result. Off the extraction
    /// pipeline, so opening a book never waits behind an import.
    private func backfillChapters(_ cached: DocContent, for document: LibraryDocument) async -> DocContent {
        let pdfURL = Self.fileURL(for: document)
        let content = await Task.detached(priority: .userInitiated) {
            ExtractionPipeline.addingChapters(to: cached, pdfURL: pdfURL)
        }.value
        guard documents.contains(where: { $0.id == document.id }) else { return content }
        let url = Self.contentCacheURL(for: document.id)
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(content) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
        // Deleted while the cache was written: the write must not bring
        // the file back (back on the main actor, as delete is).
        if !documents.contains(where: { $0.id == document.id }) {
            try? FileManager.default.removeItem(at: url)
        }
        return content
    }

    /// The Continue card's and the Continue listening shortcut's loader: the
    /// content plus the record as it is now (a reconcile may have reset its
    /// progress meanwhile). Throws CancellationError when the book was
    /// deleted while it loaded, which both callers treat as silent.
    func liveContent(for document: LibraryDocument) async throws -> (document: LibraryDocument, content: DocContent) {
        let content = try await self.content(for: document)
        // Deleted while it loaded: nothing to play, nothing to report.
        guard let live = documents.first(where: { $0.id == document.id }) else {
            throw CancellationError()
        }
        return (live, content)
    }

    // MARK: - Continue listening

    /// Pure selection (R18): the book loaded in the player when it is on the
    /// shelf, at any progress, Finished too, since the card is where it plays
    /// outside the reader. Otherwise the most recently listened in-progress
    /// document: opened (`lastOpenedAt != nil`), started
    /// (`progressFraction > 0`) and not Finished (`LibraryDocument.isFinished`,
    /// the one rule the shelf, the card and autoplay share). Ties and order
    /// resolve by `lastOpenedAt` alone, never `addedAt`. Static and
    /// nonisolated so it's unit-testable without a store.
    nonisolated static func continueListeningCandidate(
        in documents: [LibraryDocument],
        loadedID: UUID? = nil
    ) -> LibraryDocument? {
        if let loadedID, let loaded = documents.first(where: { $0.id == loadedID }) {
            return loaded
        }
        return documents
            .filter {
                $0.lastOpenedAt != nil
                    && $0.progressFraction > 0
                    && !$0.isFinished
            }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: - Progress

    /// Updates in-memory progress immediately; the disk write follows within
    /// `saveInterval` (2 s), even while progress keeps coming, and is forced
    /// through on background and termination. One element write, so one
    /// publish of `documents` per tick, not one per field.
    func saveProgress(id: UUID, sentence: Int, fraction: Double) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var document = documents[index]
        document.progressSentence = sentence
        document.progressFraction = fraction
        document.lastOpenedAt = Date()
        documents[index] = document
        scheduleDebouncedSave()
    }

    /// Marks a document as opened (drives last-listened sort on the shelf).
    func noteOpened(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].lastOpenedAt = Date()
        sortDocuments()
        persistIndex()
    }

    /// Mark as finished (R12g). Written at once, not debounced: it is a
    /// deliberate action, not a playback tick. `lastOpenedAt` and the shelf
    /// order stay put, because finishing a book isn't listening to it.
    func markFinished(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index] = Self.markingFinished(documents[index])
        persistIndex()
    }

    /// The record at its end: progress 1.0 at the last sentence. Pure, for
    /// the unit tests.
    nonisolated static func markingFinished(_ document: LibraryDocument) -> LibraryDocument {
        var finished = document
        finished.progressFraction = 1.0
        finished.progressSentence = max(document.sentenceCount - 1, 0)
        return finished
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

    #if DEBUG
    /// Destructive: removes the whole on-disk library (documents, content
    /// caches, index) and the thumbnail cache.
    ///
    /// Backing the `-uitest-reset-library` hook, and called explicitly from
    /// the composition root before the store is built — constructing a store
    /// never destroys data as a side effect, and every test hook stays
    /// auditable in one place. Debug-only: no Release build can reach it.
    static func wipeAllData() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: thumbnailsDir)
    }
    #endif

    // MARK: - Paths

    static var libraryDir: URL {
        let dir = PlatformPaths.libraryRoot
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
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? Self.decoder.decode(LibraryIndex.self, from: data)
        else { return }
        documents = index.documents
        schemaVersion = index.version
        sortDocuments()
    }

    private func persistIndex() {
        let index = LibraryIndex(version: schemaVersion, documents: documents)
        guard let data = try? Self.encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Throttles the atomic index write behind high-frequency updates
    /// (progress): the first change arms one write `saveInterval` later, and
    /// changes meanwhile ride along with it. Not a trailing debounce: at 2-3x
    /// a run of short sentences changes progress more often than every 2 s,
    /// and a debounce restarted by each change never wrote. `flushIndex`
    /// forces it through on background and termination.
    private func scheduleDebouncedSave() {
        guard pendingSave == nil else { return }
        let delay = UInt64(saveInterval * 1_000_000_000)
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            // Cancelled by a flush, which already wrote (and may have a
            // newer write armed since): leave that one alone.
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.persistIndex()
        }
    }

    /// Writes a pending progress save now (playback stopped).
    func flushPendingProgress() {
        guard pendingSave != nil else { return }
        flushIndex()
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

    /// A failed or cancelled import's partial output: content cache and thumbnail.
    private static func removeArtifacts(for id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: contentCacheURL(for: id))
        try? fm.removeItem(at: thumbnailURL(for: id))
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
            try? image.pngDataRepresentation()?.write(to: destination, options: .atomic)
        }.value
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

// MARK: - Shelf layout

/// How the Library splits the shelf: the Continue Listening hero (the loaded
/// book when there is one, see `continueListeningCandidate`) and the grid
/// remainder (hero excluded, store order kept).
///
/// Both halves come out of ONE derivation so a body evaluation never selects
/// the hero twice, and the view memoizes the result against `store.$documents`
/// — LibraryView also re-renders at the playback publish cadence (a word tick
/// several times a second), and the shelf must not be rescanned per tick.
/// Value type, `nonisolated` by construction, so it's unit-testable without a
/// store.
struct ShelfLayout {
    let hero: LibraryDocument?
    let grid: [LibraryDocument]

    /// The shelf before the store's first publish.
    static let empty = ShelfLayout(hero: nil, grid: [])

    init(for documents: [LibraryDocument], loadedID: UUID? = nil) {
        let hero = DocumentStore.continueListeningCandidate(in: documents, loadedID: loadedID)
        self.hero = hero
        self.grid = hero.map { hero in documents.filter { $0.id != hero.id } } ?? documents
    }

    private init(hero: LibraryDocument?, grid: [LibraryDocument]) {
        self.hero = hero
        self.grid = grid
    }
}

/// No user-facing text here: the importer maps it to ImportFailure's copy.
enum DocumentStoreError: Error {
    case bundledBookMissing(String)
}
