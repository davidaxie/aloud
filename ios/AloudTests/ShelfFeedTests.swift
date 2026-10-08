import SwiftUI
import XCTest
@testable import Aloud

/// The shelf's shared rules, on both hosts: the feed that rebuilds only
/// while the Library shows (P020), where focus goes after a removal (P022),
/// the iPhone shelf's rhythm (P018), the bar's edge rule (P021), the import
/// overlay's reveal delay (P015), the Files picker's several-at-once path
/// (P016), the pressed plate (P019) and the long-press menu's sections
/// (P023). Pure values and in-memory fakes: no window, no audio.
@MainActor
final class ShelfFeedTests: XCTestCase {

    private let started = PlaybackTestRig.makeDocument(hash: "shelf-a", sentences: 10,
                                                       progressSentence: 3, progressFraction: 0.3)
    private let other = PlaybackTestRig.makeDocument(hash: "shelf-b", sentences: 10)

    // MARK: - Feed (P020)

    func testAShownLibraryRebuildsOnEveryPublish() {
        var feed = ShelfFeed()
        XCTAssertTrue(feed.publish([started, other], loadedID: nil, libraryShows: true))
        XCTAssertTrue(feed.publish([started, other], loadedID: started.id, libraryShows: true))
        XCTAssertEqual(feed.builds, 2)
        XCTAssertFalse(feed.isStale)
    }

    /// The reader saves progress every sentence: twenty saves under it
    /// build nothing, and write the feed once.
    func testACoveredLibraryOnlyMarksItselfStaleOnce() {
        var feed = ShelfFeed()
        XCTAssertTrue(feed.publish([started, other], loadedID: nil, libraryShows: true))
        XCTAssertTrue(feed.publish([started, other], loadedID: started.id, libraryShows: false), "marked stale")
        for _ in 0..<20 {
            XCTAssertFalse(feed.publish([started, other], loadedID: started.id, libraryShows: false),
                           "a save under the reader writes no state")
        }
        XCTAssertEqual(feed.builds, 1, "nothing rebuilt while covered")
        XCTAssertTrue(feed.isStale)
    }

    func testShowingAgainRebuildsAStaleShelfOnce() {
        var feed = ShelfFeed()
        _ = feed.publish([started], loadedID: nil, libraryShows: true)
        _ = feed.publish([started, other], loadedID: started.id, libraryShows: false)
        XCTAssertTrue(feed.libraryShown([started, other], loadedID: started.id))
        XCTAssertEqual(feed.builds, 2)
        XCTAssertFalse(feed.isStale)
        XCTAssertFalse(feed.libraryShown([started, other], loadedID: started.id), "a current shelf is left alone")
        XCTAssertEqual(feed.builds, 2)
        XCTAssertEqual(feed.layout.hero?.id, started.id, "the loaded book is the hero")
    }

    /// Back from the reader, the Continue card shows the place the reader
    /// saved meanwhile, not the one the shelf had when it was covered.
    func testShowingAgainShowsTheProgressSavedMeanwhile() {
        var feed = ShelfFeed()
        _ = feed.publish([started, other], loadedID: started.id, libraryShows: true)
        var moved = started
        moved.progressSentence = 7
        for _ in 0..<5 { _ = feed.publish([moved, other], loadedID: started.id, libraryShows: false) }
        XCTAssertEqual(feed.layout.hero?.progressSentence, 3, "covered: the old shelf stands")
        XCTAssertTrue(feed.libraryShown([moved, other], loadedID: started.id))
        XCTAssertEqual(feed.layout.hero?.progressSentence, 7)
    }

