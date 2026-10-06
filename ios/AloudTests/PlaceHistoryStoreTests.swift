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
}
