import XCTest
import PDFKit
@testable import Aloud

/// A PDF without Title metadata is named after the file the user picked,
/// never after the UUID-named copy the library keeps.
final class ExtractionPDFTitleTests: XCTestCase {

    func testUntitledLibraryCopyIsNotNamedByUUID() async throws {
        let url = try makePDF(fileName: "\(UUID().uuidString).pdf", title: nil)
        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        XCTAssertEqual(content.title, "Untitled")
    }

    func testFallbackTitleNamesAnUntitledPDF() async throws {
        let url = try makePDF(fileName: "\(UUID().uuidString).pdf", title: nil)
        let content = try await ExtractionPipeline()
            .extract(pdfURL: url, fallbackTitle: "Quarterly Report", progress: nil)
        XCTAssertEqual(content.title, "Quarterly Report")
    }

    func testFileNameNamesAnUntitledPDFWithoutFallback() async throws {
        let url = try makePDF(fileName: "lecture-notes-\(UUID().uuidString.prefix(4)).pdf", title: nil)
        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        XCTAssertTrue(content.title.hasPrefix("lecture-notes"), "got: \(content.title)")
    }

    func testMetadataTitleWinsOverFallback() async throws {
        let url = try makePDF(fileName: "\(UUID().uuidString).pdf", title: "The Quiet Hour")
        let content = try await ExtractionPipeline()
            .extract(pdfURL: url, fallbackTitle: "Quarterly Report", progress: nil)
        XCTAssertEqual(content.title, "The Quiet Hour")
    }

    func testFileTitle() {
        XCTAssertEqual(ExtractionPipeline.fileTitle(of: URL(fileURLWithPath: "/tmp/Report.pdf")), "Report")
        XCTAssertEqual(ExtractionPipeline.fileTitle(
            of: URL(fileURLWithPath: "/tmp/3F2504E0-4F89-11D3-9A0C-0305E82C3301.pdf")), "")
    }

    // MARK: - Helpers

    private func makePDF(fileName: String, title: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try FixturePDF.write(lines: [[(text: "A short page of text for the title tests.", y: 300)]],
                             to: url, title: title)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
