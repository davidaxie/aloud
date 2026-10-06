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

    /// One rule with Continue: the reader that comes back is the book a Play
    /// from outside the app (or the Continue listening shortcut) at launch
    /// plays. A book opened and paused in its first sentence isn't started,
    /// so Continue plays the book before it; reopening that reader would
    /// stop the other book, or show it while the other plays.
    func testTheReopenedReaderIsTheBookContinuePlays() {
        var started = book(progress: 0.42)
        started.lastOpenedAt = Date().addingTimeInterval(-600)
        var unstarted = book(progress: 0)
        unstarted.lastOpenedAt = Date().addingTimeInterval(-60)
        let shelf = [started, unstarted]

        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: shelf)?.id, started.id)
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: unstarted.id, documents: shelf, enabled: true),
                     "Continue would play another book under it")
        XCTAssertEqual(LaunchRestore.readerToReopen(lastReaderID: started.id, documents: shelf, enabled: true),
                       started.id)
    }

    /// A sleep timer (or any unattended stop) in a book's last minute: its
    /// record reads Finished, yet the stop's line promises one tap resumes
    /// there. After a relaunch its reader still comes back, and Continue
    /// (remote Play, the shortcut, the card) offers it, not another book.
    /// Without that stop, or with a stored 1.0, it is at its end.
    func testAStopInTheLastMinuteKeepsItsBookOnOfferAfterARelaunch() {
        var other = book(progress: 0.3)
        other.lastOpenedAt = Date().addingTimeInterval(-600)
        var stopped = book(progress: 0.995)
        stopped.lastOpenedAt = Date().addingTimeInterval(-60)
        XCTAssertTrue(stopped.isFinished, "the record reads Finished")
        let stop = PlaybackStop(reason: .sleepTimer, documentID: stopped.id)
        let shelf = [other, stopped]

        XCTAssertFalse(DocumentStore.isAtItsEnd(stopped, stop: stop))
        XCTAssertEqual(LaunchRestore.readerToReopen(lastReaderID: stopped.id, documents: shelf, stop: stop,
                                                    enabled: true), stopped.id)
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: shelf, stop: stop)?.id, stopped.id)
        XCTAssertEqual(ShelfLayout(for: shelf, stop: stop).hero?.id, stopped.id)

        XCTAssertTrue(DocumentStore.isAtItsEnd(stopped, stop: nil))
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: stopped.id, documents: shelf, enabled: true))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: shelf)?.id, other.id)
        let elsewhere = PlaybackStop(reason: .sleepTimer, documentID: other.id)
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: shelf, stop: elsewhere)?.id, other.id,
                       "another book's stop holds nothing here")

        var heard = stopped
        heard.progressFraction = 1
        XCTAssertTrue(DocumentStore.isAtItsEnd(heard, stop: stop), "a stored 1.0 is always its end")
        XCTAssertNil(LaunchRestore.readerToReopen(lastReaderID: heard.id, documents: [other, heard], stop: stop,
                                                  enabled: true))
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

    // MARK: - What an interrupted add leaves

    /// An add the process didn't live through (iOS ended it while the Adding
    /// card showed, Quit on the Mac) leaves its copy and content cache in
    /// the library folder, never on the shelf. The launch sweep removes a
    /// book's files no record claims, and nothing else: the shelf's books,
    /// library.json, places.json and any name that isn't a book's.
    func testTheLaunchSweepRemovesOnlyFilesNoRecordClaims() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-orphans-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let kept = LibraryDocument(id: id, title: "T", fileName: "\(id.uuidString).pdf", addedAt: Date(),
                                   pageCount: 10, sentenceCount: 100, contentHash: "h", kind: .pdf)
        let orphan = UUID().uuidString
        let names = [kept.fileName, "\(kept.id.uuidString).content.json",
                     "\(orphan).pdf", "\(orphan).content.json", "\(UUID().uuidString).txt",
                     "library.json", "places.json", "notes.txt", "Shared.pdf"]
        for name in names {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }

        let removed = DocumentStore.removeOrphanedFiles(in: folder, keeping: [kept])

        XCTAssertEqual(removed.count, 3, "the interrupted adds' copies and cache")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(left, [kept.fileName, "\(kept.id.uuidString).content.json",
                              "library.json", "places.json", "notes.txt", "Shared.pdf"])
        XCTAssertTrue(DocumentStore.removeOrphanedFiles(in: folder, keeping: [kept]).isEmpty, "once")
    }
}
