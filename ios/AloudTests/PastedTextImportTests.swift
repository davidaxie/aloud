import XCTest
@testable import Aloud

/// M8's pasted text through the shared importer (`importText(_:)`): a book
/// titled from its first line with words in it, added as a text file is,
/// opened by the open rule, queued behind an add in flight, and its file
/// removed once the add ends; text that is only whitespace fails as an empty
/// text file does. Against an in-memory library, as DocumentImporterTests
/// is, so nothing touches extraction, the real shelf or audio. Compiled into
/// both test bundles; only the Mac's Library pastes.
@MainActor
final class PastedTextImportTests: XCTestCase {

    // MARK: Fixtures

    /// In-memory LibraryAdding that reads each text file while its add runs.
    /// Imports can wait on a gate the test releases one at a time.
    @MainActor
    private final class FakeLibrary: LibraryAdding {
        var documents: [LibraryDocument] = []
        var gatesImports = false
        private(set) var textTitles: [String] = []
        private(set) var textBodies: [String] = []
        private(set) var importedURLs: [URL] = []
        private var gates: [CheckedContinuation<Void, Never>] = []
        var pendingImports: Int { gates.count }

        func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            XCTFail("pasted text is never a PDF")
            return try await add(url, title: url.lastPathComponent)
        }

        func importText(title: String, author: String?, from url: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            textTitles.append(title)
            textBodies.append((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>")
            return try await add(url, title: title)
        }

        func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
            try await add(URL(fileURLWithPath: book.file), title: book.title)
        }

        func release() {
            guard !gates.isEmpty else { return }
            gates.removeFirst().resume()
        }

        private func add(_ url: URL, title: String) async throws -> LibraryDocument {
            importedURLs.append(url)
            if gatesImports {
                await withCheckedContinuation { gates.append($0) }
            }
            let document = LibraryDocument(id: UUID(), title: title, fileName: "x.txt", addedAt: Date(),
                                           pageCount: 1, sentenceCount: 1, contentHash: "h-\(title)", kind: .text)
            documents.append(document)
            return document
        }
    }

    /// What the importer told the outside world.
    private final class Log {
        var opened: [LibraryDocument] = []
        var announcements: [String] = []
    }

    private func makeImporter(_ library: FakeLibrary) -> (DocumentImporter, Log) {
        let log = Log()
        let importer = DocumentImporter(library: library) { log.announcements.append($0) }
        importer.onAdded = { log.opened.append($0) }
        return (importer, log)
    }

