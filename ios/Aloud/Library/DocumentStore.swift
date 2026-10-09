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
    // v3: classics added under a catalog title since shortened for the
    // shelf take the shorter one, once (`retitlingClassics`).
    private static let indexVersion = 3
    /// The version the loaded library.json carries, written back by every
    /// persist, so a v1 library is never stamped v2 before its backfill runs.
    private var schemaVersion = DocumentStore.indexVersion
    /// The launch backfill of sourceHash, while it runs. Imports wait for it,
    /// so an Open-in that launched the app still finds the old record.
    private var sourceHashBackfill: Task<Void, Never>?
    /// Whether library.json was read, or there is none yet. False for one
    /// that exists but can't be read (a newer build's record, a damaged
    /// file): nothing is written over it while this process lives, the
    /// shelf shows the records that still decode, and a copy is set aside
    /// (`unreadableIndexURL`). An empty or partial shelf written over it
    /// would lose every record it couldn't read, and the next launch's
    /// sweep their books' files.
    private(set) var isIndexReadable = true
    /// How library.json is written: atomically, in place. The unit tests
    /// swap in a write that fails as a full disk's does.
    var writeIndexData: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
    /// Asked just before a book added again is given its new extraction
    /// (`refreshingExtraction`): false keeps the old one, as for a book open
    /// in a reader, which shows the old text. The app lets the player go of
    /// the book here, so no progress the old text indexes lands after.
    var mayReplaceContent: (UUID) -> Bool = { _ in true }
    /// Told once a book added again has its new extraction, with the content
    /// it had and the one it has now, before the add returns: what else
    /// indexes the old text (its place history) is carried across here, so
    /// the reader opens on it (`AppModel.carryPlaces`).
    var didReplaceContent: @MainActor (_ id: UUID, _ old: DocContent, _ new: DocContent) async -> Void = { _, _, _ in }
    /// Awaited just before a chapter backfill writes its cache
    /// (`backfillChapters`): the unit tests land a refresh there.
    var willWriteBackfill: @MainActor () async -> Void = {}
    /// Awaited just after an open reads its cache off the main actor
    /// (`content(for:)`): the unit tests land a refresh there.
    var didReadContentCache: @MainActor () async -> Void = {}
    /// Bumped by each cache write a read under way off the main actor, or a
    /// chapter backfill under way, must not undo: a refresh's, a declined
    /// one's stamp, or a backfill's chapter map (`settledContentCache`).
    private var cacheWrites: [UUID: Int] = [:]

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
        isIndexReadable = loadIndex()
        // The app's own library only, and never in hosted unit tests: their
        // stores keep their records elsewhere but their files here.
        if indexURL == nil, isIndexReadable, NSClassFromString("XCTestCase") == nil {
            Self.removeOrphanedFiles(in: Self.libraryDir, keeping: documents)
        }

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
            return try await refreshingExtraction(of: existing, progress: progress)
        }
        // Cancelled while hashing: nothing to clean up yet.
        try Task.checkCancellation()
        // An index that can't be read can't record the book: refused before
        // the copy and the extraction, which could take minutes.
        guard isIndexReadable else { throw LibraryIndexError.unreadable }
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).pdf")

        do {
            // Inside the cleanup: a copy that fails partway leaves nothing.
            try await Self.copyFile(from: url, to: destination)
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
            try insert(document)
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
            return try await refreshingExtraction(of: existing, progress: progress)
        }
        try Task.checkCancellation()
        guard isIndexReadable else { throw LibraryIndexError.unreadable }
        let id = UUID()
        let destination = Self.libraryDir.appendingPathComponent("\(id.uuidString).txt")

        do {
            // Inside the cleanup: a copy that fails partway leaves nothing.
            try await Self.copyFile(from: url, to: destination)
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
            try insert(document)
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
        try? persistIndex()
        return documents[index]
    }

    /// Adds a bundled classic to the library. Offline; never adds a second
    /// copy. The record already linked by gutenbergID wins (so a renamed
    /// classic still opens), given this build's extraction when an older
    /// extractor cached it, as the same file added again is
    /// (`refreshingExtraction`, from its library copy); otherwise the
    /// bundled text is imported, and a duplicate already on the shelf (same
    /// bytes or same text) is linked instead of added.
    func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
        if let existing = document(forGutenbergID: book.gutenbergID) {
            return try await refreshingExtraction(of: existing, progress: nil)
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
        try? persistIndex()
        return documents[index]
    }

    // MARK: - Gutenberg backfill (library.json v1 → v2 → v3)

    /// One-shot migrations, each once: links classics added before v2 to
    /// their catalog entry, then gives classics added under a title the
    /// catalog has since shortened the shelf's title (v3), and stamps the
    /// library v3. A no-op on v3, and with an empty catalog (the library
    /// keeps its version and is retried next launch).
    func backfillGutenbergIDsIfNeeded(catalog: [BookshelfBook]) {
        guard schemaVersion < Self.indexVersion, !catalog.isEmpty else { return }
        if schemaVersion < 2 {
            documents = Self.backfillingGutenbergIDs(in: documents, catalog: catalog)
        }
        documents = Self.retitlingClassics(in: documents, catalog: catalog)
        schemaVersion = Self.indexVersion
        try? persistIndex()
    }

    /// Links each unlinked text record with an author to the first catalog
    /// book whose author matches (catalog or Gutenberg-header spelling) and
    /// whose title matches any of its spellings, or, for a renamed record,
    /// whose word count matches. Only records still carrying the header or
    /// the full spelling get the shelf's title or author; a user's rename
    /// is kept.
    nonisolated static func backfillingGutenbergIDs(in documents: [LibraryDocument],
                                                    catalog: [BookshelfBook]) -> [LibraryDocument] {
        documents.map { document in
            guard document.kind == .text, document.gutenbergID == nil,
                  let author = document.author else { return document }
            let match = catalog.first { book in
                (author == book.author || author == book.headerAuthor)
                    && (document.title == book.title
                        || isEarlierCatalogTitle(document.title, of: book)
                        || (document.wordCount > 0 && document.wordCount == book.words))
            }
            guard let book = match else { return document }
            var linked = document
            linked.gutenbergID = book.gutenbergID
            if isEarlierCatalogTitle(document.title, of: book) { linked.title = book.title }
            if author == book.headerAuthor { linked.author = book.author }
            return linked
        }
    }

    /// v3: each linked classic still titled as an earlier catalog had it
    /// (its full title, before the shelf shortened it, or the Gutenberg
    /// header's) takes the catalog's title now. Any other title is the
    /// listener's own rename, and is kept.
    nonisolated static func retitlingClassics(in documents: [LibraryDocument],
                                              catalog: [BookshelfBook]) -> [LibraryDocument] {
        let books = Dictionary(catalog.map { ($0.gutenbergID, $0) }, uniquingKeysWith: { first, _ in first })
        return documents.map { document in
            guard let id = document.gutenbergID, let book = books[id], document.title != book.title,
                  isEarlierCatalogTitle(document.title, of: book) else { return document }
            var retitled = document
            retitled.title = book.title
            return retitled
        }
    }

    /// Whether a record's title is one an earlier catalog gave the book: its
    /// full title or the Gutenberg header's, in any capitals. A curated
    /// title of an earlier build could differ from today's full title in
    /// its capitals alone (#25525's "The" against "the"), and was never the
    /// listener's rename.
    nonisolated static func isEarlierCatalogTitle(_ title: String, of book: BookshelfBook) -> Bool {
        [book.fullTitle, book.headerTitle].contains { spelling in
            spelling.map { title.caseInsensitiveCompare($0) == .orderedSame } ?? false
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
            try? persistIndex()
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
    /// The cache is read and decoded off the main actor (a long book's is
    /// megabytes); a refresh that wrote it meanwhile (`cacheWrites`) is read
    /// again, so the reconcile after weighs the newer content and keeps the
    /// place the refresh carried.
    func content(for document: LibraryDocument) async throws -> DocContent {
        let id = document.id
        if var cached = await settledContentCache(for: id) {
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
        // Best-effort, encoded and written off the main actor: a book that
        // extracted opens, on a full disk too, and is extracted again on
        // its next open.
        await Task.detached(priority: .userInitiated) {
            try? Self.writeContentCache(content, for: id)
        }.value
        reconcile(document, against: content)
        return content
    }

    /// The cached content, read and decoded off the main actor; nil when
    /// there is none or it doesn't decode.
    private nonisolated static func loadContentCache(for id: UUID) async -> DocContent? {
        await Task.detached(priority: .userInitiated) { readContentCache(for: id) }.value
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
    /// cache; two loads at once write the same result. A refresh that wrote
    /// the cache meanwhile (`cacheWrites`) keeps its newer one, which is
    /// returned instead: the old text written over it would undo the
    /// refresh, and the reconcile reset its place. Encoded off the main
    /// actor, written on it, where neither check can go stale before the
    /// write. Off the extraction pipeline, so opening a book never waits
    /// behind an import.
    private func backfillChapters(_ cached: DocContent, for document: LibraryDocument) async -> DocContent {
        let writes = cacheWrites[document.id, default: 0]
        let pdfURL = Self.fileURL(for: document)
        let (content, data) = await Task.detached(priority: .userInitiated) { () -> (DocContent, Data?) in
            let content = ExtractionPipeline.addingChapters(to: cached, pdfURL: pdfURL)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return (content, try? encoder.encode(content))
        }.value
        await willWriteBackfill()
        guard cacheWrites[document.id, default: 0] == writes else {
            return await settledContentCache(for: document.id) ?? content
        }
        guard let data, documents.contains(where: { $0.id == document.id }) else { return content }
        try? data.write(to: Self.contentCacheURL(for: document.id), options: .atomic)
        cacheWrites[document.id, default: 0] += 1
        return content
    }

    /// The cache, read and decoded off the main actor, as it stands once no
    /// tracked write (`cacheWrites`) landed while it was read: one that did
    /// is read again, so a refresh's newer content is never weighed as the
    /// old one, nor written back over it.
    private func settledContentCache(for id: UUID) async -> DocContent? {
        var writes = cacheWrites[id, default: 0]
        var loaded = await Self.loadContentCache(for: id)
        await didReadContentCache()
        while cacheWrites[id, default: 0] != writes {
            writes = cacheWrites[id, default: 0]
            loaded = await Self.loadContentCache(for: id)
        }
        return loaded
    }

    // MARK: - Extraction fixes for books on the shelf

    /// The same file added again, for a book whose cached content an older
    /// extractor wrote (`DocContent.extractorVersion`): it is extracted
    /// again from its library copy, so this build's fixes reach it, and its
    /// place is carried across by its text (`carriedPlace`). A place that
    /// can't be found in the new text, an extraction that fails, or an index
    /// that can't record it keeps the old content and the place as they
    /// were; the first two for good (`keepingOldExtraction`). Only here,
    /// where the user asked for the file again, never on an open. The index
    /// is written before the cache, and put back if the cache can't be: a
    /// record and a cache that disagree reset progress. The book's place
    /// history is then carried across (`didReplaceContent`).
    private func refreshingExtraction(of document: LibraryDocument,
                                      progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
        guard isIndexReadable,
              let cached = await settledContentCache(for: document.id),
              (cached.extractorVersion ?? 0) < DocContent.currentExtractorVersion else { return document }
        let fileURL = Self.fileURL(for: document)
        let fresh: DocContent
        do {
            switch document.kind {
            case .pdf:
                fresh = try await pipeline.extract(pdfURL: fileURL, fallbackTitle: document.title, progress: progress)
            case .text:
                fresh = try await pipeline.extractText(fileURL: fileURL, title: document.title, progress: progress)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await keepingOldExtraction(cached, of: document.id)
            return documents.first { $0.id == document.id } ?? document
        }
        try Task.checkCancellation()
        // As the shelf has it now: played, renamed or deleted meanwhile.
        guard var live = documents.first(where: { $0.id == document.id }) else { return document }
        if fresh.contentHash == cached.contentHash, live.contentHash == cached.contentHash {
            // The fixes didn't change this book's text: stamped, as it is.
            cacheWrites[document.id, default: 0] += 1
            try? Self.writeContentCache(fresh, for: document.id)
            return live
        }
        // Off the main actor: the whole text of both, for a long book.
        var place = await Self.carriedPlaceOffMain(of: live, from: cached, to: fresh)
        guard place != nil else {
            await keepingOldExtraction(cached, of: document.id)
            return live
        }
        guard mayReplaceContent(document.id),
              let current = documents.first(where: { $0.id == document.id }) else { return live }
        if current.progressSentence != live.progressSentence || current.progressFraction != live.progressFraction {
            // Played on while the place was found (the player has let go now).
            live = current
            place = await Self.carriedPlaceOffMain(of: live, from: cached, to: fresh)
        }
        guard let place, let index = documents.firstIndex(where: { $0.id == document.id }),
              documents[index].progressSentence == live.progressSentence,
              documents[index].progressFraction == live.progressFraction else {
            return documents.first { $0.id == document.id } ?? live
        }
        let before = documents[index]
        var refreshed = before
        refreshed.contentHash = fresh.contentHash
        refreshed.sentenceCount = fresh.sentences.count
        refreshed.pageCount = fresh.pageCount
        refreshed.progressSentence = place.sentence
        refreshed.progressFraction = place.fraction
        // A place kept by Mark as Finished counts the old text's sentences.
        refreshed.placeBeforeFinish = nil
        refreshed.fractionBeforeFinish = nil
        // A classic's count is the catalog's (see `link`).
        if refreshed.gutenbergID == nil { refreshed.wordCount = fresh.wordCount }
        documents[index] = refreshed
        do {
            try persistIndex()
            cacheWrites[document.id, default: 0] += 1
            try Self.writeContentCache(fresh, for: document.id)
        } catch {
            if let index = documents.firstIndex(where: { $0.id == document.id }) { documents[index] = before }
            try? persistIndex()
            return before
        }
        await didReplaceContent(document.id, cached, fresh)
        return refreshed
    }

    /// A refresh declined for a reason the same file added again won't
    /// change (its new extraction failed, or its place isn't in the new
    /// text): the old cache is stamped as it is, so later adds don't extract
    /// the whole book again only to keep it. Read again (off the main
    /// actor, settled against `cacheWrites`), so a chapter map a backfill
    /// gave it meanwhile stays; one deleted or refreshed meanwhile is left
    /// alone.
    private func keepingOldExtraction(_ cached: DocContent, of id: UUID) async {
        guard let current = await settledContentCache(for: id),
              documents.contains(where: { $0.id == id }),
              current.contentHash == cached.contentHash,
              (current.extractorVersion ?? 0) < DocContent.currentExtractorVersion else { return }
        cacheWrites[id, default: 0] += 1
        try? Self.writeContentCache(current, for: id)
    }

    /// Where `document`'s place in `old` falls in `new`, by text: its
    /// sentence's letters and digits, with those of the sentences after it
    /// until there are enough to tell it apart, found in the new text (the
    /// spacing, line breaks, hyphenation and punctuation an extractor fix
    /// changes are left out), at the match nearest the same share of the
    /// way in. A book at its start stays there, and a finished one stays
    /// finished. Nil when the text isn't found, as when a fixed decoding
    /// changes every letter.
    nonisolated static func carriedPlace(of document: LibraryDocument, from old: DocContent,
                                         to new: DocContent) -> (sentence: Int, fraction: Double)? {
        guard !new.sentences.isEmpty else { return nil }
        if document.progressFraction >= 1 { return (new.sentences.count - 1, 1) }
        if document.progressSentence <= 0 && document.progressFraction <= 0 { return (0, 0) }
        guard let carried = carriedSentences(of: [(document.progressSentence, nil)], from: old, to: new)[0] else {
            return nil
        }
        var wordsBefore = [0]
        for sentence in new.sentences { wordsBefore.append(wordsBefore[wordsBefore.count - 1] + sentence.wordCount) }
        let fraction = PlaybackController.positionFraction(of: carried, wordsBefore: wordsBefore,
                                                           sentenceCount: new.sentences.count)
        return (carried, fraction)
    }

    /// Where each of `places` (a sentence of `old`, and the start of its
    /// text as it was kept, if it was) falls in `new`: the sentence its text
    /// starts in, found as `carriedPlace` finds a book's place, or else by
    /// the kept start of its text alone, at the match nearest the same share
    /// of the way in; nil where neither is found. Both texts' letters are
    /// worked out once, for every place.
    nonisolated static func carriedSentences(of places: [(sentence: Int, excerpt: String?)],
                                             from old: DocContent, to new: DocContent) -> [Int?] {
        guard !new.sentences.isEmpty else { return places.map { _ in nil } }
        let oldLetters = old.sentences.map { placeLetters($0.text) }
        var oldStarts = [0]
        for letters in oldLetters { oldStarts.append(oldStarts[oldStarts.count - 1] + letters.count) }
        let oldTotal = oldStarts[oldStarts.count - 1]
        var newText: [UInt16] = []
        var newStarts: [Int] = []
        for sentence in new.sentences {
            newStarts.append(newText.count)
            newText += placeLetters(sentence.text)
        }
        // The sentence the letter at `offset` falls in.
        func sentence(at offset: Int) -> Int {
            var low = 0, high = newStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if newStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }

        return places.map { place -> Int? in
            if !oldLetters.isEmpty {
                let start = min(max(place.sentence, 0), oldLetters.count - 1)
                let expected = oldTotal > 0 ? Double(oldStarts[start]) / Double(oldTotal) * Double(newText.count) : 0
                // The place's sentence first, then the next two, which step
                // past a running header or page number left in it by an
                // older extractor.
                for anchor in start..<min(start + 3, oldLetters.count) {
                    var key: [UInt16] = []
                    var next = anchor
                    while key.count < 40, next < oldLetters.count {
                        key += oldLetters[next]
                        next += 1
                    }
                    guard key.count >= 8 || (next == oldLetters.count && !key.isEmpty) else { continue }
                    let skipped = oldStarts[anchor] - oldStarts[start]
                    guard let match = nearestMatch(of: key, in: newText, to: expected + Double(skipped)) else {
                        continue
                    }
                    return sentence(at: max(match - skipped, 0))
                }
            }
            guard let excerpt = place.excerpt else { return nil }
            let key = placeLetters(excerpt)
            guard key.count >= 8 else { return nil }
            let share = old.sentences.isEmpty ? 0 : Double(max(place.sentence, 0)) / Double(old.sentences.count)
            return nearestMatch(of: key, in: newText, to: share * Double(newText.count)).map { sentence(at: $0) }
        }
    }

    private nonisolated static func carriedPlaceOffMain(of document: LibraryDocument, from old: DocContent,
                                                        to new: DocContent) async -> (sentence: Int, fraction: Double)? {
        await Task.detached(priority: .userInitiated) {
            carriedPlace(of: document, from: old, to: new)
        }.value
    }

    /// A sentence's letters and digits, lowercased, as UTF-16: what a place
    /// is found by.
    private nonisolated static func placeLetters(_ text: String) -> [UInt16] {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return Array(String(scalars).utf16)
    }

    /// The start of `key` in `text` nearest `expected`, if it occurs.
    private nonisolated static func nearestMatch(of key: [UInt16], in text: [UInt16], to expected: Double) -> Int? {
        guard !key.isEmpty, key.count <= text.count, let first = key.first else { return nil }
        var best: Int?
        var position = 0
        let last = text.count - key.count
        while position <= last {
            if text[position] == first, text[position..<(position + key.count)].elementsEqual(key) {
                if best.map({ abs(Double(position) - expected) < abs(Double($0) - expected) }) ?? true {
                    best = position
                }
            }
            position += 1
        }
        return best
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
    /// document: opened (`lastOpenedAt != nil`), started (heard,
    /// `firstPlayedAt`, which a book stopped inside its first sentence has
    /// at progress 0; `progressFraction > 0`; or the book `stop` names) and
    /// not at its end (`isAtItsEnd`: Finished,
    /// the one rule the shelf, the card and autoplay share, unless `stop`,
    /// the controller's unattended stop, holds it at its sentence). Ties and
    /// order resolve by `lastOpenedAt` alone, never `addedAt`. Static and
    /// nonisolated so it's unit-testable without a store.
    nonisolated static func continueListeningCandidate(
        in documents: [LibraryDocument],
        loadedID: UUID? = nil,
        stop: PlaybackStop? = nil
    ) -> LibraryDocument? {
        if let loadedID, let loaded = documents.first(where: { $0.id == loadedID }) {
            return loaded
        }
        return documents
            .filter {
                $0.lastOpenedAt != nil
                    && ($0.progressFraction > 0 || $0.firstPlayedAt != nil || stop?.documentID == $0.id)
                    && !isAtItsEnd($0, stop: stop)
            }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    /// Whether a book that isn't loaded opens at its end (R24), by the
    /// controller's own rule (`PlaybackController.reopensAtItsEnd`): Finished,
    /// unless `stop` names it short of a stored 1.0. A sleep timer that
    /// stopped it in its last minute promised one tap resumes there, after a
    /// relaunch too, so Continue, remote Play and the launch restore still
    /// offer it.
    nonisolated static func isAtItsEnd(_ document: LibraryDocument, stop: PlaybackStop?) -> Bool {
        PlaybackController.reopensAtItsEnd(document,
                                           stop: stop?.documentID == document.id ? stop?.reason : nil)
    }

    // MARK: - Progress

    /// Updates in-memory progress immediately; the disk write follows within
    /// `saveInterval` (2 s), even while progress keeps coming, and is forced
    /// through on background and termination. One element write, so one
    /// publish of `documents` per tick, not one per field. A write that
    /// moves the place forgets the one kept by Mark as Finished
    /// (`placeBeforeFinish`), which would otherwise be stale; one that
    /// leaves it where it is (a finished book reopened at its end) keeps it.
    func saveProgress(id: UUID, sentence: Int, fraction: Double) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var document = documents[index]
        if sentence != document.progressSentence || fraction != document.progressFraction {
            document.placeBeforeFinish = nil
            document.fractionBeforeFinish = nil
        }
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
        try? persistIndex()
    }

    /// The book was heard: playback ran for it (`firstPlayedAt`, once).
    /// Saved with the next progress write.
    func notePlayed(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              documents[index].firstPlayedAt == nil else { return }
        documents[index].firstPlayedAt = Date()
        scheduleDebouncedSave()
    }

    /// Mark as finished (R12g). Written at once, not debounced: it is a
    /// deliberate action, not a playback tick. `lastOpenedAt` and the shelf
    /// order stay put, because finishing a book isn't listening to it.
    /// Throws, the book as it was, when library.json can't record it (out
    /// of space, or an unreadable one kept): it would be gone next launch.
    func markFinished(id: UUID) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        try changeRecord(at: index, to: Self.markingFinished(documents[index]))
    }

    /// Sets the record at `index` and writes the index, or puts the record
    /// back and throws when the write fails.
    private func changeRecord(at index: Int, to changed: LibraryDocument) throws {
        let before = documents[index]
        documents[index] = changed
        do {
            try persistIndex()
        } catch {
            documents[index] = before
            throw error
        }
    }

    /// The record at its end: progress 1.0 at the last sentence. The place
    /// it had is kept for Mark as Unfinished, unless it was already at its
    /// end (a book that finished by playing has no place to go back to).
    /// Pure, for the unit tests.
    nonisolated static func markingFinished(_ document: LibraryDocument) -> LibraryDocument {
        var finished = document
        if document.progressFraction < 1 {
            finished.placeBeforeFinish = document.progressSentence
            finished.fractionBeforeFinish = document.progressFraction
        }
        finished.progressFraction = 1.0
        finished.progressSentence = max(document.sentenceCount - 1, 0)
        return finished
    }

    /// Mark as Unfinished: a finished book back at the place it had.
    /// Written at once, as `markFinished` is, and throws, the book as it
    /// was, when library.json can't record it. `newestPlace` is the
    /// sentence of the book's newest place-history stop
    /// (`PlaceHistoryStore.places`), the place to go back to when the mark
    /// kept none.
    func markUnfinished(id: UUID, newestPlace: Int? = nil) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        try changeRecord(at: index, to: Self.markingUnfinished(documents[index], newestPlace: newestPlace))
    }

    /// The record back where it was before Mark as Finished: the place the
    /// mark kept, else `newestPlace` (a sentence of the book's current
    /// content) short of the end, else its start. The newest stop of a book
    /// that played to its end is that end: one within
    /// `PlaceHistory.samePlaceSentences` of the last sentence (or past it)
    /// is no way back, nor is any place that would still read Finished, so
    /// a book that finished by playing returns to the start, however short.
    /// The kept place goes either way. Pure, for the unit tests.
    nonisolated static func markingUnfinished(_ document: LibraryDocument,
                                              newestPlace: Int? = nil) -> LibraryDocument {
        var unfinished = document
        let last = max(document.sentenceCount - 1, 0)
        if let sentence = document.placeBeforeFinish, let fraction = document.fractionBeforeFinish {
            unfinished.progressSentence = min(max(sentence, 0), last)
            unfinished.progressFraction = min(max(fraction, 0), 1)
        } else if let sentence = newestPlace, document.sentenceCount > 0,
                  sentence < last - PlaceHistory.samePlaceSentences {
            let place = max(sentence, 0)
            unfinished.progressSentence = place
            unfinished.progressFraction = Double(place) / Double(document.sentenceCount)
        } else {
            unfinished.progressSentence = 0
            unfinished.progressFraction = 0
        }
        if unfinished.isFinished {
            unfinished.progressSentence = 0
            unfinished.progressFraction = 0
        }
        unfinished.placeBeforeFinish = nil
        unfinished.fractionBeforeFinish = nil
        return unfinished
    }

    // MARK: - Mutation

    /// Removes the book: its record from library.json, then its files. The
    /// files go only once library.json no longer lists the book: a record
    /// the write missed would name files that are gone. A write that fails
    /// (out of space, most likely: the disk a Delete is meant to clear) is
    /// tried once more after the book's caches go, which frees room. Throws,
    /// the book, its file and its content cache as they were, when the index
    /// still can't record it, and while an unreadable one is kept: the
    /// cache, held in memory meanwhile, is put back, since one extracted
    /// again under a newer extractor would reset the book's place. The shelf
    /// publishes only the outcome, so nothing watching it (the place
    /// history's sweep) acts on a delete that didn't happen.
    func delete(_ document: LibraryDocument) throws {
        let remaining = documents.filter { $0.id != document.id }
        do {
            try persistIndex(remaining)
        } catch let unreadable as LibraryIndexError {
            throw unreadable
        } catch {
            let cacheURL = Self.contentCacheURL(for: document.id)
            let kept = try? Data(contentsOf: cacheURL)
            removeCaches(of: document.id)
            do {
                try persistIndex(remaining)
            } catch {
                // Back in the room the failed write left free; a partial
                // one is removed, and the book extracts on its next open.
                if let kept, (try? kept.write(to: cacheURL)) == nil {
                    try? FileManager.default.removeItem(at: cacheURL)
                }
                throw error
            }
        }
        documents = remaining

        try? FileManager.default.removeItem(at: Self.libraryDir.appendingPathComponent(document.fileName))
        removeCaches(of: document.id)
    }

    /// The book's extracted content and thumbnail, both rebuilt from its file.
    private func removeCaches(of id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.contentCacheURL(for: id))
        try? fm.removeItem(at: Self.thumbnailURL(for: id))
    }

    /// Throws, the title as it was, when library.json can't record it, as
    /// Mark as finished does.
    func rename(_ document: LibraryDocument, to newTitle: String) throws {
        guard let title = Self.renamedTitle(newTitle),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        var renamed = documents[index]
        renamed.title = title
        try changeRecord(at: index, to: renamed)
    }

    /// The title a rename saves: the text trimmed, or nil when nothing is
    /// left, which keeps the old title. Rename's Save is off while it's nil,
    /// so Save never closes the alert on a change that isn't made.
    nonisolated static func renamedTitle(_ text: String) -> String? {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
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

    nonisolated static var libraryDir: URL {
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

    nonisolated static func contentCacheURL(for id: UUID) -> URL {
        libraryDir.appendingPathComponent("\(id.uuidString).content.json")
    }

    // MARK: - Private

    private struct LibraryIndex: Codable {
        var version: Int
        var documents: [LibraryDocument]
    }

    /// Throws, with the shelf as it was, when library.json can't record
    /// the book (out of space, or an unreadable index kept): an add the
    /// index missed would be gone next launch, and its files swept, while
    /// the importer had announced it.
    private func insert(_ document: LibraryDocument) throws {
        let shelf = documents
        documents.append(document)
        sortDocuments()
        do {
            try persistIndex()
        } catch {
            documents = shelf
            throw error
        }
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
        documents[index].placeBeforeFinish = nil
        documents[index].fractionBeforeFinish = nil
        documents[index].sentenceCount = content.sentences.count
        documents[index].pageCount = content.pageCount
        try? persistIndex()
    }

    /// Whether the shelf on disk is known: true once library.json is read,
    /// or when there is none yet (nothing was ever added); false for one
    /// that exists but can't be read (a record of a kind a newer build
    /// added, a damaged file). That one stays as it is, with a copy set
    /// aside, and the shelf shows the records that still decode.
    private func loadIndex() -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: indexURL) else {
            guard fm.fileExists(atPath: indexURL.path) else { return true }
            if !fm.fileExists(atPath: unreadableIndexURL.path) {
                try? fm.copyItem(at: indexURL, to: unreadableIndexURL)
            }
            return false
        }
        if let index = try? Self.decoder.decode(LibraryIndex.self, from: data) {
            documents = index.documents
            schemaVersion = index.version
            sortDocuments()
            return true
        }
        try? data.write(to: unreadableIndexURL, options: .atomic)
        if let partial = try? Self.decoder.decode(PartialIndex.self, from: data) {
            documents = partial.documents
            schemaVersion = partial.version ?? Self.indexVersion
            sortDocuments()
        }
        return false
    }

    /// Where an unreadable library.json's copy is set aside, beside it:
    /// `library.unreadable.json`. No UUID starts the name, so the launch
    /// sweep keeps it.
    var unreadableIndexURL: URL {
        indexURL.deletingLastPathComponent()
            .appendingPathComponent(indexURL.deletingPathExtension().lastPathComponent + ".unreadable.json")
    }

    /// What an unreadable library.json still gives: each record that decodes
    /// on its own. One record a newer build wrote (a kind this one lacks)
    /// fails the whole index, never its neighbours.
    private struct PartialIndex: Decodable {
        var version: Int?
        var documents: [LibraryDocument]

        private enum CodingKeys: String, CodingKey { case version, documents }

        /// Any value at all: steps past a record that doesn't decode.
        private struct Skipped: Decodable {
            init(from decoder: Decoder) {}
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
            var records = try container.nestedUnkeyedContainer(forKey: .documents)
            var documents: [LibraryDocument] = []
            while !records.isAtEnd {
                if let document = try? records.decode(LibraryDocument.self) {
                    documents.append(document)
                } else {
                    _ = try records.decode(Skipped.self)
                }
            }
            self.documents = documents
        }
    }

    /// Launch: a book's files (`<UUID>.pdf`, `.txt`, `.content.json`) that
    /// no record claims are removed. An add the process didn't live through
    /// (iOS ended it while the Adding card showed, Quit on the Mac) leaves
    /// its copy and cache behind, never on the shelf and out of the
    /// listener's reach. Only names that start with a UUID no record has,
    /// and no record's file name: library.json, places.json and anything
    /// else stay. Only after the index was read (`loadIndex`): one that
    /// can't be read claims nothing, and its books must stay. Returns what
    /// was removed.
    @discardableResult
    nonisolated static func removeOrphanedFiles(in folder: URL, keeping documents: [LibraryDocument]) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        let ids = Set(documents.map(\.id))
        let fileNames = Set(documents.map(\.fileName))
        var removed: [URL] = []
        for name in names where !fileNames.contains(name) {
            guard let dot = name.firstIndex(of: "."),
                  let id = UUID(uuidString: String(name[..<dot])), !ids.contains(id) else { continue }
            let url = folder.appendingPathComponent(name)
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// Writes the shelf (`shelf`, or `documents` when nil) to library.json.
    /// Throws, writing nothing, while an unreadable one is kept
    /// (`isIndexReadable`), and when the write fails (out of space): every
    /// later write carries the whole shelf, so a progress tick or flush that
    /// fails is repaired by the next that lands.
    private func persistIndex(_ shelf: [LibraryDocument]? = nil) throws {
        guard isIndexReadable else { throw LibraryIndexError.unreadable }
        let index = LibraryIndex(version: schemaVersion, documents: shelf ?? documents)
        let data = try Self.encoder.encode(index)
        try writeIndexData(data, indexURL)
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
            try? self.persistIndex()
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
        try? persistIndex()
    }

    // MARK: - File helpers (off-main)

    /// A copy of the book itself: copyItem copies a symlink as a link, which
    /// in the library would point outside it, or nowhere once relative
    /// (F038). The link's target is copied as a regular file instead. The
    /// copy never keeps the source's Finder Locked flag (`unlock(_:)`).
    static func copyFile(from source: URL, to destination: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let resolved = source.resolvingSymlinksInPath()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: resolved, to: destination)
            Self.unlock(destination)
        }.value
    }

    /// Clears the Finder Locked (immutable) and append-only flags on `url`.
    /// copyItem carries both over from a locked source, and a locked copy
    /// can never be removed: not by Delete, the launch's orphan sweep nor
    /// the inbox's cleanup, each of which goes on without a word (L004).
    /// Every copy the app makes of a user's file is unlocked here, and a
    /// leftover is unlocked before it is removed.
    nonisolated static func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.immutable: false, .appendOnly: false],
                                               ofItemAtPath: url.path)
    }

    /// Stamped with this build's extractor (`DocContent.extractorVersion`):
    /// every cache written here was just extracted, or kept by a refresh
    /// that declined it for good (`keepingOldExtraction`).
    nonisolated private static func writeContentCache(_ content: DocContent, for id: UUID) throws {
        var stamped = content
        stamped.extractorVersion = DocContent.currentExtractorVersion
        let data = try encoder.encode(stamped)
        try data.write(to: contentCacheURL(for: id), options: .atomic)
    }

    /// A failed or cancelled import's partial output: content cache and thumbnail.
    private static func removeArtifacts(for id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: contentCacheURL(for: id))
        try? fm.removeItem(at: thumbnailURL(for: id))
    }

    nonisolated private static func readContentCache(for id: UUID) -> DocContent? {
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

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
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

    init(for documents: [LibraryDocument], loadedID: UUID? = nil, stop: PlaybackStop? = nil) {
        let hero = DocumentStore.continueListeningCandidate(in: documents, loadedID: loadedID, stop: stop)
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

/// library.json exists but couldn't be read at launch, so nothing is
/// written over it. Not a DocumentStoreError: an add it stops says the
/// library couldn't be read (`ImportFailure.libraryUnreadable`), not that a
/// classic is missing.
enum LibraryIndexError: Error {
    case unreadable
}
