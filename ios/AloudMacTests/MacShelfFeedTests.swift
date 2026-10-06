import XCTest
@testable import Aloud

/// The Library stays in the window's stack under the reader, and progress
/// saves publish the store every sentence: a covered shelf only marks
/// itself stale (one state write), and showing again rebuilds it once.
@MainActor
final class MacShelfFeedTests: XCTestCase {

    private let started = PlaybackTestRig.makeDocument(hash: "shelf-a", sentences: 10,
                                                       progressSentence: 3, progressFraction: 0.3)
    private let other = PlaybackTestRig.makeDocument(hash: "shelf-b", sentences: 10)

    func testAShownLibraryRebuildsOnEveryPublish() {
        var feed = MacShelfFeed()
        XCTAssertTrue(feed.publish([started, other], loadedID: nil, libraryShows: true))
        XCTAssertTrue(feed.publish([started, other], loadedID: started.id, libraryShows: true))
        XCTAssertEqual(feed.builds, 2)
        XCTAssertFalse(feed.isStale)
    }

    func testACoveredLibraryOnlyMarksItselfStaleOnce() {
        var feed = MacShelfFeed()
        XCTAssertTrue(feed.publish([started, other], loadedID: nil, libraryShows: true))
        XCTAssertTrue(feed.publish([started, other], loadedID: started.id, libraryShows: false), "marked stale")
        for _ in 0..<20 {
            XCTAssertFalse(feed.publish([started, other], loadedID: started.id, libraryShows: false),
                           "a save under the reader writes no state")
        }
        XCTAssertEqual(feed.builds, 1, "nothing rebuilt while covered")
        XCTAssertTrue(feed.isStale)
    }

    func testShowingAgainRebuildsAStaleShelfOnce() {
        var feed = MacShelfFeed()
        _ = feed.publish([started], loadedID: nil, libraryShows: true)
        _ = feed.publish([started, other], loadedID: started.id, libraryShows: false)
        XCTAssertTrue(feed.libraryShown([started, other], loadedID: started.id))
        XCTAssertEqual(feed.builds, 2)
        XCTAssertFalse(feed.isStale)
        XCTAssertFalse(feed.libraryShown([started, other], loadedID: started.id), "a current shelf is left alone")
        XCTAssertEqual(feed.builds, 2)
        XCTAssertEqual(feed.layout.hero?.id, started.id, "the loaded book is the hero")
    }

    /// After a relaunch nothing is loaded, and a book a sleep timer stopped
    /// in its last minute reads Finished: the controller's stop keeps it the
    /// hero, as the launch restore and remote Play have it (F045).
    func testABookStoppedInItsLastMinuteStaysTheHero() {
        var older = started
        older.lastOpenedAt = Date().addingTimeInterval(-600)
        var stopped = PlaybackTestRig.makeDocument(hash: "shelf-stop", sentences: 100,
                                                   progressSentence: 99, progressFraction: 0.995)
        stopped.lastOpenedAt = Date().addingTimeInterval(-60)
        XCTAssertTrue(stopped.isFinished, "the record reads Finished")
        let stop = PlaybackStop(reason: .sleepTimer, documentID: stopped.id)

        var feed = MacShelfFeed()
        _ = feed.publish([older, stopped], loadedID: nil, libraryShows: true)
        XCTAssertEqual(feed.layout.hero?.id, older.id, "without the stop it reads Finished")
        _ = feed.publish([older, stopped], loadedID: nil, stop: stop, libraryShows: true)
        XCTAssertEqual(feed.layout.hero?.id, stopped.id, "the stop holds it at its sentence")

        _ = feed.publish([older, stopped], loadedID: nil, stop: stop, libraryShows: false)
        XCTAssertTrue(feed.libraryShown([older, stopped], loadedID: nil, stop: stop))
        XCTAssertEqual(feed.layout.hero?.id, stopped.id, "a shelf rebuilt on showing again keeps it")
    }
}
