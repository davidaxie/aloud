import UniformTypeIdentifiers
import XCTest
@testable import Aloud

/// M8's ⌘V in the Library (phase 4): what Edit ▸ Paste hands over, as the
/// item providers SwiftUI's paste command passes, goes through the intake.
/// Copied text becomes one book titled from its first line and opens; text
/// that is only whitespace fails as an empty text file does; copied files
/// are admitted as a drop's are, several as one batch; a file wins over the
/// name Finder copies with it.
///
/// Every provider is built here: no test reads or writes the system
/// pasteboard. Fixtures sit in the host's own temporary folder.
@MainActor
final class MacPasteTests: XCTestCase {

    // MARK: Fixtures

    /// In-memory LibraryAdding: each add is one new book, at once. A text
    /// add reads its file, as the store would, while the add runs.
    @MainActor
    private final class FakeLibrary: LibraryAdding {
        var documents: [LibraryDocument] = []
        private(set) var importedNames: [String] = []
        private(set) var pdfNames: [String] = []
        private(set) var textTitles: [String] = []
        private(set) var textBodies: [String] = []
        private(set) var textURLs: [URL] = []

        func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            pdfNames.append(url.lastPathComponent)
            return add(url, title: url.lastPathComponent)
        }

        func importText(title: String, author: String?, from url: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            textTitles.append(title)
            textURLs.append(url)
            textBodies.append((try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>")
            return add(url, title: title)
        }

        func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
            add(URL(fileURLWithPath: book.file), title: book.title)
        }

        private func add(_ url: URL, title: String) -> LibraryDocument {
            importedNames.append(url.lastPathComponent)
            let document = LibraryDocument(id: UUID(), title: title, fileName: "x.txt",
                                           addedAt: Date(), pageCount: 1, sentenceCount: 1,
                                           contentHash: "h-\(url.lastPathComponent)", kind: .text)
            documents.append(document)
            return document
        }
    }

    /// The Library's paste over a fake shelf: a real router for the open
    /// rule, the importer's announcements, and a stage that hands each file
    /// over where it is.
    @MainActor
    private final class Harness {
        let library: FakeLibrary
        let router: LibraryRouter
        let importer: DocumentImporter
        let intake: MacFileIntake
        private let log: Log

        private final class Log {
            var lines: [String] = []
        }

        var announcements: [String] { log.lines }

        init() {
            let library = FakeLibrary()
            let router = LibraryRouter()
            let log = Log()
            let importer = DocumentImporter(library: library) { log.lines.append($0) }
            importer.navigation = router
            // Set before the intake, which routes the open through its hold.
            importer.onAdded = { router.open($0) }
            self.library = library
            self.router = router
            self.log = log
            self.importer = importer
            intake = MacFileIntake(importer: importer, stage: MacPasteTests.inPlace)
        }
    }

    /// A stage that hands the file over where it is.
    private static let inPlace: MacFileIntake.Stage = { $0 }

    /// A fresh folder in the host's temporary directory, removed after the test.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-mac-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeFile(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "This is the fixture's only sentence.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What a copy of text puts on the pasteboard.
    private static func textItem(_ text: String) -> NSItemProvider {
        NSItemProvider(object: text as NSString)
    }

    /// What a Finder copy of one file puts on the pasteboard: its file URL,
    /// and its name as text.
    private static func fileItem(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerObject(url.lastPathComponent as NSString, visibility: .all)
        return provider
    }

    /// Polls `condition` every 10 ms; false when `timeout` passes first.
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    // MARK: Text

    /// The paste types: files first, then text.
    func testThePasteCommandTakesFilesAndText() {
        XCTAssertEqual(MacFileIntake.pasteTypes, [.fileURL, .plainText])
    }

    /// An article copied before a flight: one book, titled from its first
    /// line with words in it, opened (it plays, R4), and announced by that
    /// title. The words reach the store intact, and the paste's own file is
    /// gone once the add ends.
    func testTextBecomesOneBookTitledFromItsFirstLine() async throws {
        let h = Harness()
        let article = "\n  \n  Flying   Light:\tNotes for a Long Trip  \nThe first paragraph.\n\nThe second."

        await h.intake.admitPaste([Self.textItem(article)])
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.textTitles, ["Flying Light: Notes for a Long Trip"])
        XCTAssertEqual(h.library.textBodies, [article], "the text as copied, whitespace and all")
        XCTAssertEqual(h.library.pdfNames, [])
        let book = try XCTUnwrap(h.library.documents.first)
        XCTAssertEqual(h.router.path, [.reader(book.id)], "one paste opens playing")
        XCTAssertEqual(h.announcements, ["Added Flying Light: Notes for a Long Trip"])
        XCTAssertNil(h.importer.failure)
        XCTAssertNil(h.intake.failure)
        let file = try XCTUnwrap(h.library.textURLs.first)
        XCTAssertTrue(DocumentImporter.isPastedText(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the paste's file is removed")
    }

    /// The 2,000-character article of the PRD's check: one book, titled
    /// from line 1 alone.
    func testALongArticleIsOneBookTitledFromLineOne() async {
        let h = Harness()
        let body = String(repeating: "A sentence of the article goes on like this. ", count: 44)
        let article = "Line One of the Article\n" + body
        XCTAssertGreaterThanOrEqual(article.count, 2_000)

        await h.intake.admitPaste([Self.textItem(article)])
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.textTitles, ["Line One of the Article"])
        XCTAssertEqual(h.router.path.count, 1)
    }

