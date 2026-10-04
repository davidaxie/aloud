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
}
