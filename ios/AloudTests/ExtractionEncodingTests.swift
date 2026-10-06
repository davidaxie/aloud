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

    // MARK: - Audit fixes (F025, F091)

    private func text(_ data: Data) throws -> String {
        try extractBlocks([UInt8](data)).map(\.text).joined(separator: "\n\n")
    }

    /// Cyrillic, Chinese, Japanese and Korean saved in their legacy
    /// encodings, with no byte-order mark, read as themselves, not as
    /// Windows-1252 mojibake.
    func testLegacyNonWesternEncodingsAreDecoded() throws {
        func cf(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        let russian = "Глава первая. Мы пошли домой, и было тихо. Он сказал, что придёт завтра утром."
        let chinese = "第一章 我们回家了。天气很好，我们去公园散步。他说明天早上会来。"
        let japanese = "第一章 今日は公園へ散歩に行きました。明日の朝に来ると彼は言った。"
        let korean = "제1장 우리는 오늘 공원에 갔다. 그는 내일 아침에 온다고 말했다."
        for (sample, encoding) in [(russian, String.Encoding.windowsCP1251), (russian, cf(.KOI8_R)),
                                   (chinese, cf(.GB_18030_2000)), (japanese, .shiftJIS), (korean, cf(.EUC_KR))] {
            let data = try XCTUnwrap(sample.data(using: encoding))
            XCTAssertEqual(try text(data), sample, "\(encoding)")
        }
    }

    /// A PDF or other binary file under a .txt name is refused, not read
    /// out as gibberish; UTF-16 without a byte-order mark is still text.
    func testBinaryUnderATextNameIsRefused() throws {
        var pdf = Data("%PDF-1.7\n%".utf8)
        pdf.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3])
        pdf.append(Data("\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8))
        var random = Data()
        for index in 0..<2048 { random.append(UInt8((index * 7919 + 13) % 256)) }
        for data in [pdf, random, Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x41])] {
            XCTAssertThrowsError(try text(data)) { error in
                XCTAssertEqual(error as? ExtractionError, .unreadableTextFile)
            }
        }
        let utf16 = try XCTUnwrap("Plain words saved as UTF-16.".data(using: .utf16LittleEndian))
        XCTAssertEqual(try text(utf16), "Plain words saved as UTF-16.")
        // Western text stays on the Windows-1252 path.
        let french = try XCTUnwrap("Il était une fois un café où l'on dînait.".data(using: .windowsCP1252))
        XCTAssertEqual(try text(french), "Il était une fois un café où l'on dînait.")
    }

    func testUTF8IsUnchanged() throws {
        let blocks = try extractBlocks(utf8("It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."))
        XCTAssertEqual(blocks.map(\.text), ["It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."])
    }
}
