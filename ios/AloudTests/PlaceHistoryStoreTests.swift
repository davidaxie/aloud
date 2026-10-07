import XCTest
@testable import Aloud

/// "Where you stopped" on disk: one versioned places.json per library, here
/// a temp directory's. Round trip, a stale or newer file, another content
/// hash, and books leaving the shelf.
@MainActor
final class PlaceHistoryStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("places.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud.tests.places.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let stoppedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func stop(_ book: UUID, _ sentence: Int, minutesLater: Double = 0,
                      listened: TimeInterval = 60) -> PlaceStop {
        let end = stoppedAt.addingTimeInterval(minutesLater * 60)
        return PlaceStop(documentID: book, contentHash: "hash", sentence: sentence, excerpt: "Line\(sentence)",
                         startSentence: max(sentence - 50, 0), startedAt: end.addingTimeInterval(-listened),
                         stoppedAt: end, listenedSeconds: listened, movedAway: true)
    }

    func testRoundTripsVersionOneJSON() throws {
        let book = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(book, 40), contentHash: "hash-a")
        store.record(stop(book, 90, minutesLater: 30), contentHash: "hash-a")

        let reopened = PlaceHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reopened.places(for: book, contentHash: "hash-a").map(\.sentence), [90, 40])
        XCTAssertEqual(reopened.books, store.books)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let books = try XCTUnwrap(json["books"] as? [[String: Any]])
        XCTAssertEqual(books.first?["documentID"] as? String, book.uuidString)
        XCTAssertEqual(books.first?["contentHash"] as? String, "hash-a")
        let places = try XCTUnwrap(books.first?["places"] as? [[String: Any]])
        XCTAssertEqual(places.first?["sentence"] as? Int, 90)
        XCTAssertEqual(places.first?["excerpt"] as? String, "Line90")
        let date = try XCTUnwrap(places.last?["stoppedAt"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: date), stoppedAt, "ISO 8601, as library.json")
    }

    /// Synchronous: a stop from willTerminate is on disk before the
    /// process goes.
    func testRecordIsOnDiskBeforeReturning() {
        let book = UUID()
        PlaceHistoryStore(fileURL: fileURL).record(stop(book, 12), contentHash: "hash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(PlaceHistoryStore(fileURL: fileURL).places(for: book, contentHash: "hash").map(\.sentence), [12])
    }

    func testAShortSessionWritesNothing() {
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(UUID(), 12, listened: 5), contentHash: "hash")
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUndecodableOrNewerFileReadsEmptyAndIsRewritten() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = PlaceHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.books.isEmpty)

        let book = UUID()
        let newer = #"{"version":2,"books":[{"documentID":"\#(book.uuidString)","contentHash":"h","places":[]}]}"#
        try Data(newer.utf8).write(to: fileURL)
        XCTAssertTrue(PlaceHistoryStore(fileURL: fileURL).books.isEmpty, "a newer version reads as empty")

        let rewriting = PlaceHistoryStore(fileURL: fileURL)
        rewriting.record(stop(book, 7), contentHash: "h")
        XCTAssertEqual(PlaceHistoryStore(fileURL: fileURL).places(for: book, contentHash: "h").map(\.sentence), [7])
    }

    /// Places index one extraction: another hash shows none, and its first
    /// stop starts the list again.
    func testAnotherContentHashHidesAndThenReplacesTheBook() {
        let book = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(book, 40), contentHash: "old")
        store.record(stop(book, 90, minutesLater: 30), contentHash: "old")
        XCTAssertEqual(store.places(for: book, contentHash: "new"), [])
        XCTAssertEqual(store.places(for: nil, contentHash: "old"), [])

        store.record(stop(book, 41, minutesLater: 60), contentHash: "new")
        XCTAssertEqual(store.places(for: book, contentHash: "new").map(\.sentence), [41])
        XCTAssertEqual(store.places(for: book, contentHash: "old"), [], "the old list is gone")
    }

    private func content(_ texts: [String], hash: String) -> DocContent {
        DocContent(title: "Book", pageCount: 1,
                   sentences: texts.enumerated().map { Sentence(id: $0.offset, text: $0.element, para: 0, page: 0) },
                   paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<texts.count, page: 0)],
                   contentHash: hash)
    }

    /// K020: a book given a newer extractor's text (its place carried
    /// across) kept its places under the old hash, so Contents showed none
    /// and the next stop wrote over them. `carry` moves each to the sentence
    /// its text starts in now, by its sentence's text or else by its kept
    /// start, in the same order, under the new hash and on disk. Only one
    /// found neither way is dropped; another book is left alone.
    func testCarryMovesThePlacesToTheNewExtraction() async throws {
        let book = UUID()
        let other = UUID()
        let mojibake = "Ã¤Ã¶Ã¼ ÃŸÃ¤Ã¶ Ã¼Ã¤Ã¶Ã¼."
        let old = content(["It was a bright cold day in April, and the clocks were",
                           "striking thir- teen.",
                           "Winston Smith slipped quickly through the glass doors of Victory Man-",
                           "sions; a swirl of gritty dust entered along with him.",
                           mojibake], hash: "old")
        let new = content(["It was a bright cold day in April, and the clocks were striking thirteen.",
                           "Winston Smith slipped quickly through the glass doors of Victory Mansions.",
                           "A swirl of gritty dust entered along with him."], hash: "new")
        let places = [
            PlaceHistoryEntry(sentence: 2, stoppedAt: stoppedAt, excerpt: nil),
            // Its sentence's text isn't in the new text; its kept start is.
            PlaceHistoryEntry(sentence: 4, stoppedAt: stoppedAt.addingTimeInterval(-60),
                              excerpt: "A swirl of gritty dust entered"),
            PlaceHistoryEntry(sentence: 4, stoppedAt: stoppedAt.addingTimeInterval(-120), excerpt: mojibake),
            PlaceHistoryEntry(sentence: 0, stoppedAt: stoppedAt.addingTimeInterval(-180), excerpt: nil),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let books = [BookPlaces(documentID: book, contentHash: "old", places: places),
                     BookPlaces(documentID: other, contentHash: "old", places: [places[0]])]
        let records = try books.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        try JSONSerialization.data(withJSONObject: ["version": 1, "books": records]).write(to: fileURL)
        let store = PlaceHistoryStore(fileURL: fileURL)

        await store.carry(book, from: old, to: new)

        let carried = store.places(for: book, contentHash: "new")
        XCTAssertEqual(carried.map(\.sentence), [1, 2, 0])
        XCTAssertEqual(carried.map(\.stoppedAt), [places[0], places[1], places[3]].map(\.stoppedAt))
        XCTAssertEqual(carried.first?.excerpt, PlaceHistory.excerpt(of: new.sentences[1].text),
                       "kept by the new text, for the next carry")
        XCTAssertEqual(store.places(for: book, contentHash: "old"), [])
        XCTAssertEqual(PlaceHistoryStore(fileURL: fileURL).places(for: book, contentHash: "new").map(\.sentence),
                       [1, 2, 0], "on disk")
        XCTAssertEqual(store.places(for: other, contentHash: "old"), [places[0]], "another book is left alone")
    }

    func testForgetRemovesTheBook() {
        let kept = UUID(), gone = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(kept, 10), contentHash: "hash")
        store.record(stop(gone, 20), contentHash: "hash")
        store.forget(gone)
        let reopened = PlaceHistoryStore(fileURL: fileURL)
        XCTAssertEqual(Set(reopened.books.keys), [kept])
    }

    func testRetainSweepsBooksNotOnTheShelf() {
        let onShelf = UUID(), deleted = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(onShelf, 10), contentHash: "hash")
        store.record(stop(deleted, 20), contentHash: "hash")
        store.retain(only: [onShelf, UUID()])
        XCTAssertEqual(Set(PlaceHistoryStore(fileURL: fileURL).books.keys), [onShelf])
    }

    /// A library that failed to load (an empty shelf at launch) sweeps
    /// nothing; once a book was seen, emptying the shelf sweeps everything.
    func testAnEmptyShelfSweepsOnlyAfterABookWasSeen() {
        let book = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(book, 10), contentHash: "hash")
        store.shelfChanged(to: [])
        XCTAssertEqual(Set(store.books.keys), [book])
        store.shelfChanged(to: [book])
        store.shelfChanged(to: [])
        XCTAssertTrue(store.books.isEmpty)
    }

    /// The store writes only its own file: no DocContent cache is touched.
    func testWritesOnlyPlacesJSON() throws {
        let book = UUID()
        let store = PlaceHistoryStore(fileURL: fileURL)
        store.record(stop(book, 10), contentHash: "hash")
        store.forget(book)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["places.json"])
    }

    /// AppModel's recording: a book on the shelf, under the stop's hash or,
    /// for a recovered stop, the library record's; a book off the shelf is
    /// dropped.
    func testRecordingLooksTheBookUpOnTheShelf() {
        let store = PlaceHistoryStore(fileURL: fileURL)
        var document = PlaybackTestRig.makeDocument(hash: "shelf-hash", sentences: 100)
        document.progressSentence = 0
        let recovered = PlaceStop.recovered(from: LiveSession(documentID: document.id, sentenceIndex: 33,
                                                              wallClock: stoppedAt))
        AppModel.record(recovered, in: store, shelf: [document])
        XCTAssertEqual(store.places(for: document.id, contentHash: "shelf-hash").map(\.sentence), [33])

        AppModel.record(stop(UUID(), 50), in: store, shelf: [document])
        XCTAssertEqual(Set(store.books.keys), [document.id])
    }

    /// library.json in the temp directory, listing `documents`; the one at
    /// `unknownKindAt` is of a kind this build lacks ("epub", as a newer
    /// build might write), which fails the whole index.
    private func writeIndex(_ documents: [LibraryDocument], unknownKindAt unknown: Int? = nil,
                            named name: String = "library.json") throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = try documents.enumerated().map { offset, document -> [String: Any] in
            let json = try JSONSerialization.jsonObject(with: encoder.encode(document))
            var record = try XCTUnwrap(json as? [String: Any])
            if offset == unknown { record["kind"] = "epub" }
            return record
        }
        let index: [String: Any] = ["version": 2, "documents": records]
        let url = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: index).write(to: url)
        return url
    }

    /// A library.json this build can't read shows a partial shelf: only the
    /// records that still decode. A skipped record's places stay, and
    /// places.json is not rewritten, so they are there when a build that
    /// reads the whole shelf opens it again. Before, the partial shelf swept
    /// them. A readable shelf still sweeps.
    func testAPartialShelfSweepsNothing() throws {
        let kept = PlaybackTestRig.makeDocument(hash: "kept", sentences: 100)
        let newer = PlaybackTestRig.makeDocument(hash: "newer", sentences: 100)
        let history = PlaceHistoryStore(fileURL: fileURL)
        history.record(stop(kept.id, 40), contentHash: "hash")
        history.record(stop(newer.id, 60), contentHash: "hash")
        XCTAssertEqual(Set(history.books.keys), [kept.id, newer.id], "fixture: both books have places")
        let bytes = try Data(contentsOf: fileURL)

        let partial = DocumentStore(indexURL: try writeIndex([kept, newer], unknownKindAt: 1),
                                    saveInterval: 60, notifications: NotificationCenter())
        XCTAssertFalse(partial.isIndexReadable, "fixture: the index fails as a whole")
        XCTAssertEqual(partial.documents.map(\.id), [kept.id], "fixture: the shelf is partial")
        history.shelfObservation = AppModel.observeShelf(of: partial, in: history)
        XCTAssertEqual(Set(history.books.keys), [kept.id, newer.id], "the skipped book keeps its places")
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes, "places.json is as it was")

        let readable = DocumentStore(indexURL: try writeIndex([kept], named: "readable.json"),
                                     saveInterval: 60, notifications: NotificationCenter())
        XCTAssertTrue(readable.isIndexReadable)
        history.shelfObservation = AppModel.observeShelf(of: readable, in: history)
        XCTAssertEqual(Set(history.books.keys), [kept.id], "a readable shelf sweeps the book not on it")
    }
}
