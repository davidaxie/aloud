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

    /// G021: Greek, Hebrew, Arabic and Thai in their single-byte encodings
    /// read as Cyrillic gibberish under Windows-1251 or KOI8-R: they are
    /// refused with the save-as-UTF-8 advice instead. Cyrillic in capitals
    /// still reads.
    func testOtherSingleByteScriptsAreRefusedNotReadAsCyrillic() throws {
        func cf(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        let greek = "Η Ελλάδα είναι μια όμορφη χώρα με πολλά νησιά. Το καλοκαίρι οι άνθρωποι πηγαίνουν στη "
            + "θάλασσα και κολυμπούν. Ο παππούς μου ζούσε σε ένα μικρό χωριό κοντά στα βουνά."
        let hebrew = "ישראל היא מדינה קטנה במזרח התיכון. בקיץ חם מאוד ואנשים הולכים לים. "
            + "סבא שלי גר בכפר קטן ליד ההרים, שם הבתים היו לבנים והרחובות צרים."
        let arabic = "مصر بلد جميل على ضفاف النيل. في الصيف يذهب الناس إلى البحر للسباحة. "
            + "كان جدي يعيش في قرية صغيرة بالقرب من الجبال، حيث كانت البيوت بيضاء والشوارع ضيقة."
        let thai = "ประเทศไทยเป็นประเทศที่สวยงามมีทะเลและภูเขามากมาย ในฤดูร้อนผู้คนไปเที่ยวทะเลและว่ายน้ำ "
            + "คุณปู่ของฉันอาศัยอยู่ในหมู่บ้านเล็กๆใกล้ภูเขา"
        for (sample, encoding) in [(greek, String.Encoding.windowsCP1253), (greek, cf(.isoLatinGreek)),
                                   (hebrew, cf(.windowsHebrew)), (arabic, cf(.windowsArabic)),
                                   (thai, cf(.dosThai))] {
            let data = try XCTUnwrap(sample.data(using: encoding), "\(encoding)")
            XCTAssertThrowsError(try text(data), "\(encoding)") { error in
                XCTAssertEqual(error as? ExtractionError, .unreadableTextFile)
            }
        }
        let shouting = "ГЛАВА ПЕРВАЯ. Война и мир. Мы пошли домой, и было тихо."
        XCTAssertEqual(try text(try XCTUnwrap(shouting.data(using: .windowsCP1251))), shouting)
    }

    /// G024: a stray or trailing zero byte leaves UTF-8 text readable, and
    /// a text that mentions "%PDF-" is not taken for a PDF. A real PDF's
    /// signature still is one.
    func testStrayZerosAndAMentionedSignatureStayText() throws {
        let book = String(repeating: "The boats drifted past the pier as the light grew softer. ", count: 40)
        // The zeros themselves go with the other controls when the text is normalized.
        let read = { (data: Data) in
            try self.text(data).replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(try read(Data(book.utf8) + [0x00]), book.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(try read(Data(book.utf8) + Data(count: 4096)), book.trimmingCharacters(in: .whitespaces))
        var stray = Data(book.utf8)
        stray.insert(0x00, at: 300)
        XCTAssertFalse(TextExtractor.isBinary(stray))

        let notes = Data("Notes on file formats.\n\nEvery PDF begins with a header such as %PDF-1.7 on its first line.".utf8)
        XCTAssertFalse(TextExtractor.hasPDFSignature(notes))
        XCTAssertFalse(TextExtractor.isBinary(notes))
        XCTAssertTrue(TextExtractor.hasPDFSignature(Data("%PDF-1.4\n%".utf8)))
        XCTAssertTrue(TextExtractor.hasPDFSignature(Data([0xEF, 0xBB, 0xBF, 0x0A]) + Data("%PDF-1.7".utf8)))
    }

    func testUTF8IsUnchanged() throws {
        let blocks = try extractBlocks(utf8("It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."))
        XCTAssertEqual(blocks.map(\.text), ["It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."])
    }
}
