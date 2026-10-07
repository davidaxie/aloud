import XCTest
@testable import Aloud

/// Synthetic extracted PDFs for the chapter tests: one entry per page, its
/// paragraphs, each a list of sentences, numbered the way the extractor
/// numbers them (pages from 1, sentence ids in reading order).
enum ChapterFixtures {

    static func book(title: String = "The Small Book",
                     _ pages: [(page: Int, paragraphs: [[String]])]) -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for (page, paras) in pages {
            for para in paras {
                let start = sentences.count
                for text in para {
                    sentences.append(Sentence(id: sentences.count, text: text, para: paragraphs.count, page: page))
                }
                paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: start..<sentences.count, page: page))
            }
        }
        return DocContent(title: title,
                          pageCount: pages.map(\.page).max() ?? 0,
                          sentences: sentences,
                          paragraphs: paragraphs,
                          contentHash: "fixture-hash")
    }

    /// 28 words: front text long enough for a "Front matter" row of its own.
    static let copyright = "Copyright 2014 by the authors, who reserve every right to this book and its contents, "
        + "including the right to reproduce it in any form whatsoever, in any country."

    static func body(_ page: Int) -> [String] {
        ["Plain words fill page \(page) here.", "More plain words close page \(page)."]
    }

    /// Shaped like The Cold Start Problem: the book's title on even pages,
    /// "<CHAPTER> <n>" on odd ones, single-line and stacked caps title pages,
    /// PART pages, a header glued onto the previous page's "par-" sentence, a
    /// CONCLUSION label over a title whose header appears once, NOTES, and an
    /// ABOUT THE / AUTHOR page with no header at all.
    ///
    /// First sentences: p3 s3, p7 s15, p8 s16, p13 s33, p18 s46, p19 s47,
    /// p23 s59, p26 s70, p28 s76; the glued header is s38.
    static var coldStart: DocContent { book(coldStartPages) }

    static var coldStartPages: [(page: Int, paragraphs: [[String]])] {
        var pages: [(page: Int, paragraphs: [[String]])] = []
        for page in 1...28 {
            let paragraphs: [[String]]
            switch page {
            case 1: paragraphs = [[copyright]]
            case 2: paragraphs = [["CONTENTS"], ["Introduction and the chapters are listed here."]]
            case 3: paragraphs = [["INTRODUCTION"], body(3)]
            case 5: paragraphs = [["INTRODUCTION 5"], body(5)]
            case 7: paragraphs = [["PART I NETWORK EFFECTS"]]
            case 8: paragraphs = [["WHAT'S A"], ["NETWORK EFFECT,"], ["ANYWAY?"], body(8)]
            case 9, 11: paragraphs = [["WHAT'S A NETWORK EFFECT, ANYWAY? \(page)"], body(page)]
            case 13: paragraphs = [["A BRIEF HISTORY"], body(13)]
            case 14: paragraphs = [["14 THE SMALL BOOK"],
                                   ["Plain words fill page 14 here.", "In contemporary par- A BRIEF HISTORY"]]
            case 15: paragraphs = [["ticipation carries the glued paragraph onto page 15."]]
            case 17: paragraphs = [["A BRIEF HISTORY 17"], body(17)]
            case 18: paragraphs = [["PART II THE COLD START PROBLEM"]]
            case 19: paragraphs = [["TINY SPECK"], body(19)]
            case 21: paragraphs = [["TINY SPECK 21"], body(21)]
            case 23: paragraphs = [["CONCLUSION"], ["THE FUTURE OF"], ["NETWORK EFFECTS"], body(23)]
            case 25: paragraphs = [["THE FUTURE OF NETWORK EFFECTS 25"], body(25)]
            case 26: paragraphs = [["NOTES"], body(26)]
            case 27: paragraphs = [["NOTES 27"], body(27)]
            case 28: paragraphs = [["ABOUT THE"], ["AUTHOR"], body(28)]
            default: paragraphs = [["\(page) THE SMALL BOOK"], body(page)]   // 4, 6, 10, 12, 16, 20, 22, 24
            }
            pages.append((page, paragraphs))
        }
        return pages
    }

    /// Shaped like Traction: a contents page, PREFACE, "CHAPTER ONE" over its
    /// title line, a CONCLUSION page-top inside a chapter, and back matter
    /// with a repeated INDEX page-top.
    ///
    /// First sentences: p2 s6, p3 s9, p6 s18, p7 s22, p8 s26, p9 s29, p10 s32.
    static func traction(chapters: Int = 3) -> DocContent {
        var pages: [(page: Int, paragraphs: [[String]])] = [
            (1, [[copyright], ["CONTENTS"], ["CHAPTER ONE Traction Channels 9"],
                 ["CHAPTER TWO Traction Thinking ....... 17"], ["CHAPTER FOUR Critical Path"],
                 ["CHAPTER FIVE Targeting Blogs"]]),
            (2, [["PREFACE: Traction Trumps Everything"], body(2)]),
            (3, [["CHAPTER ONE"], ["Traction Channels"], body(3)]),
            (4, [body(4)]),
            (5, [["CONCLUSION"], body(5)]),
            (6, [["CHAPTER TWO"], ["Traction Thinking"], body(6)]),
        ]
        pages.append((7, chapters >= 3 ? [["CHAPTER THREE"], ["Bullseye"], body(7)] : [body(7)]))
        pages += [
            (8, [["ACKNOWLEDGMENTS"], body(8)]),
            (9, [["APPENDIX: MIDDLE RING TESTS"], body(9)]),
            (10, [["INDEX"], body(10)]),
            (11, [["INDEX"], body(11)]),
        ]
        return book(title: "Traction", pages)
    }

    /// Seven pages for the outline tier. Sentences: p1 s0 (copyright),
    /// p2 s1–s3 (contents), p3 s4–s5 (preface), p4 has no text, p5 s6–s9
    /// (CHAPTER ONE), p6 s10–s13 (CHAPTER TWO starts mid-page, at s11),
    /// p7 s14.
    static var outlined: DocContent {
        book([
            (1, [[copyright]]),
            (2, [["Contents"], ["Preface 3"], ["Chapter One 4"]]),
            (3, [["PREFACE: Why Traction"], ["Body of the preface goes here."]]),
            (5, [["CHAPTER ONE"], ["Traction Channels"], ["Sales is focused on the first chapter."],
                 ["More body text."]]),
            (6, [["Body continues here."], ["CHAPTER TWO"], ["Bullseye"], ["Sales teams use the bullseye."]]),
            (7, [["Final body text of the book."]]),
        ])
    }

    static func item(_ title: String, _ pageIndex: Int, depth: Int = 0) -> PDFOutlineItem {
        PDFOutlineItem(title: title, pageIndex: pageIndex, depth: depth)
    }
}

