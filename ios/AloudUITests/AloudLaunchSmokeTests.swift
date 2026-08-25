import XCTest

/// Minimal smoke coverage: the app launches, and the debug seed argument
/// (-uitest-seed-first-classic) leaves it running in the foreground.
final class AloudLaunchSmokeTests: XCTestCase {

    func testLaunchesWithSeededClassic() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-seed-first-classic"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
    }
}
