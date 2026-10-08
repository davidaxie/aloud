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

    // MARK: - Audit fix (L006)

    /// Central European text in Windows-1250 or ISO-8859-2, Turkish in
    /// Windows-1254 and Baltic in Windows-1257, mostly ASCII with no
    /// byte-order mark, read as themselves: not as Windows-1252 with a
    /// superscript "³" for "ł", "ý" for "ı" or "ø" for "ř", nor with
    /// letters lost as control characters.
    func testCentralEuropeanTurkishAndBalticCodePagesAreDecoded() throws {
        func cf(_ encoding: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
        }
        let polish = "Był sobie raz król, który żył długo i szczęśliwie. Ścieżka prowadziła przez las."
        let czech = "Dobrý den, jak se máte? Děkuji, mám se dobře. Řekl, že přijde zítra ráno, a čekal na nádraží."
        let czechWithT = "Příliš žluťoučký kůň úpěl ďábelské ódy. Šel domů a čekal."
        let hungarian = "Árvíztűrő tükörfúrógép. Őszi szél fúj. A lőtér mellett ülő öregember különös történetet mesélt."
        let croatian = "Čovjek je išao kroz šumu i vidio đaka koji je žurio kući. Ćup je bio pun vode."
        let turkish = "Uzun yıllar boyunca İstanbul şehrinde yaşamış, sonra başka bir şehre taşınmış. "
            + "Çocuklar ağaçların altında oynuyordu. Öğretmen gülümsedi."
        let lithuanian = "Lietuvos sostinė yra Vilnius. Ąžuolas augo prie upės, o vaikai žaidė kieme. "
            + "Šiandien graži diena, ir mes einame į mišką."
        let latvian = "Rīga ir Latvijas galvaspilsēta. Ķēniņš dzīvoja pilī, un ļaudis strādāja laukos. "
            + "Šodien ir skaista diena, un mēs ejam uz mežu."
        let cases: [(String, String.Encoding)] = [
            (polish, .windowsCP1250), (czech, .windowsCP1250), (czechWithT, .windowsCP1250),
            (hungarian, .windowsCP1250), (croatian, .windowsCP1250),
            (polish, .isoLatin2), (czechWithT, .isoLatin2), (hungarian, .isoLatin2),
            (turkish, .windowsCP1254), (lithuanian, cf(.windowsBalticRim)), (latvian, cf(.windowsBalticRim)),
        ]
        for (sample, encoding) in cases {
            let data = try XCTUnwrap(sample.data(using: encoding), "\(encoding)")
            XCTAssertEqual(try text(data), sample, "\(encoding)")
        }
    }

    /// L006: Western text keeps its Windows-1252 reading letter for letter,
    /// the French "è" never a Czech "č" nor the Danish "ø" a Lithuanian
    /// "ų", and Latin-1 still stands in for bytes 1252 leaves undefined.
    func testWesternTextKeepsItsWindows1252Reading() throws {
        let samples = [
            "Il était une fois un café où l'on dînait. Très bien, à côté de la forêt, Noël et le cœur naïf.",
            "El niño comió. ¿Qué pasó? ¡Hola! Mañana iremos a la montaña con el señor Muñoz. Nº 5, 1º y 2ª.",
            "È così però più bello. La città è là, perché già lo sai.",
            "Über den Fluss ging der Müller. Größe und Straße, schön.",
            "Bjørn gik på arbejde i går. Æblerne var søde, og pigen spiste dem på trappen.",
            "Það var einu sinni maður sem bjó á Íslandi. Hann átti þrjú börn og hús við sjóinn.",
            "São Paulo é uma cidade grande. As crianças comeram pão e maçã à tarde.",
            "The naïve fiancée ordered a café crème; Bjørn said señor Muñoz liked smörgåsbord. It cost £5 at 20°C.",
        ]
        for sample in samples {
            let data = try XCTUnwrap(sample.data(using: .windowsCP1252), sample)
            XCTAssertEqual(TextExtractor.latinDecoded(data), sample)
            XCTAssertEqual(try text(data), sample)
        }
        let undefined = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x81, 0x20, 0xE0, 0x20, 0x62, 0x69, 0x65, 0x6E, 0x74, 0xF4, 0x74])
        XCTAssertEqual(TextExtractor.latinDecoded(undefined), String(data: undefined, encoding: .isoLatin1))
    }

    func testUTF8IsUnchanged() throws {
        let blocks = try extractBlocks(utf8("It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."))
        XCTAssertEqual(blocks.map(\.text), ["It\u{2019}s \u{201C}fine\u{201D} \u{2014} caf\u{E9}."])
    }
}
