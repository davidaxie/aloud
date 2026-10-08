import XCTest
@testable import Aloud

/// The Mac's Classics rows. The shelf feed these tests once sat beside is
/// shared now, and its tests run on both hosts (`ShelfFeedTests`).
@MainActor
final class MacShelfFeedTests: XCTestCase {

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
}
