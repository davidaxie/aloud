import XCTest
@testable import Aloud

/// A word split by a soft hyphen (U+00AD) at a page break is rejoined like
/// one split by a normal hyphen, not glued back with a space.
final class ExtractionPDFSoftHyphenTests: XCTestCase {

    private func line(_ text: String, y: CGFloat) -> PDFTextExtractor.Line {
        PDFTextExtractor.Line(text: text, y: y, height: 14)
    }

    private func stitch(_ pages: [[PDFTextExtractor.Line]]) -> [String] {
        var blocks: [TextBlock] = []
        for (index, lines) in pages.enumerated() {
            PDFTextExtractor.appendPageParagraphs(&blocks, PDFTextExtractor.paragraphs(from: lines),
                                                  page: index + 1)
        }
        return blocks.map { TextNormalizer.normalize($0.text) }
    }

    func testSoftHyphenAcrossPagesRejoinsTheWord() {
        let blocks = stitch([
            [line("The council ratified the inter\u{00AD}", y: 500)],
            [line("national treaty in early spring.", y: 700)],
        ])
        XCTAssertEqual(blocks, ["The council ratified the international treaty in early spring."])
    }

    func testNormalHyphenAcrossPagesStillRejoins() {
        let blocks = stitch([
            [line("The council ratified the inter-", y: 500)],
            [line("national treaty in early spring.", y: 700)],
        ])
        XCTAssertEqual(blocks, ["The council ratified the international treaty in early spring."])
    }

    func testSoftHyphenWithinAPageRejoins() {
        let blocks = stitch([[
            line("The council ratified the inter\u{00AD}", y: 500),
            line("national treaty in early spring.", y: 482),
        ]])
        XCTAssertEqual(blocks, ["The council ratified the international treaty in early spring."])
    }

    func testSoftHyphenAfterANonASCIILetterRejoins() {
        let blocks = stitch([
            [line("Die Kinder liefen durch den Schwarzw\u{E4}l\u{00AD}", y: 500)],
            [line("der und sangen dabei laut.", y: 700)],
        ])
        XCTAssertEqual(blocks, ["Die Kinder liefen durch den Schwarzw\u{E4}lder und sangen dabei laut."])
        XCTAssertEqual(PDFTextExtractor.appendLine("une id\u{E9}e tr\u{E8}s s\u{E9}\u{00AD}", "\u{E9}lective"),
                       "une id\u{E9}e tr\u{E8}s s\u{E9}\u{E9}lective")
    }

    func testTrailingSoftHyphenWithoutContinuationLeavesNoMark() {
        let blocks = stitch([[line("The last word on the last page is inter\u{00AD}", y: 500)]])
        XCTAssertEqual(blocks, ["The last word on the last page is inter"])
        XCTAssertFalse(blocks[0].unicodeScalars.contains("\u{00AD}"))
    }
}
