import XCTest
@testable import Aloud

/// Text files saved by Windows Notepad or Word as "ANSI" are Windows-1252:
/// their curly quotes, apostrophes and dashes must survive decoding.
final class ExtractionEncodingTests: XCTestCase {

    private func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func extractBlocks(_ bytes: [UInt8]) throws -> [TextBlock] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-encoding-\(UUID().uuidString).txt")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try TextExtractor().extract(url: url).blocks
    }

    func testWindows1252PunctuationIsDecoded() throws {
        // "I’ll say it “twice” — don’t…" in Windows-1252, no BOM.
        let parts: [[UInt8]] = [utf8("I"), [0x92], utf8("ll say it "), [0x93], utf8("twice"),
                                [0x94], utf8(" "), [0x97], utf8(" don"), [0x92], utf8("t"), [0x85]]
        let blocks = try extractBlocks(parts.flatMap { $0 })
        XCTAssertEqual(blocks.map(\.text), ["I\u{2019}ll say it \u{201C}twice\u{201D} \u{2014} don\u{2019}t\u{2026}"])
    }

    func testWindows1252TextKeepsApostrophesThroughThePipeline() async throws {
        let parts: [[UInt8]] = [utf8("We"), [0x92], utf8("ll see; it"), [0x92], utf8("s late.")]
        let bytes = parts.flatMap { $0 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-encoding-\(UUID().uuidString).txt")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        let text = content.sentences.map(\.text).joined(separator: " ")
        // The apostrophes are kept (in whatever form the normalizer speaks
        // them), never deleted into "Well see; its late."
        XCTAssertFalse(text.contains("Well see"))
        XCTAssertFalse(text.contains("its late"))
    }

    func testBytesUndefinedInWindows1252FallBackToLatin1() throws {
        // 0x81 has no Windows-1252 mapping; the file must still open.
        let parts: [[UInt8]] = [utf8("caf"), [0xE9, 0x20, 0x81, 0x20], utf8("ok")]
        let blocks = try extractBlocks(parts.flatMap { $0 })
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].text.hasPrefix("caf\u{E9}"))
        XCTAssertTrue(blocks[0].text.hasSuffix("ok"))
    }

    func testStrayWindowsByteInAUTF8FileIsRepaired() throws {
        // UTF-8 text with one Windows-1252 apostrophe (0x92) pasted in.
        let parts: [[UInt8]] = [utf8("It\u{2019}s late \u{2014} we can\u{2019}t wait. Don"), [0x92],
                                utf8("t go, caf"), [0xE9], utf8(" friends.")]
        let blocks = try extractBlocks(parts.flatMap { $0 })
        XCTAssertEqual(blocks.map(\.text),
                       ["It\u{2019}s late \u{2014} we can\u{2019}t wait. Don\u{2019}t go, caf\u{E9} friends."])
    }

    func testStrayByteRepairNeedsMostlyUTF8() {
        // A Windows-1252 file has no valid multi-byte UTF-8 to speak of: it is
        // left to the whole-file 1252 decoding.
        XCTAssertNil(TextExtractor.repairingStrayBytes(Data([0x49, 0x92, 0x6C, 0x6C, 0x20, 0x93, 0x6F, 0x6B, 0x94])))
        XCTAssertEqual(TextExtractor.repairingStrayBytes(Data(utf8("a\u{2019}b \u{2019}c ") + [0x96, 0x20, 0x64])),
                       "a\u{2019}b \u{2019}c \u{2013} d")
    }

    func testUTF8IsUnchanged() throws {
        let blocks = try extractBlocks(utf8("It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."))
        XCTAssertEqual(blocks.map(\.text), ["It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."])
    }
}
