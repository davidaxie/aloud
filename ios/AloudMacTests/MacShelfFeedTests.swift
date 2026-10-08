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

    // MARK: - Classics

    /// A Classics row shows the book's length at the app-wide speed, like
    /// the featured card beside it in an empty Library. It read 14 min at 2×
    /// beside a 7 min featured card (H016).
    func testClassicsRowsReadTheirLengthAtTheAppWideSpeed() {
        let cask = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                 author: "Edgar Allan Poe", year: nil,
                                 file: "1063-the-cask-of-amontillado.txt", words: 2317)
        XCTAssertEqual(MacClassicsView.rowStatus(for: cask, rate: 1, inLibrary: false, adding: false), "14 min")
        XCTAssertEqual(MacClassicsView.rowStatus(for: cask, rate: 2, inLibrary: false, adding: false), "7 min")
        XCTAssertEqual(MacClassicsView.rowStatus(for: cask, rate: 2, inLibrary: true, adding: false), "In library")
        XCTAssertEqual(MacClassicsView.rowStatus(for: cask, rate: 2, inLibrary: true, adding: true), "Adding\u{2026}")
        XCTAssertEqual(MacClassicsView.rowLabel(for: cask, rate: 2),
                       "The Cask of Amontillado, by Edgar Allan Poe, about 7 minutes")
        for rate in [0.5, 1, 1.5, 2, 3] {
            let status = MacClassicsView.rowStatus(for: cask, rate: rate, inLibrary: false, adding: false)
            XCTAssertEqual("\(cask.author) · \(status)", FeaturedClassic.subtitle(for: cask, rate: rate),
                           "the featured card agrees at \(rate)×")
        }
    }

    /// L019: the Mac's Classics headings and the rows under them are one
    /// measure: a row's time is the one its shelf is chosen by, at any speed.
    /// At 0.5× a 56-minute book reads 1 hr 52 min, under An evening.
    func testClassicsShelvesAndRowsAreOneMeasure() {
        let bigFix = BookshelfBook(gutenbergID: 1, title: "The Big Fix", author: "A. Writer", year: nil,
                                   file: "1.txt", words: 9_251)
        let index = BookshelfIndex(books: [bigFix])
        for rate in [0.5, 0.75, 1, 1.5, 2, 3] {
            let minutes = MacClassicsView.rowMinutes(of: bigFix, rate: rate)
            XCTAssertEqual(minutes, bigFix.listeningMinutes(rate: rate), "\(rate)×")
            XCTAssertEqual(index.shelves(rate: rate).map(\.section), [BookshelfSection.section(forMinutes: minutes)],
                           "the heading over a \(minutes)-minute row at \(rate)×")
        }
        XCTAssertEqual(MacClassicsView.rowStatus(for: bigFix, rate: 0.5, inLibrary: false, adding: false), "1 hr 52 min")
        XCTAssertEqual(index.shelves(rate: 0.5).map(\.section), [.anEvening])
    }

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
