import XCTest
@testable import Aloud

/// Back where the listener was after Aloud closes (both apps): the reader
/// that was showing reopens at launch, paused at its place, so one Play
/// continues; a reader opened by the listener still starts the book; Play
/// from outside the app with nothing loaded continues the Continue card's
/// book; and every stop writes the place to disk at once. Nothing plays:
/// the router, the stores and the pure rules only.
@MainActor
final class LaunchRestoreTests: XCTestCase {

    private func book(finished: Bool = false, progress: Double = 0.3) -> LibraryDocument {
        var document = LibraryDocument(id: UUID(), title: "T", fileName: "x", addedAt: Date(),
                                       pageCount: 10, sentenceCount: 100, contentHash: "h", kind: .text)
        document.progressSentence = Int(progress * 100)
        document.progressFraction = finished ? 1.0 : progress
        document.lastOpenedAt = Date()
        return document
    }

    private func freshDefaults() -> UserDefaults {
        let name = "LaunchRestoreTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: - The slot

    func testTheLastReaderSlotRoundTrips() {
        let store = LastReaderStore(defaults: freshDefaults())
        XCTAssertNil(store.load())
        let id = UUID()
        store.save(id)
        XCTAssertEqual(store.load(), id)
        store.save(nil)
        XCTAssertNil(store.load(), "back on the Library: nothing to reopen")
    }

    func testTheReaderOnTopIsTheOneRecorded() {
        let id = UUID()
        XCTAssertEqual(LaunchRestore.readerID(in: [.reader(id)]), id)
        XCTAssertEqual(LaunchRestore.readerID(in: [.bookshelf, .reader(id)]), id)
        XCTAssertNil(LaunchRestore.readerID(in: [.reader(id), .settings]), "Settings over the reader")
        XCTAssertNil(LaunchRestore.readerID(in: []))
    }

    // MARK: - What reopens

    func testTheLastReaderReopensWhileItsBookIsOnTheShelfAndUnfinished() {
        let reading = book(), finished = book(finished: true)
        XCTAssertEqual(LaunchRestore.readerToReopen(lastReaderID: reading.id, documents: [reading, finished],
                                                    enabled: true), reading.id)
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: finished.id, documents: [reading, finished],
                                                  enabled: true), "a finished book's place is its end")
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: UUID(), documents: [reading], enabled: true),
                     "a deleted book never reopens")
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: nil, documents: [reading], enabled: true))
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: reading.id, documents: [reading], enabled: false))
    }

    func testRestoreIsOffInTestsUnlessAsked() {
        XCTAssertTrue(LaunchRestore.isEnabled(xcTestLoaded: false, uiTestLaunch: false, restoreRequested: false))
        XCTAssertFalse(LaunchRestore.isEnabled(xcTestLoaded: true, uiTestLaunch: false, restoreRequested: false),
                       "hosted unit tests run inside the real app")
        XCTAssertFalse(LaunchRestore.isEnabled(xcTestLoaded: false, uiTestLaunch: true, restoreRequested: false))
        XCTAssertTrue(LaunchRestore.isEnabled(xcTestLoaded: false, uiTestLaunch: true, restoreRequested: true))
        XCTAssertFalse(LaunchRestore.isEnabled, "this run is a hosted test")
    }

    // MARK: - The router

    func testOpeningABookAsksItsReaderToPlayOnce() {
        let router = LibraryRouter()
        let first = book(), second = book()
        router.open(first)
        XCTAssertFalse(router.takeAutoplayRequest(for: second.id), "only the book opened")
        XCTAssertTrue(router.takeAutoplayRequest(for: first.id))
        XCTAssertFalse(router.takeAutoplayRequest(for: first.id), "once: a rebuilt reader waits")
        router.open(second)
        XCTAssertTrue(router.takeAutoplayRequest(for: second.id))
    }

    func testAReopenedReaderNeverPlays() {
        let router = LibraryRouter()
        let reading = book()
        router.restoreReader(reading.id)
        XCTAssertEqual(router.path, [.reader(reading.id)])
        XCTAssertFalse(router.takeAutoplayRequest(for: reading.id), "paused at its place, waiting for Play")
    }

    func testRestoreOnlyOntoAnUntouchedStack() {
        let router = LibraryRouter()
        let other = book(), reading = book()
        router.showBookshelf()
        router.restoreReader(reading.id)
        XCTAssertEqual(router.path, [.bookshelf], "the listener moved first")
        let covered = LibraryRouter()
        covered.rootPresentation = .filePicker
        covered.restoreReader(reading.id)
        XCTAssertEqual(covered.path, [])
        let opened = LibraryRouter()
        opened.open(other)
        opened.restoreReader(reading.id)
        XCTAssertEqual(opened.path, [.reader(other.id)])
    }

    /// An Open-in arriving at launch: the reopened reader gives way.
    func testOpenInClearsAReopenedReader() {
        let router = LibraryRouter()
        router.restoreReader(UUID())
        router.clearForOpenIn()
        XCTAssertEqual(router.path, [])
    }

    // MARK: - Play from outside the app

    func testPlayWithNothingLoadedContinuesTheLastBook() {
        XCTAssertTrue(NowPlayingManager.continuesWithNoBook(.play, hasBook: false))
        XCTAssertTrue(NowPlayingManager.continuesWithNoBook(.togglePlayPause, hasBook: false))
        for command in [NowPlayingManager.RemoteTransportCommand.pause, .skipForward, .skipBackward,
                        .nextTrack, .previousTrack] {
            XCTAssertFalse(NowPlayingManager.continuesWithNoBook(command, hasBook: false), "\(command)")
        }
        for command in NowPlayingManager.RemoteTransportCommand.allCases {
            XCTAssertFalse(NowPlayingManager.continuesWithNoBook(command, hasBook: true), "a loaded book plays itself")
        }
    }

    // MARK: - Every stop reaches disk

    func testAFlushWritesAPendingPlaceAtOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let indexURL = folder.appendingPathComponent("library.json")
        let reading = book(progress: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        struct Index: Codable { var version: Int; var documents: [LibraryDocument] }
        try encoder.encode(Index(version: 2, documents: [reading])).write(to: indexURL)

        let store = DocumentStore(indexURL: indexURL, saveInterval: 60, notifications: NotificationCenter())
        store.saveProgress(id: reading.id, sentence: 42, fraction: 0.42)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let before = try decoder.decode(Index.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(before.documents.first?.progressSentence, 0, "throttled: not written yet")
        store.flushPendingProgress()
        let after = try decoder.decode(Index.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(after.documents.first?.progressSentence, 42, "a stop writes the place at once")
    }
}