/// The chapter tiers on synthetic text: the PDF's outline, chapter headings,
/// running headers, and the shared normalize step that every map passes.
final class PDFChapterTiersTests: XCTestCase {

    private typealias Entry = ChapterMap.Entry
    private let front = PDFChapterDetector.frontMatterTitle

    // MARK: - Outline

    func testOutlineEntriesLandOnTheirHeadingsAndFoldTheFrontMatter() throws {
        let content = ChapterFixtures.outlined
        let items = [ChapterFixtures.item("TITLE PAGE", 0), ChapterFixtures.item("COPYRIGHT", 0),
                     ChapterFixtures.item("CONTENTS", 1), ChapterFixtures.item("PREFACE: Why Traction", 2),
                     ChapterFixtures.item("CHAPTER ONE: Traction Channels", 3),
                     ChapterFixtures.item("CHAPTER TWO: Bullseye", 5)]

        let map = PDFChapterDetector.chapterMap(for: content, outline: items)

        XCTAssertEqual(map.source, .outline)
        XCTAssertEqual(map.version, ChapterMap.currentVersion)
        // TITLE PAGE and COPYRIGHT share s0 (the later wins), and both fold
        // with CONTENTS into one row. CHAPTER ONE's page 4 has no text: the
        // next sentence. CHAPTER TWO starts mid-page, on its heading.
        XCTAssertEqual(map.entries, [
            Entry(title: front, sentence: 0, section: nil),
            Entry(title: "PREFACE: Why Traction", sentence: 4, section: nil),
            Entry(title: "CHAPTER ONE: Traction Channels", sentence: 6, section: nil),
            Entry(title: "CHAPTER TWO: Bullseye", sentence: 11, section: nil),
        ])
    }

