import XCTest

/// The Settings window in the real app (R21, M10, M17, mac-ux §3.12): ⌘,
/// opens it 500 wide with exactly two toolbar tabs; both are reachable and
/// show their own controls, the natural-voice card among them; Tab walks
/// them without a beep; and nothing is clipped with the app at its minimum
/// size, light and dark. Launched muted, with no library, no model
/// (`-uitest-temp-model-dir`) and offline, so the card shows and nothing
/// downloads. No test clicks Download, a voice row or a preset, and keys go
/// to the app, never to a point in the window: each of those could speak.
/// Runs only in the consented `AloudMacUI` scheme.
final class MacSettingsUITests: XCTestCase {

    private var app: XCUIApplication?

    private static let listening = "Voice & speed"
    private static let appearance = "Text & appearance"

    /// Each tab's title and the identifier of the page it shows.
    private static let pages = [(title: listening, page: "settings.tab.listening"),
                                (title: appearance, page: "settings.tab.appearance")]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Launches with no library and no model, offline, then opens Settings
    /// with ⌘,. A test's own arguments come first, so its window size wins.
    private func openSettings(_ arguments: [String] = []) -> (app: XCUIApplication, window: XCUIElement) {
        let app = XCUIApplication.aloud(arguments + ["-uitest-reset-library", "-uitest-temp-model-dir",
                                                     "-uitest-offline"])
        self.app = app
        launchAloud(app)
        press(.settings, in: app)
        let window = app.windows["aloud.window.settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "⌘, opens the Settings window")
        return (app, window)
    }

    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any)[identifier].firstMatch
    }

    /// The toolbar tab titled `title`.
    private func tab(_ title: String, in window: XCUIElement) -> XCUIElement {
        window.toolbars.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Clicks a tab, then waits for its page and for the window to stop
    /// resizing to fit it.
    @discardableResult
    private func select(_ title: String, page identifier: String, in window: XCUIElement) -> XCUIElement {
        let button = tab(title, in: window)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the \(title) tab is in the toolbar")
        button.click()
        let page = element(identifier, in: window)
        XCTAssertTrue(page.waitForExistence(timeout: 5), "\(title) shows its page")
        var last = window.frame
        let deadline = Date().addingTimeInterval(3)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let now = window.frame
            if now == last { break }
            last = now
        } while Date() < deadline
        return page
    }

    /// Every text and control on the page lies wholly inside the window,
    /// and every text is at least a line of the ramp's smallest size
    /// (11 pt) tall. A page with a scrolling list (Voice & speed) has
    /// nothing below its fold either: with no model installed the list fits
    /// under its cap, so a text inside the window but scrolled out of the
    /// list's viewport still counts as clipped.
    private func assertNothingClipped(on page: XCUIElement, in window: XCUIElement, _ context: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let bounds = window.frame.insetBy(dx: -0.5, dy: -0.5)
        let texts = page.descendants(matching: .staticText).allElementsBoundByIndex.filter { !$0.label.isEmpty }
        XCTAssertFalse(texts.isEmpty, "\(context): the page has text", file: file, line: line)
        for text in texts {
            XCTAssertGreaterThanOrEqual(text.frame.height.rounded(), 11, "\(context): '\(text.label)' height",
                                        file: file, line: line)
            XCTAssertTrue(bounds.contains(text.frame), "\(context): '\(text.label)' \(text.frame) in \(window.frame)",
                          file: file, line: line)
        }
        let controlTypes: [XCUIElement.ElementType] = [.button, .slider, .switch, .checkBox, .segmentedControl,
                                                       .radioButton]
        for type in controlTypes {
            for control in page.descendants(matching: type).allElementsBoundByIndex where !control.frame.isEmpty {
                XCTAssertTrue(bounds.contains(control.frame),
                              "\(context): \(control.identifier) \(control.frame) in \(window.frame)",
                              file: file, line: line)
            }
        }
        let list = page.scrollViews.firstMatch
        guard list.exists else { return }
        let viewport = list.frame.insetBy(dx: -0.5, dy: -0.5)
        for type in [XCUIElement.ElementType.staticText] + controlTypes {
            for element in list.descendants(matching: type).allElementsBoundByIndex where !element.frame.isEmpty {
                XCTAssertTrue(viewport.contains(element.frame),
                              "\(context): '\(element.identifier)\(element.label)' \(element.frame) in the list's \(list.frame)",
                              file: file, line: line)
            }
        }
    }

    /// The control with keyboard focus inside `page`, as its type,
    /// identifier and label, or nil when nothing there has focus.
    private func focusedControl(in page: XCUIElement) -> String? {
        let focused = page.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        guard focused.exists else { return nil }
        return "\(focused.elementType.rawValue)|\(focused.identifier)|\(focused.label)"
    }

    // MARK: - Tests

    func testCommandCommaOpensSettingsWithExactlyTwoTabs() {
        let (_, window) = openSettings()
        // The toolbar fills after the window appears; count once it has.
        XCTAssertTrue(tab(Self.listening, in: window).waitForExistence(timeout: 5), "the toolbar shows its tabs")
        let kinds = [XCUIElement.ElementType.button, .radioButton, .toolbarButton].map(\.rawValue)
        let items = window.toolbars.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@", kinds)).allElementsBoundByIndex
        XCTAssertEqual(Set(items.map(\.label).filter { !$0.isEmpty }), [Self.listening, Self.appearance],
                       "the two tabs, and nothing else in the toolbar")
        XCTAssertFalse(tab("Licenses", in: window).exists, "licenses live in About Aloud, not a third tab")
        XCTAssertEqual(window.frame.width.rounded(), 500, "500 wide")
    }

    func testBothTabsAreReachableAndShowTheirControls() {
        let (_, window) = openSettings()

        select(Self.appearance, page: "settings.tab.appearance", in: window)
        for identifier in ["appearance.textSize.smaller", "appearance.textSize.value", "appearance.textSize.larger",
                           "appearance.scheme", "appearance.wordHighlight"] {
            XCTAssertTrue(element(identifier, in: window).waitForExistence(timeout: 5), identifier)
        }
        XCTAssertFalse(element("settings.tab.listening", in: window).exists, "one page at a time")

        select(Self.listening, page: "settings.tab.listening", in: window)
        for identifier in ["listening.speed.slider", "listening.preset.1", "listening.readAsides", "settings.privacy"] {
            XCTAssertTrue(element(identifier, in: window).waitForExistence(timeout: 5), identifier)
        }
        // M17: the natural-voice card is always here, so Michael can be
        // installed before a flight. Never clicked: it would download.
        let download = element("model.download", in: window)
        XCTAssertTrue(download.waitForExistence(timeout: 5), "the natural-voice card offers its download")
        // Inside the list's viewport, not merely the window: a button
        // scrolled below the fold can still sit within the window's frame.
        let list = element("settings.tab.listening", in: window).scrollViews.firstMatch
        XCTAssertTrue(list.exists, "the voice list scrolls in its own view")
        XCTAssertTrue(list.frame.insetBy(dx: -0.5, dy: -0.5).contains(download.frame),
                      "Download shows without scrolling: \(download.frame) in \(list.frame)")
        XCTAssertFalse(element("settings.tab.appearance", in: window).exists, "one page at a time")
        XCTAssertEqual(window.frame.width.rounded(), 500, "both tabs keep the width")
    }

    /// Under full keyboard access (this process only), Tab moves focus
    /// through each tab's controls, at least two of them on each page, and
    /// no key falls to the end of the responder chain, where it would beep.
    /// Tab only: it activates nothing.
    func testTabWalksBothTabsWithoutABeep() {
        let (app, window) = openSettings(["-AppleKeyboardUIMode", "3"])
        for (title, identifier) in Self.pages {
            let page = select(title, page: identifier, in: window)
            var focused = Set<String>()
            for _ in 0..<8 {
                press(.tab, in: app)
                if let control = focusedControl(in: page) { focused.insert(control) }
            }
            XCTAssertGreaterThanOrEqual(focused.count, 2, "\(title): Tab walks the page's controls \(focused)")
            for _ in 0..<2 { press(.shiftTab, in: app) }
        }
        let beeps = app.descendants(matching: .any)["debug.beeps"].firstMatch
        XCTAssertTrue(beeps.waitForExistence(timeout: 5))
        XCTAssertEqual(beeps.value as? String, "0", "Tab is never a dead key in Settings")
    }

    /// Settings is not resizable, so its one size is its minimum; it opens
    /// over the main window at its own minimum (520 × 480), light and dark.
    func testNothingIsClippedAtTheMinimumSizeInLightAndDark() {
        for scheme in ["-uitest-force-light", "-uitest-force-dark"] {
            let (app, window) = openSettings(["-uitest-window-size", "520x480", scheme])
            for (title, identifier) in Self.pages {
                let page = select(title, page: identifier, in: window)
                assertNothingClipped(on: page, in: window, "\(title), \(scheme)")
            }
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
    }
}
