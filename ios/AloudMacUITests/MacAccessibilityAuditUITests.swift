import XCTest

/// M18 for phase 1: `performAccessibilityAudit` with every macOS audit type
/// (contrast, element detection, hit region, sufficient description,
/// action, parent-child) finds nothing on the phase-1 screens: the empty
/// Library, the Library with books, Classics, a Classics search, the
/// reader, the Listening popover, the Aa popover and both Settings tabs.
/// Each runs in light and dark, at 1280 × 800 and at the 520 × 480 minimum.
///
/// The one exception is test plumbing: the DEBUG probes (`debug.*` and the
/// reader's playhead probe) are 1 × 1 elements that only UI-test launches
/// draw, as on the iPhone. Nothing else is allow-listed, `.parentChild`
/// least of all. No walk touches Play, a card, a row or a voice, so
/// nothing speaks. Runs only in the consented `AloudMacUI` scheme.
final class MacAccessibilityAuditUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        // Each screen reports all four of its configurations.
        continueAfterFailure = true
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testLibraryEmpty() { audit(.libraryEmpty) }
    func testLibraryWithBooks() { audit(.library) }
    func testClassics() { audit(.classics) }
    func testClassicsSearch() { audit(.classicsSearch) }
    func testReader() { audit(.reader) }
    func testListeningPopover() { audit(.listening) }
    func testAppearancePopover() { audit(.appearance) }
    func testSettingsVoiceAndSpeed() { audit(.settingsVoice) }
    func testSettingsTextAndAppearance() { audit(.settingsText) }

    private func audit(_ screen: MacPhase1Screen) {
        for configuration in MacPhase1Screen.Configuration.all {
            let launched = XCTContext.runActivity(named: "\(screen.rawValue), \(configuration.name)") { _ -> Bool in
                let app = XCUIApplication.aloud(configuration.arguments + screen.arguments)
                self.app = app
                launchAloud(app)
                // launchAloud quits a build that isn't the muted dev one: never
                // touch it, and launch nothing more.
                guard app.state == .runningForeground || app.state == .runningBackground else { return false }
                let suite = MacSuite(app: app)
                guard screen.reach(suite, test: self) != nil else {
                    app.terminate()
                    XCTFail("\(screen.rawValue) (\(configuration.name)) never showed")
                    return true
                }
                var issues: [String] = []
                do {
                    try app.performAccessibilityAudit(for: MacSuite.auditTypes) { issue in
                        if !MacSuite.isTestPlumbing(issue) { issues.append(MacSuite.describe(issue)) }
                        return true   // collected, so one failure lists them all
                    }
                } catch {
                    XCTFail("the audit didn't run on \(screen.rawValue) (\(configuration.name)): \(error)")
                }
                XCTAssertEqual(issues, [], "\(screen.rawValue) (\(configuration.name))")
                app.terminate()
                return true
            }
            if !launched { return }
        }
    }
}

/// The phase-1 screens, shared by the audit and the silent screenshots:
/// how to launch toward each, and how to reach it without speaking.
enum MacPhase1Screen: String, CaseIterable {
    case libraryEmpty = "library-empty"
    case library
    case classics
    case classicsSearch = "classics-search"
    case reader
    case listening
    case appearance
    case settingsVoice = "settings-voice"
    case settingsText = "settings-text"

    /// One appearance at one window size.
    struct Configuration {
        let name: String
        let arguments: [String]

        /// Light and dark, at the default 1280 × 800 and the minimum.
        static let all: [Configuration] = [("light", "-uitest-force-light"), ("dark", "-uitest-force-dark")]
            .flatMap { scheme, flag in
                [Configuration(name: "\(scheme) 1280x800", arguments: [flag]),
                 Configuration(name: "\(scheme) 520x480", arguments: [flag] + MacSuite.minimumWindow)]
            }
    }

    var arguments: [String] {
        switch self {
        case .libraryEmpty, .classics, .classicsSearch:
            return MacSuite.fresh
        case .library, .settingsVoice, .settingsText:
            return MacSuite.fresh + ["-uitest-seed-classics", "3"]
        case .reader, .listening, .appearance:
            return MacSuite.chapterReader
        }
    }

    /// Settings has its own window.
    var isSettings: Bool { self == .settingsVoice || self == .settingsText }

    /// Walks to the screen, paused and silent: buttons that only open a
    /// screen, ⌘F, ⌘, and typing into the search field. The window that
    /// shows it, or nil when it never appeared.
    func reach(_ suite: MacSuite, test: XCTestCase) -> XCUIElement? {
        switch self {
        case .libraryEmpty:
            return suite.element("library.featured").waitForExistence(timeout: 20) ? suite.mainWindow : nil
        case .library:
            return suite.element("library.card").waitForExistence(timeout: 30) ? suite.mainWindow : nil
        case .classics, .classicsSearch:
            let more = suite.element("library.moreClassics")
            guard more.waitForExistence(timeout: 20) else { return nil }
            more.click()
            guard suite.element("bookshelf.list").waitForExistence(timeout: 10) else { return nil }
            guard self == .classicsSearch else { return suite.mainWindow }
            suite.focusClassicsSearch(test, typing: "pride")
            return suite.element("bookshelf.row.1342").waitForExistence(timeout: 10) ? suite.mainWindow : nil
        case .reader:
            return suite.play.waitForExistence(timeout: 60) ? suite.mainWindow : nil
        case .listening, .appearance:
            guard suite.play.waitForExistence(timeout: 60) else { return nil }
            let opener = self == .listening ? "player.listening" : "reader.appearance"
            let title = self == .listening ? "listening.title" : "appearance.title"
            suite.element(opener).click()
            return suite.element(title).waitForExistence(timeout: 5) ? suite.mainWindow : nil
        case .settingsVoice, .settingsText:
            guard suite.element("library.card").waitForExistence(timeout: 30) else { return nil }
            test.press(.settings, in: suite.app)
            let window = suite.settingsWindow
            guard window.waitForExistence(timeout: 10) else { return nil }
            let tab = self == .settingsVoice ? "Voice & speed" : "Text & appearance"
            let shown = self == .settingsVoice ? "listening.speed.slider" : "appearance.textSize.value"
            // A Settings tab is a toolbar button, a radio button or a tab,
            // by the macOS version; a click on the selected one is harmless.
            _ = window.toolbars.firstMatch.waitForExistence(timeout: 5)
            let tabs = [window.toolbars.buttons[tab], window.buttons[tab], window.radioButtons[tab], window.tabs[tab]]
            tabs.map(\.firstMatch).first(where: \.exists)?.click()
            return window.descendants(matching: .any)[shown].firstMatch.waitForExistence(timeout: 5) ? window : nil
        }
    }
}
