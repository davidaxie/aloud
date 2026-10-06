import XCTest
@testable import Aloud

/// A PDF's chapter map drives its navigation like a text book's chapters:
/// Contents rows and sections, the chapter line's "N of M", the scrub span,
/// chapter steps and End of chapter. Without a usable map, PDFs list page
/// ranges, grouped when there are too many.
final class ReaderNavigationPDFChaptersTests: XCTestCase {

    private typealias Entry = ChapterMap.Entry

    private let part = "Part II: The Cold Start Problem"

    /// Nine three-word sentences: page 1 s0–s1, page 2 s2–s5, page 3 s6–s8.
    private func content(map: ChapterMap?) -> DocContent {
        let pages = [1, 1, 2, 2, 2, 2, 3, 3, 3]
        let sentences = pages.enumerated().map { index, page in
            Sentence(id: index, text: "Word word word.", para: index, page: page)
        }
        var content = DocContent(title: "Book", pageCount: 3, sentences: sentences,
                                 paragraphs: [], contentHash: "hash")
        content.chapterMap = map
        return content
    }

    private func map(_ entries: [Entry], source: ChapterMap.Source = .runningHeaders) -> ChapterMap {
        ChapterMap(version: ChapterMap.currentVersion, source: source, entries: entries)
    }

    private var chaptered: ReaderNavigation {
        ReaderNavigation(content: content(map: map([
            Entry(title: "Front matter", sentence: 0, section: nil),
            Entry(title: "Tiny Speck", sentence: 2, section: part),
            Entry(title: "Anti-Network Effects", sentence: 6, section: part),
        ])), kind: .pdf)
    }

    // MARK: - Page steps

    /// A PDF that lists pages, grouped into rows: Next Page still moves one
    /// page, not one row of pages.
    func testNextPageMovesOnePageWhereRowsGroupPages() {
        let pages = Array(1...60)
        let sentences = pages.flatMap { page in (0..<2).map { _ in page } }.enumerated().map { index, page in
            Sentence(id: index, text: String(repeating: "Word ", count: 40) + "end.", para: index, page: page)
        }
        let content = DocContent(title: "Long", pageCount: 60, sentences: sentences, paragraphs: [],
                                 contentHash: "long")
        let navigation = ReaderNavigation(content: content, kind: .pdf)
        XCTAssertLessThan(navigation.chapters.count, 60, "rows group the pages")
        XCTAssertEqual(navigation.stepTarget(from: 0, forward: true, rate: 1), 2, "page 2's first sentence")
        XCTAssertEqual(navigation.stepTarget(from: 3, forward: false, rate: 1), 2, "back to this page's start")
        XCTAssertEqual(navigation.stepTarget(from: 2, forward: false, rate: 1), 0, "then the page before")
        XCTAssertEqual(navigation.stepStart(containing: 3), 2)
        XCTAssertNil(navigation.stepTarget(from: 119, forward: true, rate: 1), "past the last page")
        // A mapped PDF steps by chapter.
        XCTAssertEqual(chaptered.stepTarget(from: 0, forward: true, rate: 1),
                       chaptered.adjustmentTarget(from: 0, forward: true, rate: 1))
    }

    // MARK: - Names outside Contents

    /// VoiceOver's coarse rotor names what Contents lists.
    func testTheRotorSaysChaptersForAMappedPDF() {
        XCTAssertEqual(ReaderRotor.chapters.name(listing: chaptered, isChapterBook: false), "Chapters")
        let pages = ReaderNavigation(content: content(map: nil), kind: .pdf)
        XCTAssertEqual(ReaderRotor.chapters.name(listing: pages, isChapterBook: false), "Pages")
        XCTAssertEqual(ReaderRotor.chapters.name(listing: nil, isChapterBook: true), "Chapters")
        XCTAssertEqual(ReaderRotor.chapters.name(listing: nil, isChapterBook: false), "Pages")
        XCTAssertEqual(ReaderRotor.sentences.name(listing: chaptered, isChapterBook: false), "Sentences")
    }

    /// Two chapters on one page keep their own titles in their rows.
    func testRowsNameTheirOwnChapterOnASharedPage() {
        let shared = ReaderNavigation(content: content(map: map([
            Entry(title: "Front matter", sentence: 0, section: nil),
            Entry(title: "One", sentence: 2, section: nil),
            Entry(title: "Two", sentence: 4, section: nil),
        ])), kind: .pdf)
        XCTAssertEqual(shared.title(ofChapter: 1), "One")
        XCTAssertEqual(shared.title(ofChapter: 2), "Two")
        XCTAssertNotEqual(shared.rowIdentifier(at: 1), shared.rowIdentifier(at: 2))
    }