    /// Text that is only whitespace is the empty text file's failure, with
    /// its fixed copy, and adds and opens nothing.
    func testWhitespaceIsTheEmptyTextFailure() async {
        for blank in ["", " \n\t\r\n  \n"] {
            let h = Harness()

            await h.intake.admitPaste([Self.textItem(blank)])

            XCTAssertEqual(h.importer.failure, .textNoText, "«\(blank)»")
            XCTAssertEqual(h.importer.failure?.title, ImportFailure.textNoText.title)
            XCTAssertEqual(h.importer.failure?.nextStep, ImportFailure.textNoText.nextStep)
            XCTAssertEqual(h.library.importedNames, [], "nothing reaches the store")
            XCTAssertEqual(h.router.path, [])
            XCTAssertEqual(h.announcements, [])
            h.importer.dismissFailure()
            XCTAssertEqual(h.importer.phase, .idle)
        }
    }

    /// Several text items are one book, in order.
    func testSeveralTextItemsAreOneBook() async {
        let h = Harness()

        await h.intake.admitPaste([Self.textItem("First part"), Self.textItem("Second part")])
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.textTitles, ["First part"])
        XCTAssertEqual(h.library.textBodies, ["First part\n\nSecond part"])
    }

    /// The same text pasted twice, through the real store (over an index of
    /// its own), is one book: the second paste opens the copy on the shelf.
    func testTheSameTextTwiceIsOneBook() async throws {
        let folder = try makeFolder()
        let store = DocumentStore(indexURL: folder.appendingPathComponent("library.json"),
                                  saveInterval: 0.05, notifications: NotificationCenter())
        addTeardownBlock { @MainActor in store.documents.forEach(store.delete) }
        let importer = DocumentImporter(library: store) { _ in }
        var opened: [LibraryDocument] = []
        importer.onAdded = { opened.append($0) }
        let intake = MacFileIntake(importer: importer, stage: Self.inPlace)
        let article = "Twice Pasted\nThis article is pasted twice. It is one book all the same."

        await intake.admitPaste([Self.textItem(article)])
        let first = await waitUntil { opened.count == 1 }
        XCTAssertTrue(first, "the first paste opens its book")
        XCTAssertEqual(store.documents.map(\.title), ["Twice Pasted"])

        await intake.admitPaste([Self.textItem(article)])
        let second = await waitUntil { opened.count == 2 }
        XCTAssertTrue(second, "the second paste opens the book on the shelf")
        XCTAssertEqual(store.documents.count, 1, "a duplicate never raises the count")
        XCTAssertEqual(Set(opened.map(\.id)).count, 1)
        XCTAssertNil(importer.failure)
    }

    // MARK: Files

    /// Two files copied in Finder are one batch, as two dropped would be:
    /// both added, none opened, one count.
    func testTwoFileURLsAreOneBatch() async throws {
        let folder = try makeFolder()
        let h = Harness()
        let files = try ["one.txt", "two.txt"].map { try writeFile($0, in: folder) }

        await h.intake.admitPaste(files.map(Self.fileItem))
        let added = await waitUntil { h.library.documents.count == 2 && h.importer.phase == .idle }
        XCTAssertTrue(added)
        let settled = await waitUntil { !h.intake.holdsOpens }
        XCTAssertTrue(settled)

        XCTAssertEqual(h.library.importedNames, ["one.txt", "two.txt"], "in the order copied")
        XCTAssertEqual(h.router.path, [], "none of them opens")
        XCTAssertEqual(h.announcements, ["Added 2 books"])
        XCTAssertEqual(h.library.textTitles, ["One", "Two"], "titled by name, as any file is")
    }

    /// A PDF copied in Finder is admitted, as a PDF, and opens.
    func testAPDFURLIsAdmitted() async throws {
        let folder = try makeFolder()
        let h = Harness()
        let pdf = try writeFile("Field Notes.pdf", in: folder)

        await h.intake.admitPaste([Self.fileItem(pdf)])
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.pdfNames, ["Field Notes.pdf"])
        XCTAssertEqual(h.library.textTitles, [], "its name, copied with it, is no book of its own")
        XCTAssertEqual(h.router.path.count, 1, "one file opens playing")
    }

    /// A copied file that isn't a PDF or plain text adds nothing: not the
    /// file, and not a book of the name Finder copies with it.
    func testACopiedPhotoAddsNothing() async throws {
        let folder = try makeFolder()
        let h = Harness()
        let photo = try writeFile("Beach.jpg", in: folder)

        await h.intake.admitPaste([Self.fileItem(photo)])
        _ = await waitUntil(0.3) { false }

        XCTAssertEqual(h.library.importedNames, [])
        XCTAssertNil(h.importer.failure)
        XCTAssertNil(h.intake.failure)
        XCTAssertEqual(h.importer.phase, .idle)
    }

    /// A paste with neither files nor text (a web link's URL alone) does nothing.
    func testAPasteWithNoFileOrTextDoesNothing() async throws {
        let h = Harness()
        let link = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/article")) as NSURL)

        await h.intake.admitPaste([link])

        XCTAssertEqual(h.library.importedNames, [])
        XCTAssertNil(h.importer.failure)
        XCTAssertEqual(h.importer.phase, .idle)
    }
}
