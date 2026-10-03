import XCTest

/// M11's keyboard matrix: every shortcut in the one table (`MacKey`, which
/// mirrors `MacShortcuts`) pressed in seven focus states: the page text, a
/// bar button, the scrub, a Library card, the Classics search field, the
/// Listening popover and Contents' "Search this book". Each press gives its
/// expected effect or its expected no-op, then the state is put back for
/// the next key, so no combination is dead. The debug beep counter
/// (`debug.beeps`, App/MacTestSilence.swift) stays 0 throughout: a key
/// nothing took would have sounded the system alert, which no mixer mutes.
/// The page fills the reader, so its text is the window's background now;
/// Contents' rows are reached from its field (↓), so the field's state
/// covers the list's way in. ⌘+ and ⌘− change only the reader size, which
/// no state shows, so one more test reads it in the Aa popover.
///
/// The reader states use Pride and Prejudice cued mid-chapter 1, so every
/// skip and chapter step has somewhere to go. Muted throughout
/// (`XCUIApplication.aloud`) with autoplay off; the one key that plays
/// (Space) is pressed again at once to pause. Keys go only through
/// `press(_:in:)` to the app, never to an element, which could click it.
/// Runs only in the consented `AloudMacUI` scheme.
final class MacKeyboardMatrixUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        // A matrix reports every dead combination, not just the first.
        continueAfterFailure = true
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - The seven states

    func testThePageText() {
        run(FocusState(
            name: "the page text",
            arguments: MacSuite.chapterReader,
            isIn: { suite in
                suite.place == .reader && !suite.isPopoverShown && suite.modals == 0 && !suite.isContentsShown
                    && suite.focus == "text.selectable"
            },
            enter: { suite, test in
                // Contents shown, then closed: the page's text takes the
                // keys (a click on it would play from there). Read-only
                // text, so Space and the arrows run their commands at once.
                XCTAssertTrue(suite.focusPage(test), "the page has the keys")
            },
            keys: Self.readerKeys(space: .toggles, left: .moves(forward: false), right: .moves(forward: true))))
    }

    func testABarButton() {
        let forward = { (suite: MacSuite) in suite.app.buttons["player.forward15"].firstMatch }
        run(FocusState(
            name: "bar button (forward 15)",
            arguments: MacSuite.chapterReader + MacSuite.keyboardNavigation,
            isIn: { suite in suite.place == .reader && suite.modals == 0 && suite.hasKeyboardFocus(forward(suite)) },
            enter: { suite, test in
                guard suite.openReader(test) else { return }
                _ = suite.tab(test) { suite.hasKeyboardFocus(forward(suite)) }
            },
            // A focused button takes Space as its own press: forward 15.
            keys: Self.readerKeys(space: .moves(forward: true), left: .moves(forward: false),
                                  right: .moves(forward: true))))
    }

    func testTheScrub() {
        let scrub = { (suite: MacSuite) in suite.element("player.scrub") }
        // The scrub's own keys: chapter starts, then the chapter's ends.
        let scrubKeys: [(MacKey, Effect)] = [(.pageDown, .moves(forward: true)), (.pageUp, .moves(forward: false)),
                                             (.end, .moves(forward: true)), (.home, .moves(forward: false))]
        var keys = Self.readerKeys(space: .toggles, left: .moves(forward: false), right: .moves(forward: true))
        // After the no-op rows (their jumps leave Undo jump up), before the
        // keys that leave the reader.
        keys.insert(contentsOf: scrubKeys, at: keys.firstIndex { $0.0 == .addFromFiles } ?? keys.endIndex)
        run(FocusState(
            name: "scrub",
            arguments: MacSuite.chapterReader + MacSuite.keyboardNavigation,
            isIn: { suite in suite.place == .reader && suite.modals == 0 && suite.hasKeyboardFocus(scrub(suite)) },
            enter: { suite, test in
                guard suite.openReader(test) else { return }
                _ = suite.tab(test) { suite.hasKeyboardFocus(scrub(suite)) }
            },
            keys: keys))
    }

    func testALibraryCard() {
        run(FocusState(
            name: "Library card",
            arguments: MacSuite.fresh + ["-uitest-seed-classics", "3"] + MacSuite.keyboardNavigation,
            isIn: { suite in suite.place == .library && suite.modals == 0 && suite.isLibraryCardFocused },
            enter: { suite, test in
                guard suite.backToLibrary(test) else { return }
                _ = suite.tab(test) { suite.isLibraryCardFocused }
            },
            keys: [
                (.faster, .stepsRate), (.slower, .stepsRate),
                // The grid's arrows move focus between cards.
                (.back15, .movesFocus), (.forward15, .movesFocus),
                // No book is loaded yet: nothing to skip or step.
                (.previousChapter, .nothing), (.nextChapter, .nothing),
                (.undoJump, .nothing), (.followVoice, .nothing), (.find, .nothing), (.contents, .nothing),
                (.biggerText, .stepsTextSize), (.smallerText, .stepsTextSize), (.back, .nothing),
                (.deleteBook, .confirmsDelete), (.addFromFiles, .opensFilePanel), (.settings, .opensSettings),
                (.addClassic, .shows(.classics)),
                // Return or Space opens the focused card (M6). Last: the
                // opened book becomes the loaded one.
                (.returnKey, .shows(.reader)), (.playPause, .shows(.reader)),
                (.closeWindow, .closesWindow),
            ]))
    }

    func testTheClassicsSearchField() {
        run(FocusState(
            name: "Classics search field",
            arguments: MacSuite.fresh,
            isIn: { suite in
                suite.place == .classics && suite.modals == 0 && suite.focus == "text.editable"
                    && !(suite.fieldText ?? "").isEmpty
            },
            enter: { suite, test in suite.focusClassicsSearch(test, typing: "pride") },
            keys: [
                // The field types the plain keys (M11): status and rate stay.
                (.playPause, .editsField), (.faster, .editsField), (.slower, .editsField),
                (.back15, .keepsField), (.forward15, .keepsField),
                (.previousChapter, .keepsField), (.nextChapter, .keepsField),
                (.find, .keepsField), (.undoJump, .keepsField), (.addClassic, .keepsField),
                (.followVoice, .nothing), (.contents, .nothing),
                (.biggerText, .stepsTextSize), (.smallerText, .stepsTextSize),
                // ⌘⌫ deletes to the line's start; Esc clears the search (M7).
                (.deleteBook, .editsField), (.escape, .editsField),
                (.addFromFiles, .opensFilePanel), (.settings, .opensSettings),
                (.back, .shows(.library)),
                (.closeWindow, .closesWindow),
            ]))
    }

    func testTheListeningPopover() {
        var keys = Self.readerKeys(space: .toggles, left: .moves(forward: false), right: .moves(forward: true))
        keys.removeLast()
        keys += [(.escape, .closesPopover), (.closeWindow, .closesPopoverOrWindow)]
        // The popover's window has the keys, so where ⌘F leaves the main
        // window's first responder isn't this state's to assert.
        if let find = keys.firstIndex(where: { $0.0 == .find }) {
            keys[find].1 = .showsContents(searchFocused: false)
        }
        run(FocusState(
            name: "Listening popover",
            // No Full Keyboard Access: no control inside takes Space or the
            // arrows, so they reach the commands.
            arguments: MacSuite.chapterReader,
            isIn: { suite in suite.place == .reader && suite.isPopoverShown && suite.modals == 0 },
            enter: { suite, test in
                guard suite.openReader(test) else { return }
                if !suite.isPopoverShown { suite.app.buttons["player.listening"].firstMatch.click() }
                _ = suite.element("listening.title").waitForExistence(timeout: 5)
            },
            keys: keys))
    }

    func testTheContentsSearchField() {
        run(FocusState(
            name: "Contents search field",
            arguments: MacSuite.chapterReader,
            isIn: { suite in
                suite.place == .reader && suite.isContentsShown && !suite.isPopoverShown && suite.modals == 0
                    && suite.focus == "text.editable" && !(suite.fieldText ?? "").isEmpty
            },
            enter: { suite, test in suite.focusContentsSearch(test, typing: "Netherfield") },
            keys: [
                // First, while the field holds the query its results answer:
                // ↓ moves into them (M16). ⌘F then brings the caret back.
                (.down, .movesIntoList),
                // The field types the plain keys (M11): status and rate stay.
                (.playPause, .editsField), (.faster, .editsField), (.slower, .editsField),
                (.back15, .keepsField), (.forward15, .keepsField),
                (.previousChapter, .keepsField), (.nextChapter, .keepsField),
                (.find, .keepsField), (.undoJump, .keepsField),
                // The voice is on the page: nothing to follow.
                (.followVoice, .nothing),
                (.biggerText, .stepsTextSize), (.smallerText, .stepsTextSize),
                // ⌘⌫ deletes to the line's start.
                (.deleteBook, .editsField),
                (.escape, .clearsThenClosesContents), (.contents, .hidesContents),
                (.addFromFiles, .opensFilePanel), (.settings, .opensSettings),
                (.addClassic, .shows(.classics)), (.back, .shows(.library)),
                (.closeWindow, .closesWindow),
            ]))
    }

    // MARK: - The size keys' effect

    /// ⌘+ and ⌘− step the reader size from anywhere (mac-ux §5.1, "Everywhere").
    /// The matrix can't see the size, so this reads it where it shows, the
    /// Aa popover's readout: one step up, then back.
    func testTheTextSizeKeysStepTheReaderSize() {
        let app = XCUIApplication.aloud(MacSuite.chapterReader)
        self.app = app
        launchAloud(app)
        guard app.state == .runningForeground || app.state == .runningBackground else { return }
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.openReader(self), "the reader opens")
        suite.element("reader.appearance").click()
        let readout = suite.element("appearance.textSize.value")
        guard readout.waitForExistence(timeout: 5) else { return XCTFail("the Aa popover shows the size") }
        let start = readout.label

        press(.biggerText, in: app)
        XCTAssertTrue(suite.poll(timeout: 5) { readout.label != start }, "⌘+ steps the size up from '\(start)'")
        press(.smallerText, in: app)
        XCTAssertTrue(suite.poll(timeout: 5) { readout.label == start }, "⌘− steps it back, got '\(readout.label)'")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - Rows

    /// The reader's rows. Space and the arrows vary with what has focus; the
    /// rest are the same in every reader state. ⌘F opens Contents with its
    /// search focused and ⌃⌘S shows it (M16), each put back with ⌃⌘S.
    /// Follow the voice is off while the page follows the voice, and
    /// Delete Book… needs a focused card.
    private static func readerKeys(space: Effect, left: Effect, right: Effect) -> [(MacKey, Effect)] {
        [
            (.faster, .stepsRate), (.slower, .stepsRate),
            // The skips first, from a cue: once a sentence has played 3 s,
            // ← restarts it instead (R14).
            (.back15, left), (.forward15, right),
            (.previousChapter, .jumps(forward: false)), (.nextChapter, .jumps(forward: true)),
            (.playPause, space),
            (.undoJump, .nothing), (.followVoice, .nothing),
            (.find, .showsContents(searchFocused: true)), (.contents, .showsContents(searchFocused: false)),
            (.biggerText, .stepsTextSize), (.smallerText, .stepsTextSize), (.deleteBook, .nothing),
            (.addFromFiles, .opensFilePanel), (.settings, .opensSettings),
            (.addClassic, .shows(.classics)), (.back, .shows(.library)),
            (.closeWindow, .closesWindow),
        ]
    }

    // MARK: - Effects

    /// What one key press should do in a state.
    enum Effect {
        /// Nothing the suite observes changes: the screen, the play state,
        /// the playhead, the announcements, the windows, the field text and
        /// Contents.
        case nothing
        /// Playback starts; the same key pauses it again.
        case toggles
        /// The cue moves back or forward (R14's one skip, or the scrub's step).
        case moves(forward: Bool)
        /// A chapter jump: the cue moves, Undo jump shows, and ⌘Z returns.
        case jumps(forward: Bool)
        /// One speed preset, announced (M10).
        case stepsRate
        /// One reader-size step, which nothing in these states shows
        /// (`testTheTextSizeKeysStepTheReaderSize` reads it): the key is
        /// taken, and everything the suite observes stays. ⌘− follows ⌘+,
        /// so the size ends where it began.
        case stepsTextSize
        /// Add from Files…'s panel; Esc cancels it.
        case opensFilePanel
        /// The Settings window; ⌘W closes it.
        case opensSettings
        /// The delete confirmation; Esc cancels it and deletes nothing.
        case confirmsDelete
        /// The window shows another screen.
        case shows(MacSuite.Place)
        /// The search field's text changes; playback is untouched.
        case editsField
        /// The search field keeps the key (the caret moves); playback is untouched.
        case keepsField
        /// Focus moves within the grid; playback is untouched.
        case movesFocus
        /// Contents shows; with `searchFocused`, "Search this book" has the
        /// keys (⌘F). ⌃⌘S hides it again.
        case showsContents(searchFocused: Bool)
        /// Contents goes, and the page's text takes the keys (⌃⌘S).
        case hidesContents
        /// Esc in Contents' field: the first clears the search and keeps
        /// the caret, the second closes the panel and gives the page the keys.
        case clearsThenClosesContents
        /// ↓ in Contents' field: focus moves into the results, the panel
        /// stays, and playback is untouched.
        case movesIntoList
        /// The Listening popover closes.
        case closesPopover
        /// The main window closes; the app runs on.
        case closesWindow
        /// ⌘W in the popover: the popover or the window under it closes.
        case closesPopoverOrWindow
    }

    /// A focus state: how to launch into it, how to tell it holds, how to
    /// (re)enter it from wherever a key left the window, and its rows.
    struct FocusState {
        let name: String
        let arguments: [String]
        let isIn: (MacSuite) -> Bool
        let enter: (MacSuite, XCTestCase) -> Void
        let keys: [(MacKey, Effect)]
    }

    // MARK: - Running a state

    private func run(_ state: FocusState) {
        let app = XCUIApplication.aloud(state.arguments)
        self.app = app
        launchAloud(app)
        guard app.state == .runningForeground || app.state == .runningBackground else { return }
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.mainWindow.waitForExistence(timeout: 10), "the main window is up")

        for (key, effect) in state.keys {
            XCTContext.runActivity(named: "\(state.name) × \(key)") { _ in
                if !state.isIn(suite) { state.enter(suite, self) }
                guard state.isIn(suite) else {
                    return XCTFail("\(state.name): couldn't enter the state before \(key)")
                }
                let before = suite.observe()
                press(key, in: app)
                if let problem = verify(effect, before: before, suite: suite) {
                    XCTFail("\(state.name) × \(key): \(problem)")
                }
                restore(after: effect, key: key, before: before, suite: suite)
                if suite.mainWindow.exists {
                    XCTAssertEqual(suite.beeps, 0, "\(state.name) × \(key): the system alert would have sounded")
                }
            }
        }
        // The window is closed now; the counter is the process's, so read
        // it once more through the reopened window.
        if suite.reopenMainWindow() {
            XCTAssertEqual(suite.beeps, 0, "\(state.name): a beep after ⌘W")
        }
    }

    /// nil when `effect` happened; otherwise what was seen instead.
    private func verify(_ effect: Effect, before: MacSuite.Observation, suite: MacSuite) -> String? {
        switch effect {
        case .nothing, .stepsTextSize:
            // A no-op is a wait that must stay uneventful.
            var changed: MacSuite.Observation?
            suite.poll(timeout: 1.5) {
                let now = suite.observe()
                if now != before { changed = now }
                return changed != nil
            }
            return changed.map { "expected no effect, got \(before) → \($0)" }
        case .toggles:
            return suite.poll(timeout: 30) { ["playing", "buffering"].contains(suite.playValue ?? "") }
                ? nil : "expected playback to start, play reads '\(suite.playValue ?? "nil")'"
        case .moves(let forward):
            return suite.poll(timeout: 5) { suite.playhead.map { Self.moved($0, from: before.playhead, forward) } ?? false }
                ? nil : "expected the cue to move \(forward ? "forward" : "back") from \(before.playhead ?? -1)"
        case .jumps(let forward):
            let moved = suite.poll(timeout: 5) { suite.playhead.map { Self.moved($0, from: before.playhead, forward) } ?? false }
            guard moved else { return "expected a chapter jump \(forward ? "forward" : "back")" }
            return suite.element("reader.undoJump").waitForExistence(timeout: 5) ? nil : "the jump offers no Undo jump"
        case .stepsRate:
            return suite.poll(timeout: 5) {
                let added = suite.announcements.dropFirst(before.announcements.count)
                return added.contains { $0.hasSuffix(MacSuite.rateAnnouncementSuffix) }
            } ? nil : "expected a speed step to be announced"
        case .opensFilePanel:
            return suite.poll(timeout: 10) { suite.isFilePanelShown } ? nil : "expected the Add from Files panel"
        case .opensSettings:
            return suite.settingsWindow.waitForExistence(timeout: 10) ? nil : "expected the Settings window"
        case .confirmsDelete:
            return suite.poll(timeout: 5) { suite.modals > before.modals && suite.app.buttons["Delete"].exists }
                ? nil : "expected the delete confirmation"
        case .shows(let place):
            return suite.poll(timeout: 20) { suite.place == place } ? nil : "expected \(place), got \(suite.place)"
        case .editsField:
            let edited = suite.poll(timeout: 5) { suite.fieldText != before.field }
            return edited ? playbackUntouched(since: before, suite: suite) : "expected the field to change from '\(before.field ?? "")'"
        case .keepsField:
            let lost = suite.poll(timeout: 1.5) { suite.focus != "text.editable" || suite.place != before.place }
            return lost ? "the field lost the key (focus \(suite.focus), \(suite.place))" : playbackUntouched(since: before, suite: suite)
        case .showsContents(let searchFocused):
            guard suite.poll(timeout: 5, { suite.isContentsShown }) else { return "expected Contents to show" }
            if searchFocused, !suite.poll(timeout: 5, { suite.focus == "text.editable" }) {
                return "expected Search this book to have the keys, focus is \(suite.focus)"
            }
            return playbackUntouched(since: before, suite: suite)
        case .hidesContents:
            guard suite.poll(timeout: 5, { !suite.isContentsShown }) else { return "expected Contents to close" }
            return suite.poll(timeout: 5) { suite.focus == "text.selectable" }
                ? playbackUntouched(since: before, suite: suite)
                : "closing Contents should give the page the keys, focus is \(suite.focus)"
        case .clearsThenClosesContents:
            let cleared = suite.poll(timeout: 5) {
                suite.isContentsShown && suite.fieldText == "" && suite.focus == "text.editable"
            }
            guard cleared else { return "the first Esc should clear the search, field '\(suite.fieldText ?? "nil")'" }
            press(.escape, in: suite.app)
            guard suite.poll(timeout: 5, { !suite.isContentsShown }) else { return "the second Esc should close Contents" }
            return suite.poll(timeout: 5) { suite.focus == "text.selectable" }
                ? playbackUntouched(since: before, suite: suite)
                : "closing Contents should give the page the keys, focus is \(suite.focus)"
        case .movesIntoList:
            // The list's own responder: not the field, the page, the bare
            // window or nothing.
            let moved = suite.poll(timeout: 5) {
                !["text.editable", "text.selectable", "window", "none", ""].contains(suite.focus)
            }
            guard moved, suite.isContentsShown, suite.place == .reader else {
                return "expected ↓ to move into the results (focus \(suite.focus), Contents \(suite.isContentsShown))"
            }
            return playbackUntouched(since: before, suite: suite)
        case .movesFocus:
            let wandered = suite.poll(timeout: 1.5) { suite.place != .library || suite.modals != before.modals }
            if wandered { return "expected focus to move in the grid, got \(suite.place)" }
            return playbackUntouched(since: before, suite: suite)
        case .closesPopover:
            return suite.poll(timeout: 5) { !suite.isPopoverShown } ? nil : "the popover stayed open"
        case .closesWindow:
            let closed = suite.poll(timeout: 5) { !suite.mainWindow.exists }
            guard closed else { return "the window stayed open" }
            return suite.app.state == .notRunning ? "the app quit with its window" : nil
        case .closesPopoverOrWindow:
            return suite.poll(timeout: 5) { !suite.isPopoverShown || !suite.mainWindow.exists }
                ? nil : "neither the popover nor the window closed"
        }
    }

    /// Status and rate unchanged (M11): no playback appeared and no speed
    /// step was announced.
    private func playbackUntouched(since before: MacSuite.Observation, suite: MacSuite) -> String? {
        let added = suite.announcements.dropFirst(before.announcements.count)
        if added.contains(where: { $0.hasSuffix(MacSuite.rateAnnouncementSuffix) }) { return "the speed changed" }
        if suite.playValue != before.play { return "the play state changed to '\(suite.playValue ?? "nil")'" }
        return nil
    }

    /// Puts back what the key changed, where the state can't by entering.
    private func restore(after effect: Effect, key: MacKey, before: MacSuite.Observation, suite: MacSuite) {
        switch effect {
        case .toggles:
            press(key, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 10) { suite.playValue == "paused" }, "the second \(key) pauses")
        case .jumps:
            press(.undoJump, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 5) { suite.playhead == before.playhead }, "⌘Z returns to the sentence it left")
        case .opensFilePanel:
            press(.escape, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 10) { !suite.isFilePanelShown }, "Esc cancels the panel")
        case .confirmsDelete:
            press(.escape, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 10) { suite.modals == before.modals }, "Esc cancels the confirmation")
        case .opensSettings:
            press(.closeWindow, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 5) { !suite.settingsWindow.exists }, "⌘W closes Settings")
        case .showsContents:
            press(.contents, in: suite.app)
            XCTAssertTrue(suite.poll(timeout: 5) { !suite.isContentsShown }, "⌃⌘S hides Contents")
            // The keyboard goes back to the text; the state's entry takes it
            // from there.
            _ = suite.poll(timeout: 2) { suite.focus == "text.selectable" }
        case .nothing, .moves, .stepsRate, .stepsTextSize, .shows, .editsField, .keepsField, .movesFocus,
             .hidesContents, .clearsThenClosesContents, .movesIntoList,
             .closesPopover, .closesWindow, .closesPopoverOrWindow:
            break   // the state's own entry puts it back, or nothing needs to
        }
    }

    private static func moved(_ now: Int, from before: Int?, _ forward: Bool) -> Bool {
        guard let before else { return false }
        return forward ? now > before : now < before
    }
}