    // MARK: - Chapters from the map

    func testAMapMakesChaptersSectionsAndLabels() {
        let navigation = chaptered

        XCTAssertEqual(navigation.rowKind, .chapters)
        XCTAssertTrue(navigation.isChaptered)
        XCTAssertTrue(navigation.isGrouped)
        XCTAssertEqual(navigation.chapters.map(\.title), ["Front matter", "Tiny Speck", "Anti-Network Effects"])
        XCTAssertEqual(navigation.chapters.map(\.startSentence), [0, 2, 6])
        XCTAssertEqual(navigation.chapters.map(\.sentenceCount), [2, 4, 3])
        XCTAssertEqual(navigation.chapters.map(\.wordCount), [6, 12, 9])
        XCTAssertEqual(navigation.chapters.map(\.page), [1, 2, 3])
        XCTAssertEqual(navigation.sections, [ContentsSection(title: nil, chapterRange: 0..<1),
                                             ContentsSection(title: part, chapterRange: 1..<3)])
        // Contents names its rows through the labels, as for text books.
        XCTAssertEqual(navigation.labels.contextTitle(forPage: 2), "Tiny Speck")
        XCTAssertEqual(navigation.labels.pageLabel(2), "Page 2")
        XCTAssertEqual(navigation.title(ofChapter: 2), "Anti-Network Effects")
        XCTAssertEqual(navigation.chapterIndex(containing: 4), 1)
        XCTAssertEqual(navigation.chapterIndex(containing: 8), 2)
        XCTAssertEqual(navigation.location(ofSentence: 4, page: 2), "Tiny Speck \u{00B7} Page 2")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: 3), "Anti-Network Effects \u{00B7} Page 3")
    }

    func testThePositionLineCountsChaptersAndTimeToTheChapterEnd() {
        let line = chaptered.positionLine(at: 3, rate: 1, documentTitle: "Book")

        XCTAssertEqual(line.kind, .chapter(number: 2, count: 3))
        XCTAssertEqual(line.title, "Tiny Speck")
        // s3…s5: nine words to the chapter's end, not the book's.
        XCTAssertEqual(line.minutesLeft, ListeningEstimate.minutes(words: 9))
        XCTAssertTrue(line.accessibilityLabel.hasPrefix("Tiny Speck, 2 of 3, "))
        XCTAssertTrue(line.accessibilityLabel.hasSuffix(" left in chapter"))
    }

    func testScrubStepsAndEndOfChapterKeepToTheChapter() {
        let navigation = chaptered

        XCTAssertEqual(navigation.scrubSpan(at: 3), 2...5)
        XCTAssertEqual(navigation.adjustmentTarget(from: 3, forward: true, rate: 1), 6)
        XCTAssertEqual(navigation.adjustmentTarget(from: 3, forward: false, rate: 1), 2)
        XCTAssertEqual(navigation.adjustmentTarget(from: 2, forward: false, rate: 1), 0)
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: navigation, sentenceCount: 9, at: 3), 5)

        // A PDF without a map still stops at the end of the book.
        let pages = ReaderNavigation(content: content(map: nil), kind: .pdf)
        XCTAssertFalse(pages.isChaptered)
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: pages, sentenceCount: 9, at: 3), 8)
        XCTAssertEqual(pages.scrubSpan(at: 3), 0...8)
    }

    // MARK: - Edge cases

    func testTwoChaptersOnOnePageKeepDistinctIdentities() {
        let navigation = ReaderNavigation(content: content(map: map([
            Entry(title: "A", sentence: 0, section: nil),
            Entry(title: "B", sentence: 2, section: nil),
            Entry(title: "C", sentence: 4, section: nil),
        ])), kind: .pdf)

        XCTAssertEqual(navigation.chapters.map(\.id), [0, 2, 4])
        XCTAssertEqual(navigation.chapters.map(\.page), [1, 2, 2])
        XCTAssertEqual(navigation.rowIdentifier(at: 1), "chapters.row.2")
        XCTAssertEqual(navigation.rowIdentifier(at: 2), "chapters.row.2.2")
        XCTAssertEqual(navigation.title(ofChapter: 2), "C")
        XCTAssertEqual(navigation.positionLine(at: 5, rate: 1, documentTitle: "Book").title, "C")
        XCTAssertEqual(navigation.location(ofSentence: 4, page: 2), "C \u{00B7} Page 2")
        XCTAssertFalse(navigation.isGrouped)
    }

    func testATamperedMapIsSanitized() {
        let navigation = ReaderNavigation(content: content(map: map([
            Entry(title: "X", sentence: 5, section: nil),
            Entry(title: "Y", sentence: 3, section: nil),
            Entry(title: "Z", sentence: 99, section: nil),
            Entry(title: "W", sentence: -1, section: nil),
        ])), kind: .pdf)

        XCTAssertEqual(navigation.chapters.map(\.startSentence), [0, 5])
        XCTAssertEqual(navigation.chapters.map(\.title), [PDFChapterDetector.frontMatterTitle, "X"])
    }

    func testAMapWithoutTwoChaptersListsPages() {
        let single = ReaderNavigation(content: content(map: map([Entry(title: "Only", sentence: 0, section: nil)])),
                                      kind: .pdf)
        let empty = ReaderNavigation(content: content(map: map([Entry(title: "A", sentence: 0, section: nil),
                                                               Entry(title: "B", sentence: 4, section: nil)],
                                                              source: .none)), kind: .pdf)

        for navigation in [single, empty] {
            XCTAssertEqual(navigation.rowKind, .pages)
            XCTAssertEqual(navigation.chapters.map(\.startSentence), [0, 2, 6])
            XCTAssertEqual(navigation.title(ofChapter: 0), "Page 1")
            XCTAssertEqual(navigation.positionLine(at: 3, rate: 1, documentTitle: "Book").kind, .pages)
        }
    }

    func testATextBookIgnoresAMap() {
        let navigation = ReaderNavigation(content: content(map: map([Entry(title: "A", sentence: 0, section: nil),
                                                                     Entry(title: "B", sentence: 4, section: nil)])),
                                          kind: .text)

        XCTAssertEqual(navigation.rowKind, .chapters)
        XCTAssertEqual(navigation.chapters.map(\.startSentence), [0, 2, 6])
        XCTAssertEqual(navigation.title(ofChapter: 0), "Word word word")
    }

    // MARK: - Page-range fallback

    func testManyPagesGroupIntoRowsOfAboutEqualTime() {
        let sentences = (0..<60).map {
            Sentence(id: $0, text: "One two three four five six seven eight nine ten.", para: $0, page: $0 + 1)
        }
        let content = DocContent(title: "Book", pageCount: 60, sentences: sentences,
                                 paragraphs: [], contentHash: "hash")

        let navigation = ReaderNavigation(content: content, kind: .pdf)

        // 600 words is well under 15 rows of 20 minutes: the 15-row floor,
        // four pages each, covering every sentence once.
        XCTAssertEqual(navigation.rowKind, .pages)
        XCTAssertFalse(navigation.isChaptered)
        XCTAssertEqual(navigation.chapters.count, ReaderNavigation.minPageGroups)
        XCTAssertEqual(navigation.chapters.map(\.sentenceCount), Array(repeating: 4, count: 15))
        XCTAssertEqual(navigation.chapters.map(\.startSentence), stride(from: 0, to: 60, by: 4).map { $0 })
        XCTAssertEqual(navigation.title(ofChapter: 0), "Pages 1\u{2013}4")
        XCTAssertEqual(navigation.title(ofChapter: 14), "Pages 57\u{2013}60")
        XCTAssertEqual(navigation.labels.contextTitle(forPage: 5), "Pages 5\u{2013}8")
        let line = navigation.positionLine(at: 6, rate: 1, documentTitle: "Book")
        XCTAssertEqual(line.kind, .pages)
        XCTAssertEqual(line.title, "Pages 5\u{2013}8")
        XCTAssertEqual(navigation.scrubSpan(at: 6), 0...59)
    }

    func testAFewPagesKeepOneRowEach() {
        let navigation = ReaderNavigation(content: content(map: nil), kind: .pdf)

        XCTAssertEqual(navigation.rowKind, .pages)
        XCTAssertEqual(navigation.chapters.map(\.page), [1, 2, 3])
        XCTAssertEqual((0..<3).map { navigation.title(ofChapter: $0) }, ["Page 1", "Page 2", "Page 3"])
        XCTAssertEqual(navigation.rowIdentifier(at: 1), "chapters.row.2")
    }
}
