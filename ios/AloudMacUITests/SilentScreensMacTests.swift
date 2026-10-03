import AppKit
import XCTest

/// Silent screenshots of the phase-1 screens (testing §2.3, tier 2): the
/// same screens the audit walks, in light and dark, at 1280 × 800 and the
/// 520 × 480 minimum. Each is the app's own window, captured as an element
/// (`XCUIElement.screenshot()`) after it is brought to the front and has
/// settled; never the whole screen. Files are named
/// `<light|dark>-<nn>-<screen>[-min]@<scale>x.png`, the scale read from the
/// capture, since element shots come at the display's own scale.
///
/// Opt-in: runs only when `ALOUD_SHOTS_DIR` reaches the runner (pass
/// `TEST_RUNNER_ALOUD_SHOTS_DIR=<dir>`); otherwise it skips. Never makes a
/// sound: muted launches with autoplay off, and the walk never touches
/// Play, a card, a row or a voice. Turn on Do Not Disturb first: an element
/// shot is a region of the screen, so a banner over the window would be in
/// it. Runs only in the consented `AloudMacUI` scheme.
final class SilentScreensMacTests: XCTestCase {

    private var dir = ""
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
        guard let dir = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ALOUD_SHOTS_DIR to capture silent screenshots.")
        }
        self.dir = dir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testLight() { capture(scheme: "light") }
    func testDark() { capture(scheme: "dark") }

    private func capture(scheme: String) {
        let configurations = MacPhase1Screen.Configuration.all.filter { $0.name.hasPrefix(scheme) }
        for configuration in configurations {
            let isMinimum = configuration.arguments.contains(MacSuite.minimumWindow[1])
            for (index, screen) in MacPhase1Screen.allCases.enumerated() {
                let app = XCUIApplication.aloud(configuration.arguments + screen.arguments)
                self.app = app
                launchAloud(app)
                // launchAloud quits a build that isn't the muted dev one; never touch it.
                guard app.state == .runningForeground || app.state == .runningBackground else { return }
                let suite = MacSuite(app: app)
                guard let window = screen.reach(suite, test: self) else {
                    XCTFail("\(screen.rawValue) (\(configuration.name)) never showed")
                    app.terminate()
                    continue
                }
                bringToFront(app)
                suite.idle(1)   // the settle: popovers and fades finish
                let shot = window.screenshot()
                let scale = Self.scale(of: shot, window: window)
                let number = index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)"
                let name = "\(scheme)-\(number)-\(screen.rawValue)\(isMinimum ? "-min" : "")@\(scale)x"
                save(shot, named: name)
                app.terminate()
            }
        }
    }

    /// Pixels per point: element shots come at the display's scale (2 on a
    /// Retina panel, often 1 on an external monitor).
    private static func scale(of shot: XCUIScreenshot, window: XCUIElement) -> Int {
        guard let pixels = NSBitmapImageRep(data: shot.pngRepresentation)?.pixelsWide,
              window.frame.width > 0 else { return 1 }
        return max(1, Int((Double(pixels) / Double(window.frame.width)).rounded()))
    }

    private func save(_ shot: XCUIScreenshot, named name: String) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        XCTAssertNoThrow(try shot.pngRepresentation.write(to: url), "writing \(url.lastPathComponent)")
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
