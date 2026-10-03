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
    case escape, pageUp, pageDown, home, end, tab, shiftTab, returnKey, down

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
        case .down: return XCUIKeyboardKey.downArrow.rawValue
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
             .tab, .returnKey, .down:
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

// MARK: - The suite's driver

/// What every Mac UI test class reads and does through the one launched
/// app: the launch argument sets, the DEBUG probes (identity, beeps, focus,
/// playhead, announcements, and calm follow's on the page), the screens
/// and how to reach them, and waits that let the app run between
/// snapshots (never a fixed sleep). Keys still go only through
/// `press(_:in:)`, and launching only through `XCUIApplication.aloud` and
/// `launchAloud` (above).
struct MacSuite {

    let app: XCUIApplication

    // MARK: Launch argument sets

    /// A fresh container as far as a test can make one: no books, no stop,
    /// default voice and speed, no natural-voice offer, and no model (so
    /// the System voice reads, with no warm-up and no download).
    static let fresh = ["-uitest-reset-library", "-uitest-reset-voice-pref",
                        "-uitest-temp-model-dir", "-uitest-reset-natural-voice-offer"]

    /// Full Keyboard Access for this process only: Tab reaches every
    /// control, and the user's System Settings stay untouched.
    static let keyboardNavigation = ["-AppleKeyboardUIMode", "3"]

    /// The window's minimum (M5). Before `aloud()`'s default size, so it wins.
    static let minimumWindow = ["-uitest-window-size", "520x480"]

    /// Pride and Prejudice (chapters), opened paused mid-chapter 1.
    static let chapterReader = fresh + ["-uitest-seed-classic", "1342", "-uitest-open-first-doc",
                                        "-uitest-seek-text", "so odd a mixture"]

    /// The Cask of Amontillado, the first classic (no chapters), opened.
    static let firstClassicReader = fresh + ["-uitest-seed-first-classic", "-uitest-open-first-doc"]

    /// How a speed step is announced: "1.25 times speed" (ListeningCopy).
    static let rateAnnouncementSuffix = "times speed"

    // MARK: Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    var mainWindow: XCUIElement { app.windows["aloud.window.main"].firstMatch }

