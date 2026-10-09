import XCTest
@testable import Aloud

/// R6: the chapter line's position text and its spoken label, and the
/// O(1)/O(log n) lookups behind them. Body sentences are exactly 165 words,
/// one minute each at 1×; headings are one word.
final class ReaderPositionLineTests: XCTestCase {

    private static let minute = Array(repeating: "word", count: 165).joined(separator: " ")

    /// One sentence per entry; nil text is a one-minute body sentence.
    private func content(_ entries: [(text: String?, page: Int)]) -> DocContent {
        let sentences = entries.enumerated().map { index, entry in
            Sentence(id: index, text: entry.text ?? Self.minute, para: index, page: entry.page)
        }
        return DocContent(title: "Test", pageCount: entries.map(\.page).max() ?? 0,
                          sentences: sentences, paragraphs: [], contentHash: "h")
    }

    /// Pages [1,1,2,2,2,3]: "I" + 1 min, "II" + 2 min, "III".
    private var chaptered: ReaderNavigation {
        ReaderNavigation(content: content([("I", 1), (nil, 1),
                                           ("II", 2), (nil, 2), (nil, 2),
                                           ("III", 3)]),
                         kind: .text)
    }

    private var chapterless: ReaderNavigation {
        ReaderNavigation(content: content([(nil, 1), (nil, 1), (nil, 1)]), kind: .text)
    }

    private func line(_ navigation: ReaderNavigation, at sentence: Int, rate: Double = 1,
                      finished: Bool = false) -> ReaderPositionLine {
        navigation.positionLine(at: sentence, rate: rate, documentTitle: "Test Book",
                                isFinished: finished)
    }

    // MARK: - Text

    func testChapteredTextReadsChapterPositionAndTimeLeftInChapter() {
        let position = line(chaptered, at: 3)
        XCTAssertEqual(position.kind, .chapter(number: 2, count: 3))
        XCTAssertEqual(position.title, "Chapter II")
        XCTAssertEqual(position.minutesLeft, 2)
        XCTAssertEqual(position.detail, "2 of 3 · 2 min left", "the short form, unchanged")
        XCTAssertEqual(position.qualifiedDetail, "2 of 3 · 2 min left in chapter")
        XCTAssertEqual(position.text, "Chapter II · 2 of 3 · 2 min left in chapter",
                       "the Large Content Viewer shows the qualified line")
        XCTAssertEqual(position.accessibilityLabel, "Chapter II, 2 of 3, 2 minutes left in chapter")
    }

    /// R3-16: only a chapter's time counts to the chapter's end, so only a
    /// chapter line says so; a book or page line counts to the end, and a
    /// finished chapter has no time to qualify.
    func testOnlyAChaptersTimeIsQualified() {
        let book = line(chapterless, at: 0)
        XCTAssertEqual(book.qualifiedDetail, book.detail)
        XCTAssertFalse(book.text.contains("in chapter"), book.text)
        XCTAssertFalse(book.accessibilityLabel.contains("in chapter"), book.accessibilityLabel)

        let pdf = ReaderNavigation(content: content([(nil, 1), (nil, 1), (nil, 3)]), kind: .pdf)
        for sentence in 0...2 {
            let pages = line(pdf, at: sentence)
            XCTAssertEqual(pages.kind, .pages)
            XCTAssertEqual(pages.qualifiedDetail, pages.detail)
            XCTAssertFalse(pages.text.contains("in chapter"), pages.text)
            XCTAssertFalse(pages.accessibilityLabel.contains("in chapter"), pages.accessibilityLabel)
        }

        let finished = line(chaptered, at: 3, finished: true)
        XCTAssertEqual(finished.qualifiedDetail, "2 of 3 · Finished")
        XCTAssertEqual(finished.text, "Chapter II · 2 of 3 · Finished")

        let hours = ReaderPositionLine(kind: .chapter(number: 24, count: 61), title: "Chapter XXIV", minutesLeft: 72)
        XCTAssertEqual(hours.detail, "24 of 61 · 1 hr 12 min left")
        XCTAssertEqual(hours.qualifiedDetail, "24 of 61 · 1 hr 12 min left in chapter")
    }

    func testDoubleSpeedHalvesTheTime() {
        XCTAssertEqual(line(chaptered, at: 3, rate: 2).minutesLeft, 1)
        XCTAssertEqual(line(chapterless, at: 0, rate: 2).minutesLeft, 2)   // 1.5 rounds up
    }

    func testChapterlessTextReadsTheBookTitle() {
        let navigation = chapterless
        XCTAssertFalse(navigation.hasChapterList)
        XCTAssertTrue(chaptered.hasChapterList)

        let position = line(navigation, at: 0)
        XCTAssertEqual(position.kind, .book)
        XCTAssertEqual(position.text, "Test Book · 3 min left")
        XCTAssertEqual(position.accessibilityLabel, "Test Book, 3 minutes left")
    }

