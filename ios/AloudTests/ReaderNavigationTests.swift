import XCTest
@testable import Aloud

/// One page-naming rule for every surface: the chapter drawer, Search in Book,
/// the player bar readout and the reader's page marks.
final class ReaderNavigationTests: XCTestCase {

    private func makeContent(pages: [Int]) -> DocContent {
        let sentences = pages.enumerated().map { index, page in
            Sentence(id: index, text: "Sentence number \(index).", para: index, page: page)
        }
        return DocContent(title: "Test",
                          pageCount: pages.max() ?? 0,
                          sentences: sentences,
                          paragraphs: [],
                          contentHash: "test-hash")
    }

    // MARK: - Page normalization

    func testOneBasedPagesDisplayUnchanged() {
        let content = makeContent(pages: [1, 1, 2, 3])
        XCTAssertEqual(content.pageOffset, 0)
        let labels = PageLabels(content: content, kind: .pdf, chapters: content.derivedChapters)
        XCTAssertEqual(labels.pageLabel(1), "Page 1")
        XCTAssertEqual(labels.pageLabel(3), "Page 3")
    }

    /// A content cache written by an older 0-based extractor is reused without
    /// re-extraction: the reader's marks already display from 1, and the drawer
    /// and search results must agree rather than showing a "Page 0" row.
    func testZeroBasedPagesShiftToStartAtOne() {
        let content = makeContent(pages: [0, 0, 1, 2])
        XCTAssertEqual(content.pageOffset, 1)
        let labels = PageLabels(content: content, kind: .pdf, chapters: content.derivedChapters)
        XCTAssertEqual(labels.displayPage(0), 1)
        XCTAssertEqual(labels.pageLabel(0), "Page 1")
        XCTAssertEqual(labels.pageLabel(2), "Page 3")
    }

    func testEmptyContentDoesNotShiftPages() {
        let content = makeContent(pages: [])
        XCTAssertEqual(content.pageOffset, 0)
    }

    // MARK: - Context titles

    func testPDFPagesReadAsPageLabels() {
        let content = makeContent(pages: [0, 1])
        let labels = PageLabels(content: content, kind: .pdf, chapters: content.derivedChapters)
        XCTAssertEqual(labels.contextTitle(forPage: 0), "Page 1")
        XCTAssertEqual(labels.contextTitle(forPage: 1), "Page 2")
    }

    /// Prose flowing across a page break leaves that break with no block of its
    /// own (`PDFTextExtractor` keeps the previous block's page number), as do
    /// blank and image-only pages. The drawer calls itself "Pages", so a row
    /// must name every page it stands for — "Page 1, Page 2, Page 5" reads as
    /// if two pages had gone missing from the book.
    func testPDFRowsNameTheWholeRunOfPagesTheyStandFor() {
        let sentences = [
            Sentence(id: 0, text: "One.", para: 0, page: 1),
            Sentence(id: 1, text: "Two.", para: 1, page: 2),   // pages 3–4 continue it
            Sentence(id: 2, text: "Five.", para: 2, page: 5),
        ]
        let content = DocContent(title: "T", pageCount: 6, sentences: sentences,
                                 paragraphs: [], contentHash: "h")
        let labels = PageLabels(content: content, kind: .pdf, chapters: content.derivedChapters)

        XCTAssertEqual(labels.contextTitle(forPage: 1), "Page 1",
                       "a row covering one page stays singular")
        XCTAssertEqual(labels.contextTitle(forPage: 2), "Pages 2\u{2013}4",
                       "the pages absorbed into this block are named, not dropped")
        XCTAssertEqual(labels.contextTitle(forPage: 5), "Pages 5\u{2013}6",
                       "the last row runs to the end of the document")
    }

    /// Search hits and drawer rows name the same place identically — a hit in
    /// the block that spans pages 2–4 must not claim a bare "Page 2" while the
    /// drawer row for it says "Pages 2–4".
    func testSearchContextAndDrawerRowAgreeOnASpanningPage() {
        let sentences = [
            Sentence(id: 0, text: "One.", para: 0, page: 1),
            Sentence(id: 1, text: "Two.", para: 1, page: 2),
        ]
        let content = DocContent(title: "T", pageCount: 4, sentences: sentences,
                                 paragraphs: [], contentHash: "h")
        let navigation = ReaderNavigation(content: content, kind: .pdf)
        let hitPage = sentences[1].page
        XCTAssertEqual(navigation.labels.contextTitle(forPage: hitPage), "Pages 2\u{2013}4")
    }

    /// Text books have no page spans: a "page" is a chapter, and the row is
    /// its title.
    func testTextBookRowsAreUnaffectedByPageSpans() {
        let sentences = [
            Sentence(id: 0, text: "CHAPTER I.", para: 0, page: 1),
            Sentence(id: 1, text: "CHAPTER II.", para: 1, page: 4),
        ]
        let content = DocContent(title: "T", pageCount: 9, sentences: sentences,
                                 paragraphs: [], contentHash: "h")
        let labels = PageLabels(content: content, kind: .text, chapters: content.derivedChapters)
        XCTAssertEqual(labels.contextTitle(forPage: 1), "CHAPTER I")
        XCTAssertEqual(labels.contextTitle(forPage: 4), "CHAPTER II")
    }

