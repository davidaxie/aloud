import PDFKit
import UIKit
import XCTest
@testable import Aloud

/// `FixturePDF` (S12) writes, with CoreGraphics and CoreText alone, PDFs that
/// PDFKit and the extractor read exactly as they read the UIKit-rendered
/// ones the fixtures and extraction tests used before.
final class FixturePDFTests: XCTestCase {

    func testTwoPagesRoundTripThroughTheExtractor() throws {
        let url = temporaryURL()
        try FixturePDF.write(pages: [
            "The first page opens the fixture. It has two sentences.",
            "The second page closes it.",
        ], to: url)

        let output = try PDFTextExtractor().extract(url: url)

        XCTAssertEqual(output.pageCount, 2)
        XCTAssertNil(output.title)
        XCTAssertEqual(output.blocks.map(\.text), [
            "The first page opens the fixture. It has two sentences.",
            "The second page closes it.",
        ])
        XCTAssertEqual(output.blocks.map(\.page), [1, 2])
    }

    func testPagesAreUSLetterAndBlankPagesStayBlank() throws {
        let url = temporaryURL()
        try FixturePDF.write(pages: ["Some text.", ""], to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
        XCTAssertEqual(document.page(at: 1)?.string?.isEmpty ?? true, true)
    }

    func testLongTextWrapsWithoutLosingAWord() throws {
        let url = temporaryURL()
        let sentence = "Every word of this sentence must land on the page inside its margins."
        let text = Array(repeating: sentence, count: 6).joined(separator: " ")
        try FixturePDF.write(pages: [text], to: url)

        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let lines = PDFTextExtractor.lines(of: page)
        XCTAssertGreaterThan(lines.count, 1, "the text didn't wrap")
        XCTAssertEqual(lines.map(\.text).joined(separator: " "), text)
    }

    func testTitleLandsInTheDocumentInfo() throws {
        let url = temporaryURL()
        try FixturePDF.write(pages: ["A short page of text for the title tests."], to: url,
                             title: "The Quiet Hour")

        XCTAssertEqual(try PDFTextExtractor().extract(url: url).title, "The Quiet Hour")
    }

    /// Positioned lines keep the gaps UIKit's `draw(at:)` gave them, so the
    /// extraction tests' layouts (line gaps, running headers, page numbers)
    /// mean the same thing through either renderer. The extractor reads only
    /// the order of lines and the gaps between them, so the gaps are pinned
    /// tightly; where the first baseline sits is the string drawer's line
    /// metrics (AppKit puts Helvetica's 3 pt lower than its ascent), so the
    /// absolute top only has to stay within the font's descent.
    func testPositionedLinesMatchUIKitPlacement() throws {
        let lines: [(text: String, y: CGFloat)] = [
            ("A running header", 40),
            ("The body begins on this line", 120),
            ("and continues on the next one.", 137),
            ("7", 740),
        ]
        let url = temporaryURL()
        try FixturePDF.write(lines: [lines], to: url)

        let fixture = try extractedLines(url)
        let uikit = try extractedLines(uikitPDF(lines))
        XCTAssertEqual(fixture.map(\.text), lines.map(\.text))
        XCTAssertEqual(fixture.map(\.text), uikit.map(\.text))
        for (ours, theirs) in zip(fixture, uikit) {
            XCTAssertEqual(ours.height, theirs.height, accuracy: 1, ours.text)
        }
        for index in fixture.indices.dropFirst() where index < uikit.count {
            XCTAssertEqual(fixture[index - 1].y - fixture[index].y,
                           uikit[index - 1].y - uikit[index].y,
                           accuracy: 0.5, "gap before '\(fixture[index].text)'")
        }
        let font = try XCTUnwrap(UIFont(name: "Helvetica", size: 14))
        if let ours = fixture.first, let theirs = uikit.first {
            XCTAssertEqual(ours.y, theirs.y, accuracy: abs(font.descender) + 1, "the first line's top")
        }
    }

    // MARK: - Helpers

    private func temporaryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-fixture-test-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func extractedLines(_ url: URL) throws -> [PDFTextExtractor.Line] {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        return PDFTextExtractor.lines(of: page)
    }

    /// The renderer the extraction tests used before `FixturePDF`.
    private func uikitPDF(_ lines: [(text: String, y: CGFloat)]) throws -> URL {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "Helvetica", size: 14) ?? UIFont.systemFont(ofSize: 14),
        ]
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            for (text, y) in lines {
                (text as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: attributes)
            }
        }
        let url = temporaryURL()
        try data.write(to: url)
        return url
    }
}
