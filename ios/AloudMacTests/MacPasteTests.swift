import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Aloud

/// M8's ⌘V in the Library (phase 4): what Edit ▸ Paste hands over, as the
/// item providers SwiftUI's paste command passes, goes through the intake.
/// Copied text becomes one book titled from its first line and opens; text
/// that is only whitespace fails as an empty text file does; copied files
/// are admitted as a drop's are, several as one batch; a file wins over the
/// name Finder copies with it. With nothing focused, Paste reaches the
/// window's key tail, which reads the pasteboard by the same rule
/// (`MacPasteTarget`, `admitPasteboard(_:)`), and one paste is one book.
///
/// Every provider is built here, and every pasteboard is a private named
/// one: no test reads or writes the system pasteboard. Fixtures sit in the
/// host's own temporary folder, and test windows are never ordered in.
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
        addTeardownBlock { @MainActor in store.documents.forEach { try? store.delete($0) } }
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

    // MARK: The tail and the pasteboard

    /// The rule both pastes share: files win, then text, else nothing.
    func testFilesWinOverTextAndNeitherIsNothing() {
        XCTAssertEqual(MacFileIntake.pasteKind(carriesFiles: true, carriesText: true), .files)
        XCTAssertEqual(MacFileIntake.pasteKind(carriesFiles: true, carriesText: false), .files)
        XCTAssertEqual(MacFileIntake.pasteKind(carriesFiles: false, carriesText: true), .text)
        XCTAssertNil(MacFileIntake.pasteKind(carriesFiles: false, carriesText: false))
    }

    /// The tail turns Paste on only while the Library offers it and the
    /// pasteboard holds what it takes: text, or a file. No Library, a copied
    /// picture (no file, no text) or nothing copied keep it grey, and Paste
    /// then does nothing. Judged by type alone, never by reading the
    /// pasteboard, which macOS would put to the user: a copied photo leaves
    /// it on, and its paste adds nothing (the photo test below). Another
    /// view's withdrawal leaves the Library's offer.
    func testTheTailOffersPasteOnlyForALibraryWithSomethingToAdd() throws {
        let folder = try makeFolder()
        let pasteboard = makePasteboard()
        let target = MacPasteTarget(pasteboard: { pasteboard })
        let keys = MacKeyRouter(searchHandoff: MacSearchHandoff(), pasteTarget: target) { _ in true }
        let item = Self.pasteItem()
        var pasted: [NSPasteboard] = []
        Self.copy([Self.textEntry("An article copied before a flight")], to: pasteboard)

        XCTAssertFalse(keys.tail.validateMenuItem(item), "no Library on screen")
        keys.tail.paste(nil)
        XCTAssertTrue(pasted.isEmpty)

        let library = UUID()
        target.offer(by: library) { pasted.append($0) }
        XCTAssertTrue(keys.tail.validateMenuItem(item), "text, with the Library on screen")
        XCTAssertTrue(keys.tail.validateUserInterfaceItem(item))

        let pdf = try writeFile("Field Notes.pdf", in: folder)
        Self.copy([Self.fileEntry(pdf)], to: pasteboard)
        XCTAssertTrue(keys.tail.validateMenuItem(item), "a PDF copied in Finder")

        let photo = try writeFile("Beach.jpg", in: folder)
        Self.copy([Self.fileEntry(photo)], to: pasteboard)
        XCTAssertTrue(keys.tail.validateMenuItem(item), "a copied file, by type: its URL is read only as it pastes")

        Self.copy([Self.imageEntry()], to: pasteboard)
        XCTAssertFalse(keys.tail.validateMenuItem(item), "a copied picture: no file, no text")
        keys.tail.paste(nil)
        XCTAssertTrue(pasted.isEmpty, "Paste off is Paste ignored")

        pasteboard.clearContents()
        XCTAssertFalse(keys.tail.validateMenuItem(item), "nothing copied")

        Self.copy([Self.textEntry("Another article")], to: pasteboard)
        target.withdraw(by: UUID())
        XCTAssertTrue(keys.tail.validateMenuItem(item), "the Library's offer stands")
        keys.tail.paste(nil)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertTrue(pasted.first === pasteboard, "read as the user pastes")

        target.withdraw(by: library)
        XCTAssertFalse(keys.tail.validateMenuItem(item), "the Library gone")
    }

    /// With nothing focused (a mouse, Full Keyboard Access off) the tail is
    /// the responder Paste reaches. A focused search field (Classics', the
    /// Contents panel's) pastes for itself: its editor comes first.
    func testAFocusedSearchFieldPastesForItselfAndTheTailTakesTheRest() throws {
        let pasteboard = makePasteboard()
        let target = MacPasteTarget(pasteboard: { pasteboard })
        let keys = MacKeyRouter(searchHandoff: MacSearchHandoff(), pasteTarget: target) { _ in true }
        target.offer(by: UUID()) { _ in }
        let window = makeWindow(tailOf: keys)
        XCTAssertTrue(Self.pasteResponder(in: window) === keys.tail, "nothing focused: the tail")

        let field = NSSearchField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field edits through the field editor")
        XCTAssertTrue(Self.pasteResponder(in: window) === editor, "the field's own Paste, before the tail")
        XCTAssertTrue(Self.chain(of: window).contains { $0 === keys.tail }, "the tail still ends the chain")
    }

    /// A PDF copied in Finder, read off the pasteboard: admitted through the
    /// intake as a PDF, and opened. Its name, copied with it, is no book.
    func testAFileURLOnThePasteboardIsAdmittedThroughTheIntake() async throws {
        let folder = try makeFolder()
        let pasteboard = makePasteboard()
        let h = Harness()
        let pdf = try writeFile("Field Notes.pdf", in: folder)
        Self.copy([Self.fileEntry(pdf)], to: pasteboard)

        h.intake.admitPasteboard(pasteboard)
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.pdfNames, ["Field Notes.pdf"])
        XCTAssertEqual(h.library.textTitles, [], "its name, copied with it, is no book of its own")
        XCTAssertEqual(h.router.path.count, 1, "one file opens playing")
        XCTAssertNil(h.intake.failure)
    }

    /// Two files copied in Finder are one batch, as two dropped would be.
    func testTwoFilesOnThePasteboardAreOneBatch() async throws {
        let folder = try makeFolder()
        let pasteboard = makePasteboard()
        let h = Harness()
        let files = try ["one.txt", "two.txt"].map { try writeFile($0, in: folder) }
        Self.copy(files.map(Self.fileEntry), to: pasteboard)

        h.intake.admitPasteboard(pasteboard)
        let added = await waitUntil { h.library.documents.count == 2 && h.importer.phase == .idle }
        XCTAssertTrue(added)
        let settled = await waitUntil { !h.intake.holdsOpens }
        XCTAssertTrue(settled)

        XCTAssertEqual(h.library.importedNames, ["one.txt", "two.txt"], "in the order copied")
        XCTAssertEqual(h.router.path, [], "none of them opens")
        XCTAssertEqual(h.announcements, ["Added 2 books"])
    }

    /// A photo copied in Finder, pasted anyway: nothing, by the same rule.
    func testAPhotoOnThePasteboardAddsNothing() async throws {
        let folder = try makeFolder()
        let pasteboard = makePasteboard()
        let h = Harness()
        let photo = try writeFile("Beach.jpg", in: folder)
        Self.copy([Self.fileEntry(photo)], to: pasteboard)

        h.intake.admitPasteboard(pasteboard)
        _ = await waitUntil(0.3) { false }

        XCTAssertEqual(h.library.importedNames, [])
        XCTAssertNil(h.importer.failure)
        XCTAssertNil(h.intake.failure)
        XCTAssertEqual(h.importer.phase, .idle)
    }

    /// Copied text, read off the pasteboard: one book titled from its first
    /// line, opened and announced, the words as copied.
    func testTextOnThePasteboardImportsOneBook() async throws {
        let pasteboard = makePasteboard()
        let h = Harness()
        let article = "\n  \n  Flying   Light:\tNotes for a Long Trip  \nThe first paragraph.\n\nThe second."
        Self.copy([Self.textEntry(article)], to: pasteboard)

        h.intake.admitPasteboard(pasteboard)
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }

        XCTAssertTrue(added)
        XCTAssertEqual(h.library.textTitles, ["Flying Light: Notes for a Long Trip"])
        XCTAssertEqual(h.library.textBodies, [article], "the text as copied, whitespace and all")
        let book = try XCTUnwrap(h.library.documents.first)
        XCTAssertEqual(h.router.path, [.reader(book.id)], "one paste opens playing")
        XCTAssertEqual(h.announcements, ["Added Flying Light: Notes for a Long Trip"])
    }

    /// One ⌘V is one book: AppKit sends Paste to the first responder in the
    /// chain that takes it. With nothing focused that is the tail, which
    /// adds the copied text once. A focused view that takes Paste itself
    /// (SwiftUI's paste command, for a focused Library view) takes it
    /// instead, and the tail is never asked.
    func testOnePasteAddsOneBook() async throws {
        let pasteboard = makePasteboard()
        let h = Harness()
        let target = MacPasteTarget(pasteboard: { pasteboard })
        let keys = MacKeyRouter(searchHandoff: MacSearchHandoff(), pasteTarget: target) { _ in true }
        target.offer(by: UUID()) { h.intake.admitPasteboard($0) }
        let window = makeWindow(tailOf: keys)
        Self.copy([Self.textEntry("Pasted Once\nThis article is pasted once.")], to: pasteboard)
        let paste = #selector(NSText.paste(_:))

        XCTAssertEqual(Self.chain(of: window).filter { $0.responds(to: paste) }.count, 1, "only the tail takes Paste")
        let first = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(first.tryToPerform(paste, with: nil))
        let added = await waitUntil { h.library.documents.count == 1 && h.importer.phase == .idle }
        XCTAssertTrue(added)
        _ = await waitUntil(0.3) { false }
        XCTAssertEqual(h.library.documents.count, 1, "one paste, one book")
        XCTAssertEqual(h.library.textTitles, ["Pasted Once"])
        XCTAssertEqual(h.announcements, ["Added Pasted Once"])

        let focused = PasteTakingView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(focused)
        XCTAssertTrue(window.makeFirstResponder(focused))
        XCTAssertTrue(focused.tryToPerform(paste, with: nil))
        XCTAssertEqual(focused.pastes, 1)
        _ = await waitUntil(0.3) { false }
        XCTAssertEqual(h.library.documents.count, 1, "the tail was never asked")
    }

    // MARK: Pasteboard fixtures

    /// A pasteboard of this test's own, released after it.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.davidxie.AloudMacTests.paste.\(UUID().uuidString)"))
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        return pasteboard
    }

    /// Puts `items` on `pasteboard` in place of what was there, as a copy does.
    private static func copy(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
    }

    /// Copied text: one item of plain text.
    private static func textEntry(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }

    /// A copied picture, as from Preview: image data, with no file and no text.
    private static func imageEntry() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
        return item
    }

    /// A Finder copy of one file: its file URL, and its name as text.
    private static func fileEntry(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        return item
    }

    /// Edit ▸ Paste as the system's Edit menu has it: `paste:`, sent to the
    /// first responder that takes it.
    private static func pasteItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    /// A window, closed after the test, with the router's tail ending its chain.
    private func makeWindow(tailOf keys: MacKeyRouter) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        keys.ensureTail(on: window)
        return window
    }

    /// `window`'s responder chain, from its first responder.
    private static func chain(of window: NSWindow) -> [NSResponder] {
        var chain: [NSResponder] = []
        var next = window.firstResponder
        while let responder = next, chain.count < 64 {
            chain.append(responder)
            next = responder.nextResponder
        }
        return chain
    }

    /// Where AppKit sends Paste in `window`: the first responder in its
    /// chain that answers it.
    private static func pasteResponder(in window: NSWindow) -> NSResponder? {
        chain(of: window).first { $0.responds(to: #selector(NSText.paste(_:))) }
    }

    /// A focused view that takes Paste itself, as SwiftUI's paste command
    /// does for a focused Library view.
    private final class PasteTakingView: NSView {
        private(set) var pastes = 0
        override var acceptsFirstResponder: Bool { true }
        @objc func paste(_ sender: Any?) { pastes += 1 }
    }
}
