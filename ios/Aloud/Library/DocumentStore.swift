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
            return existing
        }
        // Cancelled while hashing: nothing to clean up yet.
        try Task.checkCancellation()
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
            return existing
        }
        try Task.checkCancellation()
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
        try? persistIndex()
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
        try? persistIndex()
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
    /// (`progressFraction > 0`) and not at its end (`isAtItsEnd`: Finished,
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
                    && $0.progressFraction > 0
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
        try? persistIndex()
    }

    /// Mark as finished (R12g). Written at once, not debounced: it is a
    /// deliberate action, not a playback tick. `lastOpenedAt` and the shelf
    /// order stay put, because finishing a book isn't listening to it.
    func markFinished(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index] = Self.markingFinished(documents[index])
        try? persistIndex()
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

    /// Removes the book: its record from library.json, then its files. The
    /// files go only once library.json no longer lists the book: a record
    /// the write missed would name files that are gone. A write that fails
    /// (out of space, most likely: the disk a Delete is meant to clear) is
    /// tried once more after the book's caches go, which frees room and is
    /// rebuilt if the book stays. Throws, the book and its file as they
    /// were, when the index still can't record it, and while an unreadable
    /// one is kept. The shelf publishes only the outcome, so nothing
    /// watching it (the place history's sweep) acts on a delete that didn't
    /// happen.
    func delete(_ document: LibraryDocument) throws {
        let remaining = documents.filter { $0.id != document.id }
        do {
            try persistIndex(remaining)
        } catch let unreadable as LibraryIndexError {
            throw unreadable
        } catch {
            removeCaches(of: document.id)
            try persistIndex(remaining)
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

    func rename(_ document: LibraryDocument, to newTitle: String) {
        guard let title = Self.renamedTitle(newTitle),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].title = title
        try? persistIndex()
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

    static func contentCacheURL(for id: UUID) -> URL {
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
    /// (F038). The link's target is copied as a regular file instead.
    static func copyFile(from source: URL, to destination: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let resolved = source.resolvingSymlinksInPath()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: resolved, to: destination)
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
/// written over it. Not a DocumentStoreError: an add it stops reads as
/// "couldn't be opened", not as a missing classic.
enum LibraryIndexError: Error {
    case unreadable
}