    func testALabelNeverMatchesABodySentenceThatMerelyStartsWithIt() {
        let content = ChapterFixtures.outlined
        // "Sales is focused…" (s8) starts with the label; the row stays on
        // the page's first sentence.
        XCTAssertEqual(OutlineChapters.sentence(for: ChapterFixtures.item("Sales", 4), in: content), 6)
        XCTAssertNil(OutlineChapters.sentence(for: ChapterFixtures.item("Past the end", 40), in: content))
    }

    func testTextBeforeTheFirstEntryGetsAFrontMatterRow() {
        let entries = OutlineChapters.entries([ChapterFixtures.item("PREFACE: Why Traction", 2),
                                               ChapterFixtures.item("CHAPTER ONE: Traction Channels", 3)],
                                              in: ChapterFixtures.outlined)
        let map = PDFChapterDetector.normalized(entries ?? [], in: ChapterFixtures.outlined)

        XCTAssertEqual(map?.map(\.title), [front, "PREFACE: Why Traction", "CHAPTER ONE: Traction Channels"])
        XCTAssertEqual(map?.map(\.sentence), [0, 4, 6])
    }

    func testAnOutOfOrderEntryIsDroppedAndAShuffledOutlineIsRejected() {
        let content = ChapterFixtures.outlined
        let preface = ChapterFixtures.item("PREFACE: Why Traction", 2)
        let one = ChapterFixtures.item("CHAPTER ONE: Traction Channels", 3)
        let two = ChapterFixtures.item("CHAPTER TWO: Bullseye", 5)

        XCTAssertEqual(OutlineChapters.entries([preface, two, one], in: content)?.map(\.sentence), [4, 11])
        XCTAssertNil(OutlineChapters.entries([two, one, preface], in: content))
    }

    func testPageNumberBookmarksAreRejected() {
        let items = (0..<5).map { ChapterFixtures.item("Page \($0 + 1)", $0) }
        XCTAssertNil(OutlineChapters.entries(items, in: ChapterFixtures.outlined))
    }

    func testASingleBookTitleWrapperIsDescended() {
        let items = [ChapterFixtures.item("Traction", 0),
                     ChapterFixtures.item("PREFACE: Why Traction", 2, depth: 1),
                     ChapterFixtures.item("CHAPTER ONE: Traction Channels", 3, depth: 1),
                     ChapterFixtures.item("CHAPTER TWO: Bullseye", 5, depth: 1)]

        XCTAssertEqual(OutlineChapters.entries(items, in: ChapterFixtures.outlined)?.map(\.title),
                       ["PREFACE: Why Traction", "CHAPTER ONE: Traction Channels", "CHAPTER TWO: Bullseye"])
    }

