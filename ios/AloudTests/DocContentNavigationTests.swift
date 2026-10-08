import XCTest
@testable import Aloud

/// Derived chapters and word sums (Contents, the chapter line) and Contents
/// search matching over synthetic `DocContent` — no extraction pipeline
/// involved.
final class DocContentNavigationTests: XCTestCase {

    /// Builds a DocContent from (text, page) pairs with sequential sentence ids,
    /// matching the extractor's id-equals-index contract.
    private func makeContent(_ entries: [(text: String, page: Int)]) -> DocContent {
        let sentences = entries.enumerated().map { index, entry in
            Sentence(id: index, text: entry.text, para: index, page: entry.page)
        }
        return DocContent(title: "Test",
                          pageCount: entries.map(\.page).max() ?? 0,
                          sentences: sentences,
                          paragraphs: [],
                          contentHash: "test-hash")
    }

    // MARK: - Fixtures

    private var twoChapters: DocContent {
        makeContent([
            ("CHAPTER I.", 1),
            ("It was the best of times in the village.", 1),
            ("Everyone said so.", 1),
            ("CHAPTER II", 2),
            ("It was the worst of times by the river.", 2),
        ])
    }

    private var singlePage: DocContent {
        makeContent([
            ("Just one plain paragraph.", 1),
            ("Nothing chapter-like at all.", 1),
        ])
    }

    private var pdfPages: DocContent {
        makeContent([
            ("First page opening sentence.", 1),
            ("First page second sentence.", 1),
            ("Second page text here.", 2),
            ("Third page text here.", 3),
        ])
    }

    private var counted: DocContent {
        makeContent([
            ("One two three.", 1),          // 3 words
            ("Four five six seven.", 1),    // 4 words
            ("Eight.", 2),                  // 1 word
        ])
    }

    private var moby: DocContent {
        makeContent([
            ("Call me Ishmael.", 1),
            ("Some years ago — never mind how long precisely.", 1),
            ("The White Whale swam before him.", 2),
            ("A whale of a tale about a whale.", 2),
        ])
    }

    private var accented: DocContent {
        makeContent([
            ("They met at the café on the corner.", 1),
            ("A naive plan, he thought.", 1),
        ])
    }

    private var allFixtures: [DocContent] {
        [twoChapters, singlePage, makeContent([]), pdfPages, counted, moby, accented]
    }

    // MARK: - Navigation index

    /// One pass yields the chapters and the prefix word sums the chapter
    /// line's time-left subtracts.
    func testNavigationIndexMatchesChaptersAndSumsWords() {
        for content in allFixtures {
            let index = content.navigationIndex()
            XCTAssertEqual(index.chapters, content.derivedChapters)
            XCTAssertEqual(index.wordsBefore.count, content.sentences.count + 1)
            XCTAssertEqual(index.wordsBefore.first, 0)
            XCTAssertEqual(index.wordsBefore.last, content.wordCount)
            for (offset, sentence) in content.sentences.enumerated() {
                XCTAssertEqual(index.wordsBefore[offset + 1] - index.wordsBefore[offset],
                               sentence.wordCount)
            }
            XCTAssertEqual(index.wordsBefore, index.wordsBefore.sorted(), "monotonic")
        }
    }

    // MARK: - Derived chapters

    func testChaptersDerivedFromPageGroups() {
        let chapters = twoChapters.derivedChapters

        XCTAssertEqual(chapters.count, 2)

        XCTAssertEqual(chapters[0].title, "CHAPTER I")   // trailing period cleaned
        XCTAssertEqual(chapters[0].startSentence, 0)
        XCTAssertEqual(chapters[0].sentenceCount, 3)
        XCTAssertEqual(chapters[0].page, 1)
        XCTAssertEqual(chapters[0].lastSentence, 2)

        XCTAssertEqual(chapters[1].title, "CHAPTER II")
        XCTAssertEqual(chapters[1].startSentence, 3)
        XCTAssertEqual(chapters[1].sentenceCount, 2)
        XCTAssertEqual(chapters[1].page, 2)
    }

