import XCTest
import PDFKit
@testable import Aloud

final class PDFTextExtractorTests: XCTestCase {

    // MARK: - Bundled sample (2-page essay, cross-page paragraph)

    private func sampleURL() throws -> URL {
        try XCTUnwrap(Bundle(for: PDFTextExtractorTests.self)
            .url(forResource: "the-quiet-hour", withExtension: "pdf"),
            "the-quiet-hour.pdf missing from AloudTests resources")
    }

    func testSamplePDFExtractsSentences() async throws {
        let content = try await ExtractionPipeline().extract(pdfURL: sampleURL(), progress: nil)

        XCTAssertEqual(content.pageCount, 2)
        XCTAssertGreaterThan(content.sentences.count, 10)
        XCTAssertEqual(content.contentHash.count, 64)
        XCTAssertFalse(content.paragraphs.isEmpty)

        let joined = content.sentences.map(\.text).joined(separator: " ")
        // Wrapped lines were joined into flowing sentences.
        XCTAssertTrue(joined.contains("It is not the absence of sound"))
        XCTAssertTrue(joined.contains("presence of stillness"))
        // Section headings survive as their own text.
        XCTAssertTrue(joined.contains("On Attention"))
        // Nothing extracted twice.
        XCTAssertEqual(occurrences(of: "Attention is the rarest", in: joined), 1)

        // Paragraph ranges tile the sentence list exactly.
        var next = 0
        for paragraph in content.paragraphs {
            XCTAssertEqual(paragraph.sentenceIDs.lowerBound, next)
            XCTAssertFalse(paragraph.sentenceIDs.isEmpty)
            next = paragraph.sentenceIDs.upperBound
        }
        XCTAssertEqual(next, content.sentences.count)
    }

    func testSamplePDFStitchesParagraphAcrossPages() async throws {
        let content = try await ExtractionPipeline().extract(pdfURL: sampleURL(), progress: nil)
        // Page 1 ends mid-sentence ("...but of") and page 2 opens lowercase
        // ("rhythm and rest."); the stitched sentence must contain both halves.
        let stitched = content.sentences.first { $0.text.contains("rhythm and rest") }
        XCTAssertNotNil(stitched)
        XCTAssertTrue(stitched?.text.contains("but of rhythm and rest") ?? false)
    }

    func testSamplePDFReportsProgress() async throws {
        final class Box: @unchecked Sendable {
            var values: [Double] = []
            let lock = NSLock()
            func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        }
        let box = Box()
        _ = try await ExtractionPipeline().extract(pdfURL: sampleURL()) { box.add($0) }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertEqual(box.values.last, 1.0)
        XCTAssertEqual(box.values, box.values.sorted(), "progress must be monotonic")
    }

    // MARK: - Generated PDFs (deterministic geometry)

    func testRunningHeadersAndPageNumbersStripped() async throws {
        let bodies = [
            "The sparrow returned to the garden at dawn. It stayed near the old wall until the light changed. Nothing else moved in the yard.",
            "A kettle whistled in the kitchen for a long minute. Nobody rose to quiet it down. The sound faded on its own eventually.",
            "Rain traced slow lines down the glass all morning. The street below stayed empty and grey. Only the postman crossed it once.",
            "The letters arrived on Tuesday in a bundle. Most were bills and printed notices. One carried unfamiliar handwriting though.",
        ]
        let url = try makePDF(pages: bodies.enumerated().map { index, body in
            var lines: [(String, CGFloat)] = [("Quiet Journal Weekly", 40)]
            for (i, line) in wrap(body, into: 3).enumerated() {
                lines.append((line, 300 + CGFloat(i) * 20))
            }
            lines.append(("\(index + 1)", 740))
            return lines
        })

        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        let joined = content.sentences.map(\.text).joined(separator: " ")

        XCTAssertEqual(content.pageCount, 4)
        XCTAssertFalse(joined.contains("Quiet Journal Weekly"), "running header must be stripped")
        XCTAssertFalse(content.sentences.contains { $0.text.wholeMatch(of: #/\d{1,4}/#) != nil },
                       "standalone page numbers must be stripped")
        for phrase in ["sparrow returned to the garden", "kettle whistled in the kitchen",
                       "Rain traced slow lines", "letters arrived on Tuesday"] {
            XCTAssertEqual(occurrences(of: phrase, in: joined), 1, "body text for '\(phrase)'")
        }
        // Page attribution follows the source page.
        let sparrow = content.sentences.first { $0.text.contains("sparrow") }
        let letters = content.sentences.first { $0.text.contains("unfamiliar handwriting") }
        XCTAssertEqual(sparrow?.page, 1)
        XCTAssertEqual(letters?.page, 4)
    }

    func testLineWrapDeHyphenation() async throws {
        let url = try makePDF(pages: [[
            ("The council ratified the inter-", 300),
            ("national treaty in early spring.", 320),
        ]])
        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        let joined = content.sentences.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("international treaty"), "got: \(joined)")
        XCTAssertFalse(joined.contains("inter- national"))
    }

    func testParagraphBreakOnLargeVerticalGap() async throws {
        let url = try makePDF(pages: [[
            ("First paragraph line one continues", 300),
            ("and ends right here today.", 320),
            ("Second paragraph starts after a gap.", 420),
        ]])
        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        XCTAssertEqual(content.paragraphs.count, 2)
        XCTAssertTrue(content.sentences[0].text.hasPrefix("First paragraph"))
    }

    func testScannedStylePDFThrowsNoReadableText() async throws {
        // A page with no text at all — the "scanned document" case.
        let url = try makePDF(pages: [[]])
        do {
            _ = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
            XCTFail("expected ExtractionError.noReadableText")
        } catch let error as ExtractionError {
            XCTAssertEqual(error, .noReadableText)
        }
    }

    func testInvalidFileThrowsInvalidPDF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
            XCTFail("expected ExtractionError.invalidPDF")
        } catch let error as ExtractionError {
            XCTAssertEqual(error, .invalidPDF)
        }
    }

    // MARK: - Helpers

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Split `text` into `count` roughly equal word-boundary lines.
    private func wrap(_ text: String, into count: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        let per = max(1, Int((Double(words.count) / Double(count)).rounded(.up)))
        return stride(from: 0, to: words.count, by: per).map {
            words[$0..<min($0 + per, words.count)].joined(separator: " ")
        }
    }

    /// Render a deterministic PDF: each page is a list of (text, y-from-top)
    /// lines drawn in 14 pt Helvetica on US Letter.
    private func makePDF(pages: [[(String, CGFloat)]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-test-\(UUID().uuidString).pdf")
        try FixturePDF.write(lines: pages.map { $0.map { (text: $0.0, y: $0.1) } }, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
