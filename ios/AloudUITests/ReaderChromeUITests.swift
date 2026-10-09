import XCTest

/// Round 4 chrome, end to end:
/// - R4-06: at the end of a book, scrolling away from the colophon swaps
///   More classics for the way back to it, whose tap lands the colophon and
///   turns the chip back;
/// - R4-07: the gear, + and Aa let the bar size their platters and keep a
///   44 pt target;
/// - R4-08: Aa toggles its sheet, reads as selected while it is up, and the
///   sheet leaves with the reader.
///
/// No test taps Play: autoplay is suppressed (no -uitest-allow-autoplay)
/// and every launch goes through XCUIApplication.aloud, so the app is muted
/// and each reader rests paused. Run on an iOS 26 simulator for the platter
/// widths, and on iOS 17 or 18 for the framed targets.
final class ReaderChromeUITests: XCTestCase {

    private static let reset = "-uitest-reset-library"
    /// Listening banked by earlier runs could put the natural-voice offer
    /// where the chapter line and the chip expect the page.
    private static let freshOffer = "-uitest-reset-natural-voice-offer"
    private static let systemVoice = "-uitest-temp-model-dir"
    /// The widest a bar item's platter may read on iOS 26: the system back
    /// button's 44 pt circle, with room for Aa's two letters. A label framed
    /// to 44 pt read 56 (the gear) and 68 (Aa).
    private static let platterMaximum: CGFloat = 52
    /// The row the iOS 26 bar reports for an item's label inside its platter.
    private static let platterRow: CGFloat = 36

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers (this file only)

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication.aloud([Self.reset, Self.freshOffer] + arguments)
        app.launch()
        return app
    }

    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["reader.text"].firstMatch
    }

    private func appearanceButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["reader.appearance"].firstMatch
    }

    private func appearanceTitle(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["appearance.title"].firstMatch
    }

    /// Opens the first grid card and waits for the page.
    private func openTheCard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the seeded book is on the shelf", file: file, line: line)
        card.tap()
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "the reader opens", file: file, line: line)
    }

    /// The seeded classic, open and paused at its first page.
    private func openSeededReader() -> XCUIApplication {
        let app = launch(["-uitest-seed-first-classic", "-uitest-open-first-doc"])
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "The reader should open")
        return app
    }

    /// On iOS 26 the bar's glass platter is the item's frame: no wider than
    /// the back circle's, give or take Aa's letters.
    /// A bar item's target. From iOS 26 the target is the glass platter the
    /// bar draws, 44 pt as the back button's circle, but the UI test tree
    /// reports only the label's 36 pt row inside it, whatever the label's
    /// own frame (a 44 pt frame read 36 too, on a 56 to 68 pt pill), so the
    /// platter can't be measured here: the label must fill that row, and
    /// `assertSystemSizedPlatter` keeps it from growing into a pill. Before
    /// iOS 26 the label's own frame is the target.
    private func assertBarItemTarget(_ element: XCUIElement, _ name: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard #available(iOS 26, *) else {
            assertTouchTarget(element, name, file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(element.frame.height, Self.platterRow - 0.01,
                                    "\(name) is \(element.frame.height) pt tall in its platter", file: file, line: line)
    }

    private func assertSystemSizedPlatter(_ element: XCUIElement, _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard #available(iOS 26, *) else { return }
        XCTAssertLessThanOrEqual(element.frame.width, Self.platterMaximum,
                                 "\(name) is \(element.frame.width) pt wide: the bar should size its platter",
                                 file: file, line: line)
    }

    // MARK: - R4-06 The way back to the colophon

    func testScrollingAwayFromTheEndOffersTheWayBack() {
        let app = launch(["-uitest-seed-finished", Self.systemVoice])
        openTheCard(app)

        let more = app.buttons["reader.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "a Finished book reopens at the colophon with More classics")

        // Back toward the start: the colophon leaves the page below.
        readerText(app).swipeDown(velocity: .fast)
        readerText(app).swipeDown(velocity: .fast)
        let back = app.buttons["reader.theEnd.down"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "scrolled away from the colophon, the chip leads back to it")
        XCTAssertTrue(waitForNonExistence(of: more, timeout: 3), "the slot shows one chip")
        XCTAssertFalse(app.buttons["reader.followVoice.down"].exists, "not Follow: the voice has finished")
        assertTouchTarget(back, "reader.theEnd.down")

        back.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10), "landing the colophon turns the chip back into More classics")
        XCTAssertTrue(waitForNonExistence(of: back, timeout: 5))
        // While a colophon shows, the follow probe frames it.
        let window = app.windows.firstMatch.frame
        guard let colophon = activeSentenceFrame(app) else {
            XCTFail("the follow probe frames the colophon")
            return
        }
        XCTAssertTrue(window.intersects(colophon), "the colophon \(colophon) is on screen (\(window))")
        XCTAssertLessThanOrEqual(colophon.minY, more.frame.minY, "the colophon shows above the chip")
    }

    // MARK: - R4-07 Bar items

    func testTheLibrarysBarItemsKeepATargetInASystemSizedPlatter() {
        let app = launch(["-uitest-seed-first-classic"])
        let settings = app.buttons["library.settings"].firstMatch
        let add = app.buttons["library.add"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertTrue(add.waitForExistence(timeout: 5), "+ shows once the shelf holds a book")
        assertBarItemTarget(settings, "library.settings")
        assertBarItemTarget(add, "library.add")
        assertSystemSizedPlatter(settings, "library.settings")
        assertSystemSizedPlatter(add, "library.add")
    }

    func testAaKeepsATargetInASystemSizedPlatter() {
        let app = openSeededReader()
        let aa = appearanceButton(app)
        XCTAssertTrue(aa.waitForExistence(timeout: 10))
        assertBarItemTarget(aa, "reader.appearance")
        assertSystemSizedPlatter(aa, "reader.appearance")
    }

    // MARK: - R4-08 Aa toggles

    func testASecondTapOnAaClosesItsSheet() {
        let app = openSeededReader()
        let aa = appearanceButton(app)
        XCTAssertTrue(aa.waitForExistence(timeout: 10))

        aa.tap()
        XCTAssertTrue(appearanceTitle(app).waitForExistence(timeout: 5), "Aa opens its sheet")
        aa.tap()
        XCTAssertTrue(waitForNonExistence(of: appearanceTitle(app), timeout: 5), "a second tap on Aa closes its sheet")
        XCTAssertTrue(readerText(app).exists, "the reader stays")
    }

    /// VoiceOver hears what a second activation will do. Kept apart from
    /// the toggle: a bar item is hosted by the system, so this checks that
    /// the trait reaches it.
    func testAaReadsAsSelectedWhileItsSheetIsUp() {
        let app = openSeededReader()
        let aa = appearanceButton(app)
        XCTAssertTrue(aa.waitForExistence(timeout: 10))
        XCTAssertFalse(aa.isSelected, "not selected while its sheet is down")
        aa.tap()
        XCTAssertTrue(appearanceTitle(app).waitForExistence(timeout: 5), "Aa opens its sheet")
        XCTAssertTrue(aa.isSelected, "selected while its sheet is up")
    }

    func testBackTakesTheAppearanceSheetAlong() {
        let app = openSeededReader()
        let aa = appearanceButton(app)
        XCTAssertTrue(aa.waitForExistence(timeout: 10))
        aa.tap()
        XCTAssertTrue(appearanceTitle(app).waitForExistence(timeout: 5), "Aa opens its sheet")

        // The sheet leaves the bar live, so the system Back takes the tap.
        tapSystemBack(app)
        XCTAssertTrue(app.buttons["library.settings"].firstMatch.waitForExistence(timeout: 10), "Back is the Library")
        XCTAssertTrue(waitForNonExistence(of: appearanceTitle(app), timeout: 5), "the sheet leaves with the reader")
    }
}
