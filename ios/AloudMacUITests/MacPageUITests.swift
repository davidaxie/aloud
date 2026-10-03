import XCTest

/// The book page in the real window (M14, M15, R15, R16): calm follow at
/// 3× over Gatsby's long first chapter makes at most 15 programmatic
/// scrolls per 100 lines read and never lets the voice meet the toolbar or
/// the bar; a live resize from 1000 to 600 pt while following keeps the
/// voice in the band; scrolled away, nothing moves for 30 s; a click on a
/// visible sentence while paused plays that sentence; a drag selects and
/// Copy leaves the playhead; the page's menu has no Speech; and the page is
/// a text area. Read through the DEBUG probes the reader overlays
/// (`MacReaderFollowProbeOverlay`, `ReaderFollowProbe`): the playhead, the
/// follow-scroll count, the active line and the active sentence's frame.
///
/// Muted throughout (`XCUIApplication.aloud`); the follow tests allow
/// autoplay, the rest start paused and only a click plays. The clipboard
/// is the user's: Copy is checked enabled, never chosen (the hosted
/// ReaderColumnViewTests copy to a private pasteboard). Runs only in the
/// consented `AloudMacUI` scheme.
final class MacPageUITests: XCTestCase {

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

    /// The Great Gatsby (chapter I runs some 700 lines), opened straight
    /// into the reader at 19 pt (step 2, M15's size), the System voice
    /// reading (no model, no warm-up). The natural-voice offer arrives
    /// answered, so no chip takes the page's foot after a minute of
    /// listening. `extra` comes first, so its window size wins.
    private func openGatsby(_ extra: [String] = [], allowAutoplay: Bool = false) -> MacSuite {
        let app = XCUIApplication.aloud(extra + ["-uitest-reset-library", "-uitest-reset-voice-pref",
                                                 "-uitest-temp-model-dir",
                                                 "-aloud.naturalVoice.offerAnswer.v1", "notNow",
                                                 "-aloud.prefs.v1.textSize", "2",
                                                 "-uitest-seed-classic", "64317", "-uitest-open-first-doc"],
                                        allowAutoplay: allowAutoplay)
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.pageText.waitForExistence(timeout: 20), "the reader should open on the page")
        XCTAssertTrue(suite.play.waitForExistence(timeout: 10), "the bar should be up")
        return suite
    }

    /// The click target: chapter I's second paragraph. It is sentence 2,
    /// after the "I" heading (0) and "In my younger…" (1), as on the iPhone
    /// (ListeningLoopUITests). It is its paragraph's only sentence, so its
    /// first line starts at the column's edge and is all its own.
    private static let clickTarget = "Whenever you feel like criticizing"

    /// A paragraph's first sentence deep in chapter I: the open can put it
    /// on the landing line, which at the top of the book it can't.
    private static let deepInChapter = "I told her how I had stopped off in Chicago"

    // MARK: - Calm follow (M15, R16)

    func testCalmFollowStaysCalmOverAFastChapter() throws {
        // A plist real: a bare "3" lands in the argument domain as a string,
        // which the Double read ignores, and 100 sentences at 1× overrun
        // the 600 s wait.
        let suite = openGatsby(["-aloud.prefs.v1.rate", "<real>3</real>"], allowAutoplay: true)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60),
                      "opening the book should start it, got '\(suite.playValue ?? "nil")'")
        let start = try XCTUnwrap(suite.playhead, "the playhead probe should exist")
        let startScrolls = try XCTUnwrap(suite.followScrolls, "the follow probe should exist")
        let startLine = try XCTUnwrap(suite.activeLine, "the line probe should exist")

        var outOfView: [String] = []
        let reached = suite.poll(timeout: 600) {
            guard let reading = suite.steadyVoice() else { return false }
            if let problem = Self.viewProblem(reading.frame, in: suite.pageViewport) {
                outOfView.append("sentence \(reading.sentence) \(problem)")
            }
            return reading.sentence >= start + 100
        }
        XCTAssertTrue(reached, "100 sentences should play, reached \(suite.playhead ?? -1) from \(start)")
        let endScrolls = try XCTUnwrap(suite.followScrolls, "the follow probe should outlast the run")
        let endLine = try XCTUnwrap(suite.activeLine, "the line probe should outlast the run")
        let measured = endScrolls - startScrolls
        let lines = endLine - startLine
        print("MacPageUITests: \(measured) follow scrolls over 100 sentences (\(lines) lines) at 3x")
        XCTAssertEqual(outOfView, [], "the voice never meets the toolbar or the bar")
        XCTAssertGreaterThan(lines, 0, "100 sentences run down the column")
        // R16's budget: 15 or fewer follow scrolls per 100 lines read.
        XCTAssertLessThanOrEqual(Double(measured) * 100 / Double(max(lines, 1)), 15,
                                 "\(measured) scrolls over \(lines) lines")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testALiveResizeWhileFollowingKeepsTheVoiceInTheBand() throws {
        let suite = openGatsby(["-uitest-window-size", "1000x760", "-uitest-seek-text", Self.deepInChapter],
                               allowAutoplay: true)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60),
                      "opening the book should start it, got '\(suite.playValue ?? "nil")'")
        let window = suite.mainWindow
        XCTAssertEqual(window.frame.width, 1000, accuracy: 2, "the window should open 1000 pt wide")
        let opening = try XCTUnwrap(suite.waitForSteadyVoice(), "the voice probes should read")
        let viewport = try XCTUnwrap(suite.pageViewport, "the page should show")
        XCTAssertNil(Self.bandProblem(opening.frame, in: viewport), "following, the voice starts in the band")

        // 100 pt at a time: each drag is a live resize, and the voice is
        // read between them, once the page is at rest.
        var corner: CGVector?
        var problems: [String] = []
        while window.frame.width > 602 {
            let width = window.frame.width
            guard let used = dragCorner(of: suite, by: max(600, width - 100) - width, trying: corner) else {
                return XCTFail("a drag at the window's corner should resize it (at \(Int(width)) pt)")
            }
            corner = used
            let now = Int(window.frame.width)
            guard let reading = suite.waitForSteadyVoice(), let viewport = suite.pageViewport else {
                problems.append("at \(now) pt: the voice never came to rest")
                continue
            }
            if let problem = Self.bandProblem(reading.frame, in: viewport) {
                problems.append("at \(now) pt, sentence \(reading.sentence) \(problem)")
            }
        }
        XCTAssertEqual(problems, [], "the voice keeps its place in the band through the resize")
        XCTAssertEqual(window.frame.width, 600, accuracy: 4, "the window should end 600 pt wide")
        XCTAssertTrue(["playing", "buffering"].contains(suite.playValue ?? ""), "the voice reads on through it")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testScrolledAwayNothingMovesFor30Seconds() throws {
        let suite = openGatsby(["-uitest-seek-text", Self.deepInChapter], allowAutoplay: true)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60),
                      "opening the book should start it, got '\(suite.playValue ?? "nil")'")
        // Home, with the page holding the keys: a user scroll to the top of
        // the book (M15), which leaves the voice reading on below the page.
        XCTAssertTrue(suite.focusPage(self), "the page should take the keys")
        press(.home, in: suite.app)
        let follow = suite.app.buttons["reader.followVoice.down"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 5), "the Follow chip should point down at the voice")

        // At rest (two readings of the passage agree), then 30 s: no follow
        // scroll, the same passage on the page (its value is what shows),
        // and the voice reading on.
        let shown = try XCTUnwrap(steadyPassage(suite), "the page should come to rest at the top")
        let scrolls = try XCTUnwrap(suite.followScrolls, "the follow probe should exist")
        let sentence = try XCTUnwrap(suite.playhead, "the playhead probe should exist")
        suite.idle(30)
        XCTAssertEqual(suite.followScrolls, scrolls, "no follow scroll while the listener is away")
        XCTAssertEqual(suite.text(suite.pageText), shown, "the offset holds: the same passage shows")
        XCTAssertGreaterThan(try XCTUnwrap(suite.playhead), sentence, "the voice read on meanwhile")
        XCTAssertTrue(["playing", "buffering"].contains(suite.playValue ?? ""), "still reading")
        XCTAssertTrue(follow.exists, "following never re-engages by itself")

        follow.click()
        XCTAssertTrue(suite.poll(timeout: 3) {
            suite.steadyVoice().map { Self.viewProblem($0.frame, in: suite.pageViewport) == nil } ?? false
        }, "the Follow chip brings the voice back, at \(String(describing: suite.activeSentenceFrame))")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - Click, select, menu (M14, R15)

    func testAClickOnAVisibleSentenceWhilePausedPlaysIt() throws {
        // The seek hook cues the target, so its index and its place on the
        // page are known from the app before any click.
        let suite = openGatsby(["-uitest-seek-text", Self.clickTarget])
        XCTAssertEqual(suite.playValue, "paused", "no autoplay in this launch")
        let target = try XCTUnwrap(waitForPlayhead(suite, timeout: 10) { $0 > 0 },
                                   "the seek hook should cue '\(Self.clickTarget)'")
        // The page to the top of the book by hand (Home, with the page
        // holding the keys). There no follow can move it, so the target
        // stays where it is measured while the cue moves back.
        XCTAssertTrue(suite.focusPage(self), "the page should take the keys")
        press(.home, in: suite.app)
        let frame = try XCTUnwrap(restingFrame(suite, of: target), "sentence \(target) should come to rest")
        let shown = suite.text(suite.pageText)

        // The cue back to the book's first sentences, by keys.
        press(.back15, in: suite.app)
        press(.back15, in: suite.app)
        XCTAssertNotNil(waitForPlayhead(suite, timeout: 5) { $0 < target }, "← should move the cue back from \(target)")
        let settled = try XCTUnwrap(steadyPlayhead(suite), "the cue should come to rest")
        XCTAssertGreaterThanOrEqual(target, settled + 2,
                                    "sentence \(target) must not be the next one after the cue (\(settled)): "
                                        + "a natural advance would pass for the click")
        XCTAssertEqual(suite.text(suite.pageText), shown, "the page held still since sentence \(target) was measured")
        XCTAssertEqual(suite.playValue, "paused", "the skips keep the pause")

        // The target's first line, just inside the column's edge.
        let point = CGPoint(x: frame.minX + 24, y: frame.minY + min(12, frame.height / 2))
        let viewport = try XCTUnwrap(suite.pageViewport, "the page should show")
        XCTAssertTrue(viewport.insetBy(dx: 0, dy: 4).contains(point), "sentence \(target) at \(frame) should show")
        suite.coordinate(at: point).click()

        // The first sentence after the click is exactly the clicked one:
        // playing from the cue would show start + 1 first.
        let clicked = try XCTUnwrap(waitForPlayhead(suite, timeout: 5) { $0 != settled },
                                    "the click should move the playhead off \(settled)")
        XCTAssertEqual(clicked, target, "playback starts at the clicked sentence \(target), not \(clicked)")
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 30),
                      "a click plays in any state, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testADragSelectsAndLeavesThePlayhead() throws {
        let suite = openGatsby(["-uitest-seek-text", Self.clickTarget])
        let target = try XCTUnwrap(waitForPlayhead(suite, timeout: 10) { $0 > 0 },
                                   "the seek hook should cue '\(Self.clickTarget)'")
        let frame = try XCTUnwrap(restingFrame(suite, of: target), "sentence \(target) should come to rest")

        // Along the first line: a drag, never a click, so nothing plays.
        let y = frame.minY + min(12, frame.height / 2)
        suite.coordinate(at: CGPoint(x: frame.minX + 24, y: y))
            .click(forDuration: 0.2, thenDragTo: suite.coordinate(at: CGPoint(x: frame.minX + 220, y: y)))

        // Edit ▸ Copy is enabled only with a selection to copy. Looked at,
        // never chosen, so the user's clipboard keeps what it had; Esc
        // closes the menu.
        let edit = suite.app.menuBars.menuBarItems["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the menu bar has Edit")
        edit.click()
        let copy = edit.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "Edit has Copy")
        XCTAssertTrue(copy.isEnabled, "the drag left a selection to copy")
        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 3) { !copy.isHittable }, "Esc closes the menu")

        // A wait that must stay uneventful.
        let moved = suite.poll(timeout: 2) { suite.playhead != target || suite.playValue != "paused" }
        XCTAssertFalse(moved, "selecting leaves the playhead at \(target) and the pause, got "
                           + "\(suite.playhead ?? -1), '\(suite.playValue ?? "nil")'")
        XCTAssertFalse(suite.element("reader.undoJump").exists, "nothing jumped")
        XCTAssertEqual(suite.beeps, 0)
    }

    func testThePagesMenuHasNoSpeech() throws {
        let suite = openGatsby(["-uitest-seek-text", Self.clickTarget])
        let target = try XCTUnwrap(waitForPlayhead(suite, timeout: 10) { $0 > 0 },
                                   "the seek hook should cue '\(Self.clickTarget)'")
        let frame = try XCTUnwrap(restingFrame(suite, of: target), "sentence \(target) should come to rest")

        suite.coordinate(at: CGPoint(x: frame.minX + 24, y: frame.minY + min(12, frame.height / 2))).rightClick()
        let menu = suite.app.menus.containing(NSPredicate(format: "title == %@", "Play from Here")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the page's menu should open")
        let titles = menu.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        XCTAssertTrue(titles.contains("Copy"), "Copy is there: \(titles)")
        XCTAssertTrue(titles.contains { $0.hasPrefix("Look Up") }, "Look Up is there: \(titles)")
        // NSTextView's own items, Speech first: it would read aloud through
        // the system synthesizer, past the muted engine. Look Up quotes a
        // word of the book, so it is left out of the search.
        let own = titles.filter { !$0.hasPrefix("Look Up") }
        for dropped in ["Speech", "Speak", "Font", "Spelling", "Substitutions", "Transformations",
                        "Layout Orientation", "Share", "Services", "Writing Tools"] {
            XCTAssertFalse(own.contains { $0.contains(dropped) }, "no \(dropped) in the page's menu: \(titles)")
        }

        press(.escape, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { !menu.exists }, "Esc closes the menu")
        XCTAssertEqual(suite.playhead, target, "a right-click never plays")
        XCTAssertEqual(suite.playValue, "paused")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - VoiceOver (M18)

    /// The rotors aren't reachable through XCUITest on macOS; the hosted
    /// MacReaderAccessibilityTests drive them. This checks what XCUIElement
    /// shows of the page: a native text area whose value is the passage on
    /// screen.
    func testThePageIsATextArea() {
        let suite = openGatsby()
        // By identifier, whatever its type: the page must come back a text area.
        XCTAssertEqual(suite.element("reader.text").elementType, .textView, "reader.text is a text area")
        XCTAssertTrue(suite.poll(timeout: 5) { !suite.text(suite.pageText).isEmpty },
                      "its value is the passage on screen")
    }

    func testThePageOffersPlayFromHere() throws {
        throw XCTSkip("XCUIElement exposes no accessibility custom actions on macOS (no attribute names them), "
                      + "so Play from here is proven by the hosted MacReaderAccessibilityTests and the VoiceOver walk")
    }

    // MARK: - Helpers

    /// Waits for a playhead `accept` takes, and returns it.
    private func waitForPlayhead(_ suite: MacSuite, timeout: TimeInterval, _ accept: (Int) -> Bool) -> Int? {
        var found: Int?
        suite.poll(timeout: timeout) {
            guard let sentence = suite.playhead, accept(sentence) else { return false }
            found = sentence
            return true
        }
        return found
    }

    /// The playhead once two readings a poll apart agree; nil if it never
    /// holds still.
    private func steadyPlayhead(_ suite: MacSuite, timeout: TimeInterval = 5) -> Int? {
        var previous: Int?
        var rested: Int?
        suite.poll(timeout: timeout) {
            let now = suite.playhead
            if let now, now == previous { rested = now }
            previous = now
            return rested != nil
        }
        return rested
    }

    /// The passage the page shows (its value) once two readings a poll
    /// apart agree; nil if it never holds still, or names nothing.
    private func steadyPassage(_ suite: MacSuite, timeout: TimeInterval = 5) -> String? {
        var previous: String?
        var rested: String?
        suite.poll(timeout: timeout) {
            let now = suite.text(suite.pageText)
            if !now.isEmpty, now == previous { rested = now }
            previous = now
            return rested != nil
        }
        return rested
    }

    /// The active sentence's frame once the page is at rest: two steady
    /// readings that agree. nil if the playhead leaves `sentence` or the
    /// page never settles.
    private func restingFrame(_ suite: MacSuite, of sentence: Int, timeout: TimeInterval = 5) -> CGRect? {
        var previous: CGRect?
        var rested: CGRect?
        suite.poll(timeout: timeout) {
            guard let reading = suite.steadyVoice(), reading.sentence == sentence else {
                previous = nil
                return false
            }
            if reading.frame == previous { rested = reading.frame }
            previous = reading.frame
            return rested != nil
        }
        return rested
    }

    /// Drags the main window's bottom-right corner `dx` points across: a
    /// live resize, as a person makes one, through the window element alone.
    /// AppKit's resize edge straddles the frame, so the drag starts just
    /// inside the corner and, should that not take, just outside it. The
    /// offset that took, nil when none did.
    private func dragCorner(of suite: MacSuite, by dx: CGFloat, trying preferred: CGVector?) -> CGVector? {
        let window = suite.mainWindow
        let offsets = (preferred.map { [$0] } ?? []) + [CGVector(dx: -1, dy: -1), CGVector(dx: 2, dy: 2)]
        for offset in offsets {
            let width = window.frame.width
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(offset)
            corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: dx, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
            if suite.poll(timeout: 2, { abs(window.frame.width - width) > 1 }) { return offset }
        }
        return nil
    }

    /// nil while `frame` shows between the toolbar and the bar; else where
    /// it is. A sentence taller than half the page can't clear the bar, so
    /// only its top is held to the rule.
    private static func viewProblem(_ frame: CGRect, in viewport: CGRect?) -> String? {
        guard let viewport else { return "with no page showing" }
        if frame.minY >= viewport.minY - 1, frame.maxY <= viewport.maxY + 1 || frame.height > viewport.height * 0.52 {
            return nil
        }
        return "at \(frame), outside the page at \(viewport)"
    }

    /// nil while `frame` sits in R16's band of `viewport` (`FollowBand`: 18%
    /// to 70% of what shows), with a few points for rounding; else where it
    /// sits. A sentence taller than the band counts once its top has
    /// reached the landing line (28%), as `FollowBand.contains` has it.
    private static func bandProblem(_ frame: CGRect, in viewport: CGRect) -> String? {
        let height = viewport.height
        let slack: CGFloat = 8
        if frame.minY < viewport.minY + 0.18 * height - slack {
            return "at \(frame): above the band of \(viewport)"
        }
        if frame.height > (0.70 - 0.18) * height {
            return frame.minY <= viewport.minY + 0.28 * height + slack
                ? nil : "at \(frame): a tall sentence below the landing line of \(viewport)"
        }
        return frame.maxY <= viewport.minY + 0.70 * height + slack ? nil : "at \(frame): below the band of \(viewport)"
    }
}