    /// After a relaunch nothing is loaded, and a book a sleep timer stopped
    /// in its last minute reads Finished: the controller's stop keeps it the
    /// hero, as the launch restore and remote Play have it (F045).
    func testABookStoppedInItsLastMinuteStaysTheHero() {
        var older = started
        older.lastOpenedAt = Date().addingTimeInterval(-600)
        var stopped = PlaybackTestRig.makeDocument(hash: "shelf-stop", sentences: 100,
                                                   progressSentence: 99, progressFraction: 0.995)
        stopped.lastOpenedAt = Date().addingTimeInterval(-60)
        XCTAssertTrue(stopped.isFinished, "the record reads Finished")
        let stop = PlaybackStop(reason: .sleepTimer, documentID: stopped.id)

        var feed = ShelfFeed()
        _ = feed.publish([older, stopped], loadedID: nil, libraryShows: true)
        XCTAssertEqual(feed.layout.hero?.id, older.id, "without the stop it reads Finished")
        _ = feed.publish([older, stopped], loadedID: nil, stop: stop, libraryShows: true)
        XCTAssertEqual(feed.layout.hero?.id, stopped.id, "the stop holds it at its sentence")

        _ = feed.publish([older, stopped], loadedID: nil, stop: stop, libraryShows: false)
        XCTAssertTrue(feed.libraryShown([older, stopped], loadedID: nil, stop: stop))
        XCTAssertEqual(feed.layout.hero?.id, stopped.id, "a shelf rebuilt on showing again keeps it")
    }

    // MARK: - Focus after a removal (P022, H013)

    /// Delete on a card hands focus to a neighbour: the next card, else the
    /// one before, else the Continue card; from the Continue card, the
    /// grid's first. The Mac's keyboard focus and the iPhone's VoiceOver
    /// focus read the same rule.
    func testARemovedCardHandsFocusToANeighbour() {
        let hero = UUID()
        let grid = (0..<4).map { _ in UUID() }
        func next(_ removed: UUID, hero: UUID? = hero, grid: [UUID] = grid) -> UUID? {
            ShelfLayout.focusAfterRemoving(removed, hero: hero, grid: grid)
        }
        XCTAssertEqual(next(grid[1]), grid[2], "the next card")
        XCTAssertEqual(next(grid[0]), grid[1])
        XCTAssertEqual(next(grid[3]), grid[2], "the last card: the one before")
        XCTAssertEqual(next(grid[0], grid: [grid[0]]), hero, "the only card: the Continue card")
        XCTAssertNil(next(grid[0], hero: nil, grid: [grid[0]]), "nothing left")
        XCTAssertEqual(next(hero), grid[0], "the Continue card: the grid's first")
        XCTAssertNil(next(hero, grid: []), "the Continue card alone")
        XCTAssertNil(next(UUID()), "a card not on the shelf")
    }

    func testFocusIsReadOffABuiltShelf() {
        var older = other
        older.lastOpenedAt = Date().addingTimeInterval(-600)
        let third = PlaybackTestRig.makeDocument(hash: "shelf-c", sentences: 10)
        let layout = ShelfLayout(for: [started, older, third], loadedID: started.id)
        XCTAssertEqual(layout.hero?.id, started.id)
        let grid = layout.grid.map(\.id)
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(ShelfLayout.focusAfterRemoving(grid[0], in: layout), grid[1], "the middle card's neighbour")
        XCTAssertEqual(ShelfLayout.focusAfterRemoving(started.id, in: layout), grid[0])
    }

    // MARK: - Phone shelf rhythm (P018)

    /// Two columns on every phone, covers 150-175 wide on the 375 and 393
    /// pt phones (the column gap opens above 375), and one column at the
    /// accessibility sizes. A 440 pt phone keeps two wider covers.
    func testThePhoneShelfKeepsTwoComfortableColumns() {
        for width: CGFloat in [375, 393, 440] {
            let metrics = PhoneShelfMetrics(width: width, isAccessibilitySize: false)
            XCTAssertEqual(metrics.columns, 2, "\(width) pt")
            XCTAssertEqual(metrics.columnSpacing, width > 375 ? Theme.Space.lg : Theme.Space.md, "\(width) pt")
            let cover = metrics.columnWidth(forWidth: width)
            if width <= 393 {
                XCTAssertTrue((150...175).contains(cover), "\(width) pt: a \(cover) pt cover")
            } else {
                XCTAssertTrue((150...195).contains(cover), "\(width) pt: a \(cover) pt cover")
            }
        }
        XCTAssertEqual(PhoneShelfMetrics(width: 375, isAccessibilitySize: true).columns, 1, "AX sizes")
        XCTAssertEqual(PhoneShelfMetrics(width: 440, isAccessibilitySize: true).columns, 1, "AX sizes")
    }

