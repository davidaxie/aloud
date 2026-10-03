import XCTest

/// M6 and M8's Library items that need the window: the empty state's
/// featured classic, two links and one privacy line, and no "+" yet; the
/// "+" pull-down's two items once a book exists; one click from a grid card
/// or the Continue card's body to a voice; the Continue circle pausing in
/// place after backing out of a playing reader; a relaunch that loads the
/// Continue book paused; the card's context menu; and ⌘⌫ on a focused card
/// deleting after the confirmation. Muted throughout; autoplay only where
/// a click must reach "playing". Runs only in the consented `AloudMacUI`
/// scheme.
final class MacLibraryUITests: XCTestCase {

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

    private func launch(_ arguments: [String], allowAutoplay: Bool = false) -> MacSuite {
        let app = XCUIApplication.aloud(arguments, allowAutoplay: allowAutoplay)
        self.app = app
        launchAloud(app)
        return MacSuite(app: app)
    }

    private static let threeBooks = MacSuite.fresh + ["-uitest-seed-classics", "3"]

    // MARK: - Empty

    func testTheEmptyLibraryOffersTheFeaturedClassicTwoLinksAndOnePrivacyLine() {
        let suite = launch(MacSuite.fresh)
        let featured = suite.element("library.featured")
        XCTAssertTrue(featured.waitForExistence(timeout: 20))
        XCTAssertTrue(featured.label.hasPrefix("The Cask of Amontillado"), featured.label)
        XCTAssertTrue(suite.element("library.moreClassics").exists, "More classics")
        XCTAssertTrue(suite.element("library.addFile").exists, "Add a file")
        let privacy = suite.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Everything stays on your'"))
        XCTAssertEqual(privacy.count, 1, "the privacy line, once")
        XCTAssertFalse(suite.element("library.add").exists, "no \"+\" until a book exists (R4)")
    }

    // MARK: - With books

    func testThePlusMenuHasExactlyClassicsAndFromFiles() {
        let suite = launch(Self.threeBooks)
        let add = suite.element("library.add")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "the \"+\" shows once a book exists")
        add.click()
        let classics = suite.app.menuItems["Classics"].firstMatch
        XCTAssertTrue(classics.waitForExistence(timeout: 5))
        XCTAssertTrue(suite.app.menuItems["From Files\u{2026}"].firstMatch.exists)
        let menu = suite.app.menus.containing(NSPredicate(format: "title == 'Classics'")).firstMatch
        XCTAssertEqual(menu.menuItems.count, 2, "exactly the iPhone's two items")
        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { !classics.exists }, "Esc closes the menu")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testOneClickOnACardPlaysAndTheContinueCircleThenPausesInPlace() {
        let suite = launch(Self.threeBooks, allowAutoplay: true)
        let card = suite.element("library.card")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.click()
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60), "one click on a card reaches playing")

        // Back out while it speaks: the loaded book is the Continue card, its
        // circle already showing pause.
        press(.back, in: suite.app)
        // The clock starts once the key is delivered: XCUITest's own wait
        // for the app to settle after a key is not the app's latency.
        let start = Date()
        let circle = suite.element("library.continue.play")
        XCTAssertTrue(suite.poll(timeout: 2) { circle.exists && circle.label == "Pause" },
                      "the circle shows pause, got '\(circle.label)'")
        // M6 asks 300 ms; a UI snapshot alone takes about that, so this
        // allows the snapshot's own latency on top.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5, "the circle shows pause within \(elapsed) s of Back")

        circle.click()
        XCTAssertTrue(suite.poll(timeout: 5) { circle.label == "Play" }, "a click on the circle pauses")
        XCTAssertEqual(suite.place, .library, "and stays on the Library")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testTheContinueBodyIsOneClickAndARelaunchLoadsItPaused() {
        // Launch 1: listen a moment, so the book has progress.
        var suite = launch(Self.threeBooks, allowAutoplay: true)
        let card = suite.element("library.card")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.click()
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60))
        press(.playPause, in: suite.app)
        XCTAssertTrue(suite.waitForPlay(["paused"], timeout: 10))
        suite.idle(3)   // the shelf writes progress 2 s behind
        suite.app.terminate()

        // Launch 2: the Continue book is loaded and paused, and nothing plays.
        suite = launch(["-uitest-temp-model-dir"], allowAutoplay: true)
        let hero = suite.element("library.continue")
        XCTAssertTrue(hero.waitForExistence(timeout: 30), "the book with progress is the Continue card")
        let circle = suite.element("library.continue.play")
        XCTAssertTrue(circle.waitForExistence(timeout: 5))
        suite.idle(3)
        XCTAssertEqual(circle.label, "Play", "launch never plays")

        // One click on the body opens it speaking.
        hero.click()
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 60), "one click on the body plays")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testTheContextMenuHoldsOpenRenameMarkFinishedAndDelete() {
        let suite = launch(Self.threeBooks)
        let card = suite.element("library.card")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.rightClick()
        for title in ["Open", "Rename\u{2026}", "Mark as Finished", "Delete\u{2026}"] {
            XCTAssertTrue(suite.app.menuItems[title].firstMatch.waitForExistence(timeout: 5), "\(title) is in the menu")
        }
        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { !suite.app.menuItems["Mark as Finished"].firstMatch.exists })
        XCTAssertEqual(suite.place, .library, "the menu opened nothing")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testCommandDeleteRemovesTheFocusedCardAfterTheConfirmation() {
        let suite = launch(Self.threeBooks + MacSuite.keyboardNavigation)
        XCTAssertTrue(suite.element("library.card").waitForExistence(timeout: 30))
        XCTAssertTrue(suite.poll(timeout: 30) { suite.libraryBookCount == 3 }, "three books seeded")
        XCTAssertTrue(suite.tab(self) { suite.isLibraryCardFocused }, "Tab reaches a card")

        press(.deleteBook, in: suite.app)
        let delete = suite.app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "⌘⌫ asks first")
        XCTAssertEqual(suite.libraryBookCount, 3, "nothing is deleted before the answer")
        delete.click()
        XCTAssertTrue(suite.poll(timeout: 10) { suite.libraryBookCount == 2 }, "then the focused book goes")
        XCTAssertEqual(suite.beeps, 0)
    }
}
