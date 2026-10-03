import XCTest

/// M7's Classics items that need the window: ⌘F focuses the toolbar search;
/// "pride" puts Pride and Prejudice first, and one click or Return in the
/// field reaches "playing"; ↓ from the field moves focus to the top result
/// under keyboard navigation, and leaves the field its caret without it;
/// Esc clears the search and brings the three sections back; and a classic
/// already in the library opens that copy, so the shelf's count stays the
/// same. Typing goes only into the search field
/// (`MacSuite.typeIntoFocusedField`). Muted throughout; autoplay only
/// where a click must reach "playing". Runs only in the consented
/// `AloudMacUI` scheme.
///
/// Not here: a row's hint ("Opens and starts reading aloud", never
/// "Double-tap"), which XCUIElement doesn't expose on macOS.
final class MacClassicsUITests: XCTestCase {

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

    private static let prideAndPrejudice = "bookshelf.row.1342"

    /// Keyboard navigation off for this process, whatever System Settings
    /// say: only text fields and lists take focus.
    private static let noKeyboardNavigation = ["-AppleKeyboardUIMode", "0"]

    /// Classics from the empty Library, with "pride" typed into the field ⌘F
    /// focused. `arguments` add to the fresh launch.
    private func searchPride(allowAutoplay: Bool, arguments: [String] = []) -> MacSuite {
        let app = XCUIApplication.aloud(MacSuite.fresh + arguments, allowAutoplay: allowAutoplay)
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        let more = suite.element("library.moreClassics")
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.click()
        XCTAssertTrue(suite.element("bookshelf.list").waitForExistence(timeout: 10), "Classics is pushed")
        press(.find, in: app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.focus == "text.editable" }, "⌘F focuses the search field")
        XCTAssertTrue(suite.typeIntoFocusedField("pride"), "the field takes the typing")
        XCTAssertTrue(suite.poll(timeout: 5) { firstRow(in: suite)?.identifier == Self.prideAndPrejudice },
                      "Pride and Prejudice comes first, got \(firstRow(in: suite)?.identifier ?? "no rows")")
        return suite
    }

    private func firstRow(in suite: MacSuite) -> XCUIElement? {
        let row = suite.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bookshelf.row.'")).firstMatch
        return row.exists ? row : nil
    }

    func testPrideComesFirstAndOneClickPlaysIt() {
        let suite = searchPride(allowAutoplay: true)
        firstRow(in: suite)?.click()
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 90),
                      "one click adds, opens and plays, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testReturnInTheFieldPlaysTheTopResult() {
        let suite = searchPride(allowAutoplay: true)
        press(.returnKey, in: suite.app)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 90),
                      "Return plays the top result, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.beeps, 0)
    }

    /// ↓ in the field moves focus to the top result, as in Spotlight. Rows
    /// take focus under keyboard navigation (this process only).
    func testDownFromTheFieldFocusesTheTopResult() {
        let suite = searchPride(allowAutoplay: false, arguments: MacSuite.keyboardNavigation)
        let top = suite.element(Self.prideAndPrejudice)
        press(.down, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.hasKeyboardFocus(top) },
                      "the top result has focus, got '\(suite.focus)'")
        XCTAssertNotEqual(suite.focus, "text.editable", "the field gave focus up")
        XCTAssertEqual(suite.fieldText, "pride", "the search stays")
        XCTAssertEqual(suite.place, .classics, "↓ only moves focus")
        XCTAssertEqual(suite.beeps, 0)
    }

    /// Without keyboard navigation no row takes focus: the field keeps ↓
    /// for its caret, in silence.
    func testDownWithoutKeyboardNavigationStaysInTheField() {
        let suite = searchPride(allowAutoplay: false, arguments: Self.noKeyboardNavigation)
        press(.down, in: suite.app)
        suite.idle(1)
        XCTAssertEqual(suite.focus, "text.editable", "the field keeps focus")
        XCTAssertEqual(suite.fieldText, "pride")
        XCTAssertEqual(suite.place, .classics)
        XCTAssertEqual(suite.beeps, 0)
    }

    func testEscClearsTheSearchAndTheSectionsReturn() {
        let suite = searchPride(allowAutoplay: false)
        let sections = suite.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bookshelf.section.'"))
        XCTAssertEqual(sections.count, 0, "a search shows results, not sections")
        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { suite.fieldText == "" }, "Esc clears the field")
        XCTAssertTrue(suite.poll(timeout: 5) { sections.count > 0 }, "the sections come back")
        XCTAssertEqual(suite.place, .classics, "Esc never navigates (M5)")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testAClassicAlreadyInTheLibraryOpensThatCopy() {
        let app = XCUIApplication.aloud(MacSuite.fresh + ["-uitest-seed-classic", "1063"])
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.element("library.card").waitForExistence(timeout: 30))
        XCTAssertEqual(suite.libraryBookCount, 1)

        press(.addClassic, in: app)
        let row = suite.element("bookshelf.row.1063")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "⇧⌘O shows Classics")
        XCTAssertTrue(suite.poll(timeout: 5) { suite.text(row) == "In library" }, "the row says it's in the library")
        row.click()
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "one click opens it")

        XCTAssertTrue(suite.backToLibrary(self), "⌘[ walks back to the Library")
        XCTAssertTrue(suite.poll(timeout: 10) { suite.libraryBookCount == 1 }, "still one book: the same copy opened")
        XCTAssertEqual(suite.beeps, 0)
    }
}