    /// A caption never runs into the covers below it: rows, and the gap
    /// under the Continue card, are the Mac's 32.
    func testRowsStandApartAsOnTheMac() {
        XCTAssertEqual(PhoneShelfMetrics.rowSpacing, 32)
        XCTAssertGreaterThanOrEqual(PhoneShelfMetrics.rowSpacing, 32)
        XCTAssertEqual(PhoneShelfMetrics.heroToGrid, Theme.Space.xxl)
        XCTAssertEqual(PhoneShelfMetrics.topPadding, Theme.Space.lg)
        XCTAssertEqual(PhoneShelfMetrics.gutter, Theme.Space.screenGutter, "the screen gutter is kept")
    }

    // MARK: - Edge rule (P021)

    func testTheRuleShowsOnlyOnceContentIsUnderTheBar() {
        XCTAssertFalse(ShelfEdgeRule.shows(contentOffsetY: -100, topInset: 100), "at rest")
        XCTAssertFalse(ShelfEdgeRule.shows(contentOffsetY: -140, topInset: 100), "pulled down")
        XCTAssertFalse(ShelfEdgeRule.shows(contentOffsetY: -99.7, topInset: 100), "a settle's fraction")
        XCTAssertTrue(ShelfEdgeRule.shows(contentOffsetY: -60, topInset: 100), "scrolled 40 pt")
        XCTAssertTrue(ShelfEdgeRule.shows(contentOffsetY: 1, topInset: 0))
    }

    // MARK: - Import overlay reveal (P015)

    /// A fake clock: `sleep` advances it, and the add is busy until `busyFor`.
    private final class FakeClock {
        var now: Duration = .zero
        var slept: [Duration] = []
    }

    private func reveals(busyFor busy: Duration) async -> (Bool, FakeClock) {
        let clock = FakeClock()
        let revealed = await ImportOverlayReveal.revealsAfterDelay(isBusy: { clock.now < busy }) { duration in
            clock.slept.append(duration)
            clock.now += duration
        }
        return (revealed, clock)
    }

    func testAQuickAddNeverRevealsTheOverlay() async {
        let (revealed, clock) = await reveals(busyFor: .milliseconds(500))
        XCTAssertFalse(revealed, "a 0.5 s add shows nothing")
        XCTAssertEqual(clock.slept, [.milliseconds(800)])
    }

    func testASlowAddRevealsItAfterTheDelay() async {
        let (revealed, clock) = await reveals(busyFor: .milliseconds(1200))
        XCTAssertTrue(revealed, "a 1.2 s add shows it")
        XCTAssertEqual(clock.now, .milliseconds(800), "at 0.8 s")
    }

    func testIdleRevealsNothingAndWaitsForNothing() async {
        let (revealed, clock) = await reveals(busyFor: .zero)
        XCTAssertFalse(revealed)
        XCTAssertEqual(clock.slept, [], "hidden at once")
    }

    func testACancelledWaitRevealsNothing() async {
        let revealed = await ImportOverlayReveal.revealsAfterDelay(isBusy: { true }) { _ in
            throw CancellationError()
        }
        XCTAssertFalse(revealed)
    }

    func testBothAppsWaitTheSameDelay() {
        XCTAssertEqual(ImportOverlayReveal.delay, .milliseconds(800))
    }

