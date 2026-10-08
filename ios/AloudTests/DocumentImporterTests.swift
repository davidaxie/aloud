import XCTest
@testable import Aloud

/// R10: the one add path. Driven against an in-memory library, so nothing
/// touches extraction, the real shelf or audio: there is no PlaybackController
/// here, and opening is observed only as the importer's `onAdded` call (and,
/// for the open rule, a real LibraryRouter's path).
@MainActor
final class DocumentImporterTests: XCTestCase {

    // MARK: Type sniffing (F091)

    /// A PDF saved under a .txt name goes to the PDF reader by its "%PDF-"
    /// signature; text and unreadable files go by their name.
    func testPDFSignatureRoutesAMisnamedFileToThePDFReader() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-sniff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let misnamed = folder.appendingPathComponent("report.txt")
        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: misnamed)
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("Plain notes about a PDF-1 form.".utf8).write(to: notes)

        XCTAssertTrue(DocumentImporter.isPDF(misnamed))
        XCTAssertFalse(DocumentImporter.isPDF(notes))
        XCTAssertTrue(DocumentImporter.isPDF(folder.appendingPathComponent("SCAN.PDF")), "by name, unread")
        XCTAssertFalse(DocumentImporter.isPDF(folder.appendingPathComponent("missing.txt")))
    }

    // MARK: Fixtures

    /// In-memory LibraryAdding. Imports can hold (a 30 s sleep that records
    /// whether the importer cancelled it) or wait on a gate the test
    /// releases one at a time; classic adds can hold on a gate too.
    @MainActor
    private final class FakeLibrary: LibraryAdding {
        var documents: [LibraryDocument] = []
        var result: Result<LibraryDocument, any Error>
        /// Per-file results, by file name; `result` for any other file.
        var documentsByFileName: [String: LibraryDocument] = [:]
        var holdsImports = false
        var gatesImports = false
        var holdsClassics = false
        var classicError: (any Error)?
        private(set) var importedURLs: [URL] = []
        private(set) var sawCancellation = false
        private(set) var addClassicCalls = 0
        private var classicGate: CheckedContinuation<Void, Never>?
        private var importGates: [CheckedContinuation<Void, Never>] = []
        var pendingImports: Int { importGates.count }

        init(result: Result<LibraryDocument, any Error>) {
            self.result = result
        }

        func importPDF(from url: URL,
                       progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            try await importAny(url)
        }

        func importText(title: String, author: String?, from url: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            try await importAny(url)
        }

        func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
            addClassicCalls += 1
            if holdsClassics {
                await withCheckedContinuation { classicGate = $0 }
            }
            if let classicError { throw classicError }
            return DocumentImporterTests.document(title: book.title)
        }

        func releaseClassic() {
            classicGate?.resume()
            classicGate = nil
        }

        func releaseImport() {
            guard !importGates.isEmpty else { return }
            importGates.removeFirst().resume()
        }

        private func importAny(_ url: URL) async throws -> LibraryDocument {
            importedURLs.append(url)
            // Read when the import starts, so a test can make only a LATER
            // file hold: a gated file released after `holdsImports` flips
            // must not start holding too.
            let holds = holdsImports
            if gatesImports {
                await withCheckedContinuation { importGates.append($0) }
            }
            if holds {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    sawCancellation = true
                    throw error
                }
            }
            if let document = documentsByFileName[url.lastPathComponent] { return document }
            return try result.get()
        }
    }

    /// What the importer told the outside world.
    private final class Log {
        var opened: [LibraryDocument] = []
        var announcements: [String] = []
    }

    nonisolated static func document(title: String) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "x.txt", addedAt: Date(),
                        pageCount: 1, sentenceCount: 1, contentHash: "h-\(title)", kind: .text)
    }

    private func makeImporter(_ library: FakeLibrary) -> (DocumentImporter, Log) {
        let log = Log()
        let importer = DocumentImporter(library: library) { log.announcements.append($0) }
        importer.onAdded = { log.opened.append($0) }
        return (importer, log)
    }

    private var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// A real Open-in copy, so the test can watch the importer remove it.
    private func makeInboxFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent(name)
        try Data("Fixture text.".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Never read: the fake library ignores the file.
    private func pickedURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Long enough for any task the importer wrongly started to run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Files and Open-in

    func testSuccessOpensOnceAndAnnouncesAdded() async {
        let fixture = Self.document(title: "Fixture")
        let library = FakeLibrary(result: .success(fixture))
        let (importer, log) = makeImporter(library)

        importer.importFile(at: pickedURL("fixture.txt"))
        XCTAssertTrue(importer.isImporting)

        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        await settle()
        XCTAssertEqual(importer.phase, .idle)
        XCTAssertEqual(log.opened.map(\.id), [fixture.id])
        XCTAssertEqual(log.announcements, ["Added Fixture"])
    }

    func testDuplicateAnnouncesAlreadyInLibraryAndStillOpens() async {
        let existing = Self.document(title: "Fixture")
        let library = FakeLibrary(result: .success(existing))
        library.documents = [existing]
        let (importer, log) = makeImporter(library)

        importer.importFile(at: pickedURL("fixture.txt"))

        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(log.opened.map(\.id), [existing.id])
        XCTAssertEqual(log.announcements, ["Fixture is already in your library"])
    }

    func testCancelMidImportResetsAtOnceAndNeverOpens() async throws {
        let file = try makeInboxFile("aloud-cancel-test.txt")
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        library.holdsImports = true
        let (importer, log) = makeImporter(library)

        importer.importFile(at: file)
        let started = await waitUntil { !library.importedURLs.isEmpty }
        XCTAssertTrue(started)

        importer.cancel()
        XCTAssertEqual(importer.phase, .idle)

        let removed = await waitUntil { !exists(file) }
        XCTAssertTrue(removed)
        XCTAssertTrue(library.sawCancellation)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertTrue(log.announcements.isEmpty)
        XCTAssertEqual(importer.phase, .idle)
    }

    func testCancelDropsQueuedFiles() async throws {
        let first = try makeInboxFile("aloud-cancel-first.txt")
        let second = try makeInboxFile("aloud-cancel-second.txt")
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        library.holdsImports = true
        let (importer, log) = makeImporter(library)

        importer.importFile(at: first)
        importer.importFile(at: second)   // queued behind the first
        let started = await waitUntil { !library.importedURLs.isEmpty }
        XCTAssertTrue(started)

        importer.cancel()
        XCTAssertEqual(importer.phase, .idle)
        XCTAssertFalse(exists(second), "a queued Inbox copy is dropped with the queue")

        let removed = await waitUntil { !exists(first) }
        XCTAssertTrue(removed)
        await settle()
        XCTAssertEqual(library.importedURLs, [first], "the queued file never starts")
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(importer.phase, .idle)
    }

    func testFailureUsesFixedCopyAndHoldsQueue() async {
        let library = FakeLibrary(result: .failure(ExtractionError.noReadableText))
        let (importer, log) = makeImporter(library)

        importer.importFile(at: pickedURL("scan.pdf"))
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(importer.phase, .failed(.pdfNoText))

        // An Open-in arriving over the alert waits for it.
        library.result = .success(Self.document(title: "Next"))
        importer.importFile(at: pickedURL("next.txt"))
        await settle()
        XCTAssertEqual(library.importedURLs.count, 1)
        XCTAssertEqual(importer.phase, .failed(.pdfNoText))

        importer.dismissFailure()
        XCTAssertTrue(importer.isImporting)
        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(library.importedURLs.map(\.lastPathComponent), ["scan.pdf", "next.txt"])
        XCTAssertEqual(log.opened.map(\.title), ["Next"])
    }

    func testPickerCancellationIsSilent() {
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        let (importer, _) = makeImporter(library)

        importer.handlePick(.failure(CocoaError(.userCancelled)))

        XCTAssertEqual(importer.phase, .idle)
        XCTAssertTrue(library.importedURLs.isEmpty)
    }

    func testPickerFailureShowsCouldNotOpen() {
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        let (importer, _) = makeImporter(library)

        importer.handlePick(.failure(CocoaError(.fileReadNoPermission)))

        XCTAssertEqual(importer.phase, .failed(.couldNotOpen))
        XCTAssertTrue(library.importedURLs.isEmpty)
    }

    // MARK: Several at once (M8)

    /// Three files handed over at once: all added in order, none opens,
    /// and VoiceOver hears one count when the last ends, not a line each.
    func testSeveralFilesAreAllAddedNoneOpensAndOneCountIsAnnounced() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.documentsByFileName = ["a.txt": Self.document(title: "A"), "b.pdf": Self.document(title: "B"),
                                       "c.txt": Self.document(title: "C")]
        library.gatesImports = true
        let router = LibraryRouter()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.importFiles(at: ["a.txt", "b.pdf", "c.txt"].map(pickedURL))
        for count in 1...2 {
            let started = await waitUntil { library.importedURLs.count == count && library.pendingImports == 1 }
            XCTAssertTrue(started)
            library.releaseImport()
            let next = await waitUntil { library.importedURLs.count == count + 1 }
            XCTAssertTrue(next)
            XCTAssertEqual(log.announcements, [], "nothing is said until the last ends")
        }
        library.releaseImport()
        let announced = await waitUntil { !log.announcements.isEmpty }
        XCTAssertTrue(announced)
        await settle()
        XCTAssertEqual(library.importedURLs.map(\.lastPathComponent), ["a.txt", "b.pdf", "c.txt"])
        XCTAssertEqual(log.announcements, ["Added 3 books"])
        XCTAssertTrue(log.opened.isEmpty, "none of them opens")
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(importer.phase, .idle)
    }

    /// A file already on the shelf isn't counted; a batch of nothing new
    /// says so, naming the book when it held only one (the same file twice,
    /// or the others failed).
    func testABatchCountsOnlyNewBooks() async {
        let old = Self.document(title: "Old"), older = Self.document(title: "Older")
        let library = FakeLibrary(result: .success(Self.document(title: "New")))
        library.documents = [old, older]
        library.documentsByFileName = ["old.txt": old, "older.txt": older]
        let (importer, log) = makeImporter(library)

        importer.importFiles(at: [pickedURL("new.txt"), pickedURL("old.txt")])
        let announced = await waitUntil { !log.announcements.isEmpty }
        XCTAssertTrue(announced)
        XCTAssertEqual(log.announcements, ["Added 1 book"])

        importer.importFiles(at: [pickedURL("old.txt"), pickedURL("older.txt")])
        let both = await waitUntil { log.announcements.count == 2 }
        XCTAssertTrue(both)
        XCTAssertEqual(log.announcements.last, "These books are already in your library")

        importer.importFiles(at: [pickedURL("old.txt"), pickedURL("old.txt")])
        let twice = await waitUntil { log.announcements.count == 3 }
        XCTAssertTrue(twice)
        XCTAssertEqual(log.announcements.last, "Old is already in your library", "one book, named")

        // The last one fails: its alert is read first, and the line waits
        // for it to close.
        library.result = .failure(ExtractionError.noReadableText)
        importer.importFiles(at: [pickedURL("old.txt"), pickedURL("scan.pdf")])
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)
        await settle()
        XCTAssertEqual(log.announcements.count, 3, "nothing said over the alert")
        importer.dismissFailure()
        XCTAssertEqual(log.announcements.last, "Old is already in your library", "the failure isn't counted")
        await settle()
        XCTAssertEqual(log.announcements.count, 4, "said once")
        XCTAssertTrue(log.opened.isEmpty)
    }

    /// A failure in a batch shows and holds the rest, as any failure does;
    /// the count still comes once, after the last.
    func testAFailureInABatchHoldsTheRestAndTheCountComesLast() async {
        let library = FakeLibrary(result: .failure(ExtractionError.noReadableText))
        library.documentsByFileName = ["a.txt": Self.document(title: "A"), "c.txt": Self.document(title: "C")]
        let (importer, log) = makeImporter(library)

        importer.importFiles(at: ["a.txt", "scan.pdf", "c.txt"].map(pickedURL))
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(importer.phase, .failed(.pdfNoText))
        await settle()
        XCTAssertEqual(library.importedURLs.count, 2, "the third waits for the alert")
        XCTAssertEqual(log.announcements, [])

        importer.dismissFailure()
        let announced = await waitUntil { !log.announcements.isEmpty }
        XCTAssertTrue(announced)
        await settle()
        XCTAssertEqual(log.announcements, ["Added 2 books"])
        XCTAssertTrue(log.opened.isEmpty)
    }

    /// Cancel mid-batch: the rest are dropped, and the books already added
    /// are still announced.
    func testCancellingABatchAnnouncesWhatItAdded() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.documentsByFileName = ["a.txt": Self.document(title: "A")]
        library.gatesImports = true
        let (importer, log) = makeImporter(library)

        importer.importFiles(at: ["a.txt", "b.txt", "c.txt"].map(pickedURL))
        let firstStarted = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(firstStarted)
        library.gatesImports = false
        library.holdsImports = true   // the second one holds until cancelled
        library.releaseImport()
        let secondStarted = await waitUntil { library.importedURLs.count == 2 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(log.announcements, [])

        importer.cancel()
        XCTAssertEqual(log.announcements, ["Added 1 book"])
        let cancelled = await waitUntil { library.sawCancellation }
        XCTAssertTrue(cancelled)
        await settle()
        XCTAssertEqual(library.importedURLs.count, 2, "the third never starts")
        XCTAssertEqual(log.announcements, ["Added 1 book"], "said once")
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(importer.phase, .idle)
    }

    /// One file handed over the batch way is an ordinary add: it opens and
    /// is announced by title.
    func testOneFileThroughTheBatchPathIsAnOrdinaryAdd() async {
        let fixture = Self.document(title: "Fixture")
        let library = FakeLibrary(result: .success(fixture))
        let (importer, log) = makeImporter(library)

        importer.importFiles(at: [pickedURL("fixture.txt")])
        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        await settle()
        XCTAssertEqual(log.opened.map(\.id), [fixture.id])
        XCTAssertEqual(log.announcements, ["Added Fixture"])

        importer.importFiles(at: [])
        XCTAssertEqual(importer.phase, .idle, "no files, no add")
    }

    // MARK: Classics

    private let classic = BookshelfBook(gutenbergID: 1063, title: "The Cask of Amontillado",
                                        author: "Edgar Allan Poe", year: 1846,
                                        file: "1063-the-cask-of-amontillado.txt", words: 2317)

    func testAddClassicIgnoresSecondTapWhileInFlight() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let (importer, log) = makeImporter(library)

        importer.addClassic(classic)
        XCTAssertEqual(importer.addingClassicID, classic.id)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)

        importer.addClassic(classic)
        await settle()
        XCTAssertEqual(library.addClassicCalls, 1)
        XCTAssertEqual(importer.phase, .idle, "a classic shows no overlay")

        library.releaseClassic()
        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertNil(importer.addingClassicID)
        XCTAssertEqual(log.opened.map(\.title), [classic.title])
        XCTAssertTrue(log.announcements.isEmpty)
    }

    func testMissingClassicShowsClassicMissing() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.classicError = DocumentStoreError.bundledBookMissing("x")
        let (importer, log) = makeImporter(library)

        importer.addClassic(classic)
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)

        XCTAssertEqual(importer.phase, .failed(.classicMissing))
        XCTAssertNil(importer.addingClassicID)
        XCTAssertTrue(log.opened.isEmpty)
    }

    // MARK: The open rule

    /// The importer as AppModel wires it: navigation reads the router, and
    /// an open goes through router.open (logged as well).
    private func makeRoutedImporter(_ library: FakeLibrary,
                                    router: LibraryRouter) -> (DocumentImporter, Log) {
        let (importer, log) = makeImporter(library)
        importer.navigation = router
        importer.onAdded = { document in
            log.opened.append(document)
            router.open(document)
        }
        return (importer, log)
    }

    /// Two Open-in files back to back: the first must not open (and start
    /// speaking) under the second one's overlay. Only the last one opens.
    func testQueuedFilesOpenOnlyTheLast() async {
        let first = Self.document(title: "First"), second = Self.document(title: "Second")
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.documentsByFileName = ["first.txt": first, "second.txt": second]
        library.gatesImports = true
        let (importer, log) = makeImporter(library)

        importer.importFile(at: pickedURL("first.txt"))
        importer.importFile(at: pickedURL("second.txt"))   // arrives mid-import
        let firstStarted = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(firstStarted)

        library.releaseImport()
        let secondStarted = await waitUntil { library.importedURLs.count == 2 && library.pendingImports == 1 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(log.opened.map(\.title), [], "the first book stays quiet under the next overlay")
        XCTAssertEqual(log.announcements, ["Added First"], "but it is still announced")
        XCTAssertTrue(importer.isImporting)

        library.releaseImport()
        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        await settle()
        XCTAssertEqual(log.opened.map(\.id), [second.id])
        XCTAssertEqual(log.announcements, ["Added First", "Added Second"])
    }

    /// Cancelling the last of a batch leaves the user on the shelf, not in
    /// an earlier book that has been playing behind the overlay.
    func testCancellingTheLastQueuedFileOpensNothing() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.documentsByFileName = ["first.txt": Self.document(title: "First")]
        library.gatesImports = true
        let router = LibraryRouter()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.importFile(at: pickedURL("first.txt"))
        importer.importFile(at: pickedURL("second.txt"))
        let firstStarted = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(firstStarted)

        library.gatesImports = false
        library.holdsImports = true   // the second one holds until cancelled
        library.releaseImport()
        let secondStarted = await waitUntil { library.importedURLs.count == 2 }
        XCTAssertTrue(secondStarted)

        importer.cancel()
        let cancelled = await waitUntil { library.sawCancellation }
        XCTAssertTrue(cancelled)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(router.path, [])
        XCTAssertEqual(importer.phase, .idle)
    }

    /// The user stayed on the Bookshelf: the classic opens on top of it.
    func testClassicOpensWhenTheUserStaysOnTheBookshelf() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let router = LibraryRouter()
        router.showBookshelf()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        library.releaseClassic()

        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(router.path, [.bookshelf, .reader(log.opened[0].id)])
        XCTAssertTrue(log.announcements.isEmpty, "the opened reader is the confirmation")
    }

    /// A long classic still extracting while the user goes Back and opens
    /// another book: that book must keep playing, never be swapped out.
    func testSlowClassicNeverReplacesABookOpenedMeanwhile() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let router = LibraryRouter()
        router.showBookshelf()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        router.popToRoot()                          // Back
        let chosen = Self.document(title: "Gatsby")
        router.open(chosen)                         // and another book

        library.releaseClassic()
        let done = await waitUntil { importer.addingClassicID == nil }
        XCTAssertTrue(done)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(router.path, [.reader(chosen.id)])
        XCTAssertEqual(log.announcements, ["Added \(classic.title)"], "a quiet add is announced")
    }

    /// Back, then Settings: the classic must not land on top of Settings.
    func testSlowClassicNeverOpensOverSettings() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let router = LibraryRouter()
        router.showBookshelf()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        router.popToRoot()
        router.showSettings()

        library.releaseClassic()
        let done = await waitUntil { importer.addingClassicID == nil }
        XCTAssertTrue(done)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(router.path, [.settings])
    }

    /// Leaving and coming back is still leaving: the path matches again,
    /// but the user may have played another book in between.
    func testSlowClassicStaysQuietAfterLeavingAndReturning() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let router = LibraryRouter()
        router.showBookshelf()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        router.popToRoot()
        router.showBookshelf()

        library.releaseClassic()
        let done = await waitUntil { importer.addingClassicID == nil }
        XCTAssertTrue(done)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(router.path, [.bookshelf])
    }

    /// The featured classic is still adding when the user opens the file
    /// picker: its reader must not open, and speak, under the picker.
    func testClassicNeverOpensUnderARootModal() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Unused")))
        library.holdsClassics = true
        let router = LibraryRouter()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        router.rootPresentation = .filePicker

        library.releaseClassic()
        let done = await waitUntil { importer.addingClassicID == nil }
        XCTAssertTrue(done)
        await settle()
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(router.path, [])
    }

    /// An Open-in during a classic add: the classic is added quietly and
    /// only the file the user just sent opens.
    func testOpenInDuringAClassicAddOpensOnlyTheFile() async {
        let file = Self.document(title: "Paper")
        let library = FakeLibrary(result: .success(file))
        library.holdsClassics = true
        let router = LibraryRouter()
        router.showBookshelf()
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.addClassic(classic)
        let reached = await waitUntil { library.addClassicCalls == 1 }
        XCTAssertTrue(reached)
        AppModel.routeOpenIn(pickedURL("paper.txt"), router: router, importer: importer)
        XCTAssertEqual(router.path, [])
        XCTAssertFalse(importer.isImporting, "the file waits for the classic")

        library.releaseClassic()
        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        await settle()
        XCTAssertEqual(log.opened.map(\.id), [file.id])
        XCTAssertEqual(router.path, [.reader(file.id)])
        XCTAssertEqual(log.announcements, ["Added \(classic.title)", "Added Paper"])
    }

    /// A Files pick opens even when SwiftUI clears the picker's flag only
    /// after the pick was handled: closing a modal is not moving away.
    func testFilePickOpensWhenThePickerFlagClearsLate() async {
        let fixture = Self.document(title: "Fixture")
        let library = FakeLibrary(result: .success(fixture))
        library.gatesImports = true
        let router = LibraryRouter()
        router.rootPresentation = .filePicker
        let (importer, log) = makeRoutedImporter(library, router: router)

        importer.handlePick(.success(pickedURL("fixture.txt")))
        let started = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(started)
        router.rootPresentation = nil
        library.releaseImport()

        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(router.path, [.reader(fixture.id)])
    }

    // MARK: Open-in over the Library's own modals

    /// Open-in with the picker, Rename alert or Delete dialog left up: it
    /// closes first, so the overlay shows and the reader opens uncovered.
    func testOpenInClosesARootModalBeforeImporting() async {
        let presentations: [LibraryRouter.RootPresentation] = [.filePicker, .rename, .deleteConfirmation,
                                                               .deleteFailed]
        for presentation in presentations {
            let fixture = Self.document(title: "Fixture")
            let library = FakeLibrary(result: .success(fixture))
            let router = LibraryRouter()
            router.rootPresentation = presentation
            let (importer, log) = makeRoutedImporter(library, router: router)

            AppModel.routeOpenIn(pickedURL("paper.pdf"), router: router, importer: importer)
            XCTAssertNil(router.rootPresentation, "\(presentation) closes before the import")
            XCTAssertTrue(importer.isImporting)

            let opened = await waitUntil { !log.opened.isEmpty }
            XCTAssertTrue(opened, "\(presentation)")
            XCTAssertEqual(router.path, [.reader(fixture.id)])
        }
    }

    /// Open-in pops to the root before importing; that pop is its own, so
    /// it never makes the import look stale.
    func testOpenInFromDeepInTheStackStillOpens() async {
        let fixture = Self.document(title: "Fixture")
        let library = FakeLibrary(result: .success(fixture))
        let router = LibraryRouter()
        router.showBookshelf()
        router.open(Self.document(title: "Playing"))
        let (importer, log) = makeRoutedImporter(library, router: router)

        AppModel.routeOpenIn(pickedURL("paper.pdf"), router: router, importer: importer)
        XCTAssertEqual(router.path, [])

        let opened = await waitUntil { !log.opened.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(router.path, [.reader(fixture.id)])
    }

    func testNonFileURLIsIgnored() async {
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        let router = LibraryRouter()
        router.rootPresentation = .rename
        let (importer, _) = makeRoutedImporter(library, router: router)

        AppModel.routeOpenIn(URL(string: "https://example.com/a.pdf")!, router: router, importer: importer)
        XCTAssertEqual(router.rootPresentation, .rename)
        XCTAssertFalse(importer.isImporting)
    }

    /// A failure raised while a root modal is up waits for it to close, so
    /// the alert is never lost behind it with the queue held forever.
    func testFailureAlertWaitsForRootModals() {
        XCTAssertFalse(RootView.showsFailureAlert(failure: .pdfNoText, rootPresentation: .filePicker))
        XCTAssertFalse(RootView.showsFailureAlert(failure: .pdfNoText, rootPresentation: .rename))
        XCTAssertTrue(RootView.showsFailureAlert(failure: .pdfNoText, rootPresentation: nil))
        XCTAssertFalse(RootView.showsFailureAlert(failure: nil, rootPresentation: nil))
    }

    // MARK: Open-in leftovers (F036)

    /// A folder standing in for the Open-in Inbox, holding one copy an
    /// earlier add never finished with.
    private func makeLeftoverInbox() throws -> (folder: URL, leftover: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let leftover = folder.appendingPathComponent("Left Behind.pdf")
        try Data("%PDF-1.4".utf8).write(to: leftover)
        return (folder, leftover)
    }

    /// An add the app never finished (iOS ended it mid-import) leaves its
    /// Open-in copy behind. The importer clears it once idle, never while
    /// an add runs.
    func testALeftoverInboxCopyIsClearedOnceIdleNeverMidAdd() async throws {
        let (folder, leftover) = try makeLeftoverInbox()
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        library.gatesImports = true
        let importer = DocumentImporter(library: library, announce: { _ in }, inbox: folder)
        importer.inboxSweepAge = -60   // anything already there counts as left over

        importer.importFile(at: pickedURL("fixture.txt"))
        let started = await waitUntil { library.pendingImports == 1 }
        XCTAssertTrue(started)
        await settle()
        XCTAssertTrue(exists(leftover), "never swept while an add runs")

        library.releaseImport()
        let swept = await waitUntil { !exists(leftover) }
        XCTAssertTrue(swept, "cleared once the importer is idle")
        XCTAssertEqual(importer.phase, .idle)
    }

    /// A failure on screen holds the sweep with the queue; dismissing it
    /// leaves the importer idle, and the leftover goes then.
    func testALeftoverWaitsForAFailureToBeDismissed() async throws {
        let (folder, leftover) = try makeLeftoverInbox()
        let library = FakeLibrary(result: .failure(CocoaError(.fileReadCorruptFile)))
        let importer = DocumentImporter(library: library, announce: { _ in }, inbox: folder)
        importer.inboxSweepAge = -60

        importer.importFile(at: pickedURL("broken.txt"))
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)
        await settle()
        XCTAssertTrue(exists(leftover), "not idle while the failure shows")

        importer.dismissFailure()
        XCTAssertFalse(exists(leftover))
    }

    /// A copy that has only just arrived may still be on its way to the
    /// importer (a cold Open-in), so the sweep keeps it.
    func testAnInboxCopyThatJustArrivedStays() async throws {
        let (folder, fresh) = try makeLeftoverInbox()
        let library = FakeLibrary(result: .success(Self.document(title: "Fixture")))
        let importer = DocumentImporter(library: library, announce: { _ in }, inbox: folder)
        XCTAssertEqual(importer.inboxSweepAge, 60)

        importer.importFile(at: pickedURL("fixture.txt"))
        let done = await waitUntil { importer.phase == .idle }
        XCTAssertTrue(done)
        await settle()
        XCTAssertTrue(exists(fresh))

        DocumentImporter.sweepLeftovers(in: folder, arrivedBefore: Date().addingTimeInterval(-60))
        XCTAssertTrue(exists(fresh))
        DocumentImporter.sweepLeftovers(in: folder, arrivedBefore: Date().addingTimeInterval(60))
        XCTAssertFalse(exists(fresh))
    }

    /// L004: an Inbox copy that arrived locked (Finder's Locked flag, kept
    /// by the copy that brought it) still goes. Before, the sweep's removal
    /// failed without a word and the copy stayed for good.
    func testALockedInboxLeftoverIsSwept() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("aloud-locked-inbox-\(UUID().uuidString)",
                                                                   isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let locked = folder.appendingPathComponent("Locked.txt")
        try Data("Call me Ishmael.".utf8).write(to: locked)
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        addTeardownBlock { DocumentStore.unlock(locked) }

        DocumentImporter.sweepLeftovers(in: folder, arrivedBefore: Date().addingTimeInterval(60))

        XCTAssertFalse(fm.fileExists(atPath: locked.path))
    }

    /// The time an add holds against suspension is given back once, and a
    /// second end is harmless (the add's end and the system's expiry).
    func testBackgroundTimeEndsOnce() {
        let held = PlatformBackgroundTask(name: "Adding a book")
        held.end()
        XCTAssertFalse(held.isHeld)
        held.end()
        XCTAssertFalse(held.isHeld)
    }
}
