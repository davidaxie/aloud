import XCTest
@testable import Aloud

/// The shared listening-estimate rules: one words→minutes formula and one
/// phrasing, used by the bookshelf, the shelf cards and the chapter drawer.
final class ListeningEstimateTests: XCTestCase {

    // MARK: - Minutes

    func testMinutesRoundsAtTheSpokenRate() {
        XCTAssertEqual(ListeningEstimate.minutes(words: 330, wordsPerMinute: 165), 2)
        XCTAssertEqual(ListeningEstimate.minutes(words: 400, wordsPerMinute: 165), 2)   // 2.42 → 2
        XCTAssertEqual(ListeningEstimate.minutes(words: 420, wordsPerMinute: 165), 3)   // 2.55 → 3
    }

    func testShortSpansStillReadAsAMinute() {
        XCTAssertEqual(ListeningEstimate.minutes(words: 5, wordsPerMinute: 165), 1)
    }

    func testNoWordsIsNoTime() {
        XCTAssertEqual(ListeningEstimate.minutes(words: 0, wordsPerMinute: 165), 0)
        XCTAssertEqual(ListeningEstimate.minutes(words: 100, wordsPerMinute: 0), 0)
    }

    /// A faster rate is a shorter listen — the same helper serves the drawer's
    /// rate-aware estimate.
    func testRateScalesTheEstimate() {
        let oneX = ListeningEstimate.minutes(words: 33_000,
                                             wordsPerMinute: LibraryDocument.spokenWordsPerMinute)
        let twoX = ListeningEstimate.minutes(
            words: 33_000,
            wordsPerMinute: LibraryDocument.spokenWordsPerMinute * 2)
        XCTAssertEqual(oneX, 200)
        XCTAssertEqual(twoX, 100)
    }

    /// The chapter drawer and the bookshelf quote the same rule for the same
    /// word count — the two used to hold private copies of the formula.
    func testChapterAndBookshelfShareTheFormula() {
        let words = 12_345
        let chapter = DerivedChapter(page: 1, title: "T", startSentence: 0,
                                     sentenceCount: 40, wordCount: words)
        let book = BookshelfBook(gutenbergID: 1, title: "T", author: "A", year: nil,
                                 file: "t.txt", words: words)
        XCTAssertEqual(chapter.estimatedMinutes(), ListeningEstimate.minutes(words: words))
        XCTAssertEqual(book.estimatedListeningMinutes, ListeningEstimate.minutes(words: words))
    }

    // MARK: - Phrasing

    func testPhraseRollsOverIntoHours() {
        XCTAssertEqual(ListeningEstimate.phrase(minutes: 59), "59 min")
        XCTAssertEqual(ListeningEstimate.phrase(minutes: 60), "1 hr")
        XCTAssertEqual(ListeningEstimate.phrase(minutes: 120), "2 hr")
        // A chapterless classic is one derived chapter holding the whole book.
        XCTAssertEqual(ListeningEstimate.phrase(minutes: 691), "11 hr 31 min")
    }
}
