import XCTest
@testable import Aloud

/// R12a: the reading column's Chapters (Pages), Paragraphs and Sentences
/// rotors walk item starts by binary search, building nothing up front.
final class ReaderRotorTests: XCTestCase {

    /// One sentence per page entry; `paragraphs` as given (default: none).
    private func content(pages: [Int], paragraphs: [Range<Int>] = []) -> DocContent {
        let sentences = pages.enumerated().map { index, page in
            Sentence(id: index, text: "Sentence text \(index).", para: 0, page: page)
        }
        let paras = paragraphs.enumerated().map { index, range in
            Paragraph(id: index, sentenceIDs: range, page: 1)
        }
        return DocContent(title: "Test", pageCount: pages.max() ?? 0, sentences: sentences,
                          paragraphs: paras, contentHash: "h")
    }

    private func target(_ rotor: ReaderRotor, from: Int?, anchor: Int = 0, forward: Bool,
                        content: DocContent, navigation: ReaderNavigation? = nil) -> Int? {
        ReaderRotor.target(rotor, from: from, anchor: anchor, forward: forward,
                           content: content, navigation: navigation)
    }

    // MARK: - Names

    func testNamesAndCopy() {
        XCTAssertEqual(ReaderRotor.chapters.name(for: .text), "Chapters")
        XCTAssertEqual(ReaderRotor.chapters.name(for: .pdf), "Pages")
        XCTAssertEqual(ReaderRotor.paragraphs.name(for: .text), "Paragraphs")
        XCTAssertEqual(ReaderRotor.sentences.name(for: .pdf), "Sentences")
        XCTAssertEqual(ReaderRotor.playFromHere, "Play from here")
        XCTAssertEqual(ReaderRotor.textHint, "Plays from this sentence")
    }

    func testAvailableRotorsRunCoarseToFine() {
        let chaptered = content(pages: [1, 1, 2, 2], paragraphs: [0..<2, 2..<4])
        let navigation = ReaderNavigation(content: chaptered, kind: .text)
        XCTAssertEqual(ReaderRotor.available(content: chaptered, navigation: navigation),
                       [.chapters, .paragraphs, .sentences])
        XCTAssertEqual(ReaderRotor.available(content: chaptered, navigation: nil),
                       [.paragraphs, .sentences])

        let chapterless = content(pages: [1, 1], paragraphs: [0..<2])
        XCTAssertEqual(ReaderRotor.available(content: chapterless,
                                             navigation: ReaderNavigation(content: chapterless, kind: .text)),
                       [.paragraphs, .sentences])

        let bare = content(pages: [1, 1])
        XCTAssertEqual(ReaderRotor.available(content: bare, navigation: nil), [.sentences])
        XCTAssertEqual(ReaderRotor.available(content: content(pages: []), navigation: nil), [])
    }

    // MARK: - Walks

    func testSentenceWalk() {
        let ten = content(pages: Array(repeating: 1, count: 10))
        XCTAssertEqual(target(.sentences, from: nil, anchor: 5, forward: true, content: ten), 5,
                       "the first step lands on the playhead's own sentence")
        XCTAssertEqual(target(.sentences, from: 5, forward: true, content: ten), 6)
        XCTAssertEqual(target(.sentences, from: 5, forward: false, content: ten), 4)
        XCTAssertNil(target(.sentences, from: 9, forward: true, content: ten))
        XCTAssertNil(target(.sentences, from: 0, forward: false, content: ten))
        XCTAssertNil(target(.sentences, from: nil, anchor: 0, forward: true, content: content(pages: [])))
    }

    /// Paragraphs [0,3), [3,3) empty, [3,6), [6,8), [8,8) empty and past the end.
    func testParagraphWalkSkipsEmptyRanges() {
        let text = content(pages: Array(repeating: 1, count: 8),
                           paragraphs: [0..<3, 3..<3, 3..<6, 6..<8, 8..<8])
        XCTAssertEqual(target(.paragraphs, from: nil, anchor: 4, forward: true, content: text), 3)
        XCTAssertEqual(target(.paragraphs, from: nil, anchor: 7, forward: false, content: text), 6)
        XCTAssertEqual(target(.paragraphs, from: 0, forward: true, content: text), 3)
        XCTAssertEqual(target(.paragraphs, from: 3, forward: true, content: text), 6)
        XCTAssertNil(target(.paragraphs, from: 6, forward: true, content: text),
                     "the empty last paragraph is no stop")
        XCTAssertEqual(target(.paragraphs, from: 4, forward: false, content: text), 3,
                       "past the paragraph's start: back to it")
        XCTAssertEqual(target(.paragraphs, from: 3, forward: false, content: text), 0)
        XCTAssertNil(target(.paragraphs, from: 0, forward: false, content: text))
    }

