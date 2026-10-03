import XCTest
import UIKit
@testable import Aloud

/// The reading column's attributed string (`ReaderColumnText`), which both
/// columns build: sentence ranges exact after typesetting, chapter openings
/// in text books, page marks in PDFs, and the Bold Text flag and ink that
/// stand in for a trait collection.
final class ReaderColumnTextTests: XCTestCase {

    // MARK: - Reader attributed string

    private func makeContent(_ paragraphs: [[(text: String, page: Int)]]) -> DocContent {
        var sentences: [Sentence] = []
        var paras: [Paragraph] = []
        for (p, entries) in paragraphs.enumerated() {
            let start = sentences.count
            for entry in entries {
                sentences.append(Sentence(id: sentences.count, text: entry.text, para: p, page: entry.page))
            }
            paras.append(Paragraph(id: p, sentenceIDs: start..<sentences.count,
                                   page: entries.first?.page ?? 1))
        }
        return DocContent(title: "Test", pageCount: paras.map(\.page).max() ?? 1,
                          sentences: sentences, paragraphs: paras, contentHash: "h")
    }

    @MainActor
    func testSentenceRangesMatchSourceLengthsAfterTypesetting() {
        let content = makeContent([
            [("I", 1)],
            [(#""Whenever you feel," he said, "remember that.""#, 1), ("It was--late.", 1)],
            [("II", 2)],
            [("Simon Called Peter - either it was terrible.", 2)],
        ])
        let built = ReaderColumnText.makeAttributedString(
            content: content, fontSize: 19, isChapterBook: true)
        let rendered = built.string.string as NSString
        for sentence in content.sentences {
            let range = built.sentenceRanges[sentence.id]
            XCTAssertEqual(range.length, sentence.text.utf16.count)
            XCTAssertEqual(rendered.substring(with: range),
                           ReaderTypography.typeset(sentence.text))
        }
    }

    /// Three chapters, five paragraphs apart: a genuinely chaptered book.
    private func chapteredContent() -> DocContent {
        var paragraphs: [[(text: String, page: Int)]] = []
        for (chapter, numeral) in ["I", "II", "III"].enumerated() {
            paragraphs.append([(numeral, chapter + 1)])
            for n in 1...4 {
                paragraphs.append([("Paragraph \(n) of chapter \(numeral) runs on for a while.", chapter + 1)])
            }
        }
        return makeContent(paragraphs)
    }

    @MainActor
    func testChapterBooksStyleHeadingsAndDropPageMarks() {
        let content = chapteredContent()
        let built = ReaderColumnText.makeAttributedString(
            content: content, fontSize: 19, isChapterBook: true)
        XCTAssertFalse(built.string.string.contains("PAGE"),
                       "text books group by chapter; no page marks")

        let bodyFont = built.string.attribute(.font, at: built.sentenceRanges[2].location,
                                              effectiveRange: nil) as? UIFont
        for heading in [0, 5, 10] {
            let location = built.sentenceRanges[heading].location
            let style = built.string.attribute(.paragraphStyle, at: location,
                                               effectiveRange: nil) as? NSParagraphStyle
            let font = built.string.attribute(.font, at: location, effectiveRange: nil) as? UIFont
            XCTAssertEqual(style?.alignment, .center, "heading \(heading) should be centered")
            XCTAssertGreaterThan(font?.pointSize ?? 0, bodyFont?.pointSize ?? .infinity)
        }
    }

    @MainActor
    func testTooFewHeadingsGetNoOpenings() {
        let content = makeContent([
            [("I", 1)],
            [("In my younger years my father gave me some advice.", 1)],
            [("II", 2)],
            [("About half way between West Egg and New York.", 2)],
        ])
        let built = ReaderColumnText.makeAttributedString(
            content: content, fontSize: 19, isChapterBook: true)
        let style = built.string.attribute(.paragraphStyle, at: built.sentenceRanges[2].location,
                                           effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(style?.alignment, .center, "two headings are not enough for openings")
        XCTAssertFalse(built.string.string.contains("PAGE"))
    }

    @MainActor
    func testPDFsKeepPageMarksAndPlainParagraphs() {
        let content = makeContent([
            [("First page text.", 1)],
            [("Second page text.", 2)],
        ])
        let built = ReaderColumnText.makeAttributedString(
            content: content, fontSize: 19, isChapterBook: false)
        // A hairline attachment over the page numeral, never "PAGE N".
        XCTAssertFalse(built.string.string.contains("PAGE"))
        XCTAssertTrue(built.string.string.contains("\u{FFFC}\n2\n"))
        let style = built.string.attribute(.paragraphStyle, at: built.sentenceRanges[0].location,
                                           effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(style?.alignment, .center)
    }

    // MARK: - Bold Text and ink

    /// Every rule image the column asked the ink for.
    private final class Rules {
        var drawn: [(size: CGSize, color: UIColor)] = []
    }

    /// Plain, distinct colors, so each attribute shows which one it took.
    private func ink(_ rules: Rules = Rules()) -> ReaderInk {
        ReaderInk(text: .red, textMuted: .green, accent: .blue, lineStrong: .orange,
                  ruleImage: { size, color in
                      rules.drawn.append((size, color))
                      return UIImage()
                  })
    }

    private func font(at location: Int, in string: NSAttributedString) -> UIFont? {
        string.attribute(.font, at: location, effectiveRange: nil) as? UIFont
    }

    private func color(at location: Int, in string: NSAttributedString) -> UIColor? {
        string.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }

    @MainActor
    func testBoldTakesTheSerifsBoldFaceAndKeepsTheText() {
        let content = makeContent([[("A plain sentence.", 1)]])
        let regular = ReaderColumnText.makeAttributedString(content: content, fontSize: 19, bold: false, ink: ink())
        let bold = ReaderColumnText.makeAttributedString(content: content, fontSize: 19, bold: true, ink: ink())
        XCTAssertEqual(font(at: regular.sentenceRanges[0].location, in: regular.string),
                       ReaderPageStyle.serif(size: 19, bold: false))
        XCTAssertEqual(font(at: bold.sentenceRanges[0].location, in: bold.string),
                       ReaderPageStyle.serif(size: 19, bold: true))
        XCTAssertEqual(regular.string.string, bold.string.string, "Bold Text changes the face, never the text")
        XCTAssertEqual(regular.sentenceRanges, bold.sentenceRanges)
    }

    @MainActor
    func testABoldTraitCollectionBuildsTheBoldColumn() {
        let content = makeContent([[("A plain sentence.", 1)]])
        let built = ReaderColumnText.makeAttributedString(
            content: content, fontSize: 19, traits: UITraitCollection(legibilityWeight: .bold))
        XCTAssertEqual(font(at: built.sentenceRanges[0].location, in: built.string),
                       ReaderPageStyle.serif(size: 19, bold: true))
        let mark = ReaderColumnText.makeEndMark(colophon: nil, fontSize: 19,
                                                traits: UITraitCollection(legibilityWeight: .bold))
        XCTAssertEqual(mark.string, "· · ·")
    }

    @MainActor
    func testTheInkColorsTheTextTheMarksAndThePageRule() {
        let rules = Rules()
        let content = makeContent([
            [("First page text.", 1)],
            [("Second page text.", 2)],
        ])
        let built = ReaderColumnText.makeAttributedString(content: content, fontSize: 19,
                                                          bold: false, ink: ink(rules))
        XCTAssertEqual(color(at: built.sentenceRanges[1].location, in: built.string), .red, "body text")
        XCTAssertEqual(color(at: built.endMarkRange.location, in: built.string), .green, "the end mark is muted")
        let numeral = (built.string.string as NSString).range(of: "\n2\n")
        XCTAssertEqual(color(at: numeral.location + 1, in: built.string), .green, "the page numeral is muted")
        XCTAssertEqual(rules.drawn.count, 1, "one page break, one hairline")
        XCTAssertEqual(rules.drawn.first?.size, ReaderPageStyle.pageRuleSize)
        XCTAssertEqual(rules.drawn.first?.color, .orange)
    }

    @MainActor
    func testTheColophonTakesItsRuleAndColorsFromTheInk() {
        let rules = Rules()
        let colophon = ReaderColophon(title: "Lines", author: "A. Writer", words: 165 * 72, rate: 1)
        let mark = ReaderColumnText.makeEndMark(colophon: colophon, fontSize: 19, bold: false, ink: ink(rules))
        XCTAssertEqual(rules.drawn.count, 1)
        XCTAssertEqual(rules.drawn.first?.size, ReaderPageStyle.ruleSize)
        XCTAssertEqual(rules.drawn.first?.color, .blue, "the accent rule")
        let text = mark.string as NSString
        XCTAssertEqual(color(at: text.range(of: ColophonCopy.theEnd).location, in: mark), .red)
        XCTAssertEqual(color(at: text.range(of: "A. Writer").location, in: mark), .green)
    }
}