    /// `pageCount` comes from a cache an older extractor may have written; a
    /// count that disagrees with the pages actually present must not produce a
    /// backwards range.
    func testARowNeverEndsBeforeItBegins() {
        let content = makeContent(pages: [0, 1])   // 0-based, pageCount understated
        XCTAssertEqual(content.pageOffset, 1)
        let labels = PageLabels(content: content, kind: .pdf, chapters: content.derivedChapters)
        XCTAssertEqual(labels.contextTitle(forPage: 0), "Page 1")
        XCTAssertEqual(labels.contextTitle(forPage: 1), "Page 2")
    }

    func testTextBooksReadAsChapterTitles() {
        let sentences = [
            Sentence(id: 0, text: "CHAPTER I.", para: 0, page: 1),
            Sentence(id: 1, text: "The village slept.", para: 1, page: 1),
            Sentence(id: 2, text: "CHAPTER II", para: 2, page: 2),
        ]
        let content = DocContent(title: "T", pageCount: 2, sentences: sentences,
                                 paragraphs: [], contentHash: "h")
        let labels = PageLabels(content: content, kind: .text, chapters: content.derivedChapters)
        XCTAssertEqual(labels.contextTitle(forPage: 1), "CHAPTER I")
        XCTAssertEqual(labels.contextTitle(forPage: 2), "CHAPTER II")
    }

    /// A page with no derived chapter falls back to the normalized page label —
    /// not a raw "Chapter <index>" that would contradict every other surface.
    func testUnknownPageFallsBackToTheNormalizedPageLabel() {
        let content = makeContent(pages: [0, 1])
        let labels = PageLabels(content: content, kind: .text, chapters: [])
        XCTAssertEqual(labels.contextTitle(forPage: 0), "Page 1")
    }

    // MARK: - Derived once, shared

    func testNavigationDerivesChaptersAndLabelsThatAgree() {
        let content = makeContent(pages: [0, 0, 1])
        let navigation = ReaderNavigation(content: content, kind: .pdf)

        XCTAssertEqual(navigation.chapters.map(\.page), [0, 1])
        // The drawer row and a search hit on the same page name it identically.
        for chapter in navigation.chapters {
            XCTAssertEqual(navigation.labels.contextTitle(forPage: chapter.page),
                           navigation.labels.pageLabel(chapter.page))
        }
        XCTAssertEqual(navigation.labels.pageLabel(0), "Page 1")
    }

    // MARK: - Search hits

    /// Chapterless text: its one chapter is titled by the book's first
    /// sentence, which would sit under every search hit alike and read like
    /// a chapter name. A hit there has no footnote (the sentence says
    /// where, as in "Where you stopped"); chaptered text and PDFs keep theirs.
    func testASearchHitInChapterlessTextHasNoLocation() {
        let sentences = (0..<4).map {
            Sentence(id: $0, text: "It was a bright cold day in April, and the clocks struck \($0).",
                     para: $0, page: 1)
        }
        let content = DocContent(title: "T", pageCount: 1, sentences: sentences,
                                 paragraphs: [], contentHash: "h")
        let chapterless = ReaderNavigation(content: content, kind: .text)
        XCTAssertFalse(chapterless.hasChapterList)
        for sentence in sentences {
            XCTAssertNil(chapterless.searchLocation(ofSentence: sentence.id, page: sentence.page))
        }

        let chaptered = ReaderNavigation(content: DocContent(title: "T", pageCount: 2, sentences: [
            Sentence(id: 0, text: "CHAPTER I.", para: 0, page: 1),
            Sentence(id: 1, text: "The whale.", para: 1, page: 1),
            Sentence(id: 2, text: "CHAPTER II.", para: 2, page: 2),
            Sentence(id: 3, text: "The whale again.", para: 3, page: 2),
        ], paragraphs: [], contentHash: "h2"), kind: .text)
        XCTAssertEqual(chaptered.searchLocation(ofSentence: 3, page: 2), "CHAPTER II")
        XCTAssertEqual(ReaderNavigation(content: makeContent(pages: [1, 2]), kind: .pdf)
            .searchLocation(ofSentence: 1, page: 2), "Page 2")
    }

    /// A page-range PDF with more runs than Contents lists is grouped into
    /// rows ("Pages 5–8"). A search hit still names its own run, as the
    /// ungrouped rows would: a hit on page 5 is "Page 5" like one on page 6,
    /// never its group's four pages.
    func testASearchHitInAGroupedPageRangePDFNamesItsOwnRun() {
        let content = makeContent(pages: Array(1...60))
        let navigation = ReaderNavigation(content: content, kind: .pdf)
        XCTAssertLessThan(navigation.chapters.count, 60, "grouped")
        XCTAssertTrue(navigation.title(ofChapter: 1).hasPrefix("Pages "), "a row stands for several pages")
        for sentence in content.sentences {
            XCTAssertEqual(navigation.location(ofSentence: sentence.id, page: sentence.page),
                           "Page \(sentence.page)")
        }
    }
}
