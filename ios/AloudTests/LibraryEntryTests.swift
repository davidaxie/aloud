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

    /// The duration spelled out: VoiceOver reads "min" poorly (R12f). R1-09:
    /// the eyebrow first, so the name starts with the visible text, as the
    /// Continue card's does.
    func testAccessibilityLabelStartsWithTheEyebrow() {
        XCTAssertEqual(FeaturedClassic.eyebrow, "Start with a classic")
        XCTAssertEqual(FeaturedClassic.accessibilityLabel(for: cask, rate: 1),
                       "Start with a classic, The Cask of Amontillado, Edgar Allan Poe, 14 minutes")
    }

    /// R1-09: Voice Control still answers to the title, or the eyebrow.
    func testTheFeaturedClassicAnswersToItsTitle() {
        XCTAssertEqual(FeaturedClassic.inputLabels(title: cask.title),
                       ["The Cask of Amontillado", "Start with a classic"])
    }

    // MARK: - Delete's message (R1-11)

    private func record(gutenbergID: Int?) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Book", fileName: "book.txt", addedAt: Date(timeIntervalSince1970: 0),
                        pageCount: 1, sentenceCount: 10, contentHash: "hash", kind: .text,
                        gutenbergID: gutenbergID)
    }

    /// Says book, and for a bundled classic that it can come back.
    func testDeleteSaysBookAndThatAClassicCanComeBack() {
        XCTAssertEqual(DocumentAction.deleteMessage(for: record(gutenbergID: nil)),
                       "This removes the book and your place in it.")
        XCTAssertEqual(DocumentAction.deleteMessage(for: record(gutenbergID: 1063)),
                       "This removes the book and your place in it. You can add it again from Classics.")
    }

    // MARK: - Paste (R1-06)

    /// Text read is added; an empty read from a clipboard that held text was
    /// declined, and says so; an empty read from one that had none says
    /// nothing.
    func testAPasteThatReadsNothingWasDeclinedOnlyIfTextWasThere() {
        XCTAssertEqual(PasteTextAction.outcome(hadStrings: true, string: "An article"), .text("An article"))
        XCTAssertEqual(PasteTextAction.outcome(hadStrings: false, string: "An article"), .text("An article"))
        XCTAssertEqual(PasteTextAction.outcome(hadStrings: true, string: nil), .declined)
        XCTAssertEqual(PasteTextAction.outcome(hadStrings: false, string: nil), .gone)
    }

    /// The declined paste's alert names the prompt's button and the
    /// setting, and offers Settings.
    func testTheDeclinedPasteCopy() {
        XCTAssertEqual(PasteTextAction.declinedTitle, "Aloud wasn’t allowed to paste.")
        XCTAssertTrue(PasteTextAction.declinedMessage.contains("Allow Paste"))
        XCTAssertTrue(PasteTextAction.declinedMessage.contains("Paste from Other Apps in Settings > Aloud"))
        XCTAssertEqual(PasteTextAction.openSettings, "Open Settings")
    }

    // MARK: - The long-press menu's lead (R1-07)

    func testTheMenuLeadIsPlayOnlyWhenTheOpenPlays() {
        XCTAssertEqual(OpenMenuItem.title(plays: true), "Play")
        XCTAssertEqual(OpenMenuItem.systemImage(plays: true), "play.fill")
        XCTAssertEqual(OpenMenuItem.title(plays: false), "Open")
        XCTAssertEqual(OpenMenuItem.systemImage(plays: false), "book")
        // R4-10: offered under Play only, so a book opens without the voice.
        XCTAssertEqual(OpenMenuItem.silentTitle, "Open Without Playing")
        XCTAssertEqual(OpenMenuItem.silentSystemImage, "book")
        XCTAssertEqual(OpenMenuItem.silentSystemImage, OpenMenuItem.systemImage(plays: false),
                       "the same book glyph as the lead's Open")
        XCTAssertNotEqual(OpenMenuItem.silentTitle, OpenMenuItem.title(plays: true))
    }

    // MARK: - Add menu

    /// R10, with P017: the iPhone's + menu has exactly three items, the two
    /// both apps share and then the clipboard's text. The Mac's keeps the
    /// two, and pastes from its Edit menu.
    func testAddMenuHasExactlyThreeItems() {
        XCTAssertEqual(LibraryAddMenuItem.allCases.map(\.title) + [PasteTextAction.menuTitle],
                       ["Classics", "From Files\u{2026}", "Paste Text"])
        XCTAssertEqual(LibraryAddMenuItem.allCases.map(\.title), ["Classics", "From Files\u{2026}"], "the Mac's")
    }
}
