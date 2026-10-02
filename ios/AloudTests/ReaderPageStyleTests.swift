import XCTest
import UIKit
@testable import Aloud

/// Book-page typesetting (PRD R5): leading scale, indents, hyphenation, and
/// which chapter headings earn an opening.
final class ReaderPageStyleTests: XCTestCase {

    // MARK: - Leading

    func testLeadingTableValues() {
        XCTAssertEqual(ReaderPageStyle(fontSize: 16).lineHeight, 26)     // 16 × 1.60 = 25.6
        XCTAssertEqual(ReaderPageStyle(fontSize: 17.5).lineHeight, 28)   // 27.65
        XCTAssertEqual(ReaderPageStyle(fontSize: 19).lineHeight, 29)     // 29.45
        XCTAssertEqual(ReaderPageStyle(fontSize: 21).lineHeight, 32)     // 31.92
        XCTAssertEqual(ReaderPageStyle(fontSize: 23).lineHeight, 35)     // 34.5
        XCTAssertEqual(ReaderPageStyle(fontSize: 30).lineHeightMultiple, 1.50, accuracy: 0.0001)
    }

    func testLeadingInterpolatesBetweenTablePoints() {
        let mid = ReaderPageStyle(fontSize: 20).lineHeightMultiple   // between 19 (1.55) and 21 (1.52)
        XCTAssertEqual(mid, 1.535, accuracy: 0.0001)
        XCTAssertEqual(ReaderPageStyle(fontSize: 12).lineHeightMultiple, 1.60, accuracy: 0.0001)
    }

    // MARK: - Openings

    func testOpeningsNeedThreeHeadings() {
        XCTAssertEqual(ReaderPageStyle.openingParagraphs(candidates: [0, 10]), [])
        XCTAssertEqual(ReaderPageStyle.openingParagraphs(candidates: [0, 10, 20]), [0, 10, 20])
    }

    func testOpeningsTooCloseTogetherAreDropped() {
        XCTAssertEqual(ReaderPageStyle.openingParagraphs(candidates: [0, 3, 10, 12, 20]), [0, 10, 20])
    }

    // MARK: - Small caps run

    func testFirstWordsLength() {
        XCTAssertEqual(ReaderPageStyle.utf16LengthOfFirstWords("In my younger and more", count: 3),
                       "In my younger".utf16.count)
        XCTAssertEqual(ReaderPageStyle.utf16LengthOfFirstWords("Short one", count: 3),
                       "Short one".utf16.count)
        XCTAssertEqual(ReaderPageStyle.utf16LengthOfFirstWords("  Lead  space here now", count: 2),
                       "  Lead  space".utf16.count)
    }

    // MARK: - Attributed string

    private func chaptered() -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for (chapter, numeral) in ["I", "II", "III"].enumerated() {
            for text in [numeral, "In my younger and more vulnerable years.",
                         "Second paragraph here.", "Third paragraph here.", "Fourth paragraph here."] {
                let id = sentences.count
                sentences.append(Sentence(id: id, text: text, para: paragraphs.count, page: chapter + 1))
                paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: id..<(id + 1),
                                            page: chapter + 1))
            }
        }
        return DocContent(title: "T", pageCount: 3, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "h")
    }

    private func style(_ built: (string: NSAttributedString, sentenceRanges: [NSRange], endMarkRange: NSRange),
                       sentence: Int) -> NSParagraphStyle? {
        built.string.attribute(.paragraphStyle, at: built.sentenceRanges[sentence].location,
                               effectiveRange: nil) as? NSParagraphStyle
    }

    @MainActor
    func testBodyParagraphsUseBookMetrics() {
        let built = ReaderTextView.Coordinator.makeAttributedString(
            content: chaptered(), fontSize: 19, isChapterBook: true)
        let body = style(built, sentence: 2)   // an ordinary paragraph mid-chapter
        XCTAssertEqual(body?.minimumLineHeight, 29)
        XCTAssertEqual(body?.maximumLineHeight, 29)
        XCTAssertEqual(body?.firstLineHeadIndent, 21)   // round(1.1 × 19)
        XCTAssertEqual(body?.paragraphSpacing, 9)       // round(0.45 × 19)
        XCTAssertEqual(body?.hyphenationFactor, 0.25)
        XCTAssertEqual(body?.alignment, .natural)
    }

    @MainActor
    func testParagraphAfterOpeningIsUnindentedWithSmallCapsLead() {
        let built = ReaderTextView.Coordinator.makeAttributedString(
            content: chaptered(), fontSize: 19, isChapterBook: true)
        let first = style(built, sentence: 6)   // first paragraph of chapter II
        XCTAssertEqual(first?.firstLineHeadIndent, 0)

        let lead = built.string.attribute(.font, at: built.sentenceRanges[6].location,
                                          effectiveRange: nil) as? UIFont
        let settings = lead?.fontDescriptor.object(forKey: .featureSettings) as? [[UIFontDescriptor.FeatureKey: Int]]
        XCTAssertNotNil(settings, "opening words carry the small-caps feature")

        // The fourth word is back to plain body.
        let range = built.sentenceRanges[6]
        let fourth = (built.string.string as NSString)
            .range(of: "more", options: [], range: range)
        let plain = built.string.attribute(.font, at: fourth.location, effectiveRange: nil) as? UIFont
        XCTAssertNil(plain?.fontDescriptor.object(forKey: .featureSettings))
    }

    @MainActor
    func testOpeningAddsRuleWithoutTouchingSentenceText() {
        let content = chaptered()
        let built = ReaderTextView.Coordinator.makeAttributedString(
            content: content, fontSize: 19, isChapterBook: true)
        let rendered = built.string.string as NSString
        for sentence in content.sentences {
            XCTAssertEqual(rendered.substring(with: built.sentenceRanges[sentence.id]),
                           ReaderTypography.typeset(sentence.text))
        }
        // One accent rule per opening (three chapters).
        let attachments = rendered.components(separatedBy: "\u{FFFC}").count - 1
        XCTAssertEqual(attachments, 3)
    }
}
