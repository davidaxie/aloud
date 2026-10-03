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

    // MARK: - Faces (R2)

    /// The faces come through the Platform seam now; each is the face the
    /// UIKit derivation gave before, spelled out here directly.
    func testFacesAreTheOnesUIKitDerived() throws {
        let regular = try XCTUnwrap(UIFont(name: Theme.serifFamilyName, size: 19))
        XCTAssertEqual(ReaderPageStyle.serif(size: 19), regular)

        let boldDescriptor = try XCTUnwrap(regular.fontDescriptor.withSymbolicTraits(
            regular.fontDescriptor.symbolicTraits.union(.traitBold)))
        let bold = UIFont(descriptor: boldDescriptor, size: 19)
        XCTAssertEqual(ReaderPageStyle.serif(size: 19, bold: true).fontDescriptor, bold.fontDescriptor)
        XCTAssertEqual(ReaderPageStyle.serif(size: 19, bold: true).pointSize, 19)

        // Bold Italic under Bold Text: the italic is derived from the bold face.
        let italicDescriptor = try XCTUnwrap(bold.fontDescriptor.withSymbolicTraits(
            bold.fontDescriptor.symbolicTraits.union(.traitItalic)))
        XCTAssertEqual(ReaderPageStyle.italicSerif(size: 19, bold: true).fontDescriptor,
                       UIFont(descriptor: italicDescriptor, size: 19).fontDescriptor)

        let features: [[UIFontDescriptor.FeatureKey: Int]] = [[
            .type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector,
        ]]
        let smallCaps = ReaderPageStyle.smallCapsSerif(size: 23)
        XCTAssertEqual(smallCaps.pointSize, 23)
        XCTAssertEqual(smallCaps.fontDescriptor,
                       UIFont(descriptor: try XCTUnwrap(UIFont(name: Theme.serifFamilyName, size: 23))
                                  .fontDescriptor.addingAttributes([.featureSettings: features]),
                              size: 23).fontDescriptor)
    }

    /// The rule image is today's: the color resolved for the traits'
    /// appearance, drawn at their display scale. Asked of the iOS column's
    /// ink, so it holds whichever helper draws the rule.
    func testRuleImageResolvesForTheTraits() {
        let size = ReaderPageStyle.ruleSize
        let color = UIColor { $0.userInterfaceStyle == .dark ? .blue : .red }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.displayScale = 3
        }
        let image = ReaderInk(traits: traits).ruleImage(size, color)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let expected = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        // The renderer rounds to whole pixels (1.5 pt × 3 → 5 px), so the size
        // is the reference's, not the requested 1.5 pt.
        XCTAssertEqual(image.size, expected.size)
        XCTAssertEqual(image.scale, 3)
        XCTAssertEqual(image.pngData(), expected.pngData())
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
        let built = ReaderColumnText.makeAttributedString(
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
        let built = ReaderColumnText.makeAttributedString(
            content: chaptered(), fontSize: 19, isChapterBook: true)
        let first = style(built, sentence: 6)   // first paragraph of chapter II
        XCTAssertEqual(first?.firstLineHeadIndent, 0)

        let lead = built.string.attribute(.font, at: built.sentenceRanges[6].location,
                                          effectiveRange: nil) as? PlatformFont
        let settings = lead?.fontDescriptor.object(forKey: .featureSettings) as? [[UIFontDescriptor.FeatureKey: Int]]
        XCTAssertNotNil(settings, "opening words carry the small-caps feature")

        // The fourth word is back to plain body.
        let range = built.sentenceRanges[6]
        let fourth = (built.string.string as NSString)
            .range(of: "more", options: [], range: range)
        let plain = built.string.attribute(.font, at: fourth.location, effectiveRange: nil) as? PlatformFont
        XCTAssertNil(plain?.fontDescriptor.object(forKey: .featureSettings))
    }

    @MainActor
    func testOpeningAddsRuleWithoutTouchingSentenceText() {
        let content = chaptered()
        let built = ReaderColumnText.makeAttributedString(
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