    func testPartContainersBecomeSectionsAndFoldTheirOwnPage() {
        let content = ChapterFixtures.book([
            (1, [[ChapterFixtures.copyright]]),
            (2, [["PREFACE"], ["Preface body text here."]]),
            (3, [["PART ONE"]]),
            (4, [["CHAPTER 1"], ["Chapter one body."]]),
            (5, [["CHAPTER 2"], ["Chapter two body."]]),
            (6, [["PART TWO"]]),
            (7, [["CHAPTER 3"], ["Chapter three body."]]),
            (8, [["CHAPTER 4"], ["Chapter four body."]]),
            (9, [["NOTES"], ["Notes body."]]),
        ])
        let items = [ChapterFixtures.item("PREFACE", 1),
                     ChapterFixtures.item("PART ONE", 2),
                     ChapterFixtures.item("CHAPTER 1", 3, depth: 1),
                     ChapterFixtures.item("CHAPTER 2", 4, depth: 1),
                     ChapterFixtures.item("PART TWO", 5),
                     ChapterFixtures.item("CHAPTER 3", 6, depth: 1),
                     ChapterFixtures.item("CHAPTER 4", 7, depth: 1),
                     ChapterFixtures.item("NOTES", 8)]

        let map = PDFChapterDetector.chapterMap(for: content, outline: items)

        XCTAssertEqual(map.source, .outline)
        XCTAssertEqual(map.entries, [
            Entry(title: front, sentence: 0, section: nil),
            Entry(title: "PREFACE", sentence: 1, section: nil),
            Entry(title: "CHAPTER 1", sentence: 3, section: "PART ONE"),
            Entry(title: "CHAPTER 2", sentence: 6, section: "PART ONE"),
            Entry(title: "CHAPTER 3", sentence: 8, section: "PART TWO"),
            Entry(title: "CHAPTER 4", sentence: 11, section: "PART TWO"),
            Entry(title: "NOTES", sentence: 13, section: nil),
        ])
    }

    // MARK: - Headings