    // MARK: - Several files from the picker (P016)

    @MainActor
    private final class FakeLibrary: LibraryAdding {
        var documents: [LibraryDocument] = []
        var byFileName: [String: LibraryDocument] = [:]
        private(set) var imported: [String] = []

        func importPDF(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            try add(url)
        }

        func importText(title: String, author: String?, from url: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> LibraryDocument {
            try add(url)
        }

        func addClassic(_ book: BookshelfBook) async throws -> LibraryDocument {
            throw CocoaError(.fileNoSuchFile)
        }

        private func add(_ url: URL) throws -> LibraryDocument {
            imported.append(url.lastPathComponent)
            guard let document = byFileName[url.lastPathComponent] else { throw ExtractionError.noReadableText }
            documents.append(document)
            return document
        }
    }

    private static func document(_ title: String) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "x.txt", addedAt: Date(),
                        pageCount: 1, sentenceCount: 1, contentHash: "h-\(title)", kind: .text)
    }

    private func picked(_ names: [String]) -> [URL] {
        names.map { FileManager.default.temporaryDirectory.appendingPathComponent($0) }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testPickingThreeAddsThemAllOpensNoneAndSaysOneCount() async {
        let library = FakeLibrary()
        library.byFileName = ["a.txt": Self.document("A"), "b.pdf": Self.document("B"), "c.txt": Self.document("C")]
        var said: [String] = []
        var opened: [LibraryDocument] = []
        let importer = DocumentImporter(library: library) { said.append($0) }
        importer.onAdded = { opened.append($0) }

        importer.handlePicks(.success(picked(["a.txt", "b.pdf", "c.txt"])))
        let done = await waitUntil { !said.isEmpty }
        XCTAssertTrue(done)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(library.imported, ["a.txt", "b.pdf", "c.txt"])
        XCTAssertEqual(said, ["Added 3 books"], "one count, once")
        XCTAssertTrue(opened.isEmpty, "the reader does not open")
    }

    func testPickingOneOpensIt() async {
        let library = FakeLibrary()
        let book = Self.document("One")
        library.byFileName = ["one.txt": book]
        var opened: [LibraryDocument] = []
        let importer = DocumentImporter(library: library) { _ in }
        importer.onAdded = { opened.append($0) }

        importer.handlePicks(.success(picked(["one.txt"])))
        let done = await waitUntil { !opened.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(opened.map(\.id), [book.id], "one pick opens, playing by the open rule (R4)")
    }

    /// A broken file among three is named in the alert, and the other two
    /// are still added.
    func testABrokenFileInAPickIsNamedAndTheRestAreAdded() async {
        let library = FakeLibrary()
        library.byFileName = ["a.txt": Self.document("A"), "c.txt": Self.document("C")]
        var said: [String] = []
        let importer = DocumentImporter(library: library) { said.append($0) }

        importer.handlePicks(.success(picked(["a.txt", "broken.pdf", "c.txt"])))
        let failed = await waitUntil { importer.failure != nil }
        XCTAssertTrue(failed)
        let title = try? XCTUnwrap(importer.failureTitle)
        XCTAssertEqual(title, importer.failure?.title(naming: "broken.pdf"))
        XCTAssertTrue(title?.contains("broken.pdf") ?? false, title ?? "no title")
        importer.dismissFailure()
        let done = await waitUntil { !said.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(library.imported, ["a.txt", "broken.pdf", "c.txt"])
        XCTAssertEqual(said, ["Added 2 books"])
    }

    func testBackingOutOfThePickerIsSilent() {
        let library = FakeLibrary()
        let importer = DocumentImporter(library: library) { _ in }
        importer.handlePicks(.failure(CocoaError(.userCancelled)))
        XCTAssertEqual(importer.phase, .idle)
        importer.handlePicks(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertEqual(importer.phase, .failed(.couldNotOpen))
    }

    // MARK: - Pressed plate (P019)

    /// Pressed, a surface2 plate reaches `outset` past the card; at rest
    /// nothing is drawn round it. Rendered at 2x, so pixel (24, 72) is 12 pt
    /// in from the edge: on the plate, 4 pt past the 40 pt label.
    func testThePressedPlateDrawsOnlyWhilePressed() throws {
        func render(pressed: Bool) throws -> RenderedPixels {
            let view = ShelfPlateButtonStyle.Plated(isPressed: pressed) {
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(16)
            return try XCTUnwrap(RenderedPixels(view, size: CGSize(width: 72, height: 72)))
        }
        let pressed = try render(pressed: true)
        let resting = try render(pressed: false)
        XCTAssertGreaterThan(pressed.rgba(x: 24, y: 72).a, 200, "the plate, 4 pt past the card")
        XCTAssertEqual(resting.rgba(x: 24, y: 72).a, 0, "no plate at rest")
        XCTAssertEqual(pressed.rgba(x: 4, y: 72).a, 0, "the plate stops at its outset")
    }

    func testThePressScalesOnlyWithMotion() {
        XCTAssertTrue(ShelfPlateButtonStyle.drawsPlate(isPressed: true))
        XCTAssertFalse(ShelfPlateButtonStyle.drawsPlate(isPressed: false))
        XCTAssertEqual(ShelfPlateButtonStyle.scale(isPressed: true, reduceMotion: false), 0.98)
        XCTAssertEqual(ShelfPlateButtonStyle.scale(isPressed: true, reduceMotion: true), 1, "Reduce Motion: the plate alone")
        XCTAssertEqual(ShelfPlateButtonStyle.scale(isPressed: false, reduceMotion: false), 1)
    }

    /// The plate never dims the card: no opacity anywhere in the style.
    func testThePlateNeverDimsTheCard() throws {
        let path = "Theme/PressStyles.swift"
        let s = try SourceTree.sources(only: [path])
        let code = SwiftLiterals.code(in: try XCTUnwrap(s[path]))
        XCTAssertFalse(code.contains(".opacity("), "a press shows a plate, never a fade")
        XCTAssertTrue(code.contains(".fill(Theme.surface2)"))
        XCTAssertTrue(code.contains(".padding(-outset)"), "the plate takes no layout")
    }

    // MARK: - Long-press menu (P023)

    func testDeleteSitsInASectionOfItsOwn() {
        let reading = PlaybackTestRig.makeDocument(hash: "menu-a", sentences: 10, progressSentence: 2,
                                                   progressFraction: 0.2)
        XCTAssertEqual(DocumentAction.menuSections(for: reading), [[.rename, .markFinished], [.delete]])
        let finished = PlaybackTestRig.makeDocument(hash: "menu-b", sentences: 10, progressSentence: 9,
                                                    progressFraction: 1)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(DocumentAction.menuSections(for: finished), [[.rename], [.delete]])
        for document in [reading, finished] {
            XCTAssertEqual(DocumentAction.menuSections(for: document).flatMap { $0 },
                           DocumentAction.available(for: document),
                           "the menu and VoiceOver's actions are one list")
        }
    }

    // MARK: - Paste (P017)

    /// The iPhone's + menu: the two items both apps share, then the
    /// clipboard's text. The Mac's menu keeps the two (it pastes with ⌘V).
    func testTheIPhoneAddMenuEndsWithPasteText() {
        XCTAssertEqual(LibraryAddMenuItem.allCases.map(\.title) + [PasteTextAction.menuTitle],
                       ["Classics", "From Files\u{2026}", "Paste Text"])
        XCTAssertEqual(LibraryAddMenuItem.allCases.count, 2, "the Mac's + menu")
        XCTAssertEqual(PasteTextAction.systemImage, "doc.on.clipboard")
        XCTAssertEqual(PasteTextAction.linkTitle, "Paste text")
    }
}
