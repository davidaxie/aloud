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