    func testNumberedHeadingsTakeTheirTitleLinesAndNamedMatterAroundThem() throws {
        let entries = try XCTUnwrap(PDFChapterDetector.normalized(
            try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.traction())), in: ChapterFixtures.traction()))

        // The contents lines (a page number, a dot leader, two adjacent
        // headings) are not chapters; the CONCLUSION inside chapter one and
        // the second INDEX are ignored.
        XCTAssertEqual(entries.map(\.title), [
            front, "PREFACE: Traction Trumps Everything", "CHAPTER ONE: Traction Channels",
            "CHAPTER TWO: Traction Thinking", "CHAPTER THREE: Bullseye", "ACKNOWLEDGMENTS",
            "APPENDIX: MIDDLE RING TESTS", "INDEX",
        ])
        XCTAssertEqual(entries.map(\.sentence), [0, 6, 9, 18, 22, 26, 29, 32])
    }

    func testTwoNumberedHeadingsAreNotEnough() {
        XCTAssertNil(HeadingChapters.entries(in: ChapterFixtures.traction(chapters: 2)))
    }

    // MARK: - Running headers

    func testRunningHeadersFindChaptersPartsAndBackMatter() throws {
        let content = ChapterFixtures.coldStart
        XCTAssertNil(HeadingChapters.entries(in: content), "no CHAPTER headings: the header tier's turn")

        let map = PDFChapterDetector.chapterMap(for: content, outline: [])

        XCTAssertEqual(map.source, .runningHeaders)
        // Starts at title pages; a Part page folds into the chapter after it;
        // back matter sits outside the last Part. CONTENTS, the stacked
        // title's first line and CONCLUSION alone are not chapters.
        XCTAssertEqual(map.entries, [
            Entry(title: front, sentence: 0, section: nil),
            Entry(title: "Introduction", sentence: 3, section: nil),
            Entry(title: "What's a Network Effect, Anyway?", sentence: 15, section: "Part I: Network Effects"),
            Entry(title: "A Brief History", sentence: 33, section: "Part I: Network Effects"),
            Entry(title: "Tiny Speck", sentence: 46, section: "Part II: The Cold Start Problem"),
            Entry(title: "Conclusion: The Future of Network Effects", sentence: 59, section: nil),
            Entry(title: "Notes", sentence: 70, section: nil),
            Entry(title: "About the Author", sentence: 76, section: nil),
        ])
    }

    /// F003: the extractor now takes headers off the page and keeps them in
    /// `pageHeaders`; the tier reads them there and finds the same chapters
    /// it found when they were the pages' first paragraphs.
    func testRunningHeadersTakenOffThePageStillFindChapters() throws {
        var headers: [Int: String] = [:]
        var pages: [(page: Int, paragraphs: [[String]])] = []
        for (page, paragraphs) in ChapterFixtures.coldStartPages {
            var kept = paragraphs
            if page == 14 {
                // Extracted today: no header glued onto page 14's last sentence.
                kept = [ChapterFixtures.body(14)]
                headers[15] = "A BRIEF HISTORY 15"
                headers[14] = "14 THE SMALL BOOK"
            } else if page == 15 {
                kept = [ChapterFixtures.body(15)]
            } else if [4, 5, 6, 9, 10, 11, 12, 16, 17, 20, 21, 22, 24, 25, 27].contains(page),
                      let header = paragraphs.first?.first {
                headers[page] = header
                kept = Array(paragraphs.dropFirst())
            }
            pages.append((page, kept))
        }
        var content = ChapterFixtures.book(pages)
        XCTAssertNil(RunningHeaderChapters.entries(in: content), "headers gone from the text")

        content.pageHeaders = headers
        let map = PDFChapterDetector.chapterMap(for: content, outline: [])

        XCTAssertEqual(map.source, .runningHeaders)
        XCTAssertEqual(map.entries.map(\.title), [
            front, "Introduction", "What's a Network Effect, Anyway?", "A Brief History", "Tiny Speck",
            "Conclusion: The Future of Network Effects", "Notes", "About the Author",
        ])
        XCTAssertEqual(map.entries.map(\.section), [
            nil, nil, "Part I: Network Effects", "Part I: Network Effects", "Part II: The Cold Start Problem",
            nil, nil, nil,
        ])
    }

    /// F004: a running header that repeats a numbered heading ("Chapter 1
    /// Departure" on later pages) is not another chapter. Numbering that
    /// starts again in a new Part is.
    func testRunningHeadsOfANumberedHeadingCountOnce() throws {
        let names = ["ONE": "Departure", "TWO": "Crossing", "THREE": "Arrival"]
        func chapters(_ start: Int) -> [(page: Int, paragraphs: [[String]])] {
            var pages: [(page: Int, paragraphs: [[String]])] = []
            var page = start
            for (number, word) in [(1, "ONE"), (2, "TWO"), (3, "THREE")] {
                pages.append((page, [["CHAPTER \(word)"], [names[word]!], ChapterFixtures.body(page)]))
                for inner in 1...4 {
                    pages.append((page + inner, [["Chapter \(number) \(names[word]!)"], ChapterFixtures.body(page + inner)]))
                }
                page += 5
            }
            return pages
        }
        let book = ChapterFixtures.book([(1, [[ChapterFixtures.copyright]])] + chapters(2))
        let entries = try XCTUnwrap(HeadingChapters.entries(in: book))
        XCTAssertEqual(entries.map(\.title), ["CHAPTER ONE: Departure", "CHAPTER TWO: Crossing", "CHAPTER THREE: Arrival"])

        let parts = ChapterFixtures.book([(1, [[ChapterFixtures.copyright]]), (2, [["PART ONE"]])]
            + chapters(3) + [(18, [["PART TWO"]])] + chapters(19))
        let twice = try XCTUnwrap(HeadingChapters.entries(in: parts))
        XCTAssertEqual(twice.count, 6, "\(twice.map(\.title))")
        XCTAssertEqual(HeadingChapters.chapterNumber("Chapter Twenty-One"), 21)
        XCTAssertEqual(HeadingChapters.chapterNumber("CHAPTER XIV: Home"), 14)
    }

    /// G000: numbering that starts again keeps every chapter, whatever
    /// heads the new run: Emma's VOLUME II, A Tale of Two Cities' "Book
    /// the Second", an omnibus's next novel, a Part heading mid-page. A
    /// running header straight after its chapter's opening still counts once.
    func testNumberingThatStartsAgainKeepsEveryChapter() throws {
        let roman = ["I", "II", "III", "IV", "V"]
        var page = 1
        func next() -> Int { page += 1; return page }

        // Emma: VOLUME I–III, CHAPTER I–IV in each, a running head inside each chapter.
        var emma: [(page: Int, paragraphs: [[String]])] = [(1, [["EMMA"], ["By Jane Austen"]])]
        for volume in roman.prefix(3) {
            emma.append((next(), [["VOLUME \(volume)"]]))
            for number in roman.prefix(4) {
                emma.append((next(), [["CHAPTER \(number)"], ChapterFixtures.body(page)]))
                emma.append((next(), [["Chapter \(number) Emma"], ChapterFixtures.body(page)]))
            }
        }
        let volumes = try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.book(emma)))
        XCTAssertEqual(volumes.count, 12, "\(volumes.map(\.title))")
        let sections: [String?] = ["VOLUME I", "VOLUME II", "VOLUME III"].flatMap { Array(repeating: $0, count: 4) }
        XCTAssertEqual(volumes.map(\.section), sections)

        // A Tale of Two Cities: Book the First (3), the Second (5), the Third (3).
        page = 1
        var cities: [(page: Int, paragraphs: [[String]])] = [(1, [[ChapterFixtures.copyright]])]
        for (book, count) in [("First\u{2014}Recalled to Life", 3), ("Second\u{2014}the Golden Thread", 5),
                              ("Third\u{2014}the Track of a Storm", 3)] {
            cities.append((next(), [["Book the \(book)"]]))
            for number in roman.prefix(count) {
                cities.append((next(), [["CHAPTER \(number)."], ["The Period"], ChapterFixtures.body(page)]))
            }
        }
        let books = try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.book(cities)))
        XCTAssertEqual(books.count, 11, "\(books.map(\.title))")
        XCTAssertEqual(books.last?.title, "CHAPTER III: The Period")
        XCTAssertEqual(books.last?.section, "Book the Third\u{2014}the Track of a Storm")

        // An omnibus's second novel, and a Part heading below the page's first line.
        page = 1
        var omnibus: [(page: Int, paragraphs: [[String]])] = [(1, [[ChapterFixtures.copyright]])]
        for novel in ["THE FIRST NOVEL", "THE SECOND NOVEL"] {
            omnibus.append((next(), [[novel]]))
            for number in ["ONE", "TWO", "THREE"] {
                omnibus.append((next(), [["CHAPTER \(number)"], ChapterFixtures.body(page)]))
            }
        }
        omnibus.append((next(), [ChapterFixtures.body(page), ["PART THREE"], ["CHAPTER ONE"], ["Late Start"]]))
        let novels = try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.book(omnibus)))
        XCTAssertEqual(novels.map(\.title), ["CHAPTER ONE", "CHAPTER TWO", "CHAPTER THREE",
                                            "CHAPTER ONE", "CHAPTER TWO", "CHAPTER THREE",
                                            "CHAPTER ONE: Late Start"])

        // A preface that walks through the chapters doesn't take their numbers.
        let preface = [("Getting Started", "ONE"), ("Find Users", "TWO"), ("Ship", "THREE")]
        var guide: [(page: Int, paragraphs: [[String]])] = [(1, [["PREFACE"], ["How this book is organized."]])]
        for (index, (name, _)) in preface.enumerated() {
            guide.append((1, [["Chapter \(index + 1): \(name)"],
                              ["It covers one step.", "It has examples.", "It ends with a list."]]))
        }
        page = 1
        for (name, word) in preface {
            guide.append((next(), [["CHAPTER \(word)"], [name], ChapterFixtures.body(page)]))
        }
        let titles = try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.book(guide))).map(\.title)
        XCTAssertEqual(Array(titles.suffix(3)), ["CHAPTER ONE: Getting Started", "CHAPTER TWO: Find Users",
                                                 "CHAPTER THREE: Ship"])
    }

    /// H012: the chapter markers of the languages the importer decodes on
    /// purpose are headings too, with their title lines and running heads
    /// counted once; a marker inside a sentence, or a sentence after one,
    /// stays prose.
    func testLocalizedChapterHeadingsAreFound() throws {
        func titles(_ chapters: [[String]]) throws -> [String] {
            var pages: [(page: Int, paragraphs: [[String]])] = [(1, [[ChapterFixtures.copyright]])]
            for (index, lines) in chapters.enumerated() {
                pages.append((index + 2, lines.map { [$0] } + [ChapterFixtures.body(index + 2)]))
            }
            return try XCTUnwrap(HeadingChapters.entries(in: ChapterFixtures.book(pages)), "\(chapters)").map(\.title)
        }
        XCTAssertEqual(try titles([["第一章 山村少年"], ["第一章 山村少年"], ["第二章", "镇上"], ["第十二章：归来"]]),
                       ["第一章 山村少年", "第二章: 镇上", "第十二章：归来"])
        XCTAssertEqual(try titles([["제1장 시작"], ["제2장"], ["第3話 出会い"]]), ["제1장 시작", "제2장", "第3話 出会い"])
        let russian = [["Глава 1", "Начало"], ["Глава вторая"], ["ГЛАВА ТРЕТЬЯ. Дорога"]]
        let found = ["Глава 1: Начало", "Глава вторая", "ГЛАВА ТРЕТЬЯ. Дорога"]
        XCTAssertEqual(try titles(russian), found)
        XCTAssertEqual(try titles([["Kapitel 1"], ["Zweites Kapitel"], ["Kapitel 3: Die Heimkehr"]]),
                       ["Kapitel 1", "Zweites Kapitel", "Kapitel 3: Die Heimkehr"])
        XCTAssertEqual(try titles([["Chapitre premier"], ["Capítulo II"], ["Capitolo 3"]]),
                       ["Chapitre premier", "Capítulo II", "Capitolo 3"])
        // I007: a bare CJK marker's next paragraph is its title only when
        // it reads as one: not the chapter's opening sentence, a line of
        // dialogue, or unspaced text longer than a heading's title.
        XCTAssertEqual(try titles([["第一章", "清晨，薄雾笼罩着整个小山村，远处传来几声鸡鸣。"], ["第二章", "镇上"],
                                   ["第三章", "清晨薄雾笼罩着整个小山村远处传来几声鸡鸣母亲早早起来生火做饭父亲扛着锄头下地去了"],
                                   ["第四章", "他说：「走吧。」她没有回答"]]),
                       ["第一章", "第二章: 镇上", "第三章", "第四章"])
        XCTAssertEqual(try titles([["第一話", "「先生」"], ["第二話", "出会い"], ["第三話", "彼はそう言って笑った。"]]),
                       ["第一話", "第二話: 出会い", "第三話"])

        for prose in ["第四章就讲完了。", "第五章 我们走了。", "Глава семьи сказал", "Глава 5 описывает дом",
                      "Глава 4. Начало 9", "Kapitel 6 beschreibt das", "Chapitre 7 montre comment."] {
            XCTAssertEqual(try titles([russian[0], [prose], russian[1], russian[2]]), found, prose)
        }

        XCTAssertEqual(HeadingChapters.chapterNumber("第一百零五回"), 105)
        XCTAssertEqual(HeadingChapters.chapterNumber("第１２章 归来"), 12)
        XCTAssertEqual(HeadingChapters.chapterNumber("제 3 장"), 3)
        XCTAssertEqual(HeadingChapters.chapterNumber("ГЛАВА III"), 3)
        XCTAssertEqual(HeadingChapters.chapterNumber("Глава четвёртая"), 4)
        XCTAssertEqual(HeadingChapters.chapterNumber("Erstes Kapitel"), 1)
    }

    func testSparsePageTopsWithoutABookHeaderFailTheGate() {
        var pages: [(page: Int, paragraphs: [[String]])] = []
        let tops = [5: "TARGETS", 9: "TARGETS", 14: "CONCLUSION", 18: "CONCLUSION", 24: "SUMMARY", 27: "SUMMARY"]
        for page in 1...30 {
            pages.append((page, tops[page].map { [[$0], ChapterFixtures.body(page)] } ?? [ChapterFixtures.body(page)]))
        }
        XCTAssertNil(RunningHeaderChapters.entries(in: ChapterFixtures.book(title: "Traction", pages)))
    }

    func testDisplayTitleCasesAllCapsHeaders() {
        XCTAssertEqual(RunningHeaderChapters.displayTitle("WHAT'S A NETWORK EFFECT, ANYWAY?"),
                       "What's a Network Effect, Anyway?")
        XCTAssertEqual(RunningHeaderChapters.displayTitle("ANTI-NETWORK EFFECTS"), "Anti-Network Effects")
        XCTAssertEqual(RunningHeaderChapters.displayTitle("COMPETING OVER THE HARD SIDE"),
                       "Competing over the Hard Side")
        XCTAssertEqual(RunningHeaderChapters.displayTitle("PAYING UP FOR LAUNCH"), "Paying Up for Launch")
        XCTAssertEqual(RunningHeaderChapters.displayTitle("ROCKETSHIP GROWTH T2D3"), "Rocketship Growth T2D3")
        XCTAssertEqual(RunningHeaderChapters.displayTitle("Already Mixed Case"), "Already Mixed Case")
        XCTAssertEqual(RunningHeaderChapters.partTitle("PART II THE COLD START PROBLEM"),
                       "Part II: The Cold Start Problem")
        XCTAssertEqual(RunningHeaderChapters.partTitle("PART ONE"), "Part One")
        XCTAssertNil(RunningHeaderChapters.partTitle("PARTING WORDS"))
        XCTAssertEqual(RunningHeaderChapters.key(of: "TINY SPECK 63"), "TINY SPECK")
        XCTAssertEqual(RunningHeaderChapters.key(of: "xii PREFACE"), "PREFACE")
    }

    // MARK: - Tier order and normalize

    func testTiersRunOutlineThenHeadingsThenRunningHeaders() {
        let traction = ChapterFixtures.traction()
        let outline = [ChapterFixtures.item("PREFACE: Traction Trumps Everything", 1),
                       ChapterFixtures.item("CHAPTER ONE: Traction Channels", 2)]

        XCTAssertEqual(PDFChapterDetector.chapterMap(for: traction, outline: outline).source, .outline)
        XCTAssertEqual(PDFChapterDetector.chapterMap(for: traction, outline: []).source, .headings)
        XCTAssertEqual(PDFChapterDetector.chapterMap(for: ChapterFixtures.coldStart, outline: []).source,
                       .runningHeaders)

        let plain = ChapterFixtures.book((1...6).map { (page: $0, paragraphs: [ChapterFixtures.body($0)]) })
        let nothing = PDFChapterDetector.chapterMap(for: plain, outline: [])
        XCTAssertEqual(nothing.source, ChapterMap.Source.none)
        XCTAssertEqual(nothing.entries, [])
        XCTAssertEqual(nothing.version, ChapterMap.currentVersion)
    }

    func testNormalizeOrdersCleansAndStartsAtZero() throws {
        let content = ChapterFixtures.book((1...10).map { (page: $0, paragraphs: [["Word word word."]]) })
        let long = String(repeating: "Long ", count: 20)
        let raw = [Entry(title: "A", sentence: 2, section: nil),
                   Entry(title: "B", sentence: 2, section: nil),
                   Entry(title: "Gamma", sentence: 5, section: nil),
                   Entry(title: "Delta", sentence: 4, section: nil),
                   Entry(title: long, sentence: 7, section: nil),
                   Entry(title: "Out", sentence: 10, section: nil)]

        let entries = try XCTUnwrap(PDFChapterDetector.normalized(raw, in: content))

        // Six words of front text join the first entry instead of a row.
        XCTAssertEqual(entries.map(\.sentence), [0, 5, 7])
        XCTAssertEqual(entries[0].title, "B")
        XCTAssertEqual(entries[1].title, "Gamma")
        XCTAssertEqual(entries[2].title, DocContent.cleanedChapterTitle(long, maxLength: 80))
        XCTAssertTrue(entries[2].title.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(entries[2].title.count, 81)
        XCTAssertNil(PDFChapterDetector.normalized([Entry(title: "Only", sentence: 3, section: nil)], in: content))
    }
}
