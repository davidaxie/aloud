import XCTest
@testable import Aloud

/// R4 and R10: the empty Library's featured classic and the + menu.
final class LibraryEntryTests: XCTestCase {

    private let cask = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                     author: "Edgar Allan Poe", year: nil,
                                     file: "1063-the-cask-of-amontillado.txt", words: 2317)

    private func book(_ id: Int, words: Int) -> BookshelfBook {
        BookshelfBook(gutenbergID: id, title: "Book \(id)", author: "Author", year: nil,
                      file: "\(id).txt", words: words)
    }

    // MARK: - Featured classic

    func testCatalogShipsTheFeaturedClassic() throws {
        let catalog = BookshelfCatalog.load(from: .main)
        try XCTSkipIf(catalog.isEmpty, "no bundled catalog in this build")
        let featured = try XCTUnwrap(catalog.first { $0.gutenbergID == FeaturedClassic.gutenbergID })
        XCTAssertEqual(featured.title, "The Cask of Amontillado")
        XCTAssertEqual(featured.author, "Edgar Allan Poe")
        XCTAssertEqual(FeaturedClassic.resolve(in: catalog)?.gutenbergID, 1063)
    }

    func testSubtitleAtOneX() {
        XCTAssertEqual(FeaturedClassic.subtitle(for: cask, rate: 1), "Edgar Allan Poe · 14 min")
        // The estimate follows the app-wide speed (R7): 2317 words at 1.5×.
        XCTAssertEqual(FeaturedClassic.subtitle(for: cask, rate: 1.5), "Edgar Allan Poe · 9 min")
    }

    func testFallbackPicksShortestWhenMissing() {
        // No 1063: the shortest book with a known length, the first on a tie.
        let catalog = [book(1, words: 90_000), book(2, words: 0), book(3, words: 4_000),
                       book(4, words: 4_000), book(5, words: 12_000)]
        XCTAssertEqual(FeaturedClassic.resolve(in: catalog)?.gutenbergID, 3)
        // A book shorter than the Cask (2317 words), so the preference is what
        // picks 1063: 'shortest wins' alone would pick book 6.
        let shorter = book(6, words: 1_000)
        XCTAssertEqual(FeaturedClassic.resolve(in: catalog + [shorter])?.gutenbergID, 6,
                       "Without 1063, book 6 is the shortest")
        XCTAssertEqual(FeaturedClassic.resolve(in: catalog + [shorter, cask])?.gutenbergID, 1063,
                       "1063 wins whenever it ships, even when a shorter book exists")
        XCTAssertNil(FeaturedClassic.resolve(in: []))
        XCTAssertNil(FeaturedClassic.resolve(in: [book(2, words: 0)]))
    }

    /// The duration spelled out: VoiceOver reads "min" poorly (R12f).
    func testAccessibilityLabelStartsWithTitle() {
        XCTAssertEqual(FeaturedClassic.accessibilityLabel(for: cask, rate: 1),
                       "The Cask of Amontillado, Edgar Allan Poe, 14 minutes")
    }

    // MARK: - Add menu

    func testAddMenuHasExactlyTwoItems() {
        XCTAssertEqual(LibraryAddMenuItem.allCases.map(\.title), ["Classics", "From Files\u{2026}"])
    }
}
