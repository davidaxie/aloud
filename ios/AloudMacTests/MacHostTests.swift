import AppKit
import XCTest
@testable import Aloud

/// The hosted unit-test process never shows the app (testing §1.2(f)): it
/// runs the windowless accessory host, and it is the muted dev build, never
/// the shipping app (D1, D2).
@MainActor
final class MacHostTests: XCTestCase {

    func testHostedRunShowsNoWindowAndNeverActivates() {
        XCTAssertTrue(MacHostProcess.isHostedUnitTest)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).map(\.title), [], "a hosted run opens no window")
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "no Dock icon, no app switcher entry")
    }

    /// Tests run the Debug build, whose identity can't reach the user's app
    /// or its container.
    func testHostIsTheDevBuild() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.davidxie.Aloud.mac.dev")
    }

    func testHostedProcessIsMuted() {
        XCTAssertTrue(UITestHooks.muteAudio)
    }

    /// The rule behind the entry point: XCTest in the process (or its
    /// configuration file in the environment) means the windowless host,
    /// unless a UI test launched the app, which wants the real window.
    func testHostedUnitTestRule() {
        let configured = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        XCTAssertTrue(MacHostProcess.isHostedUnitTest(isUITestLaunch: false, environment: [:], xcTestLoaded: true))
        XCTAssertTrue(MacHostProcess.isHostedUnitTest(isUITestLaunch: false, environment: configured,
                                                      xcTestLoaded: false))
        XCTAssertFalse(MacHostProcess.isHostedUnitTest(isUITestLaunch: false, environment: [:], xcTestLoaded: false),
                       "a plain launch opens the window")
        XCTAssertFalse(MacHostProcess.isHostedUnitTest(isUITestLaunch: true, environment: configured,
                                                       xcTestLoaded: true),
                       "a UI-test launch opens the window")
    }
}