    /// The Settings window: SwiftUI names it, and titles it by its tab.
    var settingsWindow: XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings' OR title CONTAINS[c] 'settings' "
                                         + "OR title == 'Voice & speed' OR title == 'Text & appearance'")).firstMatch
    }

    var play: XCUIElement { app.buttons["player.play"].firstMatch }

    /// Classics' toolbar search, or in the reader Contents' "Search this
    /// book" (`search.field`): the one search field either screen shows.
    var searchField: XCUIElement { app.searchFields.firstMatch }

    /// The reader's Contents panel, docked or floating.
    var contentsPanel: XCUIElement { element("contents.panel") }

    var isContentsShown: Bool { contentsPanel.exists }

    /// The book page's text (`reader.text`): a text area, as VoiceOver
    /// reads it. Its frame is the whole book's; `pageViewport` is what shows.
    var pageText: XCUIElement { app.textViews["reader.text"].firstMatch }

    var isPopoverShown: Bool { element("listening.title").exists }

    /// Add from Files…'s open panel: a sheet on the window, or the panel's
    /// own Open and Cancel buttons wherever the system draws it.
    var isFilePanelShown: Bool {
        app.sheets.count > 0 || (app.buttons["Open"].exists && app.buttons["Cancel"].exists)
    }

    /// Sheets, dialogs and alerts over any window.
    var modals: Int { app.sheets.count + app.dialogs.count + app.alerts.count }

    var windows: Int { app.windows.count }

    // MARK: Probes

    /// keyDowns that would have beeped (`debug.beeps`); nil without the probe.
    var beeps: Int? { Int(Self.string(element("debug.beeps").value)) }

    /// The main window's first responder (`debug.focus`): "window",
    /// "text.editable", an identifier or a class.
    var focus: String { Self.string(element("debug.focus").value) }

    /// The playhead from the reader's DEBUG probe; nil outside the reader.
    var playhead: Int? {
        let prefix = "reader.sentence."
        let probe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        guard probe.exists else { return nil }
        return Int(probe.identifier.dropFirst(prefix.count))
    }

    /// What VoiceOver would have heard, oldest first (muted: recorded only).
    var announcements: [String] {
        let probe = element("debug.announcements")
        guard probe.exists else { return [] }
        return Self.string(probe.value).split(separator: "\n").map(String.init)
    }

    /// "playing", "buffering", "paused", "stopped, playback error"; nil
    /// outside the reader.
    var playValue: String? { play.exists ? Self.string(play.value) : nil }

    /// The search field's text: Classics', or Contents' in the reader; nil
    /// where neither shows.
    var fieldText: String? {
        guard place == .classics || (place == .reader && isContentsShown), searchField.exists else { return nil }
        let text = Self.string(searchField.value)
        return text == searchField.placeholderValue ? "" : text
    }

    /// Whether `element` has keyboard focus, through the attribute XCUITest
    /// keeps for it; false when it can't be read.
    func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        guard element.exists, element.responds(to: NSSelectorFromString("hasKeyboardFocus")) else { return false }
        return (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    var isLibraryCardFocused: Bool {
        app.descendants(matching: .any).matching(identifier: "library.card").allElementsBoundByIndex
            .contains { hasKeyboardFocus($0) }
    }

    /// Books on the Library: the grid's cards and the Continue card.
    var libraryBookCount: Int {
        app.descendants(matching: .any).matching(identifier: "library.card").count
            + app.descendants(matching: .any).matching(identifier: "library.continue").count
    }

    // MARK: Screens

    enum Place: Equatable, CustomStringConvertible {
        case library, classics, reader, closed

        var description: String {
            switch self {
            case .library: return "the Library"
            case .classics: return "Classics"
            case .reader: return "the reader"
            case .closed: return "no window"
            }
        }
    }

    var place: Place {
        guard mainWindow.exists else { return .closed }
        if play.exists { return .reader }
        if element("bookshelf.list").exists { return .classics }
        return .library
    }

    /// One reading of everything a key could change.
    struct Observation: Equatable, CustomStringConvertible {
        var place: Place
        var play: String?
        var playhead: Int?
        var announcements: [String]
        var windows: Int
        var modals: Int
        var field: String?
        var contents: Bool

        var description: String {
            "\(place), play \(play ?? "-"), sentence \(playhead.map(String.init) ?? "-"), "
                + "\(announcements.count) announced, \(windows) windows, \(modals) modals, field '\(field ?? "-")'"
                + (contents ? ", Contents shown" : "")
        }
    }

    func observe() -> Observation {
        Observation(place: place, play: playValue, playhead: playhead, announcements: announcements,
                    windows: windows, modals: modals, field: fieldText, contents: isContentsShown)
    }

    /// Back to the reader of the loaded book: from Classics pushed over it
    /// (⌘[), or from the Library through the Continue card's body. True
    /// once the reader shows.
    @discardableResult
    func openReader(_ test: XCTestCase, timeout: TimeInterval = 30) -> Bool {
        if place == .reader { return true }
        if modals > 0 { test.press(.escape, in: app) }
        if place == .classics {
            test.press(.back, in: app)
            if play.waitForExistence(timeout: 5) { return true }
        }
        if place == .library {
            let hero = element("library.continue")
            if hero.waitForExistence(timeout: 5) {
                hero.click()
            } else if element("library.card").exists {
                element("library.card").click()
            }
        }
        return play.waitForExistence(timeout: timeout)
    }

    /// Back to the Library root with ⌘[, one screen at a time.
    @discardableResult
    func backToLibrary(_ test: XCTestCase) -> Bool {
        for _ in 0..<3 where place != .library {
            if modals > 0 { test.press(.escape, in: app) }
            test.press(.back, in: app)
            _ = poll(timeout: 5) { place != .reader && place != .classics }
        }
        return place == .library
    }

    /// Classics with its search field focused (⌘F) and holding `typing`.
    func focusClassicsSearch(_ test: XCTestCase, typing: String) {
        if place == .library {
            let more = element("library.moreClassics")
            if more.exists { more.click() } else { test.press(.addClassic, in: app) }
        }
        guard element("bookshelf.list").waitForExistence(timeout: 10) else { return }
        if focus != "text.editable" {
            test.press(.find, in: app)
            _ = poll(timeout: 5) { focus == "text.editable" }
        }
        if (fieldText ?? "").isEmpty { typeIntoFocusedField(typing) }
    }

    /// The reader with its page holding the keys ("text.selectable"):
    /// Contents shown, then hidden (⌃⌘S), which hands the keyboard back to
    /// the text. A click would do it too, but a click on the page plays.
    /// True once the page has the keys.
    @discardableResult
    func focusPage(_ test: XCTestCase) -> Bool {
        guard openReader(test) else { return false }
        if isPopoverShown { test.press(.escape, in: app) }
        if !isContentsShown {
            test.press(.contents, in: app)
            _ = poll(timeout: 5) { isContentsShown }
        }
        test.press(.contents, in: app)
        return poll(timeout: 5) { !isContentsShown && focus == "text.selectable" }
    }

    /// The reader's Contents with "Search this book" focused (⌘F) and
    /// holding `typing`, its results landed (past the 200 ms debounce).
    func focusContentsSearch(_ test: XCTestCase, typing: String) {
        guard openReader(test) else { return }
        if isPopoverShown { test.press(.escape, in: app) }
        if !isContentsShown || focus != "text.editable" {
            test.press(.find, in: app)
            _ = poll(timeout: 5) { isContentsShown && focus == "text.editable" }
        }
        if (fieldText ?? "").isEmpty, typeIntoFocusedField(typing) {
            _ = element("search.count").waitForExistence(timeout: 10)
        }
    }

    /// Types `text` into the search field, and only while a field has the
    /// keys: letters sent to a window would each be a key nothing takes.
    /// The one place a Mac UI test types text. False when nothing was typed.
    @discardableResult
    func typeIntoFocusedField(_ text: String) -> Bool {
        guard focus == "text.editable", searchField.exists else { return false }
        searchField.typeText(text)
        return true
    }

    /// Presses Tab until `focused` holds, at most `limit` times.
    @discardableResult
    func tab(_ test: XCTestCase, limit: Int = 30, until focused: () -> Bool) -> Bool {
        for _ in 0..<limit {
            if focused() { return true }
            test.press(.tab, in: app)
        }
        return focused()
    }

    /// The main window back after ⌘W, through Window ▸ Aloud (a click, not
    /// a key). True once it shows.
    func reopenMainWindow() -> Bool {
        if mainWindow.exists { return true }
        guard app.state == .runningForeground || app.state == .runningBackground else { return false }
        let windowMenu = app.menuBars.menuBarItems["Window"].firstMatch
        guard windowMenu.exists else { return false }
        windowMenu.click()
        let item = app.menuBars.menuItems["Aloud"].firstMatch
        guard item.waitForExistence(timeout: 3) else { return false }
        item.click()
        return mainWindow.waitForExistence(timeout: 5)
    }

    /// A point on screen inside the main window, to click, drag from or
    /// scroll at.
    func coordinate(at point: CGPoint) -> XCUICoordinate {
        let frame = mainWindow.frame
        return mainWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
    }

    /// Waits until `values` contains the play button's value.
    func waitForPlay(_ values: Set<String>, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { values.contains(playValue ?? "") }
    }

    // MARK: The page (R16, M15)

    /// What of the page shows, on screen: its scroll view below the
    /// toolbar, beside a docked Contents, above the player bar. nil outside
    /// the reader.
    var pageViewport: CGRect? {
        let scroll = app.scrollViews.containing(.textView, identifier: "reader.text").firstMatch
        guard scroll.exists else { return nil }
        var frame = scroll.frame
        // The toolbar is the page's paper: should the text scroll under it,
        // what shows starts at its edge.
        let toolbar = mainWindow.toolbars.firstMatch
        if toolbar.exists, toolbar.frame.maxY > frame.minY, toolbar.frame.maxY < frame.maxY {
            frame = CGRect(x: frame.minX, y: toolbar.frame.maxY,
                           width: frame.width, height: frame.maxY - toolbar.frame.maxY)
        }
        return frame
    }

    /// Programmatic follow scrolls since the page opened
    /// (`reader.followScrolls.<n>`); nil outside the reader.
    var followScrolls: Int? { probeNumber(after: "reader.followScrolls.") }

    /// The page line the active sentence's top sits on, from the top of the
    /// column (`reader.activeLine.<n>`): R16's budget is per 100 lines read.
    var activeLine: Int? { probeNumber(after: "reader.activeLine.") }

    /// The active sentence's frame on screen (`reader.activeSentence`).
    var activeSentenceFrame: CGRect? {
        let probe = element("reader.activeSentence")
        return probe.exists ? probe.frame : nil
    }

    /// The playhead and the active sentence's frame from one moment. The
    /// frame probe redraws a beat after the playhead probe, so a single
    /// pair can mix two sentences: it counts only when two reads of each
    /// agree. nil while they don't, or a probe is missing.
    func steadyVoice() -> (sentence: Int, frame: CGRect)? {
        guard let sentence = playhead, let frame = activeSentenceFrame,
              playhead == sentence, activeSentenceFrame == frame else { return nil }
        return (sentence, frame)
    }

    /// The first steady reading within `timeout`.
    func waitForSteadyVoice(timeout: TimeInterval = 3) -> (sentence: Int, frame: CGRect)? {
        var reading: (sentence: Int, frame: CGRect)?
        poll(timeout: timeout) {
            reading = steadyVoice()
            return reading != nil
        }
        return reading
    }

    // MARK: Waiting

    /// Re-checks `condition` until it holds or `timeout` passes, letting the
    /// app run between snapshots. True when it held.
    @discardableResult
    func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            guard Date() < deadline else { return false }
            // An expectation nobody fulfils: a wait that spins the run loop
            // and never fails the test.
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "poll")], timeout: 0.2)
        }
    }

    /// Lets the app run for `seconds`, for a state that must hold that long.
    func idle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "idle")], timeout: seconds)
    }

    // MARK: Audits

    /// The macOS audit (testing §2.4): every type there is on the Mac.
    static let auditTypes: XCUIAccessibilityAuditType = [.contrast, .elementDetection, .hitRegion,
                                                         .sufficientElementDescription, .action, .parentChild]

    /// The DEBUG probes are test plumbing, not UI (as on the iPhone): the
    /// 1 × 1 identity, beep, focus and playhead probes, and the page's calm
    /// follow probes (`MacReaderFollowProbeOverlay`), drawn only in UI-test
    /// launches.
    static func isTestPlumbing(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let identifier = issue.element?.identifier else { return false }
        return ["debug.", "reader.sentence.", "reader.followScrolls.", "reader.activeLine.", "reader.activeSentence"]
            .contains { identifier.hasPrefix($0) }
    }

    /// One audit issue as a line a failure can act on: what, the element's
    /// identifier and label, and where it sits.
    static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let types: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.action, "action"),
            (.parentChild, "parentChild"),
        ]
        let check = types.first { issue.auditType.contains($0.0) }?.1 ?? "audit \(issue.auditType.rawValue)"
        guard let element = issue.element else { return "\(issue.compactDescription) (\(check)) [no element]" }
        let f = element.frame
        return "\(issue.compactDescription) (\(check)) [\(element.identifier)] '\(element.label)' "
            + "(\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width))x\(Int(f.height)))"
    }

    /// An element's value as text ("" for none).
    func text(_ element: XCUIElement) -> String {
        Self.string(element.value)
    }

    // MARK: Private

    /// The number an identifier probe ends with, after `prefix`.
    private func probeNumber(after prefix: String) -> Int? {
        let probe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        guard probe.exists else { return nil }
        return Int(probe.identifier.dropFirst(prefix.count))
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? value.map { "\($0)" } ?? ""
    }
}
