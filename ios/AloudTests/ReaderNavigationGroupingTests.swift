import XCTest
@testable import Aloud

/// R17: heading-only Part/Book/Act/Epilogue chapters fold into the chapter
/// after them, so the chapter count, "N of M" and the scrub count real
/// chapters, and Contents groups the rest under section headers.
final class ReaderNavigationGroupingTests: XCTestCase {

    /// One entry per chapter: its heading is a paragraph of its own (one
    /// sentence per string in `heading`), then one paragraph per body string.
    /// Each chapter is a page, as the text extractor makes them.
    private func content(_ chapters: [(heading: [String], body: [String])]) -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        func paragraph(_ texts: [String], page: Int) {
            let start = sentences.count
            for text in texts {
                sentences.append(Sentence(id: sentences.count, text: text, para: paragraphs.count, page: page))
            }
            paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: start..<sentences.count, page: page))
        }
        for (index, chapter) in chapters.enumerated() {
            paragraph(chapter.heading, page: index + 1)
            for body in chapter.body { paragraph([body], page: index + 1) }
        }
        return DocContent(title: "Test", pageCount: chapters.count, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "h")
    }

    private func navigation(_ chapters: [(heading: [String], body: [String])],
                            kind: DocKind = .text) -> ReaderNavigation {
        ReaderNavigation(content: content(chapters), kind: kind)
    }

    private let prose = "It was a bright cold day in April, and the clocks were striking thirteen."

    /// BOOK ONE, CHAPTER I (two body paragraphs), CHAPTER II, BOOK TWO, CHAPTER I.
    private var twoBooks: [(heading: [String], body: [String])] {
        [(["BOOK ONE"], []),
         (["CHAPTER I"], [prose, prose]),
         (["CHAPTER II"], [prose]),
         (["BOOK TWO"], []),
         (["CHAPTER I"], [prose])]
    }

    // MARK: - Folding

    func testBooksFoldIntoTheChapterAfterThem() {
        let source = content(twoBooks)
        let raw = source.derivedChapters
        let navigation = ReaderNavigation(content: source, kind: .text)

        XCTAssertEqual(navigation.chapters.count, 3)
        let first = navigation.chapters[0]
        XCTAssertEqual(first.startSentence, 0, "the folded chapter starts at its BOOK heading")
        XCTAssertEqual(first.page, raw[1].page, "and keeps CHAPTER I's page")
        XCTAssertEqual(first.title, "CHAPTER I")
        XCTAssertEqual(first.sentenceCount, raw[0].sentenceCount + raw[1].sentenceCount)
        XCTAssertEqual(first.wordCount, raw[0].wordCount + raw[1].wordCount)
        XCTAssertEqual(navigation.chapters[2].startSentence, raw[3].startSentence)
        XCTAssertEqual(navigation.chapters[2].lastSentence, raw[4].lastSentence)

        XCTAssertEqual(navigation.sections, [
            ContentsSection(title: "BOOK ONE", chapterRange: 0..<2),
            ContentsSection(title: "BOOK TWO", chapterRange: 2..<3),
        ])
        XCTAssertEqual(navigation.sections.map(\.id), [0, 2])
        XCTAssertTrue(navigation.isGrouped)
    }

    func testPositionAndLookupsCountFoldedChapters() {
        let source = content(twoBooks)
        let navigation = ReaderNavigation(content: source, kind: .text)
        let position = navigation.positionLine(at: 0, rate: 1, documentTitle: "Test")
        XCTAssertEqual(position.kind, .chapter(number: 1, count: 3))
        XCTAssertEqual(position.title, "CHAPTER I")

        let bookTwoHeading = source.derivedChapters[3].startSentence
        XCTAssertEqual(navigation.chapterIndex(containing: bookTwoHeading), 2)
        XCTAssertEqual(navigation.scrubSpan(at: bookTwoHeading),
                       bookTwoHeading...navigation.chapters[2].lastSentence)
    }

    func testLabelsStillNameTheContainerPage() {
        let source = content(twoBooks)
        let navigation = ReaderNavigation(content: source, kind: .text)
        let bookOnePage = source.derivedChapters[0].page
        XCTAssertEqual(navigation.labels.contextTitle(forPage: bookOnePage), "BOOK ONE")
    }

    func testConsecutiveContainersMergeIntoOneSection() {
        let navigation = navigation([
            (["PART I"], []),
            (["Book I. The History Of A Family"], []),
            (["CHAPTER I"], [prose]),
            (["CHAPTER II"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 2)
        XCTAssertEqual(navigation.chapters[0].startSentence, 0)
        XCTAssertEqual(navigation.chapters[0].title, "CHAPTER I")
        XCTAssertEqual(navigation.sections, [
            ContentsSection(title: "PART I · Book I. The History Of A Family", chapterRange: 0..<2),
        ])
    }

    /// A heading split into two sentences is still one paragraph: heading-only.
    func testMultiSentenceHeadingParagraphIsStillHeadingOnly() {
        let navigation = navigation([
            (["Book I.", "The History Of A Family."], []),
            (["CHAPTER I"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 1)
        XCTAssertEqual(navigation.sections.first?.title, "Book I")
    }

    func testEpilogueOrdinalsFold() {
        let navigation = navigation([
            (["CHAPTER XVI"], [prose]),
            (["FIRST EPILOGUE: 1813 - 20"], []),
            (["CHAPTER I"], [prose]),
            (["SECOND EPILOGUE"], []),
            (["CHAPTER I"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 3)
        XCTAssertEqual(navigation.sections.map(\.title),
                       [nil, "FIRST EPILOGUE: 1813 - 20", "SECOND EPILOGUE"])
    }

    // MARK: - What never folds

    func testNumeralChapterAndPrologueHeadingsStayRows() {
        let navigation = navigation([
            (["III"], []),
            (["CHAPTER V"], []),
            (["PROLOGUE"], []),
            (["CHAPTER VI"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 4)
        XCTAssertEqual(navigation.sections, [ContentsSection(title: nil, chapterRange: 0..<4)])
        XCTAssertFalse(navigation.isGrouped)
    }

    func testProseOpeningWithPartNeverFolds() {
        let navigation = navigation([
            (["Part of this book was written abroad."], []),
            (["CHAPTER I"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 2)
        XCTAssertFalse(navigation.isGrouped)
    }

    /// A Part heading with its own text is a real chapter.
    func testContainerWithBodyTextStaysAChapter() {
        let navigation = navigation([
            (["PART ONE"], [prose]),
            (["CHAPTER I"], [prose]),
        ])
        XCTAssertEqual(navigation.chapters.count, 2)
        XCTAssertFalse(navigation.isGrouped)
    }

    func testPDFsNeverGroup() {
        let navigation = navigation(twoBooks, kind: .pdf)
        XCTAssertEqual(navigation.chapters.count, 5)
        XCTAssertEqual(navigation.sections, [ContentsSection(title: nil, chapterRange: 0..<5)])
        XCTAssertFalse(navigation.isGrouped)
    }

    func testTrailingContainerStaysAChapter() {
        let navigation = navigation([
            (["CHAPTER I"], [prose]),
            (["CHAPTER II"], [prose]),
            (["BOOK TWO"], []),
        ])
        XCTAssertEqual(navigation.chapters.count, 3)
        XCTAssertEqual(navigation.chapters[2].title, "BOOK TWO")
        XCTAssertEqual(navigation.sections, [ContentsSection(title: nil, chapterRange: 0..<3)])
    }

    func testLeadingChaptersFormAnUntitledSection() {
        let navigation = navigation([
            (["PREFACE"], [prose]),
            (["BOOK ONE"], []),
            (["CHAPTER I"], [prose]),
            (["CHAPTER II"], [prose]),
        ])
        XCTAssertEqual(navigation.sections, [
            ContentsSection(title: nil, chapterRange: 0..<1),
            ContentsSection(title: "BOOK ONE", chapterRange: 1..<3),
        ])
    }

    func testChapterlessAndEmptyText() {
        let chapterless = navigation([(["It begins."], [prose, prose])])
        XCTAssertEqual(chapterless.sections, [ContentsSection(title: nil, chapterRange: 0..<1)])
        XCTAssertFalse(chapterless.hasChapterList)

        let empty = ReaderNavigation(content: content([]), kind: .text)
        XCTAssertTrue(empty.chapters.isEmpty)
        XCTAssertTrue(empty.sections.isEmpty)
    }

    // MARK: - Qualified titles

    func testQualifiedTitles() {
        let source = content(twoBooks)
        let navigation = ReaderNavigation(content: source, kind: .text)
        let pages = source.derivedChapters.map(\.page)
        XCTAssertEqual(navigation.qualifiedTitle(forPage: pages[0]), "BOOK ONE")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: pages[1]), "BOOK ONE · CHAPTER I")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: pages[2]), "BOOK ONE · CHAPTER II")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: pages[3]), "BOOK TWO")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: pages[4]), "BOOK TWO · CHAPTER I")
    }

    func testUngroupedQualifiedTitlesAreContextTitles() {
        for kind in [DocKind.text, .pdf] {
            let source = content([(["CHAPTER I"], [prose]), (["CHAPTER II"], [prose])])
            let navigation = ReaderNavigation(content: source, kind: kind)
            for page in source.derivedChapters.map(\.page) {
                XCTAssertEqual(navigation.qualifiedTitle(forPage: page),
                               navigation.labels.contextTitle(forPage: page), "\(kind) page \(page)")
            }
        }
    }

    /// Pages before the first section header read without a prefix.
    func testLeadingSectionPagesReadUnqualified() {
        let source = content([(["PREFACE"], [prose]), (["BOOK ONE"], []), (["CHAPTER I"], [prose])])
        let navigation = ReaderNavigation(content: source, kind: .text)
        XCTAssertEqual(navigation.qualifiedTitle(forPage: 1), "PREFACE")
        XCTAssertEqual(navigation.qualifiedTitle(forPage: 3), "BOOK ONE · CHAPTER I")
    }
}
