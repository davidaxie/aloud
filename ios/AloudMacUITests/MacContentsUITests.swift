import XCTest

/// M16's Contents in the real window: ⌘F opens it with "Search this book"
/// focused, and the typing and Return jump to the match; a chapter click
/// plays from that chapter, and ⌘Z restores the sentence and the pause;
/// The Cask of Amontillado, a book without a chapter list, shows search
/// only; and the panel docks beside the page from a 780 pt window, staying
/// after a jump, and floats over it below, closing after one and handing
/// the page the keys. Typing goes only into the search field
/// (`MacSuite.typeIntoFocusedField`).
///
/// Muted throughout, autoplay off; a Contents jump plays on the Mac (M16),
/// muted like every other sound here. Runs only in the consented
/// `AloudMacUI` scheme.
final class MacContentsUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// One match, in chapter II: a jump forward from the cue mid-chapter I
    /// of more than 3 sentences, so it offers Undo jump.
    private static let phrase = "earliest of those who waited"

    /// Launches into the reader, paused, with `arguments`.
    private func openReader(_ arguments: [String]) -> MacSuite {
        let app = XCUIApplication.aloud(arguments)
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 20), "the reader should open")
        XCTAssertTrue(suite.pageText.waitForExistence(timeout: 10), "the page should show")
        return suite
    }

    /// Shows Contents with ⌃⌘S, from the menus' key.
    private func showContents(_ suite: MacSuite) {
        if !suite.isContentsShown { press(.contents, in: suite.app) }
        XCTAssertTrue(suite.contentsPanel.waitForExistence(timeout: 5), "⌃⌘S shows Contents")
    }

    /// The chapter rows, top to bottom.
    private func chapterRows(_ suite: MacSuite) -> [XCUIElement] {
        suite.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chapters.row.'"))
            .allElementsBoundByIndex.filter(\.exists).sorted { $0.frame.minY < $1.frame.minY }
    }

    /// A row two past the current chapter's (`.isSelected`), else the
    /// third: a chapter other than the playhead's, on screen.
    private func rowToPick(_ suite: MacSuite) -> XCUIElement? {
        let rows = chapterRows(suite).filter(\.isHittable)
        guard !rows.isEmpty else { return nil }
        let current = rows.firstIndex(where: \.isSelected) ?? 0
        return rows[min(current + 2, rows.count - 1)]
    }

    func testFindTypingAndReturnJumpToTheMatch() throws {
        let suite = openReader(MacSuite.chapterReader)
        let start = try XCTUnwrap(suite.playhead, "the playhead probe should exist")

        press(.find, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.isContentsShown && suite.focus == "text.editable" },
                      "⌘F opens Contents with Search this book focused, focus is \(suite.focus)")
        XCTAssertTrue(suite.typeIntoFocusedField(Self.phrase), "the field takes the typing")
        let count = suite.element("search.count")
        // A Text's words: its label, or on some systems its value.
        XCTAssertTrue(suite.poll(timeout: 10) { count.exists && [count.label, suite.text(count)].contains("1 match") },
                      "the search finds the one match, got '\(count.exists ? count.label : "nothing")'")
        let result = suite.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
        XCTAssertTrue(result.exists, "its result row shows")
        let match = try XCTUnwrap(Int(result.identifier.dropFirst("search.result.".count)), result.identifier)

        // Return in the field: the top result, as Spotlight does.
        press(.returnKey, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.playhead == match },
                      "Return jumps to sentence \(match), the playhead reads \(suite.playhead ?? -1)")
        XCTAssertGreaterThan(match, start, "the match is past the cue")
        XCTAssertTrue(suite.element("reader.undoJump").waitForExistence(timeout: 5), "the jump offers Undo jump")
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 30),
                      "a Contents jump plays from there, got '\(suite.playValue ?? "nil")'")
        // 1280 pt wide: docked, so the panel stays for the next step.
        XCTAssertTrue(suite.isContentsShown, "a docked panel stays after a jump")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testAChapterClickPlaysAndCommandZRestores() throws {
        let suite = openReader(MacSuite.chapterReader)
        let start = try XCTUnwrap(suite.playhead, "the playhead probe should exist")
        XCTAssertEqual(suite.playValue, "paused", "no autoplay in this launch")
        showContents(suite)
        XCTAssertTrue(suite.poll(timeout: 5) { !chapterRows(suite).isEmpty }, "Contents lists the chapters")
        let row = try XCTUnwrap(rowToPick(suite), "a chapter row should be on screen")
        let picked = row.identifier

        row.click()
        let landed = suite.poll(timeout: 5) { (suite.playhead ?? start) != start }
        XCTAssertTrue(landed, "a click on \(picked) moves the playhead off \(start)")
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 5),
                      "a chapter click plays from there, got '\(suite.playValue ?? "nil")'")
        XCTAssertTrue(suite.element("reader.undoJump").waitForExistence(timeout: 5), "the jump offers Undo jump")

        // Within the chip's 10 s.
        press(.undoJump, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.playhead == start },
                      "⌘Z returns to sentence \(start), the playhead reads \(suite.playhead ?? -1)")
        XCTAssertTrue(suite.waitForPlay(["paused"], timeout: 10),
                      "⌘Z restores the pause, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testTheCaskOfAmontilladoShowsSearchOnly() {
        // Gutenberg 1063: a short story, no chapter list.
        let suite = openReader(MacSuite.fresh + ["-uitest-seed-classic", "1063", "-uitest-open-first-doc"])
        showContents(suite)
        XCTAssertTrue(suite.app.searchFields["search.field"].firstMatch.waitForExistence(timeout: 5),
                      "Search this book is there")
        // A wait that must stay uneventful: no row or section ever shows.
        let listed = suite.poll(timeout: 2) {
            !chapterRows(suite).isEmpty
                || suite.app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'contents.section.'")).count > 0
        }
        XCTAssertFalse(listed, "a book without chapters shows search only")

        press(.find, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.focus == "text.editable" },
                      "⌘F focuses Search this book, focus is \(suite.focus)")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - Docked or floating (mac-ux §3.6)

    func testFrom780WideContentsDocksBesideThePage() throws {
        let suite = openReader(MacSuite.chapterReader + ["-uitest-window-size", "780x700"])
        XCTAssertEqual(suite.mainWindow.frame.width, 780, accuracy: 2, "the window should open 780 pt wide")
        showContents(suite)
        let panel = suite.contentsPanel.frame
        let page = try XCTUnwrap(suite.pageViewport, "the page should show")
        XCTAssertGreaterThanOrEqual(page.minX, panel.maxX - 1, "the page starts where the panel ends: \(panel), \(page)")

        // A docked panel stays after a jump, its list keeping the keys.
        let row = try XCTUnwrap(rowToPick(suite), "a chapter row should be on screen")
        let start = try XCTUnwrap(suite.playhead)
        row.click()
        XCTAssertTrue(suite.poll(timeout: 5) { suite.playhead != start }, "the click jumps")
        let closed = suite.poll(timeout: 2) { !suite.isContentsShown }
        XCTAssertFalse(closed, "docked, Contents stays after a jump")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testBelow780WideContentsFloatsOverThePage() throws {
        let suite = openReader(MacSuite.chapterReader + ["-uitest-window-size", "760x700"])
        XCTAssertEqual(suite.mainWindow.frame.width, 760, accuracy: 2, "the window should open 760 pt wide")
        showContents(suite)
        let panel = suite.contentsPanel.frame
        let page = try XCTUnwrap(suite.pageViewport, "the page should show")
        // The card's margin is inside its frame: the page starts with it.
        XCTAssertTrue(page.minX < panel.minX + 1 && page.maxX > panel.maxX,
                      "the card floats over the page, which keeps the window's width: \(panel), \(page)")

        // A card closes after a jump, uncovering the page it moved, and the
        // page takes the keys.
        let row = try XCTUnwrap(rowToPick(suite), "a chapter row should be on screen")
        let start = try XCTUnwrap(suite.playhead)
        row.click()
        XCTAssertTrue(suite.poll(timeout: 5) { suite.playhead != start }, "the click jumps")
        XCTAssertTrue(suite.poll(timeout: 5) { !suite.isContentsShown }, "floating, Contents closes after a jump")
        XCTAssertTrue(suite.poll(timeout: 5) { suite.focus == "text.selectable" },
                      "the page has the keys, focus is \(suite.focus)")
        XCTAssertEqual(suite.beeps, 0)
    }
}
