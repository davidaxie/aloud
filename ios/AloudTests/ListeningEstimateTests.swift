import XCTest
@testable import Aloud

/// The shared listening-estimate rules: one words→minutes formula, one
/// seconds→minutes rounding and one phrasing, used by the bookshelf, the
/// shelf cards, Contents and the sleep chip.
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

    /// The chapter line's visible time left.
    func testLeftPhrase() {
        XCTAssertEqual(ListeningEstimate.leftPhrase(minutes: 8), "8 min left")
        XCTAssertEqual(ListeningEstimate.leftPhrase(minutes: 72), "1 hr 12 min left")
    }

    /// The same durations spelled out for VoiceOver.
    func testSpokenPhrase() {
        XCTAssertEqual(ListeningEstimate.spokenPhrase(minutes: 1), "1 minute")
        XCTAssertEqual(ListeningEstimate.spokenPhrase(minutes: 8), "8 minutes")
        XCTAssertEqual(ListeningEstimate.spokenPhrase(minutes: 60), "1 hour")
        XCTAssertEqual(ListeningEstimate.spokenPhrase(minutes: 72), "1 hour 12 minutes")
        XCTAssertEqual(ListeningEstimate.spokenPhrase(minutes: 120), "2 hours")
    }

    /// The spoken span for a hint that adds time: "more" after its number.
    func testSpokenMorePhrase() {
        XCTAssertEqual(ListeningEstimate.spokenMorePhrase(minutes: 1), "1 more minute")
        XCTAssertEqual(ListeningEstimate.spokenMorePhrase(minutes: 15), "15 more minutes")
        XCTAssertEqual(ListeningEstimate.spokenMorePhrase(minutes: 60), "1 more hour")
        XCTAssertEqual(ListeningEstimate.spokenMorePhrase(minutes: 90), "1 more hour 30 minutes")
    }

    /// The Bookshelf row's rough spoken length: whole hours from an hour up.
    func testAboutPhrase() {
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 1), "about 1 minute")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 14), "about 14 minutes")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 60), "about 1 hour")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 89), "about 1 hour")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 90), "about 2 hours")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 300), "about 5 hours")
        XCTAssertEqual(ListeningEstimate.aboutPhrase(minutes: 772), "about 13 hours")
    }

    /// The scrub preview's clock: floored, never negative, hours from 60 min.
    func testClock() {
        XCTAssertEqual(ListeningEstimate.clock(seconds: 0), "0:00")
        XCTAssertEqual(ListeningEstimate.clock(seconds: 59.9), "0:59")
        XCTAssertEqual(ListeningEstimate.clock(seconds: 245), "4:05")
        XCTAssertEqual(ListeningEstimate.clock(seconds: 3_599.9), "59:59")
        XCTAssertEqual(ListeningEstimate.clock(seconds: 3_600), "1:00:00")
        XCTAssertEqual(ListeningEstimate.clock(seconds: 3_725), "1:02:05")
        XCTAssertEqual(ListeningEstimate.clock(seconds: -3), "0:00")
        XCTAssertEqual(ListeningEstimate.clock(seconds: .nan), "0:00")
    }

    // MARK: - Seconds

    /// The one seconds→minutes rounding the cards use: nearest minute, never
    /// under one for any time at all, and none for no (or nonsense) time.
    func testWholeMinutes() {
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: 0), 0)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: -5), 0)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: .nan), 0)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: .infinity), 0)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: 1), 1)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: 89), 1)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: 90), 2)
        XCTAssertEqual(ListeningEstimate.wholeMinutes(seconds: 4_320), 72)
    }

    /// The sleep chip's countdown: rounded up, minutes never rolled into
    /// hours, and 0:00 below zero.
    func testCountdown() {
        XCTAssertEqual(ListeningEstimate.countdown(seconds: 1_694), "28:14")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: 3_600), "60:00")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: 0.2), "0:01")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: 59.01), "1:00")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: 0), "0:00")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: -3), "0:00")
        XCTAssertEqual(ListeningEstimate.countdown(seconds: .nan), "0:00")
    }
}
