import XCTest

extension XCUIApplication {

    /// The only way a Mac UI test creates the app: the TEST_TARGET_NAME
    /// product (Aloud Dev, com.davidxie.Aloud.mac.dev), always muted by
    /// argument AND environment, autoplay off unless asked, no window
    /// restoration, fixed size. `-uitest-allow-autoplay` lifts the autoplay
    /// suppression only; nothing un-mutes.
    ///
    /// The only place XCUIApplication() and `launchArguments =` may appear.
    /// Never `XCUIApplication(bundleIdentifier:)`: LaunchServices may pick a
    /// stale Aloud Dev from another worktree, or the shipping app.
    static func aloud(_ arguments: [String] = [], allowAutoplay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()                      // exact built product, not a LaunchServices lookup
        app.launchArguments = ["-uitest-mute"] + arguments
            + (allowAutoplay ? ["-uitest-allow-autoplay"] : [])
            + ["-uitest-window-size", "1280x800",        // first match wins, so a test's own size comes earlier
               "-ApplePersistenceIgnoreState", "YES"]    // no restored reader, no restored playback
        app.launchEnvironment["ALOUD_MUTE"] = "1"
        return app
    }
}

/// Every key a Mac UI test may press: the shortcuts of the app's one command
/// table (mac-prd, Keyboard) plus focus movement. A key nothing handles makes
/// AppKit beep through the alert channel, which no mixer mutes, so tests send
/// only these, through `press(_:in:)` (testing §1.2(e)). Quit, Hide, Minimize
/// and Full Screen are left out: they would take the window from the test.
enum MacKey: CaseIterable {
    case playPause, back15, forward15, previousChapter, nextChapter
    case faster, slower, followVoice, undoJump, find, contents
    case biggerText, smallerText, back, addFromFiles, addClassic, deleteBook
    case settings, closeWindow
    case escape, pageUp, pageDown, home, end, tab, shiftTab, returnKey

    /// The key, as `typeKey` takes it.
    var key: String {
        switch self {
        case .playPause: return XCUIKeyboardKey.space.rawValue
        case .back15, .previousChapter: return XCUIKeyboardKey.leftArrow.rawValue
        case .forward15, .nextChapter: return XCUIKeyboardKey.rightArrow.rawValue
        case .faster: return "]"
        case .slower, .back: return "["
        case .followVoice: return "j"
        case .undoJump: return "z"
        case .find: return "f"
        case .contents: return "s"
        case .biggerText: return "+"
        case .smallerText: return "-"
        case .addFromFiles, .addClassic: return "o"
        case .deleteBook: return XCUIKeyboardKey.delete.rawValue
        case .settings: return ","
        case .closeWindow: return "w"
        case .escape: return XCUIKeyboardKey.escape.rawValue
        case .pageUp: return XCUIKeyboardKey.pageUp.rawValue
        case .pageDown: return XCUIKeyboardKey.pageDown.rawValue
        case .home: return XCUIKeyboardKey.home.rawValue
        case .end: return XCUIKeyboardKey.end.rawValue
        case .tab, .shiftTab: return XCUIKeyboardKey.tab.rawValue
        case .returnKey: return XCUIKeyboardKey.return.rawValue
        }
    }

    /// The modifiers held with `key`.
    var modifiers: XCUIElement.KeyModifierFlags {
        switch self {
        case .previousChapter, .nextChapter, .followVoice, .undoJump, .find, .biggerText, .smallerText,
             .back, .addFromFiles, .deleteBook, .settings, .closeWindow:
            return .command
        case .contents: return [.control, .command]
        case .addClassic: return [.shift, .command]
        case .shiftTab: return .shift
        case .playPause, .back15, .forward15, .faster, .slower, .escape, .pageUp, .pageDown, .home, .end,
             .tab, .returnKey:
            return []
        }
    }
}

/// Shared helpers for every Mac UI-test class: launching, keys and focus.
/// Each class terminates its app in `tearDown`.
extension XCTestCase {

    /// Launch, then fail closed: the identity probe must say dev + muted
    /// before anything is touched. A stale binary that predates the probe
    /// fails here too.
    func launchAloud(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.launch()
        let probe = app.descendants(matching: .any)["debug.identity"].firstMatch
        guard probe.waitForExistence(timeout: 10),
              let value = probe.value as? String, value.hasPrefix("com.davidxie.Aloud.mac.dev|muted") else {
            app.terminate()
            XCTFail("Not the muted dev build", file: file, line: line)
            return
        }
    }

    /// The only way a Mac UI test sends a key: one from `MacKey`, to
    /// `element` (the app, a window or a focused control).
    func press(_ key: MacKey, in element: XCUIElement) {
        element.typeKey(key.key, modifierFlags: key.modifiers)
    }

    /// Brings an app this test launched to the front, for a window
    /// screenshot. `activate()` on an app that isn't running would launch it
    /// without our arguments, so it is refused here, and this is the only
    /// place `activate()` may appear.
    func bringToFront(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard app.state == .runningForeground || app.state == .runningBackground else {
            XCTFail("bringToFront needs an app launched by launchAloud", file: file, line: line)
            return
        }
        app.activate()
    }
}
