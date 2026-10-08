import CryptoKit
import XCTest
@testable import Aloud

/// Re-opening a file already on the shelf returns that book, even across an
/// extractor change. A record's stored contentHash goes stale when the
/// extractor changes (its cached content is reused), so the store dedupes on
/// sourceHash, the SHA-256 of the file's bytes, first. Records from before
/// sourceHash get it from their library copy at launch. Pure statics and
/// temporary files only: no store instance, so the real shelf is untouched.
@MainActor
final class SourceHashDedupeTests: XCTestCase {

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func record(kind: DocKind = .pdf, contentHash: String = "old-extractor-hash",
                        sourceHash: String? = nil, title: String = "Report") -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "\(UUID().uuidString).pdf",
                        addedAt: Date(timeIntervalSince1970: 0), pageCount: 3, sentenceCount: 40,
                        contentHash: contentHash, kind: kind, sourceHash: sourceHash)
    }

    /// A temporary file holding `data`, removed after the test.
    private func file(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-sourcehash-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Bytes that differ across the 1 MiB read boundary, so a streaming bug
    /// that drops or repeats a chunk changes the hash.
    private func largeData() -> Data {
        Data((0..<(2 * 1_048_576 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    // MARK: - Codable

    /// A record written before sourceHash existed (exactly what an old
    /// library.json holds) still decodes.
    private let oldBlob = """
    {
        "id": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F",
        "title": "Walden",
        "fileName": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F.txt",
        "addedAt": "2025-11-02T09:00:00Z",
        "pageCount": 1,
        "sentenceCount": 4021,
        "progressSentence": 120,
        "progressFraction": 0.03,
        "contentHash": "abc123",
        "kind": "text",
        "wordCount": 114000,
        "gutenbergID": 205
    }
    """

    func testOldIndexBlobDecodesWithoutSourceHash() throws {
        let document = try Self.decoder.decode(LibraryDocument.self, from: Data(oldBlob.utf8))
        XCTAssertNil(document.sourceHash)
        XCTAssertEqual(document.title, "Walden")
        XCTAssertEqual(document.contentHash, "abc123")
        XCTAssertEqual(document.progressSentence, 120)
        XCTAssertEqual(document.gutenbergID, 205)
    }

    func testSourceHashRoundtripsAndNilWritesNoKey() throws {
        var document = try Self.decoder.decode(LibraryDocument.self, from: Data(oldBlob.utf8))
        let untouched = String(decoding: try Self.encoder.encode(document), as: UTF8.self)
        XCTAssertFalse(untouched.contains("sourceHash"), "old records stay byte-stable until hashed")

        document.sourceHash = "feedface"
        let decoded = try Self.decoder.decode(LibraryDocument.self,
                                              from: Self.encoder.encode(document))
        XCTAssertEqual(decoded.sourceHash, "feedface")
        XCTAssertEqual(decoded.id, document.id)
    }

    // MARK: - Hashing

    func testSourceHashIsTheSHA256OfTheBytes() async throws {
        let data = largeData()
        let url = try file(data)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let hash = try await DocumentStore.sourceHash(of: url)
        XCTAssertEqual(hash, expected)
        XCTAssertEqual(hash.count, 64)
    }

    /// The hash names the bytes, not the file: the same content under
    /// another name (the library copy, an Inbox copy) hashes the same, and
    /// one changed byte does not.
    func testSameBytesHashTheSameAndOneByteDiffers() async throws {
        var data = largeData()
        let original = try await DocumentStore.sourceHash(of: try file(data, name: "a.pdf"))
        let copy = try await DocumentStore.sourceHash(of: try file(data, name: "b.pdf"))
        data[data.count - 1] ^= 0xFF
        let edited = try await DocumentStore.sourceHash(of: try file(data, name: "c.pdf"))

        XCTAssertEqual(original, copy)
        XCTAssertNotEqual(original, edited)
    }

    func testMissingFileThrows() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-sourcehash-missing-\(UUID().uuidString)")
        do {
            _ = try await DocumentStore.sourceHash(of: missing)
            XCTFail("an unreadable file has no hash")
        } catch {}
    }

    // MARK: - Dedupe

    /// The bug: a book imported before the extractor rewrite keeps its old
    /// contentHash, so re-opening the same file matched nothing on text and
    /// added a second copy. Its bytes still match.
    func testSameFileMatchesDespiteAStaleContentHash() {
        let shelf = [record(contentHash: "old-extractor-hash", sourceHash: "bytes")]

        XCTAssertNil(DocumentStore.duplicate(of: "new-extractor-hash", kind: .pdf, in: shelf),
                     "the text match alone misses it")
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil,
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id,
                       "found before extraction, by its bytes")
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "new-extractor-hash",
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id)
    }

    func testBytesWinOverAnotherRecordsText() {
        let byText = record(contentHash: "text", title: "Re-saved copy")
        let byBytes = record(contentHash: "stale", sourceHash: "bytes", title: "Original")
        let match = DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "text",
                                               kind: .pdf, in: [byText, byBytes])
        XCTAssertEqual(match?.title, "Original")
    }

    /// Different bytes, same text (a re-saved PDF): still one book.
    func testTextStillMatchesWhenTheBytesDiffer() {
        let shelf = [record(contentHash: "text", sourceHash: "other-bytes")]
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: "text",
                                                  kind: .pdf, in: shelf)?.id, shelf[0].id)
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil,
                                                kind: .pdf, in: shelf),
                     "before extraction only the bytes can match")
    }

    func testKindAndEmptyHashesNeverMatch() {
        let shelf = [record(kind: .text, contentHash: "", sourceHash: "bytes")]
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "bytes", contentHash: nil, kind: .pdf, in: shelf),
                     "a PDF and a text file are never merged")
        XCTAssertNil(DocumentStore.existingCopy(sourceHash: "", contentHash: "", kind: .text,
                                                in: [record(kind: .text, contentHash: "", sourceHash: "")]))
    }

    // MARK: - Launch backfill

    func testBackfillFillsOnlyMissingHashes() {
        let legacy = record(sourceHash: nil, title: "Legacy")
        let hashed = record(sourceHash: "kept", title: "Hashed")
        let missingCopy = record(sourceHash: nil, title: "No copy")
        let hashes = [legacy.id: "legacy-bytes", hashed.id: "would-overwrite"]

        let filled = DocumentStore.fillingSourceHashes(in: [legacy, hashed, missingCopy], from: hashes)

        XCTAssertEqual(filled.map(\.sourceHash), ["legacy-bytes", "kept", nil])
        XCTAssertEqual(filled.map(\.id), [legacy.id, hashed.id, missingCopy.id], "order and records kept")
        XCTAssertEqual(filled[0].contentHash, legacy.contentHash, "nothing else changes")
    }

    /// End to end over real files: a PDF and a text file added before this
    /// release, each with a stale contentHash and no sourceHash. The
    /// backfill hashes their library copies; re-picking the same files
    /// (another path, same bytes) then finds both before extraction.
    func testBackfilledRecordsAreFoundWhenTheSameFilesAreOpenedAgain() async throws {
        let pdfBytes = largeData()
        let textBytes = Data("Call me Ishmael. Some years ago, never mind how long precisely.".utf8)
        let pdf = record(kind: .pdf, contentHash: "stale-pdf")
        let text = record(kind: .text, contentHash: "stale-text", title: "Moby Dick")
        let libraryCopies = [pdf.id: try file(pdfBytes, name: "\(pdf.id).pdf"),
                             text.id: try file(textBytes, name: "\(text.id).txt")]

        var hashes: [UUID: String] = [:]
        for (id, url) in libraryCopies { hashes[id] = try await DocumentStore.sourceHash(of: url) }
        let shelf = DocumentStore.fillingSourceHashes(in: [pdf, text], from: hashes)

        let pickedPDF = try await DocumentStore.sourceHash(of: try file(pdfBytes, name: "report.pdf"))
        let pickedText = try await DocumentStore.sourceHash(of: try file(textBytes, name: "moby.txt"))
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: pickedPDF, contentHash: nil,
                                                  kind: .pdf, in: shelf)?.id, pdf.id)
        XCTAssertEqual(DocumentStore.existingCopy(sourceHash: pickedText, contentHash: nil,
                                                  kind: .text, in: shelf)?.id, text.id)
    }

    // MARK: - Extraction fixes for books on the shelf (J008)

    /// A store over an index of its own, none yet, removed after the test.
    private func makeStore() -> DocumentStore {
        let index = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-refresh-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: index) }
        return DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
    }

    private func content(_ texts: [String], hash: String) -> DocContent {
        DocContent(title: "Book", pageCount: 1,
                   sentences: texts.enumerated().map { Sentence(id: $0.offset, text: $0.element, para: 0, page: 0) },
                   paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<texts.count, page: 0)],
                   contentHash: hash)
    }

    private let novel = """
        It was a bright cold day in April, and the clocks were striking thirteen. \
        Winston Smith slipped quickly through the glass doors of Victory Mansions. \
        A swirl of gritty dust entered along with him.
        """

    /// What an older extractor made of `novel`: hard-wrapped lines split
    /// mid-sentence, a hyphenated word, other punctuation.
    private var olderSentences: [String] {
        ["It was a bright cold day in April, and the clocks were",
         "striking thir- teen.",
         "Winston Smith slipped quickly through the glass doors of Victory Man-",
         "sions; a swirl of gritty dust entered along with him."]
    }

    /// The place is found by its letters, wherever the new extraction
    /// splits, spaces or hyphenates them; the start stays the start, the
    /// end the end, and text that isn't there (a fixed decoding) is nil.
    func testThePlaceIsCarriedAcrossByItsText() {
        let old = content(olderSentences, hash: "old")
        let new = content(["It was a bright cold day in April, and the clocks were striking thirteen.",
                           "Winston Smith slipped quickly through the glass doors of Victory Mansions.",
                           "A swirl of gritty dust entered along with him."], hash: "new")
        var book = record(kind: .text, contentHash: "old")
        book.progressSentence = 2
        book.progressFraction = 0.5

        let place = DocumentStore.carriedPlace(of: book, from: old, to: new)
        XCTAssertEqual(place?.sentence, 1, "Winston's sentence")
        XCTAssertEqual(place?.fraction ?? -1, Double(new.sentences[0].wordCount) /
                       Double(new.sentences.reduce(0) { $0 + $1.wordCount }), accuracy: 1e-9)

        book.progressSentence = 0
        book.progressFraction = 0
        XCTAssertEqual(DocumentStore.carriedPlace(of: book, from: old, to: new)?.sentence, 0)
        book.progressSentence = 3
        book.progressFraction = 1
        XCTAssertEqual(DocumentStore.carriedPlace(of: book, from: old, to: new)?.sentence, 2)
        XCTAssertEqual(DocumentStore.carriedPlace(of: book, from: old, to: new)?.fraction, 1)

        let mojibake = content(["Ã¤Ã¶Ã¼ ÃŸÃ¤Ã¶ Ã¼Ã¤Ã¶Ã¼.", "Ã¶Ã¼Ã¤ Ã¶Ã¼Ã¤Ã¶ Ã¼Ã¤Ã¶Ã¼Ã¤Ã¶Ã¼ Ã¤Ã¶Ã¼."], hash: "mojibake")
        book.progressSentence = 1
        book.progressFraction = 0.4
        XCTAssertNil(DocumentStore.carriedPlace(of: book, from: mojibake, to: new))
    }

    /// The bug: the same file added again returned the record an older
    /// extractor shelved, its old text and all, and Delete then add was the
    /// only way out, losing the place. Now it is extracted again, its place
    /// carried by text and the new cache stamped; opening it never
    /// re-extracts on its own.
    func testTheSameFileAddedAgainGetsTheNewExtractionAndKeepsItsPlace() async throws {
        let store = makeStore()
        let picked = try file(Data(novel.utf8), name: "\(UUID().uuidString)-novel.txt")
        let added = try await store.importText(title: "Nineteen", from: picked)
        addTeardownBlock { @MainActor in try? store.delete(added) }
        let current = try await store.content(for: added)

        // As an older build shelved it: its cache unstamped, its place in
        // the older text.
        try Self.encoder.encode(content(olderSentences, hash: "older-extractor"))
            .write(to: DocumentStore.contentCacheURL(for: added.id))
        let opened = try await store.content(for: added)
        XCTAssertEqual(opened.contentHash, "older-extractor", "an open never re-extracts")
        store.saveProgress(id: added.id, sentence: 2, fraction: 0.5)

        let again = try await store.importText(title: "Nineteen", from: picked)

        XCTAssertEqual(again.id, added.id, "still one book")
        let live = try XCTUnwrap(store.documents.first { $0.id == added.id })
        XCTAssertEqual(live.contentHash, current.contentHash, "the new extraction")
        let winston = try XCTUnwrap(current.sentences.firstIndex { $0.text.hasPrefix("Winston") })
        XCTAssertEqual(live.progressSentence, winston, "the place, carried by its text")
        let cached = try Self.decoder.decode(DocContent.self,
                                             from: Data(contentsOf: DocumentStore.contentCacheURL(for: added.id)))
        XCTAssertEqual(cached.contentHash, current.contentHash)
        XCTAssertEqual(cached.extractorVersion, DocContent.currentExtractorVersion)
    }

    /// A place that can't be found in the new text keeps the old content
    /// and the place as they were.
    func testAPlaceThatCantBeCarriedKeepsTheOldContent() async throws {
        let store = makeStore()
        let picked = try file(Data(novel.utf8), name: "\(UUID().uuidString)-novel.txt")
        let added = try await store.importText(title: "Nineteen", from: picked)
        addTeardownBlock { @MainActor in try? store.delete(added) }
        let old = content(["Ã¤Ã¶Ã¼ ÃŸÃ¤Ã¶ Ã¼Ã¤Ã¶Ã¼.", "Ã¶Ã¼Ã¤ Ã¶Ã¼Ã¤Ã¶ Ã¼Ã¤Ã¶Ã¼Ã¤Ã¶Ã¼ Ã¤Ã¶Ã¼."], hash: "mojibake")
        try Self.encoder.encode(old).write(to: DocumentStore.contentCacheURL(for: added.id))
        _ = try await store.content(for: added)
        store.saveProgress(id: added.id, sentence: 1, fraction: 0.4)

        _ = try await store.importText(title: "Nineteen", from: picked)

        let live = try XCTUnwrap(store.documents.first { $0.id == added.id })
        XCTAssertEqual(live.contentHash, "mojibake")
        XCTAssertEqual(live.progressSentence, 1)
        let kept = try await store.content(for: live)
        XCTAssertEqual(kept.contentHash, "mojibake", "the old cache is kept")
    }

    // MARK: - Loop 4 re-review (K014, K020, K022, K023)

    /// A store over an index holding `documents`, removed after the test.
    private func makeStore(holding documents: [LibraryDocument]) throws -> DocumentStore {
        let index = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-refresh-\(UUID().uuidString).json")
        let records = try documents.map { try JSONSerialization.jsonObject(with: Self.encoder.encode($0)) }
        try JSONSerialization.data(withJSONObject: ["version": 2, "documents": records]).write(to: index)
        addTeardownBlock { try? FileManager.default.removeItem(at: index) }
        return DocumentStore(indexURL: index, saveInterval: 60, notifications: NotificationCenter())
    }

    private func cache(of id: UUID) throws -> DocContent {
        try Self.decoder.decode(DocContent.self, from: Data(contentsOf: DocumentStore.contentCacheURL(for: id)))
    }

    /// K014: a classic an older build shelved, tapped again on the
    /// Bookshelf, came back through its gutenbergID link before any refresh,
    /// so this build's extraction never reached it. Now it gets it from its
    /// library copy (no bundled file needed), its place carried across, as
    /// the same file added again does.
    func testAClassicTappedAgainGetsTheNewExtraction() async throws {
        let id = UUID()
        let classic = LibraryDocument(id: id, title: "Nineteen", fileName: "\(id.uuidString).txt",
                                      addedAt: Date(timeIntervalSince1970: 0), pageCount: 1,
                                      sentenceCount: olderSentences.count, progressSentence: 2,
                                      progressFraction: 0.5, contentHash: "older-extractor", kind: .text,
                                      gutenbergID: 1063)
        try Data(novel.utf8).write(to: DocumentStore.fileURL(for: classic))
        try Self.encoder.encode(content(olderSentences, hash: "older-extractor"))
            .write(to: DocumentStore.contentCacheURL(for: id))
        let store = try makeStore(holding: [classic])
        addTeardownBlock { @MainActor in try? store.delete(classic) }
        let book = BookshelfBook(gutenbergID: 1063, title: "Nineteen", author: "George Orwell", year: nil,
                                 file: "not-bundled-on-purpose.txt", words: 0)

        let tapped = try await store.addClassic(book)

        XCTAssertEqual(tapped.id, id, "still one book")
        let live = try XCTUnwrap(store.documents.first { $0.id == id })
        let cached = try cache(of: id)
        XCTAssertNotEqual(live.contentHash, "older-extractor", "this build's extraction")
        XCTAssertEqual(live.contentHash, cached.contentHash)
        XCTAssertEqual(cached.extractorVersion, DocContent.currentExtractorVersion)
        let winston = try XCTUnwrap(cached.sentences.firstIndex { $0.text.hasPrefix("Winston") })
        XCTAssertEqual(live.progressSentence, winston, "the place, carried by its text")
    }

    /// K020: the refresh gave the book a new content hash, and its place
    /// history, kept under the old one, vanished from Contents; the next
    /// stop then wrote over it. Now AppModel's wiring carries the places
    /// across before the add returns, each to where its text starts now.
    func testTheSameFileAddedAgainKeepsItsPlaceHistory() async throws {
        let store = makeStore()
        let picked = try file(Data(novel.utf8), name: "\(UUID().uuidString)-novel.txt")
        let added = try await store.importText(title: "Nineteen", from: picked)
        addTeardownBlock { @MainActor in try? store.delete(added) }
        try Self.encoder.encode(content(olderSentences, hash: "older-extractor"))
            .write(to: DocumentStore.contentCacheURL(for: added.id))
        _ = try await store.content(for: added)
        store.saveProgress(id: added.id, sentence: 2, fraction: 0.5)
        let placesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-refresh-places-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: placesURL) }
        let stopped = Date(timeIntervalSince1970: 1_790_000_000)
        let kept = BookPlaces(documentID: added.id, contentHash: "older-extractor", places: [
            PlaceHistoryEntry(sentence: 2, stoppedAt: stopped, excerpt: olderSentences[2]),
            PlaceHistoryEntry(sentence: 0, stoppedAt: stopped.addingTimeInterval(-3600), excerpt: olderSentences[0]),
        ])
        let records = [try JSONSerialization.jsonObject(with: Self.encoder.encode(kept))]
        try JSONSerialization.data(withJSONObject: ["version": 1, "books": records]).write(to: placesURL)
        let history = PlaceHistoryStore(fileURL: placesURL)
        AppModel.carryPlaces(of: store, in: history)

        _ = try await store.importText(title: "Nineteen", from: picked)

        let live = try XCTUnwrap(store.documents.first { $0.id == added.id })
        XCTAssertNotEqual(live.contentHash, "older-extractor", "fixture: the book was refreshed")
        let winston = try XCTUnwrap(try cache(of: added.id).sentences.firstIndex { $0.text.hasPrefix("Winston") })
        let carried = history.places(for: added.id, contentHash: live.contentHash)
        XCTAssertEqual(carried.map(\.sentence), [winston, 0], "each where its text starts now")
        XCTAssertEqual(carried.map(\.stoppedAt), kept.places.map(\.stoppedAt))
        XCTAssertEqual(PlaceHistoryStore(fileURL: placesURL).places(for: added.id, contentHash: live.contentHash)
                           .map(\.sentence), [winston, 0], "on disk")
    }

    /// K022: a chapter backfill that began on a PDF's old cache wrote it
    /// back over the new one a refresh committed meanwhile, and the
    /// reconcile after reset the book to the old text, at its start. Now
    /// the refresh's newer cache stays, and the open gets it.
    func testAChapterBackfillNeverWritesOverANewerCache() async throws {
        let store = makeStore()
        let picked = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-refresh-\(UUID().uuidString).pdf")
        try FixturePDF.write(pages: [novel], to: picked)
        addTeardownBlock { try? FileManager.default.removeItem(at: picked) }
        let added = try await store.importPDF(from: picked)
        addTeardownBlock { @MainActor in try? store.delete(added) }
        let current = try await store.content(for: added)
        XCTAssertGreaterThan(current.sentences.count, 1, "fixture: a place past the start")
        // As an older build cached it: no chapter map, unstamped. The open
        // after gives the record its hash (and the cache a chapter map,
        // taken away again).
        let older = try Self.encoder.encode(content(current.sentences.map(\.text), hash: "older-extractor"))
        let cacheURL = DocumentStore.contentCacheURL(for: added.id)
        try older.write(to: cacheURL)
        _ = try await store.content(for: added)
        try older.write(to: cacheURL)
        store.saveProgress(id: added.id, sentence: 1, fraction: 0.5)
        // The same file added again, committing while the backfill is out.
        store.willWriteBackfill = { [store] in
            store.willWriteBackfill = {}
            _ = try? await store.importPDF(from: picked)
        }

        let opened = try await store.content(for: try XCTUnwrap(store.documents.first { $0.id == added.id }))

        let live = try XCTUnwrap(store.documents.first { $0.id == added.id })
        XCTAssertEqual(live.contentHash, current.contentHash, "the refresh stands")
        XCTAssertEqual(live.progressSentence, 1, "its carried place too")
        XCTAssertEqual(opened.contentHash, current.contentHash, "the open gets the newer cache")
        let cached = try cache(of: added.id)
        XCTAssertEqual(cached.contentHash, current.contentHash)
        XCTAssertEqual(cached.extractorVersion, DocContent.currentExtractorVersion)
    }

    /// K023: a refresh declined because the place isn't in the new text
    /// left the cache unstamped, so every later add of the same file
    /// extracted the whole book again only to keep the old one. Now the old
    /// cache is stamped as it is, and the next add returns at once.
    func testARefreshDeclinedForGoodIsNotTriedAgain() async throws {
        let store = makeStore()
        let picked = try file(Data(novel.utf8), name: "\(UUID().uuidString)-novel.txt")
        let added = try await store.importText(title: "Nineteen", from: picked)
        addTeardownBlock { @MainActor in try? store.delete(added) }
        let old = content(["Ã¤Ã¶Ã¼ ÃŸÃ¤Ã¶ Ã¼Ã¤Ã¶Ã¼.", "Ã¶Ã¼Ã¤ Ã¶Ã¼Ã¤Ã¶ Ã¼Ã¤Ã¶Ã¼Ã¤Ã¶Ã¼ Ã¤Ã¶Ã¼."], hash: "mojibake")
        try Self.encoder.encode(old).write(to: DocumentStore.contentCacheURL(for: added.id))
        _ = try await store.content(for: added)
        store.saveProgress(id: added.id, sentence: 1, fraction: 0.4)

        _ = try await store.importText(title: "Nineteen", from: picked)

        let cached = try cache(of: added.id)
        XCTAssertEqual(cached.contentHash, "mojibake", "the old text is kept")
        XCTAssertEqual(cached.sentences.map(\.text), old.sentences.map(\.text))
        XCTAssertEqual(cached.extractorVersion, DocContent.currentExtractorVersion, "and not tried again")
        let live = try XCTUnwrap(store.documents.first { $0.id == added.id })
        XCTAssertEqual(live.contentHash, "mojibake")
        XCTAssertEqual(live.progressSentence, 1)
    }

    /// F038: a file handed over as a symlink lands in the library as a copy
    /// of the book, a regular file, never a link that points outside the
    /// library (or nowhere, once a relative one is moved).
    func testTheLibraryCopyOfASymlinkIsTheFileItPointsTo() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("aloud-symlink-\(UUID().uuidString)",
                                                                   isDirectory: true)
        let books = folder.appendingPathComponent("Books", isDirectory: true)
        let desktop = folder.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: books, withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("Call me Ishmael.".utf8)
        try bytes.write(to: books.appendingPathComponent("novel.txt"))
        let link = desktop.appendingPathComponent("novel.txt")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../Books/novel.txt")

        let copy = folder.appendingPathComponent("library-copy.txt")
        try await DocumentStore.copyFile(from: link, to: copy)

        let type = try fm.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular, "the copy is the book, not a link")
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    /// L004: a Finder-locked file's library copy isn't locked, so Delete and
    /// the launch's orphan sweep can remove it. Before, copyItem kept the
    /// lock and every removal failed without a word, leaving the book's
    /// bytes in the container for good. The user's own file keeps its lock.
    func testALockedFilesLibraryCopyCanBeRemoved() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("aloud-locked-\(UUID().uuidString)",
                                                                   isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Locked.txt")
        try Data("Call me Ishmael.".utf8).write(to: source)
        try fm.setAttributes([.immutable: true], ofItemAtPath: source.path)
        addTeardownBlock { DocumentStore.unlock(source) }
        XCTAssertEqual(try fm.attributesOfItem(atPath: source.path)[.immutable] as? Bool, true,
                       "the host locks a file as Finder does")

        let copy = folder.appendingPathComponent("library-copy.txt")
        try await DocumentStore.copyFile(from: source, to: copy)

        XCTAssertNotEqual(try fm.attributesOfItem(atPath: copy.path)[.immutable] as? Bool, true,
                          "the library's copy is unlocked")
        XCTAssertNoThrow(try fm.removeItem(at: copy), "Delete can remove it")
        XCTAssertFalse(fm.fileExists(atPath: copy.path))
        XCTAssertEqual(try fm.attributesOfItem(atPath: source.path)[.immutable] as? Bool, true,
                       "the user's file is left as it was")
    }
}
