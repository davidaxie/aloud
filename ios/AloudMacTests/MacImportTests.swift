import XCTest
@testable import Aloud

/// M8 on the Mac: every route in goes through `MacFileIntake` and then the
/// shared importer. The same file twice is one book; several files, from
/// any route, Open With's included, are all added, none opens, and one
/// count is announced; a cloud placeholder the coordinator can't fetch
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

    /// Three files are all added and none opens, VoiceOver hears one count
    /// for them (M8), and the hold ends with the batch: the next single
    /// file opens as usual, announced by its title.
    func testThreeFilesAreAddedAndNoneOpens() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        var announcements: [String] = []
        let importer = DocumentImporter(library: library) { announcements.append($0) }
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
        XCTAssertEqual(announcements, ["Added 3 books"], "one count, not a line per file")

        let single = try writeText("d.txt", in: folder)
        intake.admit([single])
        let opened = await waitUntil { router.path.count == 1 }
        XCTAssertTrue(opened, "one file still opens playing")
        XCTAssertEqual(library.documents.count, 4)
        XCTAssertEqual(announcements, ["Added 3 books", "Added d.txt"], "and is announced as before")
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

    /// A file still copying in shows on the import overlay (its name, no
    /// progress yet), and Cancel drops it: when the copy lands it is never
    /// handed over, nothing is added and no failure shows.
    func testCancelWhileAFileCopiesAddsNothing() async throws {
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

        intake.admit([try writeText("cloud.txt", in: folder)])
        let copying = await waitUntil { intake.copyingName == "cloud.txt" }
        XCTAssertTrue(copying, "the copy is published before the importer has it")
        XCTAssertEqual(importer.phase, .idle)
        let shown = try XCTUnwrap(MacImportOverlay.shown(phase: importer.phase, copyingName: intake.copyingName))
        XCTAssertEqual(shown.name, "cloud.txt")
        XCTAssertEqual(shown.progress, 0)

        intake.cancel()
        XCTAssertNil(intake.copyingName, "the overlay goes at once")
        XCTAssertNil(MacImportOverlay.shown(phase: importer.phase, copyingName: intake.copyingName))
        await download.finish()
        let settled = await waitUntil { !intake.holdsOpens }
        XCTAssertTrue(settled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.documents.count, 0, "a cancelled copy is never added")
        XCTAssertEqual(importer.phase, .idle)
        XCTAssertNil(intake.failure)
        XCTAssertEqual(router.path, [])
    }

    /// A cancelled copy whose read runs on (a slow cloud download) never
    /// leaves the overlay up over the next file's book, nor holds the next
    /// batch's opens; and while two drops copy, the card names the one
    /// still copying, never one already added (G010).
    func testACancelledCopyStillReadingNeitherShowsNorHolds() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let importer = DocumentImporter(library: library) { _ in }
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        let download = Download()
        let intake = MacFileIntake(importer: importer) { url in
            if url.lastPathComponent == "big.txt" { await download.finished() }
            return url
        }

        intake.admit([try writeText("big.txt", in: folder)])
        let copying = await waitUntil { intake.copyingName == "big.txt" }
        XCTAssertTrue(copying)
        intake.cancel()
        intake.admit([try writeText("notes.txt", in: folder)])
        let added = await waitUntil { library.documents.count == 1 && importer.phase == .idle }
        XCTAssertTrue(added, "the next file is added while the cancelled read runs on")
        XCTAssertNil(intake.copyingName, "no card for a file already added")
        XCTAssertNil(MacImportOverlay.shown(phase: importer.phase, copyingName: intake.copyingName))

        intake.admit([try writeText("one.txt", in: folder), try writeText("two.txt", in: folder)])
        let both = await waitUntil { library.documents.count == 3 && importer.phase == .idle }
        XCTAssertTrue(both)
        let released = await waitUntil(2) { !intake.holdsOpens }
        XCTAssertTrue(released, "a batch's hold ends with the batch, not with the cancelled read")
        XCTAssertNil(intake.copyingName)

        await download.finish()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.documents.count, 3, "the cancelled copy is never added")
        XCTAssertNil(intake.copyingName)
    }

    /// Two drops copying at once: when the quick one is added, the card
    /// names the slow one, still copying, until it too is handed over.
    func testOverlappingCopiesNameTheOneStillCopying() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let importer = DocumentImporter(library: library) { _ in }
        let download = Download()
        let intake = MacFileIntake(importer: importer) { url in
            if url.lastPathComponent == "big.txt" { await download.finished() }
            return url
        }

        intake.admit([try writeText("big.txt", in: folder)])
        let copying = await waitUntil { intake.copyingName == "big.txt" }
        XCTAssertTrue(copying)
        intake.admit([try writeText("notes.txt", in: folder)])
        let added = await waitUntil { library.documents.count == 1 && importer.phase == .idle }
        XCTAssertTrue(added)
        XCTAssertEqual(intake.copyingName, "big.txt", "the file still copying, not the one added")

        await download.finish()
        let both = await waitUntil { library.documents.count == 2 && importer.phase == .idle }
        XCTAssertTrue(both)
        XCTAssertNil(intake.copyingName)
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
        var announcements: [String] = []
        let importer = DocumentImporter(library: library) { announcements.append($0) }
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
        XCTAssertEqual(announcements, ["Added 2 books"], "the two that were added, counted once")
        XCTAssertEqual(intake.failure, .notDownloaded)
    }

    // MARK: Open With and the Dock

    /// What the window's `onOpenURL` does with each file SwiftUI hands it.
    private func openWith(_ url: URL, router: LibraryRouter, intake: MacFileIntake,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(MacRootView.receiveOpened(url, router: router, intake: intake),
                     "an addable file shows no failure", file: file, line: line)
    }

    /// An importer over `library` that opens through `router` and announces
    /// through `announce`, and an intake over it that copies nothing.
    private func openWithIntake(library: FakeLibrary, router: LibraryRouter,
                                announce: @escaping (String) -> Void) -> (DocumentImporter, MacFileIntake) {
        let importer = DocumentImporter(library: library, announce: announce)
        importer.navigation = router
        importer.onAdded = { router.open($0) }
        return (importer, MacFileIntake(importer: importer, stage: Self.inPlace))
    }

    /// Two files of one Open With, handed over one at a time in the same
    /// turn, are one batch: both added, neither opens, one count. Before the
    /// gathering, each was its own add, announced one by one, and the last
    /// opened.
    func testFilesOpenedTogetherAreOneBatch() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        router.showBookshelf()
        var announcements: [String] = []
        let (importer, intake) = openWithIntake(library: library, router: router) { announcements.append($0) }
        let files = try ["a.txt", "b.pdf"].map { try writeText($0, in: folder) }

        for file in files { openWith(file, router: router, intake: intake) }
        let added = await waitUntil { library.documents.count == 2 && importer.phase == .idle }
        XCTAssertTrue(added, "both are added")
        let settled = await waitUntil { !intake.holdsOpens }
        XCTAssertTrue(settled, "the hold ends with the batch")
        XCTAssertEqual(library.importedNames, ["a.txt", "b.pdf"], "in the order handed over")
        XCTAssertEqual(router.path, [], "the bare Library, and neither opens")
        XCTAssertEqual(announcements, ["Added 2 books"], "one count, not a line per file")
    }

    /// One file alone opens playing (R4), from wherever the user was.
    func testOneFileOpenedAloneOpens() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        router.showBookshelf()
        var announcements: [String] = []
        let (_, intake) = openWithIntake(library: library, router: router) { announcements.append($0) }

        openWith(try writeText("one.txt", in: folder), router: router, intake: intake)
        let opened = await waitUntil { router.path.count == 1 }
        XCTAssertTrue(opened, "the file opens")
        let id = try XCTUnwrap(library.documents.first?.id)
        XCTAssertEqual(router.path, [.reader(id)], "over the bare Library, not Classics")
        XCTAssertEqual(announcements, ["Added one.txt"])
        XCTAssertFalse(intake.holdsOpens)
    }

    /// A type Aloud can't add, forced in by Open With ▸ Other…: the window
    /// stays as it was (the reader, Rename still up), nothing is added, and
    /// the failure says what Aloud reads. Before, the window was cleared
    /// first and the intake then dropped the file without a word.
    func testAnUnsupportedFileOpenedKeepsTheWindowAndSaysWhy() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let reading = UUID()
        router.path = [.reader(reading)]
        router.rootPresentation = .rename
        let (importer, intake) = openWithIntake(library: library, router: router) { _ in }
        let notes = folder.appendingPathComponent("notes.docx")
        try Data("PK".utf8).write(to: notes)

        let failure = MacRootView.receiveOpened(notes, router: router, intake: intake)

        XCTAssertEqual(failure, .textNoText)
        XCTAssertEqual(failure?.nextStep, "Try a PDF or a plain-text file.")
        XCTAssertEqual(router.path, [.reader(reading)], "the reader stays open")
        XCTAssertEqual(router.rootPresentation, .rename, "Rename stays up")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.importedNames, [], "nothing is added")
        XCTAssertEqual(importer.phase, .idle)
        XCTAssertNil(intake.failure)
    }

    /// The app delegate's fallback (no Open With entry; the UI tests' replay)
    /// takes the same care: a type Aloud can't add leaves the reader and
    /// Rename up, where it cleared the window first and the intake then
    /// dropped the file (H045). An addable file beside it still clears and
    /// adds.
    func testTheDelegatesFallbackKeepsTheWindowForAnUnsupportedFile() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        let reading = UUID()
        router.path = [.reader(reading)]
        router.rootPresentation = .rename
        let (_, intake) = openWithIntake(library: library, router: router) { _ in }
        let notes = folder.appendingPathComponent("notes.docx")
        try Data("PK".utf8).write(to: notes)

        MacAppDelegate.admitWithoutEntry([notes], router: router, intake: intake)

        XCTAssertEqual(router.path, [.reader(reading)], "the reader stays open")
        XCTAssertEqual(router.rootPresentation, .rename, "Rename stays up")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.importedNames, [], "nothing is added")

        MacAppDelegate.admitWithoutEntry([notes, try writeText("one.txt", in: folder)],
                                         router: router, intake: intake)
        XCTAssertNil(router.rootPresentation, "an addable file clears the window")
        let added = await waitUntil { library.importedNames == ["one.txt"] }
        XCTAssertTrue(added, "only the addable file is added")
    }

    /// The same file handed over twice in one turn is one file: added once
    /// and opened, not a batch of two that opens none.
    func testOneFileHandedOverTwiceStillOpens() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        var announcements: [String] = []
        let (importer, intake) = openWithIntake(library: library, router: router) { announcements.append($0) }
        let file = try writeText("twice.txt", in: folder)

        openWith(file, router: router, intake: intake)
        openWith(file, router: router, intake: intake)
        let opened = await waitUntil { router.path.count == 1 && importer.phase == .idle }
        XCTAssertTrue(opened, "the file opens")
        XCTAssertEqual(library.importedNames, ["twice.txt"], "added once")
        XCTAssertEqual(announcements, ["Added twice.txt"])
        XCTAssertFalse(intake.holdsOpens)
    }

    /// Two opens in turns of their own are two gatherings, each a single
    /// open: the second book takes the first one's place.
    func testOpensInSeparateTurnsEachOpen() async throws {
        let folder = try makeFolder()
        let library = FakeLibrary()
        let router = LibraryRouter()
        var announcements: [String] = []
        let (importer, intake) = openWithIntake(library: library, router: router) { announcements.append($0) }

        openWith(try writeText("first.txt", in: folder), router: router, intake: intake)
        let first = await waitUntil { router.path.count == 1 && importer.phase == .idle }
        XCTAssertTrue(first, "the first file opens")
        let firstID = try XCTUnwrap(library.documents.first?.id)
        XCTAssertEqual(router.path, [.reader(firstID)])

        openWith(try writeText("second.txt", in: folder), router: router, intake: intake)
        let second = await waitUntil { library.documents.count == 2 && importer.phase == .idle }
        XCTAssertTrue(second, "the second file is added")
        let secondID = try XCTUnwrap(library.documents.last?.id)
        let reopened = await waitUntil { router.path == [.reader(secondID)] }
        XCTAssertTrue(reopened, "and opens in its own turn, as a single file")
        XCTAssertEqual(announcements, ["Added first.txt", "Added second.txt"], "each announced by its title")
        XCTAssertFalse(intake.holdsOpens)
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

    /// A failure before the importer reads as the importer would: a PDF by
    /// its "%PDF-" signature under any name, as `DocumentImporter.isPDF`
    /// has it (F091). A cloud file that couldn't be fetched is never read
    /// again to find out.
    func testAFailedFileIsAPDFByTheImportersOwnTest() throws {
        let folder = try makeFolder()
        let misnamed = folder.appendingPathComponent("report.txt")
        try Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: misnamed)
        XCTAssertTrue(MacFileIntake.isPDF(misnamed), "a PDF saved as .txt")
        XCTAssertFalse(MacFileIntake.isPDF(try writeText("notes.txt", in: folder)))
        XCTAssertTrue(MacFileIntake.isPDF(folder.appendingPathComponent("SCAN.PDF")), "by its name, unread")
        XCTAssertEqual(MacFileIntake.isPDF(misnamed), DocumentImporter.isPDF(misnamed))

        var asked = false
        func sniff() -> Bool { asked = true; return true }
        XCTAssertEqual(MacFileIntake.failure(for: CocoaError(.ubiquitousFileUnavailable), isPDF: sniff()),
                       .notDownloaded)
        XCTAssertFalse(asked, "an unfetched cloud file isn't read")
        XCTAssertEqual(MacFileIntake.failure(for: CocoaError(.fileReadNoSuchFile), isPDF: sniff()), .couldNotOpen)
        XCTAssertTrue(asked)
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

    /// A dropped symbolic link stages the file it points to, as a regular
    /// file: a relative link would dangle from the staging folder, and an
    /// absolute one would leave the library a link outside its container.
    func testASymbolicLinkStagesTheFileItPointsTo() throws {
        let folder = try makeFolder()
        let root = folder.appendingPathComponent("Inbox", isDirectory: true)
        let books = folder.appendingPathComponent("Books", isDirectory: true)
        let desktop = folder.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let real = try writeText("real.txt", in: books)
        let relative = desktop.appendingPathComponent("relative.txt")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "../Books/real.txt")
        let absolute = desktop.appendingPathComponent("absolute.txt")
        try FileManager.default.createSymbolicLink(at: absolute, withDestinationURL: real)

        for link in [relative, absolute] {
            let staged = try MacFileIntake.stageCopy(of: link, into: root, read: MacFileIntake.systemCoordinatedRead)
            XCTAssertEqual(staged.lastPathComponent, link.lastPathComponent, "the dropped name")
            let type = try FileManager.default.attributesOfItem(atPath: staged.path)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeRegular, "\(link.lastPathComponent): a copy, not a link")
            XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: real))
        }
    }

    /// The real stage lands where the importer deletes its file after the
    /// add, so a staged copy never outlives its import.
    func testStagedCopiesLandWhereTheImporterCleansUp() {
        let staged = MacFileIntake.stagingRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("book.pdf")
        XCTAssertTrue(DocumentImporter.isInboxCopy(staged))
    }

    /// A quit or crash mid-add leaves a staged copy no queue will reach:
    /// the first add of the next launch clears it. Later sweeps take only
    /// empty folders, and nothing that isn't the intake's own.
    func testTheFirstSweepOfALaunchClearsAnEarlierRunsCopies() throws {
        let root = try makeFolder()
        let fm = FileManager.default
        let unfinished = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let empty = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let foreign = root.appendingPathComponent("Keep", isDirectory: true)
        for folder in [unfinished, empty, foreign] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        _ = try writeText("left.txt", in: unfinished)
        _ = try writeText("other.txt", in: foreign)

        MacFileIntake.sweepStagingFolders(in: root, includingUnfinished: false)
        XCTAssertFalse(fm.fileExists(atPath: empty.path), "an empty folder goes on every sweep")
        XCTAssertTrue(fm.fileExists(atPath: unfinished.path), "a copy in flight is left alone mid-launch")

        MacFileIntake.sweepStagingFolders(in: root, includingUnfinished: true)
        XCTAssertFalse(fm.fileExists(atPath: unfinished.path), "an earlier run's copy goes at launch")
        XCTAssertTrue(fm.fileExists(atPath: foreign.appendingPathComponent("other.txt").path),
                      "only the intake's own folders")
    }
}
