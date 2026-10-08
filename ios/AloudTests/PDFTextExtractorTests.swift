import XCTest
import PDFKit
import CoreText
import NaturalLanguage
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

    // MARK: - Audit fixes (L005, L009, L012)

    /// Five pages: a paragraph running from page 1 onto pages 2 and 3,
    /// then one paragraph each on pages 4 and 5.
    private func runOnPDF(title: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-test-\(UUID().uuidString).pdf")
        try FixturePDF.write(pages: [
            "The first page starts a long paragraph that runs on and",
            "it keeps going. Page two has its own sentence here and",
            "the third page ends it. Another sentence on page three.",
            "A new paragraph opens the fourth page. It stays there.",
            "The fifth page is short.",
        ], to: url, title: title)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// L009: a paragraph stitched across pages gives each sentence the
    /// page it starts on, not the paragraph's first page, so page
    /// navigation and the outline find sentences on pages 2 and 3.
    func testStitchedParagraphKeepsEachSentencesPage() async throws {
        let content = try await ExtractionPipeline().extract(pdfURL: runOnPDF(), progress: nil)

        XCTAssertEqual(content.paragraphs.map(\.page), [1, 4, 5])
        XCTAssertEqual(content.sentences.map(\.page), [1, 2, 3, 4, 4, 5])
        XCTAssertEqual(content.sentences.map(\.para), [0, 0, 0, 1, 1, 2])
        XCTAssertTrue(content.sentences[0].text.hasSuffix("runs on and it keeps going."))
        XCTAssertTrue(content.sentences[1].text.hasPrefix("Page two has its own sentence"))
        XCTAssertEqual(content.sentences[2].text, "Another sentence on page three.")
    }

    /// L009: stitching a paragraph that runs on page after page reads
    /// only the end of what it has so far, so it takes linear time; it
    /// used to rescan the whole paragraph for every page (minutes for a
    /// few hundred pages of Thai).
    func testLongRunOnParagraphStitchesInLinearTime() {
        let words = "and the river kept on running past the old mill where nobody worked any longer "
        let body = String(repeating: words, count: 19)
        var blocks: [TextBlock] = []
        let start = Date()
        for page in 1...300 {
            PDFTextExtractor.appendPageParagraphs(&blocks, [(page == 1 ? "The " : "") + body + "then"],
                                                  page: page, english: true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.laterPages.map(\.page), Array(2...300))
        XCTAssertEqual(blocks.first?.letters, blocks.first.map { TextBlock.letters(in: $0.text) })
    }

    /// L005: reading the pages through several openings of the document
    /// (so PDFKit lets go of the pages already read) changes nothing.
    func testPagesReadThroughSeveralOpeningsMatchOne() throws {
        let url = try runOnPDF(title: "The Quiet Hour")
        let whole = try PDFTextExtractor().extract(url: url)
        for perOpening in [1, 2] {
            let batched = try PDFTextExtractor(pagesPerOpening: perOpening).extract(url: url)
            XCTAssertEqual(batched.title, "The Quiet Hour")
            XCTAssertEqual(batched.pageCount, 5)
            XCTAssertEqual(batched.blocks.map(\.text), whole.blocks.map(\.text))
            XCTAssertEqual(batched.blocks.map(\.page), whole.blocks.map(\.page))
            XCTAssertEqual(batched.blocks.map(\.laterPages), whole.blocks.map(\.laterPages))
            XCTAssertEqual(batched.pageHeaders, whole.pageHeaders)
        }
        XCTAssertEqual(whole.blocks.map(\.page), [1, 4, 5])
    }

    /// L005: pass 1 drains each page's temporaries and reopens the
    /// document every `pagesPerOpening` pages; L009: pass 2 can be
    /// cancelled.
    func testPageReadingHoldsBoundedMemoryAndCancels() throws {
        let s = try SourceTree.sources(only: ["Extraction/PDFTextExtractor.swift"])
        let source = try XCTUnwrap(s["Extraction/PDFTextExtractor.swift"])
        XCTAssertTrue(source.contains("try autoreleasepool { () throws -> [Line] in"))
        XCTAssertTrue(source.contains("if index % perOpening == 0 {"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "try Task.checkCancellation()").count - 1, 2)
        XCTAssertEqual(PDFTextExtractor().pagesPerOpening, 100)
    }

    /// L012: reading the pages with PDFKit, the quick part, fills the bar
    /// to 0.3, not 0.9; folding the pages and splitting sentences report
    /// the rest instead of the bar sitting at 90%.
    func testPDFProgressCoversEveryStage() async throws {
        final class Box: @unchecked Sendable {
            var values: [Double] = []
            let lock = NSLock()
            func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        }
        let box = Box()
        _ = try await ExtractionPipeline().extract(pdfURL: runOnPDF()) { box.add($0) }
        let values = box.values
        XCTAssertEqual(values, values.sorted(), "progress must be monotonic")
        XCTAssertEqual(values.last, 1.0)
        XCTAssertGreaterThanOrEqual(values.count, 5)
        XCTAssertEqual(values[4], 0.3, accuracy: 1e-9, "the fifth page read ends PDFKit's share")
        XCTAssertTrue(values.contains { $0 > 0.3 && $0 < 0.6 }, "folding the pages reports nothing")
        XCTAssertTrue(values.contains { $0 > 0.6 && $0 < 1 }, "splitting sentences reports nothing")
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

    // MARK: - Audit fixes

    /// F003: a printed book's headers alternate, the book's title on left
    /// pages and the chapter's on right ones, so neither repeats on half
    /// the pages. Both are taken off (and kept for the chapter tier), the
    /// sentence a page break cuts is whole again, and the chapter's title
    /// on its opening page stays.
    func testAlternatingRunningHeadersAreStrippedAndPagesRejoin() async throws {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heath", "inlet", "juniper",
                     "kestrel", "linden", "meadow", "nettle", "orchard", "pebble", "quarry", "rowan", "sorrel", "thistle"]
        func body(_ page: Int) -> [String] {
            let word = words[page - 1]
            // Page 6's last sentence runs on to page 7.
            return ["the \(word) path wound along the harbour wall", "and the boats drifted past the \(word) pier",
                    "while the light over the \(word) grew softer on", "the water near the \(word) steps"
                        + (page == 6 ? " and" : ".")]
        }
        // Front matter on 1-4; chapters open on 5 and 13 with a sunk title.
        let url = try makePDF(pages: (1...20).map { page -> [(String, CGFloat)] in
            var lines: [(String, CGFloat)] = []
            if page == 5 || page == 13 {
                lines.append((page == 5 ? "HARBOUR LIGHTS" : "OPEN WATER", 200))
            } else if page > 5, page % 2 == 0 {
                lines.append(("\(page) THE SMALL BOOK", 40))
            } else if page > 5 {
                lines.append(("\(page < 13 ? "HARBOUR LIGHTS" : "OPEN WATER") \(page)", 40))
            }
            for (i, line) in body(page).enumerated() { lines.append((line, 300 + CGFloat(i) * 20)) }
            return lines
        })

        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        let joined = content.sentences.map(\.text).joined(separator: " ")

        XCTAssertFalse(joined.contains("THE SMALL BOOK"), "left-page header read aloud: \(joined)")
        XCTAssertEqual(occurrences(of: "HARBOUR LIGHTS", in: joined), 1, "only the opening page's title")
        XCTAssertEqual(occurrences(of: "OPEN WATER", in: joined), 1, "only the opening page's title")
        XCTAssertTrue(joined.contains("near the fjord steps and the grove path wound"), "pages 6 and 7 rejoin")
        XCTAssertEqual(content.pageHeaders?[7], "HARBOUR LIGHTS 7")
        XCTAssertEqual(content.pageHeaders?[8], "8 THE SMALL BOOK")
        XCTAssertNil(content.pageHeaders?[5], "an opening title is no header")
    }

    /// G005: short chapters' "CHAPTER n" openings sit at one height, set
    /// apart, a few pages apart, and a devotional's "Day n" tops every page.
    /// Each is numbered afresh, so none is a running header. A header that
    /// repeats its chapter's number still is one.
    func testNumberedChapterOpeningsAreNeverRunningHeaders() {
        typealias Line = PDFTextExtractor.Line
        let names = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heath", "inlet", "juniper"]
        func body(_ page: Int, top: CGFloat) -> [Line] {
            let word = names[page % 10] + " " + names[page / 10 % 10]
            return (0..<4).map { Line(text: "The \(word) path wound along wall \(["one", "two", "three", "four"][$0]).",
                                      y: top - CGFloat($0) * 20, height: 16) }
        }
        func kept(_ pages: [[Line]]) -> [String] {
            let running = PDFTextExtractor.runningHeadersByPage(pages)
            return pages.indices.flatMap { PDFTextExtractor.stripNoise(pages[$0], running: running[$0]).map(\.text) }
        }

        var short: [[Line]] = []
        for chapter in 1...12 {
            short.append([Line(text: "CHAPTER \(chapter)", y: 600, height: 16)] + body(short.count, top: 500))
            short.append(body(short.count, top: 740))
            short.append(body(short.count, top: 740))
        }
        XCTAssertEqual(kept(short).filter { $0.hasPrefix("CHAPTER") }.count, 12, "every opening stays")

        let days = (1...30).map { [Line(text: "Day \($0)", y: 760, height: 16)] + body($0, top: 700) }
        XCTAssertEqual(kept(days).filter { $0.hasPrefix("Day") }.count, 30, "every day's heading stays")

        var headed: [[Line]] = []
        for chapter in 1...3 {
            headed.append([Line(text: "CHAPTER \(chapter)", y: 600, height: 16)] + body(headed.count, top: 500))
            for _ in 1...4 {
                headed.append([Line(text: "Chapter \(chapter) The Return", y: 760, height: 16)]
                              + body(headed.count, top: 700))
            }
        }
        let text = kept(headed)
        XCTAssertFalse(text.contains { $0.hasSuffix("The Return") }, "a chapter's own running header goes")
        XCTAssertEqual(text.filter { $0.hasPrefix("CHAPTER") }.count, 3)
    }

    /// G005 end to end: three-page chapters headed "Chapter n." keep their
    /// headings in the text and list as chapters.
    func testShortChaptersKeepTheirHeadingsAndRows() async throws {
        let names = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heath", "inlet", "juniper"]
        let url = try makePDF(pages: (0..<36).map { page -> [(String, CGFloat)] in
            let word = names[page % 10] + " " + names[page / 10 % 10]
            let top: CGFloat = page % 3 == 0 ? 300 : 80
            var lines = (0..<4).map { ("The \(word) path wound past the \(names[$0]) wall.", top + CGFloat($0) * 20) }
            if page % 3 == 0 { lines.insert(("Chapter \(page / 3 + 1).", 200), at: 0) }
            return lines
        })

        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        let joined = content.sentences.map(\.text).joined(separator: " ")
        for chapter in 1...12 { XCTAssertTrue(joined.contains("Chapter \(chapter)."), "Chapter \(chapter) read aloud") }
        let map = try XCTUnwrap(content.chapterMap)
        XCTAssertEqual(map.source, .headings)
        XCTAssertEqual(map.entries.count, 12, "\(map.entries.map(\.title))")
    }

    /// F024: page images with one text page (a scan's usage notice or
    /// cover sheet) are a scanned PDF, not a book of a few sentences.
    func testMostlyScannedPDFThrowsNoReadableText() async throws {
        let notice = [("This book was digitized from a library copy for public use.", CGFloat(300))]
        let url = try makePDF(pages: [notice] + Array(repeating: [], count: 11))
        do {
            _ = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
            XCTFail("expected ExtractionError.noReadableText")
        } catch let error as ExtractionError {
            XCTAssertEqual(error, .noReadableText)
        }
        XCTAssertFalse(PDFTextExtractor.isMostlyScanned(pagesWithText: 2, pageCount: 4), "a short PDF keeps its text")
        XCTAssertFalse(PDFTextExtractor.isMostlyScanned(pagesWithText: 3, pageCount: 20))
    }

    /// F078: a page that continues a sentence with an accented lowercase
    /// letter is joined on; Chinese and Japanese line wraps add no space,
    /// Korean ones keep theirs.
    func testNonASCIIContinuationsAndCJKWraps() {
        var blocks = [TextBlock(text: "Er sah, wie es", page: 1)]
        PDFTextExtractor.appendPageParagraphs(&blocks, ["über den Fluss ging."], page: 2)
        XCTAssertEqual(blocks.map(\.text), ["Er sah, wie es über den Fluss ging."])
        blocks = [TextBlock(text: "avec un grand", page: 1)]
        PDFTextExtractor.appendPageParagraphs(&blocks, ["élan vers la porte."], page: 2)
        XCTAssertEqual(blocks.map(\.text), ["avec un grand élan vers la porte."])
        blocks = [TextBlock(text: "He walked home", page: 1)]
        PDFTextExtractor.appendPageParagraphs(&blocks, ["Then it rained."], page: 2)
        XCTAssertEqual(blocks.count, 2, "a capital still starts a new paragraph")

        XCTAssertEqual(PDFTextExtractor.appendLine("我们今天去", "公园散步。"), "我们今天去公园散步。")
        XCTAssertEqual(PDFTextExtractor.appendLine("今日は公園へ", "散歩に行きました。"), "今日は公園へ散歩に行きました。")
        XCTAssertEqual(PDFTextExtractor.appendLine("우리는 오늘", "공원에 갔다."), "우리는 오늘 공원에 갔다.")
        XCTAssertEqual(PDFTextExtractor.appendLine("plain words", "go on"), "plain words go on")
    }

    /// G022: a Chinese or Japanese sentence that a page break cuts is whole
    /// again, with no space; one that ends in "。" or "」" stays its own
    /// paragraph even when the next page opens with a year.
    func testCJKSentencesRejoinAcrossPagesAndFullStopsFinishThem() {
        func stitched(_ previous: String, _ next: String) -> [String] {
            var blocks = [TextBlock(text: previous, page: 1)]
            PDFTextExtractor.appendPageParagraphs(&blocks, [next], page: 2)
            return blocks.map(\.text)
        }
        XCTAssertEqual(stitched("我们今天去", "公园散步。"), ["我们今天去公园散步。"])
        XCTAssertEqual(stitched("今日は公園へ", "散歩に行きました。"), ["今日は公園へ散歩に行きました。"])
        XCTAssertEqual(stitched("我们在公园散步。", "1949年10月1日，中华人民共和国成立。").count, 2)
        XCTAssertEqual(stitched("「行きましょう。」", "2時に出発した。").count, 2)
        XCTAssertEqual(stitched("我们在公园散步。", "第二天下雨了。").count, 2)
        XCTAssertEqual(stitched("那是在", "1949年的秋天。"), ["那是在 1949年的秋天。"])
    }

    /// H044: Korean, Arabic, Hebrew, Hindi and Thai sentences that a page
    /// break cuts are whole again, with a space; one that ends in a full
    /// stop, "।", "؟" or "۔" stays its own paragraph.
    func testCaselessScriptSentencesRejoinAcrossPages() {
        func stitched(_ previous: String, _ next: String) -> [String] {
            var blocks = [TextBlock(text: previous, page: 1)]
            PDFTextExtractor.appendPageParagraphs(&blocks, [next], page: 2)
            return blocks.map(\.text)
        }
        XCTAssertEqual(stitched("우리는 오늘", "공원에 갔다."), ["우리는 오늘 공원에 갔다."])
        XCTAssertEqual(stitched("ذهبنا اليوم إلى", "الحديقة العامة."), ["ذهبنا اليوم إلى الحديقة العامة."])
        XCTAssertEqual(stitched("הלכנו היום אל", "הפארק הגדול."), ["הלכנו היום אל הפארק הגדול."])
        XCTAssertEqual(stitched("हम आज", "पार्क गए।"), ["हम आज पार्क गए।"])
        XCTAssertEqual(stitched("वह बहुत खुश थी", "क्योंकि बारिश हुई।").count, 1, "a trailing vowel sign is looked past")
        XCTAssertEqual(stitched("เราไปที่", "สวนสาธารณะวันนี้").count, 1)

        XCTAssertEqual(stitched("그는 갔다.", "다음 날 비가 왔다.").count, 2)
        XCTAssertEqual(stitched("वह घर गया।", "फिर बारिश हुई।").count, 2)
        XCTAssertEqual(stitched("هل ذهبت؟", "نعم ذهبت.").count, 2)
        XCTAssertEqual(stitched("یہ کتاب ہے۔", "وہ قلم ہے۔").count, 2)
        XCTAssertEqual(stitched("He walked home", "공원에 갔다.").count, 2, "a caseless page after a cased one")
    }

    /// H010: a compound that wraps at its own hyphen keeps it, within a
    /// page and across a page break; a syllable split is still re-joined.
    func testCompoundsWrappedAtTheirHyphenKeepIt() throws {
        if NLEmbedding.wordEmbedding(for: .english) == nil {
            throw XCTSkip("No built-in English word embedding on this system")
        }
        typealias Line = PDFTextExtractor.Line
        let page = [Line(text: "It was a well-", y: 500, height: 14),
                    Line(text: "known fact that the self-", y: 482, height: 14),
                    Line(text: "evident truth was plain to the inter-", y: 464, height: 14),
                    Line(text: "national council.", y: 446, height: 14)]
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: page),
                       ["It was a well-known fact that the self-evident truth was plain to the international council."])

        var blocks: [TextBlock] = []
        PDFTextExtractor.appendPageParagraphs(&blocks, PDFTextExtractor.paragraphs(from: [
            Line(text: "Then the twenty-", y: 500, height: 14)]), page: 1)
        PDFTextExtractor.appendPageParagraphs(&blocks, PDFTextExtractor.paragraphs(from: [
            Line(text: "five men and her mother-in-", y: 700, height: 14),
            Line(text: "law came to the sitting-", y: 682, height: 14),
            Line(text: "room.", y: 664, height: 14)]), page: 2)
        XCTAssertEqual(blocks.map { TextNormalizer.normalize($0.text) },
                       ["Then the twenty-five men and her mother-in-law came to the sitting-room."])
    }

    /// I009: the compound rule's word list is English, so in French, German
    /// or Italian a syllable split whose halves happen to be English words
    /// ("main-⏎tenant") is re-joined, within a page and across a break: by
    /// the book's language, or without one the text around the break.
    func testNonEnglishSyllableSplitsRejoin() {
        typealias Line = PDFTextExtractor.Line
        func lines(_ texts: [String]) -> [Line] {
            texts.enumerated().map { Line(text: $1, y: 500 - CGFloat($0) * 18, height: 14) }
        }
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: lines(["Il est main-", "tenant parti avec ses amis."])),
                       ["Il est maintenant parti avec ses amis."])
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: lines(["Der Not-", "fall war schlimmer als wir alle erwartet hatten."])),
                       ["Der Notfall war schlimmer als wir alle erwartet hatten."])
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: lines(["Era tan-", "to tempo che non lo vedevo, e mi mancava."])),
                       ["Era tanto tempo che non lo vedevo, e mi mancava."])
        var blocks: [TextBlock] = []
        PDFTextExtractor.appendPageParagraphs(&blocks, PDFTextExtractor.paragraphs(from: lines(["Elle est par-"])), page: 1)
        PDFTextExtractor.appendPageParagraphs(&blocks, PDFTextExtractor.paragraphs(from: lines(["tie hier soir avec ses amis."])),
                                              page: 2)
        XCTAssertEqual(blocks.map { TextNormalizer.normalize($0.text) }, ["Elle est partie hier soir avec ses amis."])

        XCTAssertEqual(PDFTextExtractor.paragraphs(from: lines(["Il est main-", "tenant parti."]), english: false),
                       ["Il est maintenant parti."])
        let french = lines(["Il faisait encore nuit quand nous sommes partis de la maison,",
                            "et personne ne savait vraiment où la route allait nous mener."])
        XCTAssertFalse(PDFTextExtractor.readsAsEnglish(PDFTextExtractor.languageSample(Array(repeating: french, count: 30))))
        XCTAssertTrue(PDFTextExtractor.readsAsEnglish(PDFTextExtractor.languageSample(
            [lines(["It was still dark when we left the house, and nobody", "knew where the road would take us."])])))
    }

    /// H007: a typeset book marks its paragraphs with a first-line indent
    /// and even leading. Each indent after a finished sentence, or after a
    /// line that stops short of the justified edge, opens a paragraph; a
    /// block quote's lines, set in alike and running on, stay together.
    func testFirstLineIndentsOpenParagraphs() {
        typealias Line = PDFTextExtractor.Line
        var y: CGFloat = 600
        func line(_ text: String, _ minX: CGFloat, _ maxX: CGFloat) -> Line {
            defer { y -= 12 }
            return Line(text: text, y: y, height: 12, minX: minX, maxX: maxX)
        }
        let page = [
            line("The rain had stopped by the time Mara reached", 72, 378),
            line("the station, but the platform was still slick and", 54, 378),
            line("shining under the lamps, and the rails ran off into", 54, 378),
            line("the dark.", 54, 110),
            line("She read the timetable twice, though she knew", 72, 378),
            line("the last train had gone an hour before, and still", 54, 378),
            line("she waited. The porter said only this:", 54, 300),
            line("Nobody waits here for long, and nobody waits", 72, 360),
            line("for nothing, he told her over his shoulder.", 72, 340),
            line("\"Yes,\" she said.", 72, 160),
            line("A dog barked three times somewhere beyond the", 72, 378),
            line("yard and then thought better of it, and the night", 54, 378),
            line("went quiet again over the empty platform and", 54, 378),
            line("the dark line of the rails.", 54, 200),
        ]
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: page), [
            "The rain had stopped by the time Mara reached the station, but the platform was still slick and shining under the lamps, and the rails ran off into the dark.",
            "She read the timetable twice, though she knew the last train had gone an hour before, and still she waited. The porter said only this:",
            "Nobody waits here for long, and nobody waits for nothing, he told her over his shoulder.",
            "\"Yes,\" she said.",
            "A dog barked three times somewhere beyond the yard and then thought better of it, and the night went quiet again over the empty platform and the dark line of the rails.",
        ])
        // Lines all at one margin, as before, fold by gaps alone.
        y = 600
        let flush = [line("One line of a paragraph that wraps on", 54, 378),
                     line("to a second line and ends here.", 54, 200),
                     line("A sentence that starts at the margin.", 54, 220)]
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: flush).count, 1)
    }

    /// I012: on a page of one-line exchanges the indent, not the margin, is
    /// the commonest start. The margin is then the column the few wrapped
    /// lines run on at, so each exchange is still its own paragraph, curly
    /// quotes and all. A hanging indent (entries set out, their run-on
    /// lines in) is not read that way.
    func testDialoguePagesKeepTheirParagraphs() {
        typealias Line = PDFTextExtractor.Line
        var y: CGFloat = 600
        func line(_ text: String, _ minX: CGFloat, _ maxX: CGFloat) -> Line {
            defer { y -= 14 }
            return Line(text: text, y: y, height: 12, minX: minX, maxX: maxX)
        }
        let page = [
            line("\u{201C}Where are you going?\u{201D}", 90, 200),
            line("\u{201C}Out.\u{201D}", 90, 120),
            line("\u{201C}Out where?\u{201D}", 90, 160),
            line("\"Just out.\"", 90, 150),
            line("He looked at her for a long moment over the rim of his", 90, 378),
            line("cup and said nothing at all.", 72, 230),
            line("\u{201C}When will you be back?\u{201D}", 90, 220),
            line("\u{201C}Late.\u{201D}", 90, 125),
            line("\u{201C}How late?\u{201D}", 90, 150),
            line("She shrugged and pulled on her coat, and the door shut", 90, 378),
            line("behind her before he could answer.", 72, 260),
            line("\u{201C}Fine.\u{201D}", 90, 125),
        ]
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: page), [
            "\"Where are you going?\"", "\"Out.\"", "\"Out where?\"", "\"Just out.\"",
            "He looked at her for a long moment over the rim of his cup and said nothing at all.",
            "\"When will you be back?\"", "\"Late.\"", "\"How late?\"",
            "She shrugged and pulled on her coat, and the door shut behind her before he could answer.",
            "\"Fine.\"",
        ])

        y = 600
        let hanging = [
            line("Abbott, Edwin. Flatland: A Romance of Many", 72, 378),
            line("Dimensions. London: Seeley, 1884.", 90, 300),
            line("Baum, L. Frank. The Wonderful Wizard of Oz.", 72, 378),
            line("Chicago: George M. Hill, 1900.", 90, 290),
            line("Carroll, Lewis. Alice's Adventures in Wonderland.", 72, 378),
            line("London: Macmillan, 1865.", 90, 260),
            line("Eliot, George. Middlemarch. Edinburgh: William", 72, 378),
            line("Blackwood and Sons, 1871. Reprinted in a cheaper", 90, 378),
            line("edition, with the author's corrections.", 90, 300),
        ]
        XCTAssertEqual(PDFTextExtractor.indentBreaks(hanging), [])
    }

    /// H007 end to end: a CoreText-typeset trade page (first-line indents,
    /// justified, no space between paragraphs) reads back with each of its
    /// paragraphs opening a block, not one block per page.
    func testIndentedTypesetPDFKeepsItsParagraphs() throws {
        let openings = ["Amber", "Birch", "Cedar", "Delta", "Ember", "Fjord", "Grove", "Heath", "Inlet", "Juniper"]
        let sentences = [
            "the rain had stopped by the time Mara reached the station, but the platform was still slick and shining under the lamps.",
            "She stood near the timetable and read it twice, though she already knew the last train had gone an hour before.",
            "A porter wheeled an empty cart past her and nodded without slowing, as if strangers waiting for nothing were common here.",
            "Somewhere beyond the yard a dog barked three times and then thought better of it.",
        ]
        let body = openings.enumerated().map { index, word in
            "\(word) said that " + (0..<4).map { sentences[($0 + index) % 4] }.joined(separator: " ")
        }.joined(separator: "\n")

        // An 18 pt first-line indent, no space between paragraphs, justified.
        let indent: CGFloat = 18, spacing: CGFloat = 0, alignment = CTTextAlignment.justified
        let style = withUnsafeBytes(of: indent) { indent in
            withUnsafeBytes(of: spacing) { spacing in
                withUnsafeBytes(of: alignment) { alignment in
                    let settings = [
                        CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: indent.count, value: indent.baseAddress!),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: spacing.count, value: spacing.baseAddress!),
                        CTParagraphStyleSetting(spec: .alignment, valueSize: alignment.count, value: alignment.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        let attributed = NSAttributedString(string: body, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times New Roman" as CFString, 11, nil),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-test-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 432, height: 648)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0
        while start < attributed.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0),
                                                 CGPath(rect: CGRect(x: 54, y: 54, width: 324, height: 540), transform: nil), nil)
            CTFrameDraw(frame, context)
            start += max(1, CTFrameGetVisibleStringRange(frame).length)
            context.endPDFPage()
        }
        context.closePDF()

        let output = try PDFTextExtractor().extract(url: url)
        XCTAssertGreaterThan(output.pageCount, 1)
        let starts = output.blocks.map { $0.text.split(separator: " ").first.map(String.init) ?? "" }
        for word in openings {
            XCTAssertTrue(starts.contains(word), "\(word)'s paragraph opens a block; got \(starts)")
        }
        XCTAssertLessThanOrEqual(output.blocks.count, openings.count + output.pageCount - 1)
    }

    /// H047: roman folios counting on at the foot of the front matter go;
    /// a bare "II" opening a chapter and one-word lines spelled with
    /// numeral letters ("vivid", "Did", "civil") stay.
    func testRomanFoliosGoButRomanHeadingsAndWordsStay() {
        typealias Line = PDFTextExtractor.Line
        func body(_ text: String, top: CGFloat) -> [Line] {
            (0..<3).map { Line(text: "\(text) line \(["one", "two", "three"][$0]).", y: top - CGFloat($0) * 18, height: 14) }
        }
        let pages: [[Line]] = [
            body("Preface", top: 700) + [Line(text: "vii", y: 40, height: 14)],
            body("Preface", top: 700) + [Line(text: "viii", y: 40, height: 14)],
            body("Preface", top: 700) + [Line(text: "ix", y: 40, height: 14)],
            [Line(text: "II", y: 640, height: 20)] + body("The river was high that spring", top: 560)
                + [Line(text: "41", y: 40, height: 14)],
            [Line(text: "42", y: 760, height: 14),
             Line(text: "And all the colours of that morning were so", y: 700, height: 14),
             Line(text: "bright, so sharp, so impossibly", y: 682, height: 14),
             Line(text: "vivid", y: 664, height: 14)],
            [Line(text: "Did", y: 700, height: 14),
             Line(text: "the night remember us at all,", y: 682, height: 14),
             Line(text: "or only the long road home?", y: 664, height: 14),
             Line(text: "civil", y: 646, height: 14),
             Line(text: "44", y: 40, height: 14)],
        ]
        let folios = PDFTextExtractor.folioLines(pages)
        let kept = pages.indices.flatMap {
            PDFTextExtractor.stripNoise(pages[$0], running: [], folios: folios[$0]).map(\.text)
        }
        for noise in ["vii", "viii", "ix", "41", "42", "44"] {
            XCTAssertFalse(kept.contains(noise), "\(noise) is a folio")
        }
        for word in ["II", "vivid", "Did", "civil"] {
            XCTAssertTrue(kept.contains(word), "\(word) stays")
        }
        XCTAssertEqual(PDFTextExtractor.romanValue("xiv"), 14)
        XCTAssertEqual(PDFTextExtractor.romanValue("MCMXCIX"), 1999)
        XCTAssertNil(PDFTextExtractor.romanValue("Did"))
        XCTAssertFalse(PDFTextExtractor.isPageNumberLine("mild"))
        XCTAssertTrue(PDFTextExtractor.isPageNumberLine("xii"))
    }

    /// J004: a book in another language opens its short chapters with
    /// "Глава n", "Kapitel n", "第n章" or "제n장", numbered afresh in digits
    /// or Han numerals, so none is a running header, whether the run or
    /// the whole-book rule sees it. A chapter's own "Глава 3 Возвращение"
    /// through chapter 3 still is one.
    func testLocalizedChapterOpeningsAreNeverRunningHeaders() {
        typealias Line = PDFTextExtractor.Line
        let han = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        let labels: [(prefix: String, label: (Int) -> String)] = [
            ("Глава", { "Глава \($0)" }), ("ГЛАВА", { "ГЛАВА \($0)" }), ("Kapitel", { "Kapitel \($0)" }),
            ("Capítulo", { "Capítulo \($0)" }), ("Chapitre", { "Chapitre \($0)" }), ("Capitolo", { "Capitolo \($0)" }),
            ("第", { "第\($0)章" }), ("제", { "제\($0)장" }), ("第", { "第\(han[$0 - 1])章" }),
        ]
        for (prefix, label) in labels {
            for length in [2, 3] {
                var pages: [[Line]] = []
                for chapter in 1...12 {
                    pages.append([Line(text: label(chapter), y: 600, height: 16)] + chapterBody(pages.count, top: 500))
                    for _ in 1..<length { pages.append(chapterBody(pages.count, top: 740)) }
                }
                XCTAssertEqual(keptAfterHeaderPass(pages).filter { $0.hasPrefix(prefix) }.count, 12,
                               "\(label(1)) openings, \(length)-page chapters")
            }
        }

        var headed: [[Line]] = []
        for chapter in 1...3 {
            headed.append([Line(text: "Глава \(chapter)", y: 600, height: 16)] + chapterBody(headed.count, top: 500))
            for _ in 1...4 {
                headed.append([Line(text: "Глава \(chapter) Возвращение", y: 760, height: 16)]
                              + chapterBody(headed.count, top: 700))
            }
        }
        let text = keptAfterHeaderPass(headed)
        XCTAssertFalse(text.contains { $0.hasSuffix("Возвращение") }, "a chapter's own running header goes")
        XCTAssertEqual(text.filter { $0.hasPrefix("Глава") }.count, 3)
        XCTAssertEqual(PDFTextExtractor.openingNumber("第十二章"), 12)
        XCTAssertEqual(PDFTextExtractor.openingNumber("제7장"), 7)
        XCTAssertNil(PDFTextExtractor.openingNumber("Глава семьи сказал"))
    }

    /// J004 end to end: two-page chapters opening "Глава n" keep their
    /// headings in the text and list as chapters.
    func testLocalizedShortChaptersKeepTheirHeadingsAndRows() async throws {
        let names = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heath", "inlet", "juniper"]
        let url = try makePDF(pages: (0..<24).map { page -> [(String, CGFloat)] in
            let word = names[page % 10] + " " + names[page / 10 % 10]
            let top: CGFloat = page % 2 == 0 ? 300 : 80
            var lines = (0..<4).map { ("The \(word) path wound past the \(names[$0]) wall.", top + CGFloat($0) * 20) }
            if page % 2 == 0 { lines.insert(("Глава \(page / 2 + 1)", 200), at: 0) }
            return lines
        })

        let content = try await ExtractionPipeline().extract(pdfURL: url, progress: nil)
        let joined = content.sentences.map(\.text).joined(separator: " ")
        for chapter in 1...12 { XCTAssertTrue(joined.contains("Глава \(chapter)"), "Глава \(chapter) read aloud") }
        let map = try XCTUnwrap(content.chapterMap)
        XCTAssertEqual(map.source, .headings)
        XCTAssertEqual(map.entries.count, 12, "\(map.entries.map(\.title))")
    }

    /// J040: a chapter's bare number ("7", "1984") set large on its
    /// opening page stays. Folios at the foot go, and so do folios set
    /// large that count on from page to page.
    func testBareNumberHeadingsStayButFoliosGo() {
        typealias Line = PDFTextExtractor.Line
        func body(_ text: String, top: CGFloat) -> [Line] {
            (0..<3).map { Line(text: "\(text) line \(["one", "two", "three"][$0]).", y: top - CGFloat($0) * 18, height: 14) }
        }
        let pages: [[Line]] = [
            body("The harbour was still", top: 700) + [Line(text: "41", y: 40, height: 14)],
            [Line(text: "7", y: 600, height: 28)] + body("The river was high that spring", top: 520),
            body("The orchard had flowered", top: 700) + [Line(text: "43", y: 40, height: 14)],
            [Line(text: "1984", y: 600, height: 28)] + body("The winter came early", top: 520)
                + [Line(text: "44", y: 40, height: 14)],
            [Line(text: "45", y: 760, height: 28)] + body("The meadow lay under snow", top: 700),
            [Line(text: "46", y: 760, height: 28)] + body("The nettles came back", top: 700),
        ]
        let folios = PDFTextExtractor.folioLines(pages)
        let kept = pages.indices.flatMap {
            PDFTextExtractor.stripNoise(pages[$0], running: [], folios: folios[$0]).map(\.text)
        }
        for noise in ["41", "43", "44", "45", "46"] {
            XCTAssertFalse(kept.contains(noise), "\(noise) is a folio")
        }
        for heading in ["7", "1984"] {
            XCTAssertTrue(kept.contains(heading), "\(heading) is a chapter's heading")
        }
    }

    /// J035: a page set in two columns reads its left column, then its
    /// right, under a title spanning both. A page of one column with a
    /// centred heading, and a contents page's right-hand page numbers,
    /// keep their order.
    func testTwoColumnPagesReadColumnByColumn() {
        typealias Line = PDFTextExtractor.Line
        func line(_ text: String, _ y: CGFloat, x: CGFloat, width: CGFloat) -> Line {
            Line(text: text, y: y, height: 10, minX: x, maxX: x + width)
        }
        let title = line("Title", 740, x: 150, width: 230)
        let left = (0..<5).map { line("L\($0)", 700 - CGFloat($0) * 12, x: 36, width: $0 == 4 ? 120 : 230) }
        let right = (0..<4).map { line("R\($0)", 700 - CGFloat($0) * 12, x: 316, width: 225) }
        let page = [title] + zip(left, right).flatMap { [$0, $1] } + [left[4]]
        XCTAssertEqual(PDFTextExtractor.columnRuns(page).map { $0.map(\.text) },
                       [["Title"], ["L0", "L1", "L2", "L3", "L4"], ["R0", "R1", "R2", "R3"]])

        let single = [line("CHAPTER 3", 740, x: 250, width: 100)]
            + (0..<9).map { line("S\($0)", 700 - CGFloat($0) * 12, x: 36, width: $0 % 3 == 2 ? 200 : 480) }
        XCTAssertNil(PDFTextExtractor.gutter(single))
        XCTAssertEqual(PDFTextExtractor.columnRuns(single).map { $0.map(\.text) }, [single.map(\.text)])

        let contents = (0..<8).flatMap { row in
            [line("Chapter \(row + 1) of the book", 700 - CGFloat(row) * 14, x: 36, width: 200),
             line("\(row * 10 + 1)", 700 - CGFloat(row) * 14, x: 500, width: 12)]
        }
        XCTAssertNil(PDFTextExtractor.gutter(contents))
    }

    /// J035 end to end: a typeset two-column page reads each column
    /// through, a paragraph running on from the left column's foot into
    /// the right's top, not the two a line of each in turn.
    func testTwoColumnPDFReadsColumnByColumn() throws {
        let left = ["The harbour lay quiet under a low grey sky,", "and the fishing boats rocked against the old",
                    "stone wall while the gulls circled over the", "nets that the men had left to dry along the",
                    "pier since the early hours of the morning and"]
        let right = ["nobody came down to the water until noon.", "Results from the survey arrived by the late",
                     "post and the clerk read them twice before he", "carried them up the hill to the council hall",
                     "where the members were waiting for the news."]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-test-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.beginPDFPage(nil)
        draw("Notes From a Quiet Harbour Town", x: 200, y: 740)
        for row in 0..<5 {
            draw(left[row], x: 54, y: 700 - CGFloat(row) * 12)
            draw(right[row], x: 316, y: 700 - CGFloat(row) * 12)
        }
        draw("7", x: 303, y: 40)
        context.endPDFPage()
        context.closePDF()

        let output = try PDFTextExtractor().extract(url: url)
        let joined = output.blocks.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.hasPrefix("Notes From a Quiet Harbour Town"), joined)
        XCTAssertTrue(joined.contains("The harbour lay quiet under a low grey sky, and the fishing boats rocked"), joined)
        XCTAssertTrue(joined.contains("early hours of the morning and nobody came down to the water until noon."), joined)
        XCTAssertTrue(joined.hasSuffix("where the members were waiting for the news."), joined)
    }

    /// K008: a page turned a quarter (/Rotate 90) to show text set sideways
    /// on it level, as a landscape page is, reads its lines in order, not
    /// by where each one ends on the unturned page. A page turned with its
    /// text level on it keeps its order too.
    func testQuarterTurnedPagesReadTheirLinesInOrder() throws {
        let rows = ["Chapter Two", "",
                    "The first paragraph of the landscape page starts here and",
                    "runs on for a second line that is about as long as the", "first one, and then it ends.", "",
                    "A second paragraph opens below it and keeps going", "until the end of the page, where a short line",
                    "closes it."]
        func turnedPage(sideways: Bool) throws -> PDFPage {
            let data = NSMutableData()
            var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
            let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
            context.beginPDFPage(nil)
            if sideways {
                context.translateBy(x: 612, y: 0)
                context.rotate(by: .pi / 2)
            }
            for (row, text) in rows.enumerated() where !text.isEmpty {
                context.textPosition = CGPoint(x: 72, y: 540 - CGFloat(row) * 14)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ])), context)
            }
            context.endPDFPage()
            context.closePDF()
            let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
            page.rotation = 90
            return page
        }
        for sideways in [true, false] {
            let page = try turnedPage(sideways: sideways)
            XCTAssertEqual(PDFTextExtractor.paragraphs(from: PDFTextExtractor.lines(of: page)), [
                "Chapter Two",
                "The first paragraph of the landscape page starts here and runs on for a second line that is about as long as the first one, and then it ends.",
                "A second paragraph opens below it and keeps going until the end of the page, where a short line closes it.",
            ], "text set sideways: \(sideways)")
        }
    }

    /// K012: a page set in two columns in Hebrew or Arabic reads its right
    /// column, then its left, and a column set flush right, its lines
    /// stopping short on the left, is still a column.
    func testRightToLeftColumnsReadRightColumnFirst() {
        typealias Line = PDFTextExtractor.Line
        func line(_ text: String, _ y: CGFloat, x: CGFloat, width: CGFloat) -> Line {
            Line(text: text, y: y, height: 10, minX: x, maxX: x + width)
        }
        let widths: [CGFloat] = [225, 200, 215, 190, 225]
        for flushRight in [false, true] {
            let first = (0..<5).map { row -> Line in
                let width = flushRight ? widths[row] : 225
                return line("טור ראשון שורה \(row)", 700 - CGFloat(row) * 12, x: 541 - width, width: width)
            }
            let second = (0..<5).map { row -> Line in
                let width = flushRight ? widths[4 - row] : 225
                return line("טור שני שורה \(row)", 700 - CGFloat(row) * 12, x: 266 - width, width: width)
            }
            let page = zip(second, first).flatMap { [$0, $1] }
            XCTAssertNotNil(PDFTextExtractor.gutter(page), "flush right: \(flushRight)")
            XCTAssertEqual(PDFTextExtractor.columnRuns(page).map { $0.map(\.text) },
                           [first.map(\.text), second.map(\.text)], "flush right: \(flushRight)")
        }
        XCTAssertTrue(PDFTextExtractor.readsRightToLeft([line("العمود الأول، السطر 1", 700, x: 316, width: 225)]))
        XCTAssertFalse(PDFTextExtractor.readsRightToLeft([line("The first column, line 1", 700, x: 36, width: 225)]))
    }

    /// K016: a line run into the gutter inside the columns (a long address,
    /// a wide equation), which PDFKit joins with the right column's line
    /// beside it, leaves both columns whole; a title spanning the page
    /// still stands apart.
    func testALineCrossingTheGutterInsideTheColumnsKeepsThemWhole() throws {
        typealias Line = PDFTextExtractor.Line
        func line(_ text: String, _ y: CGFloat, x: CGFloat, width: CGFloat) -> Line {
            Line(text: text, y: y, height: 10, minX: x, maxX: x + width)
        }
        let title = line("Title", 740, x: 150, width: 230)
        let rows = (0..<8).flatMap { row -> [Line] in
            let y = 700 - CGFloat(row) * 12
            return row == 4 ? [line("L4 R4", y, x: 36, width: 505)]
                : [line("L\(row)", y, x: 36, width: 230), line("R\(row)", y, x: 316, width: 225)]
        }
        let page = [title] + rows
        XCTAssertEqual(PDFTextExtractor.straddlers(page, gutter: try XCTUnwrap(PDFTextExtractor.gutter(page))), [9])
        XCTAssertEqual(PDFTextExtractor.columnRuns(page).map { $0.map(\.text) },
                       [["Title"], ["L0", "L1", "L2", "L3", "L4 R4", "L5", "L6", "L7"],
                        ["R0", "R1", "R2", "R3", "R5", "R6", "R7"]])
    }

    /// K016 end to end: a left line's unbroken address runs into the
    /// gutter; the page still reads its left column through, then its
    /// right, the right line beside the address in its place.
    func testAnAddressRunIntoTheGutterReadsInItsColumn() throws {
        let words = "the method we propose here uses a simple model of reading order that holds for most papers and books"
            .split(separator: " ").map(String.init)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-test-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let font = CTFontCreateWithName("Times-Roman" as CFString, 10, nil)
        func typeset(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
        }
        func width(_ text: String) -> CGFloat { CTLineGetTypographicBounds(typeset(text), nil, nil, nil) }
        let columnWidth: CGFloat = 229.5, rightX: CGFloat = 72 + 229.5 + 10
        func filled(_ tag: String, from start: Int) -> String {
            var text = tag, index = start
            while width(text + " " + words[index % words.count]) < columnWidth {
                text += " " + words[index % words.count]
                index += 1
            }
            return text
        }
        context.beginPDFPage(nil)
        for row in 0..<12 {
            var left = filled("L\(row)", from: row)
            if row == 5 {
                left = "See https://example.org/"
                while width(left) < columnWidth + 5 { left += "x" }
            }
            context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(row) * 12)
            CTLineDraw(typeset(left), context)
            context.textPosition = CGPoint(x: rightX, y: 700 - CGFloat(row) * 12)
            CTLineDraw(typeset(filled("R\(row)", from: row + 3)), context)
        }
        context.endPDFPage()
        context.closePDF()

        let joined = try PDFTextExtractor().extract(url: url).blocks.map(\.text).joined(separator: " ")
        func position(_ tag: String) throws -> Int {
            try XCTUnwrap(joined.range(of: tag).map { joined.distance(from: joined.startIndex, to: $0.lowerBound) },
                          "\(tag) in \(joined)")
        }
        let order = try ["L4 ", "See https", "L6 ", "L11 ", "R0 ", "R4 ", "R5 ", "R6 ", "R11 "].map(position)
        XCTAssertEqual(order, order.sorted(), joined)
    }

    /// K019: on a page of one column over a block set in two (footnotes, a
    /// list), a body paragraph's short last line stays with its paragraph,
    /// whatever it starts with.
    func testShortLastLinesOverTwoColumnNotesStayWithTheirParagraphs() {
        typealias Line = PDFTextExtractor.Line
        let endings = ["London, and never returned.", "\u{201C}Yes,\u{201D} he said.", "Holmes."]
        var page: [Line] = []
        var y: CGFloat = 700
        for (index, ending) in endings.enumerated() {
            for row in 0..<3 {
                page.append(Line(text: "Body \(index) line \(row) runs the full width of the page and on", y: y,
                                 height: 12, minX: 36, maxX: 541))
                y -= 14
            }
            page.append(Line(text: ending, y: y, height: 12, minX: 36, maxX: 260))
            y -= 28
        }
        let notes = (0..<5).flatMap { row -> [Line] in
            let y = 420 - CGFloat(row) * 11
            return [Line(text: "Note \(row) on the left", y: y, height: 9, minX: 36, maxX: 266),
                    Line(text: "Note \(row) on the right", y: y, height: 9, minX: 316, maxX: 541)]
        }
        page += notes
        XCTAssertNotNil(PDFTextExtractor.gutter(page))
        let runs = PDFTextExtractor.columnRuns(page)
        XCTAssertEqual(runs.map(\.count), [12, 5, 5])
        let paragraphs = PDFTextExtractor.paragraphs(from: runs[0])
        XCTAssertEqual(paragraphs.count, endings.count, "\(paragraphs)")
        for (paragraph, ending) in zip(paragraphs, endings) {
            XCTAssertTrue(paragraph.hasSuffix("and on " + TextNormalizer.normalize(ending)), paragraph)
        }
    }

    // MARK: - Helpers

    /// Four body lines from `top` down, worded for page `page` alone.
    private func chapterBody(_ page: Int, top: CGFloat) -> [PDFTextExtractor.Line] {
        let names = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heath", "inlet", "juniper"]
        let word = names[page % 10] + " " + names[page / 10 % 10]
        return (0..<4).map {
            PDFTextExtractor.Line(text: "The \(word) path wound along wall \(["one", "two", "three", "four"][$0]).",
                                  y: top - CGFloat($0) * 20, height: 16)
        }
    }

    /// The pages' lines left after the running-header and noise passes.
    private func keptAfterHeaderPass(_ pages: [[PDFTextExtractor.Line]]) -> [String] {
        let running = PDFTextExtractor.runningHeadersByPage(pages)
        return pages.indices.flatMap { PDFTextExtractor.stripNoise(pages[$0], running: running[$0]).map(\.text) }
    }

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
