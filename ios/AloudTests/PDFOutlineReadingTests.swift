import PDFKit
import XCTest
@testable import Aloud

/// Reading a real PDF's outline with PDFKit (on both platforms, off the main
/// thread), extraction storing the chapter map, and the backfill that gives
/// books imported before chapter maps theirs without touching their text.
final class PDFOutlineReadingTests: XCTestCase {

    private func temporaryURL(_ pathExtension: String = "pdf") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let pages = [
        "Preface. The preface comes first and sets the scene for the rest.",
        "Chapter one. The first chapter begins the story on this page.",
        "Chapter two. The second chapter carries the story further along.",
        "The second chapter goes on for another page of plain text.",
        "Notes. A few notes close the book at the very end.",
    ]

    /// Preface (page 1); Part One over Chapter 1 (page 2) and Chapter 2
    /// (page 3, through a go-to action); Notes (page 5). `partPage` nil
    /// leaves Part One without a destination of its own.
    private func outline(for document: PDFDocument, partPage: Int?) throws -> PDFOutline {
        func node(_ label: String, page: Int?) throws -> PDFOutline {
            let item = PDFOutline()
            item.label = label
            if let page {
                item.destination = PDFDestination(page: try XCTUnwrap(document.page(at: page)),
                                                  at: CGPoint(x: 0, y: 792))
            }
            return item
        }
        let root = PDFOutline()
        let part = try node("Part One", page: partPage)
        let two = try node("Chapter 2", page: nil)
        two.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(document.page(at: 2)),
                                                               at: CGPoint(x: 0, y: 792)))
        part.insertChild(try node("Chapter 1", page: 1), at: 0)
        part.insertChild(two, at: 1)
        root.insertChild(try node("Preface", page: 0), at: 0)
        root.insertChild(part, at: 1)
        root.insertChild(try node("Notes", page: 4), at: 2)
        return root
    }

    /// The five pages with the same bookmarks written into the file
    /// (CoreGraphics: PDFKit doesn't save an outline set in code), Part One
    /// on page 2.
    private func outlinedPDF() throws -> URL {
        let url = temporaryURL()
        try FixturePDF.write(pages: Self.pages, to: url, outline: [
            .init(title: "Preface", page: 1),
            .init(title: "Part One", page: 2, children: [.init(title: "Chapter 1", page: 2),
                                                          .init(title: "Chapter 2", page: 3)]),
            .init(title: "Notes", page: 5),
        ])
        return url
    }

    // MARK: - Reading

    func testOutlineItemsKeepOrderPagesAndDepth() throws {
        let source = temporaryURL()
        try FixturePDF.write(pages: Self.pages, to: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        document.outlineRoot = try outline(for: document, partPage: nil)

        // Part One has no destination: it takes its first chapter's page.
        XCTAssertEqual(PDFChapterDetector.outlineItems(of: document), [
            PDFOutlineItem(title: "Preface", pageIndex: 0, depth: 0),
            PDFOutlineItem(title: "Part One", pageIndex: 1, depth: 0),
            PDFOutlineItem(title: "Chapter 1", pageIndex: 1, depth: 1),
            PDFOutlineItem(title: "Chapter 2", pageIndex: 2, depth: 1),
            PDFOutlineItem(title: "Notes", pageIndex: 4, depth: 0),
        ])
        XCTAssertEqual(PDFChapterDetector.outlineItems(of: document, maxDepth: 1).map(\.title),
                       ["Preface", "Part One", "Notes"])
    }

    func testAWrittenOutlineReadsBackFromTheFile() throws {
        let items = PDFChapterDetector.outlineItems(at: try outlinedPDF())

        XCTAssertEqual(items.map(\.title), ["Preface", "Part One", "Chapter 1", "Chapter 2", "Notes"])
        XCTAssertEqual(items.map(\.pageIndex), [0, 1, 1, 2, 4])
        XCTAssertEqual(items.map(\.depth), [0, 0, 1, 1, 0])
    }

    func testNoOutlineAndNoPDFReadAsEmpty() throws {
        let plain = temporaryURL()
        try FixturePDF.write(pages: ["A page without any bookmarks at all."], to: plain)
        let text = temporaryURL("txt")
        try Data("Not a PDF, just a line of text.".utf8).write(to: text)

        XCTAssertEqual(PDFChapterDetector.outlineItems(at: plain), [])
        XCTAssertEqual(PDFChapterDetector.outlineItems(at: text), [])
        XCTAssertEqual(PDFChapterDetector.outlineItems(at: temporaryURL()), [])
    }

    func testTheOutlineReadsTheSameOffTheMainThread() async throws {
        let url = try outlinedPDF()
        let here = PDFChapterDetector.outlineItems(at: url)

        let detached = await Task.detached { PDFChapterDetector.outlineItems(at: url) }.value

        XCTAssertEqual(here.count, 5)
        XCTAssertEqual(detached, here)
    }

    // MARK: - Extraction

    func testExtractionStoresTheOutlineMap() async throws {
        let content = try await ExtractionPipeline().extract(pdfURL: try outlinedPDF(), progress: nil)
        let map = try XCTUnwrap(content.chapterMap)

        XCTAssertEqual(map.source, .outline)
        XCTAssertEqual(map.version, ChapterMap.currentVersion)
        XCTAssertEqual(map.entries.map(\.title), ["Preface", "Chapter 1", "Chapter 2", "Notes"])
        XCTAssertEqual(map.entries.map(\.section), [nil, "Part One", "Part One", nil])
        XCTAssertEqual(map.entries.map { content.sentences[$0.sentence].page }, [1, 2, 3, 5])
        XCTAssertEqual(map.entries.first?.sentence, 0)
    }

    func testAPDFWithNothingToGoOnStoresAnEmptyMap() async throws {
        let url = temporaryURL()
        try FixturePDF.write(pages: ["Just one page of plain text, with no chapters in it."], to: url)

        let map = try await ExtractionPipeline().extract(pdfURL: url, progress: nil).chapterMap

        XCTAssertEqual(map?.source, ChapterMap.Source.none)
        XCTAssertEqual(map?.entries, [])
    }

    // MARK: - Backfill

    func testOnlyPDFsWithoutACurrentMapNeedOne() {
        let bare = ChapterFixtures.outlined
        var current = bare
        current.chapterMap = ChapterMap(version: ChapterMap.currentVersion, source: .none, entries: [])
        var older = bare
        older.chapterMap = ChapterMap(version: ChapterMap.currentVersion - 1, source: .outline, entries: [])

        XCTAssertTrue(DocumentStore.needsChapterMap(bare, kind: .pdf))
        XCTAssertTrue(DocumentStore.needsChapterMap(older, kind: .pdf))
        XCTAssertFalse(DocumentStore.needsChapterMap(current, kind: .pdf))
        XCTAssertFalse(DocumentStore.needsChapterMap(bare, kind: .text))
    }

    /// A cache from before chapter maps: the backfill adds the same map an
    /// import would and leaves the text and its hash alone, which is what
    /// keeps the book's saved progress (a reconcile resets progress only
    /// when the hash changes).
    func testBackfillAddsTheMapAndKeepsTheTextAndHash() async throws {
        let url = try outlinedPDF()
        let pipeline = ExtractionPipeline()
        var imported = try await pipeline.extract(pdfURL: url, progress: nil)
        let expected = imported.chapterMap
        imported.chapterMap = nil
        let cached = try JSONDecoder().decode(DocContent.self, from: JSONEncoder().encode(imported))
        XCTAssertTrue(DocumentStore.needsChapterMap(cached, kind: .pdf))

        let filled = await pipeline.addingChapters(to: cached, pdfURL: url)

        XCTAssertEqual(filled.chapterMap, expected)
        XCTAssertEqual(filled.chapterMap?.source, .outline)
        XCTAssertEqual(filled.contentHash, imported.contentHash)
        XCTAssertEqual(filled.sentences.map(\.text), imported.sentences.map(\.text))
        XCTAssertEqual(filled.sentences.map(\.page), imported.sentences.map(\.page))
        XCTAssertFalse(DocumentStore.needsChapterMap(filled, kind: .pdf))
    }

    func testBackfillWithoutTheFileStillMapsTheText() async {
        let content = ChapterFixtures.traction()

        let filled = await ExtractionPipeline().addingChapters(to: content, pdfURL: temporaryURL())

        XCTAssertEqual(filled.chapterMap?.source, .headings)
        XCTAssertEqual(filled.contentHash, content.contentHash)
    }
}