    func testSinglePageBookIsOneChapter() {
        let chapters = singlePage.derivedChapters
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].startSentence, 0)
        XCTAssertEqual(chapters[0].sentenceCount, 2)
        XCTAssertEqual(chapters[0].title, "Just one plain paragraph")
    }

    func testEmptyContentHasNoChapters() {
        XCTAssertTrue(makeContent([]).derivedChapters.isEmpty)
    }

    /// PDF fallback: pages carry no headings, but the same grouping yields one
    /// entry per page with correct seek targets — the sheet renders "Page N".
    func testPDFStylePagesEachBecomeAChapter() {
        let chapters = pdfPages.derivedChapters
        XCTAssertEqual(chapters.map(\.page), [1, 2, 3])
        XCTAssertEqual(chapters.map(\.startSentence), [0, 2, 3])
        XCTAssertEqual(chapters.map(\.sentenceCount), [2, 1, 1])
    }

    func testChapterWordCountSumsGroupWords() {
        let chapters = counted.derivedChapters
        XCTAssertEqual(chapters[0].wordCount, 7)
        XCTAssertEqual(chapters[1].wordCount, 1)
    }

    /// Chapter word counts and the whole-book count come from one rule, so the
    /// drawer's chapter minutes still sum to the book's estimate.
    func testDocumentWordCountSumsTheSameRuleAsChapters() {
        let content = counted
        XCTAssertEqual(content.wordCount, 8)
        XCTAssertEqual(content.derivedChapters.reduce(0) { $0 + $1.wordCount }, content.wordCount)
    }

    func testEstimatedMinutesAtSpokenRate() {
        let chapter = DerivedChapter(page: 1, title: "T", startSentence: 0,
                                     sentenceCount: 10, wordCount: 330)
        XCTAssertEqual(chapter.estimatedMinutes(wordsPerMinute: 165), 2)

        let short = DerivedChapter(page: 1, title: "T", startSentence: 0,
                                   sentenceCount: 1, wordCount: 5)
        XCTAssertEqual(short.estimatedMinutes(wordsPerMinute: 165), 1)   // floor of one minute

        let empty = DerivedChapter(page: 1, title: "T", startSentence: 0,
                                   sentenceCount: 0, wordCount: 0)
        XCTAssertEqual(empty.estimatedMinutes(), 0)
    }

    /// The drawer quotes the time the listener will actually spend: at 2× a
    /// chapter takes half as long, matching the player bar's time left.
    func testEstimatedMinutesHonorsPlaybackRate() {
        let chapter = DerivedChapter(page: 1, title: "T", startSentence: 0,
                                     sentenceCount: 100, wordCount: 3_300)
        let base = LibraryDocument.spokenWordsPerMinute
        XCTAssertEqual(chapter.estimatedMinutes(wordsPerMinute: base), 20)
        XCTAssertEqual(chapter.estimatedMinutes(wordsPerMinute: base * 2), 10)
        XCTAssertEqual(chapter.estimatedMinutes(wordsPerMinute: base * 0.5), 40)
    }

    func testChapterContainsSentence() {
        let chapter = DerivedChapter(page: 2, title: "T", startSentence: 5,
                                     sentenceCount: 3, wordCount: 30)
        XCTAssertFalse(chapter.contains(sentence: 4))
        XCTAssertTrue(chapter.contains(sentence: 5))
        XCTAssertTrue(chapter.contains(sentence: 7))
        XCTAssertFalse(chapter.contains(sentence: 8))
    }

    // MARK: - Title cleaning

    func testTitleCleaningCollapsesWhitespace() {
        XCTAssertEqual(DocContent.cleanedChapterTitle("CHAPTER  I\n  The   Beginning"),
                       "CHAPTER I The Beginning")
    }

    func testTitleCleaningStripsLoneTrailingPeriod() {
        // "IV." loses the period, then reads as a bare numeral (below).
        XCTAssertEqual(DocContent.cleanedChapterTitle("IV."), "Chapter IV")
        XCTAssertEqual(DocContent.cleanedChapterTitle("Chapter 1. Down the Rabbit-Hole."),
                       "Chapter 1. Down the Rabbit-Hole")
        // An ellipsis of periods is not a lone trailing period.
        XCTAssertEqual(DocContent.cleanedChapterTitle("And so it went..."), "And so it went...")
    }

    func testBareNumeralHeadingsBecomeChapters() {
        // Gutenberg's most common chapter style is a lone numeral, which reads
        // as a stray mark in a drawer list.
        XCTAssertEqual(DocContent.cleanedChapterTitle("I"), "Chapter I")
        XCTAssertEqual(DocContent.cleanedChapterTitle("XVII"), "Chapter XVII")
        XCTAssertEqual(DocContent.cleanedChapterTitle("3"), "Chapter 3")
        XCTAssertEqual(DocContent.cleanedChapterTitle("iv"), "Chapter iv")
    }

    func testTitlesThatMerelyContainNumeralsAreUntouched() {
        XCTAssertEqual(DocContent.cleanedChapterTitle("The Return"), "The Return")
        XCTAssertEqual(DocContent.cleanedChapterTitle("I Am Born"), "I Am Born")
        XCTAssertEqual(DocContent.cleanedChapterTitle("CHAPTER IV"), "CHAPTER IV")
        // Words built entirely from roman-numeral letters are not numerals:
        // only well-formed numerals get the "Chapter" prefix.
        XCTAssertEqual(DocContent.cleanedChapterTitle("CIVIL"), "CIVIL")
        XCTAssertEqual(DocContent.cleanedChapterTitle("MILD"), "MILD")
        XCTAssertEqual(DocContent.cleanedChapterTitle("VIVID"), "VIVID")
        XCTAssertEqual(DocContent.cleanedChapterTitle("DIM"), "DIM")
    }

    func testTitleCleaningTruncatesLongBodyText() {
        let long = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let cleaned = DocContent.cleanedChapterTitle(long, maxLength: 60)
        XCTAssertTrue(cleaned.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cleaned.count, 61)   // 60 + ellipsis
    }

    func testTitleCleaningLeavesShortTitlesAlone() {
        XCTAssertEqual(DocContent.cleanedChapterTitle("CHAPTER XII"), "CHAPTER XII")
    }

    // MARK: - Search matching

    func testSearchIsCaseInsensitive() {
        let matches = moby.matches(of: "WHALE")
        XCTAssertEqual(matches.map(\.sentenceID), [2, 3])
        XCTAssertEqual(matches[0].matchedText, "Whale")
        XCTAssertEqual(matches[1].matchedText, "whale")
    }

    func testSearchIsDiacriticInsensitive() {
        let content = accented
        // Plain query finds the accented text…
        XCTAssertEqual(content.matches(of: "cafe").map(\.sentenceID), [0])
        // …and an accented query finds plain text.
        XCTAssertEqual(content.matches(of: "naïve").map(\.sentenceID), [1])
    }

    func testSearchReportsOneMatchPerSentenceAtFirstOccurrence() {
        let matches = moby.matches(of: "whale")
        let last = matches.last!
        XCTAssertEqual(last.sentenceID, 3)
        // First occurrence, not the second "whale".
        XCTAssertEqual(last.text.distance(from: last.text.startIndex,
                                          to: last.range.lowerBound), 2)
    }

    func testSearchCarriesPageForContext() {
        let matches = moby.matches(of: "Ishmael")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].page, 1)
        XCTAssertEqual(matches[0].text, "Call me Ishmael.")
    }

    func testEmptyAndWhitespaceQueriesMatchNothing() {
        XCTAssertTrue(moby.matches(of: "").isEmpty)
        XCTAssertTrue(moby.matches(of: "   \n").isEmpty)
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertEqual(moby.matches(of: "  Ishmael  ").map(\.sentenceID), [0])
    }

    func testNoMatchesForAbsentText() {
        XCTAssertTrue(moby.matches(of: "Ahab").isEmpty)
    }

    /// The scan runs off the main thread and is abandoned when the next
    /// keystroke supersedes it, so it polls cancellation per sentence and
    /// yields nothing once cancelled.
    func testCancelledScanYieldsNoResults() {
        XCTAssertTrue(moby.matches(of: "whale", isCancelled: { true }).isEmpty)
    }

    func testScanStopsAtTheSentenceWhereCancellationArrives() {
        var seen = 0
        // Cancels once the scan reaches the third sentence — the first two
        // matches would otherwise have been collected.
        let matches = moby.matches(of: "whale", isCancelled: {
            seen += 1
            return seen > 2
        })
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(seen, 3, "Scan should stop polling once cancelled")
    }

    func testUncancelledScanKeepsSentenceOrder() {
        let matches = moby.matches(of: "whale", isCancelled: { false })
        XCTAssertEqual(matches.map(\.sentenceID), [2, 3])
    }

    // MARK: - Chapter openers (R1-37)

    /// Speech says a bare numeral as a chapter where Contents starts one: a
    /// text book's page runs.
    func testATextBooksOpenersAreItsChapterStarts() {
        XCTAssertEqual(twoChapters.chapterOpenerSentences(kind: .text), [0, 3])
        XCTAssertEqual(twoChapters.chapterOpenerSentences(kind: .text, chapters: twoChapters.derivedChapters), [0, 3])
        XCTAssertEqual(singlePage.chapterOpenerSentences(kind: .text), [0])
        XCTAssertEqual(makeContent([]).chapterOpenerSentences(kind: .text), [])
    }

    /// A PDF's openers are its chapter map's entries; a PDF whose map found
    /// nothing, or that has none yet, has no openers: its page runs are
    /// physical pages.
    func testAPDFsOpenersAreItsChapterMapsEntries() {
        var pdf = makeContent([("IV", 1), ("Body text on the page.", 1), ("More body text.", 2),
                               ("V", 2), ("The last chapter's text.", 3)])
        XCTAssertEqual(pdf.chapterOpenerSentences(kind: .pdf), [], "no map yet")
        pdf.chapterMap = ChapterMap(version: ChapterMap.currentVersion, source: .headings, entries: [
            ChapterMap.Entry(title: "Chapter IV", sentence: 0, section: nil),
            ChapterMap.Entry(title: "Chapter V", sentence: 3, section: nil),
        ])
        XCTAssertEqual(pdf.chapterOpenerSentences(kind: .pdf), [0, 3])
        pdf.chapterMap = ChapterMap(version: ChapterMap.currentVersion, source: .none, entries: [])
        XCTAssertEqual(pdf.chapterOpenerSentences(kind: .pdf), [], "a map that found nothing")
    }
}