    /// Polls `condition` every 10 ms; false when `timeout` passes first.
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private var pastedFiles: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: DocumentImporter.pastedTextFolder.path)) ?? [])
    }

    // MARK: Title

    func testTitleIsTheFirstLineWithWords() {
        let cases: [(String, String?)] = [
            ("Flying Light\nThe first paragraph.", "Flying Light"),
            ("\n \t\n  Flying   Light:\tNotes  \r\nBody", "Flying Light: Notes"),
            ("\u{00A0}Hello\u{2028}World", "Hello"),
            ("One line", "One line"),
            ("", nil),
            (" \n\t\r\n  \n", nil),
        ]
        for (text, title) in cases {
            XCTAssertEqual(DocumentImporter.pastedTitle(from: text), title, "«\(text)»")
        }
    }

    /// A long first line is cut back to a whole word, with "…"; a line with
    /// no break late enough is cut where the limit falls.
    func testALongFirstLineIsCutAtAWord() throws {
        let limit = DocumentImporter.pastedTitleLimit
        let words = try XCTUnwrap(DocumentImporter.pastedTitle(from: String(repeating: "word ", count: 30)))
        XCTAssertTrue(words.hasSuffix("word…"), words)
        XCTAssertLessThanOrEqual(words.count, limit + 1)
        XCTAssertFalse(words.dropLast().hasSuffix(" "))

        let run = try XCTUnwrap(DocumentImporter.pastedTitle(from: String(repeating: "x", count: 200)))
        XCTAssertEqual(run, String(repeating: "x", count: limit) + "…")

        let exact = String(repeating: "y", count: limit)
        XCTAssertEqual(DocumentImporter.pastedTitle(from: exact), exact, "at the limit, whole")
    }

    // MARK: Adding

    /// One paste: a text add under its title, its words intact, opened and
    /// announced by that title, its own file gone once the add ends.
    func testPastedTextIsAddedUnderItsTitleAndOpens() async throws {
        let library = FakeLibrary()
        let (importer, log) = makeImporter(library)
        let text = "Flying Light\nThe first paragraph.\n\nThe second."

        importer.importText(text)
        XCTAssertEqual(importer.phase, .importing(fileName: "Flying Light", progress: 0),
                       "the overlay names the title, not a file")
        let added = await waitUntil { log.opened.count == 1 }

        XCTAssertTrue(added)
        XCTAssertEqual(library.textTitles, ["Flying Light"])
        XCTAssertEqual(library.textBodies, [text])
        XCTAssertEqual(log.opened.map(\.title), ["Flying Light"])
        XCTAssertEqual(log.announcements, [ImportCopy.added("Flying Light")])
        XCTAssertEqual(importer.phase, .idle)
        let file = try XCTUnwrap(library.importedURLs.first)
        XCTAssertTrue(DocumentImporter.isPastedText(file))
        XCTAssertFalse(DocumentImporter.isInboxCopy(file))
        let removed = await waitUntil { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(removed, "the paste's file is removed once the add ends")
    }

    func testWhitespaceFailsAsAnEmptyTextFile() {
        let library = FakeLibrary()
        let (importer, log) = makeImporter(library)
        let before = pastedFiles

        importer.importText(" \n\t \n")

        XCTAssertEqual(importer.failure, .textNoText)
        XCTAssertEqual(library.importedURLs, [], "nothing reaches the store")
        XCTAssertEqual(pastedFiles, before, "and nothing is written")
        XCTAssertEqual(log.opened.count, 0)
        XCTAssertEqual(log.announcements, [])
    }

    /// Behind a file in flight, the paste waits its turn, then is added
    /// under its title; the file it waited on doesn't open, the paste does.
    func testAPasteBehindAnAddWaitsItsTurn() async throws {
        let library = FakeLibrary()
        library.gatesImports = true
        let (importer, log) = makeImporter(library)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-first-\(UUID().uuidString).txt")
        try Data("The first file.".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        importer.importFile(at: file)
        let first = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(first)
        importer.importText("Second Thoughts\nA pasted note.")
        XCTAssertEqual(library.importedURLs.count, 1, "queued, not started")

        library.release()
        let second = await waitUntil { library.pendingImports == 1 && library.importedURLs.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(importer.phase, .importing(fileName: "Second Thoughts", progress: 0))
        XCTAssertEqual(log.opened.count, 0, "the first add had the paste behind it")

        library.release()
        let opened = await waitUntil { log.opened.count == 1 }
        XCTAssertTrue(opened)
        XCTAssertEqual(log.opened.map(\.title), ["Second Thoughts"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file picked in place is kept")
    }

    /// Cancel drops a queued paste, and its file with it.
    func testCancelDropsAQueuedPasteAndItsFile() async throws {
        let library = FakeLibrary()
        library.gatesImports = true
        let (importer, log) = makeImporter(library)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aloud-first-\(UUID().uuidString).txt")
        try Data("The first file.".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let before = pastedFiles

        importer.importFile(at: file)
        let started = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(started)
        importer.importText("Never Added\nA pasted note.")
        XCTAssertEqual(pastedFiles.count, before.count + 1, "written while it waits")

        importer.cancel()
        library.release()

        XCTAssertEqual(importer.phase, .idle)
        XCTAssertEqual(pastedFiles, before, "the queued paste's file is gone")
        _ = await waitUntil(0.3) { false }
        XCTAssertFalse(library.textTitles.contains("Never Added"))
        XCTAssertEqual(log.opened.count, 0)
    }
}
