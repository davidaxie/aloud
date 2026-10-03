import XCTest

/// The Mac app launches as the muted dev build and nothing else: the
/// identity probe reads `com.davidxie.Aloud.mac.dev|muted`, then the app is
/// terminated. Runs only in the consented `AloudMacUI` scheme.
final class MacLaunchSmokeUITests: XCTestCase {

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

    func testLaunchesTheMutedDevBuild() {
        let app = XCUIApplication.aloud()
        self.app = app
        launchAloud(app)
        let probe = app.descendants(matching: .any)["debug.identity"].firstMatch
        let identity = (probe.value as? String) ?? ""
        XCTAssertEqual(Array(identity.components(separatedBy: "|").prefix(2)),
                       ["com.davidxie.Aloud.mac.dev", "muted"], identity)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }
}
