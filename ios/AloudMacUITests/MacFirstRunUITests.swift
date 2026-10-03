import XCTest

/// M6's first run: a fresh container with no seed hooks opens on the empty
/// Library with nothing in front of it, and one click on the featured
/// classic reaches "playing", muted. The launch resets the library, the
/// voice and speed, and the natural-voice offer, and hides the model, which
/// is what a first launch finds; it seeds nothing. Autoplay is allowed, as a
/// real first click has it; the identity probe proves the process is muted.
/// Runs only in the consented `AloudMacUI` scheme.
final class MacFirstRunUITests: XCTestCase {

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

    func testOneClickOnTheFeaturedClassicReachesPlaying() {
        let app = XCUIApplication.aloud(MacSuite.fresh, allowAutoplay: true)
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)

        let featured = suite.element("library.featured")
        XCTAssertTrue(featured.waitForExistence(timeout: 20), "the empty Library features a classic")
        XCTAssertTrue(featured.label.hasPrefix("The Cask of Amontillado"), featured.label)
        XCTAssertEqual(suite.modals, 0, "no sheet or alert before the first click")
        XCTAssertFalse(suite.play.exists, "nothing is open, so nothing can play")

        featured.click()

        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60),
                      "one click reaches playing, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.modals, 0, "no sheet or alert on the way")
        XCTAssertTrue(suite.text(suite.element("debug.identity")).hasSuffix("|muted"), "and it is muted")
        XCTAssertEqual(suite.beeps, 0)
    }
}