    /// Pages [1,1,2,2,2,3]: chapters start at 0, 2 and 5.
    func testChapterWalk() {
        let text = content(pages: [1, 1, 2, 2, 2, 3])
        let navigation = ReaderNavigation(content: text, kind: .text)
        func step(from: Int?, anchor: Int = 0, forward: Bool) -> Int? {
            target(.chapters, from: from, anchor: anchor, forward: forward, content: text, navigation: navigation)
        }
        XCTAssertEqual(step(from: nil, anchor: 3, forward: true), 2)
        XCTAssertEqual(step(from: 0, forward: true), 2)
        XCTAssertEqual(step(from: 2, forward: true), 5)
        XCTAssertNil(step(from: 5, forward: true))
        XCTAssertEqual(step(from: 3, forward: false), 2)
        XCTAssertEqual(step(from: 2, forward: false), 0)
        XCTAssertNil(step(from: 0, forward: false))
        XCTAssertNil(target(.chapters, from: 0, forward: true, content: text, navigation: nil))
    }

    /// J019: in a PDF with no outline and more pages than Contents lists,
    /// the rows group pages ("Pages 13–24"), but the rotor named Pages still
    /// moves one page a flick, as Next Page does, and names the page it
    /// lands on.
    func testPagesRotorStepsOnePageWhereContentsGroupsPages() {
        // 60 pages of two 41-word sentences: page p starts at sentence 2(p-1).
        let sentences = (1...60).flatMap { page in [page, page] }.enumerated().map { index, page in
            Sentence(id: index, text: String(repeating: "Word ", count: 40) + "end.", para: index, page: page)
        }
        let pdf = DocContent(title: "Long", pageCount: 60, sentences: sentences, paragraphs: [],
                             contentHash: "long")
        let navigation = ReaderNavigation(content: pdf, kind: .pdf)
        XCTAssertLessThan(navigation.chapters.count, 60, "fixture: Contents groups the pages")
        XCTAssertEqual(ReaderRotor.chapters.name(listing: navigation, isChapterBook: false), "Pages")
        func step(from: Int?, anchor: Int = 0, forward: Bool) -> Int? {
            target(.chapters, from: from, anchor: anchor, forward: forward, content: pdf, navigation: navigation)
        }
        var landed: [Int] = []
        var at = step(from: nil, forward: true)
        while let here = at {
            landed.append(here)
            at = step(from: here, forward: true)
        }
        XCTAssertEqual(landed, Array(stride(from: 0, through: 118, by: 2)), "every page, one flick each")
        XCTAssertEqual(step(from: 27, forward: false), 26, "back to this page's start")
        XCTAssertEqual(step(from: 26, forward: false), 24, "then the page before")
        XCTAssertEqual(step(from: nil, anchor: 27, forward: true), 26, "the first flick lands on the playhead's page")
        XCTAssertEqual(navigation.rotorStepTitle(containing: 27), "Page 14", "the landing names its own page")
        XCTAssertEqual(navigation.rotorStepTitle(containing: 0), "Page 1")
        // Ungrouped rows are the steps, named as Contents names them.
        let text = content(pages: [1, 1, 2, 2, 2, 3])
        let chaptered = ReaderNavigation(content: text, kind: .text)
        XCTAssertEqual(chaptered.rotorSteps.map(\.startSentence), chaptered.chapters.map(\.startSentence))
        XCTAssertEqual(chaptered.rotorStepTitle(containing: 3), chaptered.title(ofChapter: 1))
    }

    // MARK: - Cost

    /// Pepys-scale: 1,000 paragraph steps over 60,000 sentences in 20,000
    /// paragraphs well inside a VoiceOver swipe.
    func testParagraphStepsAreCheap() {
        let sentences = (0..<60_000).map { Sentence(id: $0, text: "w.", para: $0 / 3, page: 1) }
        let paragraphs = (0..<20_000).map { Paragraph(id: $0, sentenceIDs: ($0 * 3)..<($0 * 3 + 3), page: 1) }
        let big = DocContent(title: "Big", pageCount: 1, sentences: sentences,
                             paragraphs: paragraphs, contentHash: "h")
        let start = CFAbsoluteTimeGetCurrent()
        var landed = 0
        for index in 0..<1_000 {
            landed &+= ReaderRotor.target(.paragraphs, from: index * 59, anchor: 0, forward: index.isMultiple(of: 2),
                                          content: big, navigation: nil) ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertGreaterThan(landed, 0)
        XCTAssertLessThan(elapsed, 0.05, "1,000 paragraph targets took \(elapsed) s")
    }
}
