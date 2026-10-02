import XCTest
@testable import Aloud

/// NFKC must not turn fractions and superscripts into different numbers
/// ("4½" became "41⁄2", read "forty-one").
final class ExtractionFractionTests: XCTestCase {

    func testVulgarFractionsSurvive() {
        XCTAssertEqual(TextNormalizer.normalize("It is in New Zealand stock, paying 4½ per cent."),
                       "It is in New Zealand stock, paying 4½ per cent.")
        XCTAssertEqual(TextNormalizer.normalize("18¾ miles"), "18¾ miles")
        XCTAssertEqual(TextNormalizer.normalize("$8.40¾ Oil"), "$8.40¾ Oil")
        XCTAssertEqual(TextNormalizer.normalize("at 90⅛ and 89¼"), "at 90⅛ and 89¼")
        XCTAssertEqual(TextNormalizer.normalize("½ a mile, ⅓ of it"), "½ a mile, ⅓ of it")
    }

    func testSuperscriptsSurvive() {
        XCTAssertEqual(TextNormalizer.normalize("x² + y³"), "x² + y³")
        XCTAssertEqual(TextNormalizer.normalize("10⁶ cells"), "10⁶ cells")
        XCTAssertEqual(TextNormalizer.normalize("in childhood.¹ Then"), "in childhood.¹ Then")
    }

    func testOtherCompatibilityFormsStillFold() {
        XCTAssertEqual(TextNormalizer.normalize("ﬁve and ½ ﬂoors"), "five and ½ floors")
        XCTAssertEqual(TextNormalizer.normalize("ﬁ4½ﬂ"), "fi4½fl")
        XCTAssertEqual(TextNormalizer.normalize("\u{FF11}\u{FF12} items"), "12 items") // full-width digits
        XCTAssertEqual(TextNormalizer.normalize("H₂O"), "H2O")
    }

    func testIdempotent() {
        let once = TextNormalizer.normalize("ﬁrst 4½\u{2014}then 10⁶, x²\u{2026}")
        XCTAssertEqual(TextNormalizer.normalize(once), once)
    }

    func testFractionSurvivesTheTextPipeline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-fraction-\(UUID().uuidString).txt")
        try Data("It is in New Zealand stock, paying 4½ per cent.".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        XCTAssertEqual(content.sentences.map(\.text), ["It is in New Zealand stock, paying 4½ per cent."])
    }
}
