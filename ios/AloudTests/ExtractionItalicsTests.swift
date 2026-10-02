import XCTest
@testable import Aloud

/// Gutenberg plain text marks italics as _word_; the markers are removed so
/// the reader doesn't show them. Underscores that aren't italics stay.
final class ExtractionItalicsTests: XCTestCase {

    func testPairedMarkersAreRemoved() {
        XCTAssertEqual(TextExtractor.strippingItalicMarkers(
            "Abbey, _its completeness, finish, and_ entrain, _obscure the undoubted_ merit."),
            "Abbey, its completeness, finish, and entrain, obscure the undoubted merit.")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("There was nothing so _very_ remarkable."),
                       "There was nothing so very remarkable.")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("_Chap 34._"), "Chap 34.")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("“_You_ are dancing,” _she_ said."),
                       "“You are dancing,” she said.")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("_a_ _b_"), "a b")
    }

    func testSpanAcrossAWrappedLine() {
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("when the Rabbit actually _took a\nwatch out of its waistcoat-pocket_, and looked"),
                       "when the Rabbit actually took a\nwatch out of its waistcoat-pocket, and looked")
    }

    func testOtherUnderscoresStay() {
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("snake_case_name"), "snake_case_name")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("Mr. ____ was absent."), "Mr. ____ was absent.")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("__init__"), "__init__")
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("a lone _ mark"), "a lone _ mark")
    }

    /// A prepended mark (U+0600, U+0605, U+0D4E, U+110BD) joins the "_" after
    /// it into one character: that underscore is no marker, and stripping
    /// must not step back past the start of the string (it used to trap).
    func testUnderscoreJoinedToAPrependedMarkDoesNotCrash() {
        for prepend in ["\u{0600}", "\u{0605}", "\u{0D4E}", "\u{110BD}"] {
            XCTAssertEqual(TextExtractor.strippingItalicMarkers(prepend + "_x_"), prepend + "_x_")
            XCTAssertEqual(TextExtractor.strippingItalicMarkers(prepend + "_x_ and more"), prepend + "_x_ and more")
        }
        // With a space between, the pair is an ordinary italic span.
        XCTAssertEqual(TextExtractor.strippingItalicMarkers("\u{0600} _x_"), "\u{0600} x")
    }

    func testFileWithAPrependedMarkBeforeAnItalicPairExtracts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-italics-\(UUID().uuidString).txt")
        try Data("Some ordinary first paragraph.\n\n  \u{0605}_note_ second paragraph here.\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        XCTAssertEqual(content.paragraphs.count, 2)
        XCTAssertTrue(content.sentences.contains { $0.text.contains("second paragraph") })
    }

    func testExtractedSentencesHaveNoMarkers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-italics-\(UUID().uuidString).txt")
        try Data("There was nothing so _very_ remarkable in that.".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        XCTAssertEqual(content.sentences.map(\.text), ["There was nothing so very remarkable in that."])
    }
}