    func testHoursRollOverInBothForms() {
        let navigation = ReaderNavigation(content: content(Array(repeating: (nil, 1), count: 72)),
                                          kind: .text)
        let position = line(navigation, at: 0)
        XCTAssertEqual(position.text, "Test Book · 1 hr 12 min left")
        XCTAssertEqual(position.accessibilityLabel, "Test Book, 1 hour 12 minutes left")
    }

    // MARK: - PDF

    func testPDFReadsItsPageRangeAndTimeToTheEnd() {
        let navigation = ReaderNavigation(content: content([(nil, 1), (nil, 1), (nil, 3)]),
                                          kind: .pdf)
        let first = line(navigation, at: 0)
        XCTAssertEqual(first.kind, .pages)
        XCTAssertEqual(first.text, "Pages 1\u{2013}2 · 3 min left")
        XCTAssertEqual(first.accessibilityLabel, "Pages 1\u{2013}2, 3 minutes left")
        XCTAssertEqual(line(navigation, at: 2).text, "Page 3 · 1 min left")
    }

    func testSinglePagePDFReadsOnePage() {
        let navigation = ReaderNavigation(content: content([(nil, 1)]), kind: .pdf)
        XCTAssertEqual(line(navigation, at: 0).text, "Page 1 · 1 min left")
    }

    // MARK: - Clamping and edge cases

    func testOutOfRangeSentencesClamp() {
        let navigation = chaptered
        XCTAssertEqual(line(navigation, at: -1), line(navigation, at: 0))
        XCTAssertEqual(line(navigation, at: 99), line(navigation, at: 5))
        XCTAssertEqual(line(navigation, at: 99).kind, .chapter(number: 3, count: 3))
    }

    func testEmptyContentReadsTheBookTitle() {
        let navigation = ReaderNavigation(content: content([]), kind: .text)
        XCTAssertEqual(line(navigation, at: 0),
                       ReaderPositionLine(kind: .book, title: "Test Book", minutesLeft: 0))
        XCTAssertNil(line(navigation, at: 0, finished: true).minutesLeft)
    }

    func testFinishedReplacesTheTime() {
        let chapter = line(chaptered, at: 3, finished: true)
        XCTAssertNil(chapter.minutesLeft)
        XCTAssertEqual(chapter.detail, "2 of 3 · Finished")
        XCTAssertEqual(chapter.accessibilityLabel, "Chapter II, 2 of 3, finished")

        let book = line(chapterless, at: 2, finished: true)
        XCTAssertTrue(book.detail.hasSuffix("Finished"))
        XCTAssertTrue(book.accessibilityLabel.hasSuffix("finished"))
        XCTAssertEqual(book.text, "Test Book · Finished")
    }

    // MARK: - Contents rows

    /// A Contents row shows "8 min" but speaks its time in full (R25), after
    /// the visible title.
    func testContentsRowLabelSpellsOutItsTime() {
        let current = ContentsSearch.chapterAccessibilityLabel(title: "CHAPTER I", minutes: 72, isCurrent: true)
        let other = ContentsSearch.chapterAccessibilityLabel(title: "CHAPTER II", minutes: 8, isCurrent: false)
        XCTAssertEqual(current, "CHAPTER I, 1 hour 12 minutes, current")
        XCTAssertEqual(other, "CHAPTER II, 8 minutes")
        for label in [current, other] {
            XCTAssertNil(label.range(of: #"\b(min|hr)\b"#, options: .regularExpression), label)
        }
    }

    // MARK: - Lookups

    func testChapterIndexAtEveryBoundary() {
        let navigation = chaptered
        let expected = [0, 0, 1, 1, 1, 2]
        for (sentence, chapter) in expected.enumerated() {
            XCTAssertEqual(navigation.chapterIndex(containing: sentence), chapter, "sentence \(sentence)")
        }
        XCTAssertEqual(navigation.chapterIndex(containing: -3), 0)
        XCTAssertEqual(navigation.chapterIndex(containing: 100), 2)
        XCTAssertNil(ReaderNavigation(content: content([]), kind: .text).chapterIndex(containing: 0))
    }

    func testWordsRemainingMatchesANaiveSum() {
        let source = content([("One two three.", 1), ("Four five.", 1), ("Six.", 2),
                              ("Seven eight nine ten.", 2), ("Eleven.", 3)])
        let navigation = ReaderNavigation(content: source, kind: .text)
        let words = source.sentences.map(\.wordCount)
        for from in -1...6 {
            for through in -1...6 {
                let first = min(max(from, 0), words.count - 1)
                let last = min(max(through, 0), words.count - 1)
                let naive = first <= last ? words[first...last].reduce(0, +) : 0
                XCTAssertEqual(navigation.wordsRemaining(from: from, through: through), naive,
                               "\(from)...\(through)")
            }
        }
        XCTAssertEqual(ReaderNavigation(content: content([]), kind: .text)
            .wordsRemaining(from: 0, through: 3), 0)
    }
}
