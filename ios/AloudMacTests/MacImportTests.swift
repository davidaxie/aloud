import XCTest
@testable import Aloud

/// M8 on the Mac: every route in goes through `MacFileIntake` and then the
/// shared importer. The same file twice is one book; several files are all
/// added and none opens; a cloud placeholder the coordinator can't fetch
/// fails as `notDownloaded` and stores nothing. Fixtures are written into
/// the test host's own temporary folder: a sandboxed host can't read the
/// checkout.
@MainActor
final class MacImportTests: XCTestCase {

    // MARK: Fixtures

    /// In-memory LibraryAdding: each file adds one new book, at once.
    @MainActor
    private final class FakeLibrary: LibraryAdding {
        var documents: [LibraryDocument] = []
        private(set) var importedNames: [String] = []

        func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            add(url)
        }

        func importText(title: String, author: String?, from url: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            add(url)
        }

        func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
            add(URL(fileURLWithPath: book.file))
        }

        private func add(_ url: URL) -> LibraryDocument {
            importedNames.append(url.lastPathComponent)
            let document = LibraryDocument(id: UUID(), title: url.lastPathComponent, fileName: "x.txt",
                                           addedAt: Date(), pageCount: 1, sentenceCount: 1,
                                           contentHash: "h-\(url.lastPathComponent)", kind: .text)
            documents.append(document)
            return document
        }
    }

    /// A fresh folder in the host's temporary directory, removed after the test.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-mac-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeText(_ name: String, in folder: URL, sentences: Int = 3) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let text = (1...sentences).map { "This is sentence number \($0) of the fixture." }.joined(separator: " ")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
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

    /// A stage that hands the file over where it is.
    private static let inPlace: MacFileIntake.Stage = { $0 }

    // MARK: Dedupe

    /// The same file added twice, through the real coordinated copy and the
    /// real store (over an index of its own), is one book: the second add
    /// opens the copy already on the shelf.
    func testTheSameFileTwiceLeavesTheCountUnchanged() async throws {
        let folder = try makeFolder()
        let store = DocumentStore(indexURL: folder.appendingPathComponent("library.json"),
                                  saveInterval: 0.05, notifications: NotificationCenter())
        addTeardownBlock { @MainActor in store.documents.forEach(store.delete) }
        let importer = DocumentImporter(library: store) { _ in }
        var opened: [LibraryDocument] = []
        importer.onAdded = { opened.append($0) }
        let intake = MacFileIntake(importer: importer)
        let fixture = try writeText("twice.txt", in: folder)

        intake.admit([fixture])
        let first = await waitUntil { opened.count == 1 }
        XCTAssertTrue(first, "the first add opens its book")
        XCTAssertEqual(store.documents.count, 1)

        intake.admit([fixture])
        let second = await waitUntil { opened.count == 2 }
        XCTAssertTrue(second, "the second add opens the book on the shelf")
        XCTAssertEqual(store.documents.count, 1, "a duplicate never raises the count")
        XCTAssertEqual(Set(opened.map(\.id)).count, 1, "both adds open the one book")
        XCTAssertNil(intake.failure)
        XCTAssertEqual(importer.phase, .idle)
    }

    // MARK: Batches

    /// Three files are all added and none opens, and the hold ends with the
    /// batch: the next single file opens as usual.
    func testThreeFilesAreAddedAndNoneOpens() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let importer = DocumentImporter(library: library) { _ in }
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        let intake = MacFileIntake(importer: importer, stage: Self.inPlace)
        let files = try ["a.txt", "b.txt", "c.pdf"].map { try writeText($0, in: folder) }

        intake.admit(files)
        let added = await waitUntil { library.documents.count == 3 && importer.phase == .idle }
        XCTAssertTrue(added, "all three are added")
        let settled = await waitUntil { !intake.holdsOpens }
        XCTAssertTrue(settled, "the hold ends with the batch")
        XCTAssertEqual(library.importedNames, ["a.txt", "b.txt", "c.pdf"], "in the order chosen")
        XCTAssertEqual(router.path, [], "none of them opens")

        let single = try writeText("d.txt", in: folder)
        intake.admit([single])
        let opened = await waitUntil { router.path.count == 1 }
        XCTAssertTrue(opened, "one file still opens playing")
        XCTAssertEqual(library.documents.count, 4)
    }

    /// The open rule counts the copy: a user who moves on while a cloud
    /// file downloads stays where they went, and the book is added quietly.
    func testMovingOnWhileAFileCopiesAddsItQuietly() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let importer = DocumentImporter(library: library) { _ in }
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        let download = Download()
        let intake = MacFileIntake(importer: importer) { url in
            await download.finished()
            return url
        }

        intake.admit([try writeText("slow.txt", in: folder)])
        router.showBookshelf()
        await download.finish()
        let added = await waitUntil { library.documents.count == 1 && importer.phase == .idle }
        XCTAssertTrue(added, "the file is still added")
        let settled = await waitUntil { !intake.holdsOpens }
        XCTAssertTrue(settled)
        XCTAssertEqual(router.path, [.bookshelf], "the user stays in Classics")
    }

    /// A download that ends when the test says so.
    private actor Download {
        private var isFinished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func finished() async {
            guard !isFinished else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish() {
            isFinished = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Only PDFs and plain text get in: a folder or another type is left out
    /// of a mixed drop, and doesn't make a batch of what remains.
    func testOnlyPDFAndPlainTextAreAdmitted() async throws {
        let folder = try makeFolder()
        XCTAssertTrue(MacFileIntake.isAddable(folder.appendingPathComponent("a.pdf")))
        XCTAssertTrue(MacFileIntake.isAddable(folder.appendingPathComponent("b.txt")))
        XCTAssertTrue(MacFileIntake.isAddable(folder.appendingPathComponent("SCAN.PDF")),
                      "the importer reads an upper-case extension, so the drop takes it")
        XCTAssertFalse(MacFileIntake.isAddable(folder.appendingPathComponent("c.docx")))
        XCTAssertFalse(MacFileIntake.isAddable(folder))
        XCTAssertFalse(MacFileIntake.isAddable(URL(string: "https://example.com/a.pdf")!))

        let library = FakeLibrary()
        let router = LibraryRouter()
        let importer = DocumentImporter(library: library) { _ in }
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        let intake = MacFileIntake(importer: importer, stage: Self.inPlace)
        let text = try writeText("only.txt", in: folder)
        intake.admit([text, folder.appendingPathComponent("notes.docx"), folder])
        let opened = await waitUntil { router.path.count == 1 }
        XCTAssertTrue(opened, "one addable file opens")
        XCTAssertEqual(library.importedNames, ["only.txt"])
    }

    /// A batch with one placeholder in it: the other two are still added,
    /// neither opens, and the one failure is the alert's.
    func testABatchWithAFailedCopyAddsTheRestAndOpensNone() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let importer = DocumentImporter(library: library) { _ in }
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        let intake = MacFileIntake(importer: importer) { url in
            guard url.lastPathComponent != "cloud.pdf" else {
                throw MacFileIntake.CoordinationError(underlying: CocoaError(.fileReadUnknown))
            }
            return url
        }
        let files = try ["a.txt", "cloud.pdf", "c.txt"].map { try writeText($0, in: folder) }

        intake.admit(files)
        let added = await waitUntil { library.documents.count == 2 && importer.phase == .idle }
        XCTAssertTrue(added, "the two that copied are added")
        let settled = await waitUntil { !intake.holdsOpens }
        XCTAssertTrue(settled)
        XCTAssertEqual(library.importedNames, ["a.txt", "c.txt"])
        XCTAssertEqual(router.path, [], "still a batch: none of them opens")
        XCTAssertEqual(intake.failure, .notDownloaded)
    }

    // MARK: Cloud placeholders

    /// The rule: the coordinator's refusal, and the system's own "not
    /// available" for a cloud file, read as `notDownloaded`; anything else
    /// as the importer would read it.
    func testACoordinatorFailureMapsToNotDownloaded() {
        let refused = MacFileIntake.CoordinationError(
            underlying: NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue))
        XCTAssertEqual(MacFileIntake.failure(for: refused, isPDF: true), .notDownloaded)
        XCTAssertEqual(MacFileIntake.failure(for: refused, isPDF: false), .notDownloaded)
        XCTAssertEqual(MacFileIntake.failure(for: CocoaError(.ubiquitousFileUnavailable), isPDF: true),
                       .notDownloaded)
        XCTAssertEqual(MacFileIntake.failure(for: CocoaError(.fileWriteOutOfSpace), isPDF: true), .outOfSpace)
        XCTAssertEqual(MacFileIntake.failure(for: CocoaError(.fileReadNoSuchFile), isPDF: false), .couldNotOpen)
        XCTAssertEqual(ImportFailure.notDownloaded.title, "This file isn't downloaded yet.")
    }

    /// A refused coordinated read stages nothing: no copy, no folder.
    func testARefusedReadStagesNothing() throws {
        let folder = try makeFolder()
        let root = folder.appendingPathComponent("Inbox", isDirectory: true)
        let source = try writeText("placeholder.pdf", in: folder)
        let refuse: MacFileIntake.CoordinatedRead = { _, _ in
            throw MacFileIntake.CoordinationError(underlying: CocoaError(.fileReadUnknown))
        }
        XCTAssertThrowsError(try MacFileIntake.stageCopy(of: source, into: root, read: refuse)) { error in
            XCTAssertEqual(MacFileIntake.failure(for: error, isPDF: true), .notDownloaded)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertEqual(left, [], "the staging folder is removed with its failure")
    }

    /// Through the intake: the alert's row is `notDownloaded`, the importer
    /// never sees the file, and the library stores nothing.
    func testAPlaceholderTheCoordinatorCantFetchStoresNothing() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let importer = DocumentImporter(library: library) { _ in }
        var opened = 0
        importer.onAdded = { _ in opened += 1 }
        let intake = MacFileIntake(importer: importer) { _ in
            throw MacFileIntake.CoordinationError(underlying: CocoaError(.fileReadUnknown))
        }
        intake.admit([try writeText("cloud.pdf", in: folder)])
        let failed = await waitUntil { intake.failure != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(intake.failure, .notDownloaded)
        XCTAssertEqual(library.documents.count, 0, "nothing is stored")
        XCTAssertEqual(library.importedNames, [], "the importer never sees it")
        XCTAssertEqual(importer.phase, .idle, "the importer's own failure slot stays free")
        XCTAssertEqual(opened, 0)
        intake.dismissFailure()
        XCTAssertNil(intake.failure)
    }

    /// The real coordinator, over an ordinary local file: a byte-identical
    /// copy under its own name, in its own folder.
    func testTheSystemCoordinatedCopyKeepsTheNameAndTheBytes() throws {
        let folder = try makeFolder()
        let root = folder.appendingPathComponent("Inbox", isDirectory: true)
        let source = try writeText("Moby-Dick ch1.txt", in: folder)
        let staged = try MacFileIntake.stageCopy(of: source, into: root, read: MacFileIntake.systemCoordinatedRead)
        XCTAssertEqual(staged.lastPathComponent, "Moby-Dick ch1.txt")
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: source))
    }

    /// The real stage lands where the importer deletes its file after the
    /// add, so a staged copy never outlives its import.
    func testStagedCopiesLandWhereTheImporterCleansUp() {
        let staged = MacFileIntake.stagingRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("book.pdf")
        XCTAssertTrue(DocumentImporter.isInboxCopy(staged))
    }
}
