import XCTest

/// The listening loop end to end (R15, R16): a tap on the text plays from
/// it, every jump can be undone, the text follows calmly, and once the
/// listener scrolls away it waits for them.
///
/// Muted like every UI test, but these start playback, so never run them
/// without the user's OK. They read the playhead and the follow probes only
/// through the XCUIHelpers helpers.
final class ListeningLoopUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Great Gatsby, opened straight into the reader at 19pt (step 2).
    /// The temp model dir keeps the System voice (no warm-up). The offer
    /// arrives answered, in the argument domain, so it never takes the
    /// chapter line's slot after a minute of listening: the band's bottom is
    /// read from the chapter line.
    private func openGatsby(_ extra: [String] = [], allowAutoplay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-temp-model-dir", "-uitest-reset-library",
                                         "-aloud.naturalVoice.offerAnswer.v1", "notNow",
                                         "-aloud.prefs.v1.textSize", "2",
                                         "-uitest-seed-classic", "64317", "-uitest-open-first-doc"] + extra,
                                        allowAutoplay: allowAutoplay)
        app.launch()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 20),
                      "The reader should open")
        return app
    }

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        return play
    }

    private func chapterLine(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reader.chapterLine"].firstMatch
    }

    /// Opens Contents from the chapter line and picks a chapter row.
    private func pickChapter(row: Int, in app: XCUIApplication) {
        let line = chapterLine(app)
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.tap()
        let chapter = app.buttons["chapters.row.\(row)"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), "Contents should list chapter row \(row)")
        chapter.tap()
        XCTAssertTrue(waitForNonExistence(of: app.textFields["search.field"].firstMatch, timeout: 5),
                      "Contents should close")
    }

    /// Whether the active sentence sits between the nav bar and the player
    /// bar. A sentence taller than the band can't clear the player; only its
    /// top is held to the rule.
    private func voiceIsInView(_ app: XCUIApplication) -> Bool {
        guard let frame = activeSentenceFrame(app) else { return false }
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = chapterLine(app).frame.minY
        guard frame.minY >= top - 1 else { return false }
        return frame.maxY <= bottom + 1 || frame.height > (bottom - top) * 0.52
    }

    /// Re-checks `condition` for up to `seconds`.
    private func holds(within seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    private func pause(_ seconds: TimeInterval, _ reason: String) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: reason)], timeout: seconds)
    }

    /// The playhead and the active sentence's frame from one moment. The
    /// frame probe redraws a beat after the playhead probe, so a single pair
    /// can mix two sentences: the reading counts only when two reads of
    /// each agree. Nil when they don't, or a probe is missing.
    private func steadySample(_ app: XCUIApplication) -> (sentence: Int, frame: CGRect)? {
        guard let sentence = currentSentence(app), let frame = activeSentenceFrame(app),
              currentSentence(app) == sentence, activeSentenceFrame(app) == frame else { return nil }
        return (sentence, frame)
    }

    /// The active sentence's frame, once its probe has drawn.
    private func waitForActiveFrame(_ app: XCUIApplication) -> CGRect? {
        _ = app.descendants(matching: .any)["reader.activeSentence"].firstMatch.waitForExistence(timeout: 5)
        return activeSentenceFrame(app)
    }

    /// How fast the text is moving, in points per second, from two reads of
    /// the active sentence's frame. With the playhead held, that frame moves
    /// only with the text. Nil while the probe is missing.
    private func textSpeed(_ app: XCUIApplication) -> CGFloat? {
        guard let first = activeSentenceFrame(app) else { return nil }
        let firstRead = Date()
        pause(0.1, "let the text move")
        guard let second = activeSentenceFrame(app) else { return nil }
        let seconds = max(Date().timeIntervalSince(firstRead), 0.001)
        return abs(second.minY - first.minY) / CGFloat(seconds)
    }

    /// Just inside the column's left inset (ReaderUITextView.layoutSubviews),
    /// at screen height `y`: a tap there lands on the first character of
    /// whatever line is there, where mid-column can miss a short line.
    private func lineStart(atY y: CGFloat, in app: XCUIApplication) -> XCUICoordinate {
        let text = app.textViews["reader.text"].firstMatch
        let frame = text.frame
        let inset = max(24, (frame.width - 640) / 2)
        return text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: inset + 3, dy: y - frame.minY))
    }

    // MARK: - Tap to play (R15)

    /// The tap target: chapter I's second paragraph. It is sentence 2, after
    /// the "I" heading (0) and "In my younger…" (1)
    /// (TextExtractorTests.testGutenbergFrontMatterExcluded). It is its
    /// paragraph's only sentence, so every line it covers is its own.
    private static let tapTarget = "Whenever you feel like criticizing"

    /// The active sentence's frame once the text is at rest: two steady
    /// readings 0.3 s apart that agree. Nil if the playhead leaves `sentence`
    /// or the text never settles.
    private func restingFrame(of sentence: Int, in app: XCUIApplication,
                              timeout: TimeInterval = 5) -> CGRect? {
        var previous: CGRect?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reading = steadySample(app), reading.sentence == sentence {
                if reading.frame == previous { return reading.frame }
                previous = reading.frame
            } else {
                previous = nil
            }
            pause(0.3, "let the text come to rest")
        }
        return nil
    }

    /// A tap at screen point `point`, on the reading column.
    private func textCoordinate(_ point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
        let text = app.textViews["reader.text"].firstMatch
        return text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - text.frame.minX, dy: point.y - text.frame.minY))
    }

    func testTappingTheTextWhilePausedPlaysFromThere() throws {
        // The seek hook cues the target, so its index and its place on the
        // page are known from the app before any tap. Nothing here relies on
        // a tap to say which sentence was hit.
        let app = openGatsby(["-uitest-seek-text", Self.tapTarget])
        let play = playButton(app)
        XCTAssertEqual(stringValue(of: play), "paused", "No autoplay in this launch")
        let target = try XCTUnwrap(waitForSentence(in: app, timeout: 10) { $0 > 0 },
                                   "The seek hook should cue '\(Self.tapTarget)'")

        // The open put it on the landing line. Scrolled back by hand to the
        // top of the book, it sits where a plain open draws it. Measured only
        // when no follow scroll moved the text in the meantime.
        let text = app.textViews["reader.text"].firstMatch
        var measured: CGRect?
        for _ in 0..<3 where measured == nil {
            let scrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should exist")
            text.swipeDown()
            text.swipeDown()
            let frame = restingFrame(of: target, in: app)
            if followScrollCount(app) == scrolls { measured = frame }
        }
        let targetFrame = try XCTUnwrap(measured, "Sentence \(target) should come to rest at the top of the book")

        // Chapter I's start through Contents, not the text. Chapter I's
        // heading never fits the band, so the jump always lands at the top of
        // the book, where the target was measured.
        pickChapter(row: 1, in: app)
        let start = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 != target },
                                  "Contents should move the playhead to chapter I's start")
        XCTAssertGreaterThanOrEqual(target, start + 2,
                                    "Sentence \(target) must not be the next one after the playhead (\(start)): "
                                        + "a natural advance would pass for the tap")
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 5), "A chapter pick while paused stays paused")
        let startFrame = try XCTUnwrap(restingFrame(of: start, in: app), "Sentence \(start) should come to rest")
        XCTAssertLessThan(startFrame.maxY, targetFrame.minY,
                          "Sentence \(start) at \(startFrame) should sit above sentence \(target) at \(targetFrame)")
        let startScrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should exist")

        // The target's first line, mid-column.
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = chapterLine(app).frame.minY
        let point = CGPoint(x: targetFrame.midX, y: targetFrame.minY + 10)
        XCTAssertTrue((top + 4...bottom - 4).contains(point.y),
                      "Sentence \(target)'s first line should be on screen, at \(targetFrame)")
        textCoordinate(point, in: app).tap()

        // The first sentence after the tap is exactly the tapped one. Playing
        // from the playhead would show start + 1 first, and a jump to a
        // neighbouring sentence would show target - 1 or target + 1.
        let tapped = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 != start },
                                   "The tap should move the playhead off \(start)")
        XCTAssertEqual(tapped, target, "Playback starts at the tapped sentence \(target), not \(tapped)")

        // R16: a sentence already in the band (18% to 70% of the space
        // between the bars) stays put. One outside it is brought into view.
        // The margins cover the band's own rounding. Read while the voice is
        // still on the target, which takes seconds to speak.
        let landed = try XCTUnwrap(restingFrame(of: target, in: app), "Sentence \(target) should come to rest")
        let height = bottom - top
        if targetFrame.minY >= top + 0.18 * height + 8, targetFrame.maxY <= top + 0.70 * height - 16 {
            XCTAssertEqual(followScrollCount(app), startScrolls, "A sentence already in the band stays put")
            XCTAssertEqual(landed.minY, targetFrame.minY, accuracy: 0.5,
                           "Sentence \(target) stays where it was tapped: \(targetFrame) became \(landed)")
        } else {
            XCTAssertTrue(voiceIsInView(app), "A tapped sentence outside the band is brought into view, at \(landed)")
        }
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 30),
                      "A tap plays in any state, got '\(stringValue(of: play))'")
    }

    /// Below this the coast may end before XCUITest's tap lands: from
    /// 300 pt/s, UIKit's normal deceleration still runs for over a second.
    private static let movingTextSpeed: CGFloat = 300

    func testATapRightAfterAFlingOnlyStopsTheScroll() throws {
        let app = openGatsby()
        let play = playButton(app)
        let start = try XCTUnwrap(waitForSentence(in: app, timeout: 10) { _ in true })
        XCTAssertNotNil(waitForActiveFrame(app), "The probe should frame sentence \(start)")
        let startScrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should exist")
        let text = app.textViews["reader.text"].firstMatch
        // Resolved before the fling, so nothing slows the tap once it moves.
        let target = lineStart(atY: text.frame.minY + 0.4 * text.frame.height, in: app)

        text.swipeUp(velocity: .fast)
        // XCUITest sometimes lets a fling settle before its next event: then
        // there is no moving text to tap, so skip rather than pass.
        let speed = try XCTUnwrap(textSpeed(app), "The probe should frame sentence \(start)")
        guard speed >= Self.movingTextSpeed else {
            throw XCTSkip("The fling had settled (\(Int(speed)) pt/s) before the tap could land")
        }
        target.tap()
        XCTAssertFalse(waitForValue(in: ["playing", "buffering"], of: play, timeout: 3),
                       "A tap on moving text only stops it, got '\(stringValue(of: play))'")
        XCTAssertEqual(currentSentence(app), start, "The playhead stays on \(start)")
        XCTAssertEqual(followScrollCount(app), startScrolls, "Nothing brought the text back to the voice")
        // And it did stop the coast where it was.
        let stopped = try XCTUnwrap(activeSentenceFrame(app))
        pause(1, "a coast would still be moving")
        XCTAssertEqual(activeSentenceFrame(app), stopped, "The text holds where the tap caught it")
    }

    // MARK: - Undo jump and the Follow chip (R15, R16)

    func testUndoJumpRestoresThePassageAndJumpsAlwaysBringTheTextAlong() throws {
        // Passage A: a sentence a page into chapter I.
        let app = openGatsby(["-uitest-seek-text", "unaffected scorn"])
        let play = playButton(app)
        let passage = try XCTUnwrap(waitForSentence(in: app, timeout: 10) { $0 > 0 },
                                    "The seek hook should cue chapter I")

        pickChapter(row: 3, in: app)
        XCTAssertNotNil(waitForSentence(in: app, timeout: 5) { $0 != passage }, "The chapter pick should move")
        let undo = app.buttons["reader.undoJump"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "A chapter jump offers Undo jump")
        undo.tap()
        XCTAssertTrue(waitForSentence(passage, in: app, timeout: 5), "Undo returns to passage \(passage)")
        XCTAssertEqual(stringValue(of: play), "paused", "Undo restores the paused state")
        XCTAssertTrue(waitForNonExistence(of: undo, timeout: 5), "The chip leaves once used")

        // An unused offer expires after 10 s.
        pickChapter(row: 3, in: app)
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForNonExistence(of: undo, timeout: 11), "The offer lasts 10 s")

        // Scrolled past the voice, the chip points back up at it.
        let text = app.textViews["reader.text"].firstMatch
        for _ in 0..<3 { text.swipeUp() }
        XCTAssertTrue(app.buttons["reader.followVoice.up"].firstMatch.waitForExistence(timeout: 5),
                      "The Follow chip should point up at the voice")

        // A deliberate jump always brings the text to its target.
        pickChapter(row: 5, in: app)
        XCTAssertTrue(holds(within: 0.5) { voiceIsInView(app) },
                      "The jump target should be in view, at \(String(describing: activeSentenceFrame(app)))")
    }

    // MARK: - Calm follow (R16)

    /// What the text did while the listener was scrolled away.
    private struct AwayWatch {
        var samples = 0
        /// Later steady readings of a sentence already read once.
        var compared = 0
        /// A sentence whose frame changed while it played: the offset moved.
        var moved: [String] = []
        /// The voice above the player bar: something brought the text to it.
        var inView: [String] = []
        var first: Int?
        var last: Int?
    }

    /// Steady readings for `seconds`. With the offset fixed, a sentence's
    /// frame holds for as long as it plays, so any offset change while a
    /// sentence plays shows as a moved frame, whether or not it went through
    /// the follow-scroll counter (handleLayout's correction doesn't).
    private func watchWhileAway(_ app: XCUIApplication, seconds: TimeInterval, barTop: CGFloat) -> AwayWatch {
        var watch = AwayWatch()
        var firstFrames: [Int: CGRect] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let reading = steadySample(app) else { continue }
            let (sentence, frame) = reading
            watch.samples += 1
            watch.first = watch.first ?? sentence
            watch.last = sentence
            if let earlier = firstFrames[sentence] {
                watch.compared += 1
                if abs(earlier.minY - frame.minY) > 0.5 || abs(earlier.minX - frame.minX) > 0.5 {
                    watch.moved.append("sentence \(sentence): \(earlier) became \(frame)")
                }
            } else {
                firstFrames[sentence] = frame
            }
            if frame.minY < barTop - 1 {
                watch.inView.append("sentence \(sentence) at \(frame)")
            }
        }
        return watch
    }

    func testCalmFollowStaysCalmAndWaitsForTheListener() throws {
        // A plist real: a bare "3" lands in the argument domain as a string,
        // which the Double read ignores, and 100 sentences at 1x overrun the
        // 600 s wait.
        let app = openGatsby(["-aloud.prefs.v1.rate", "<real>3</real>"], allowAutoplay: true)
        let play = playButton(app)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60),
                      "Opening the book should start it, got '\(stringValue(of: play))'")
        let start = try XCTUnwrap(currentSentence(app))
        let startScrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should exist")
        let startLine = try XCTUnwrap(activeLine(app), "The line probe should exist")

        var outOfView: [String] = []
        let reached = waitForSentence(in: app, timeout: 600) { sentence in
            if !voiceIsInView(app) {
                outOfView.append("sentence \(sentence) at \(String(describing: activeSentenceFrame(app)))")
            }
            return sentence >= start + 100
        }
        let endScrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should outlast the run")
        let endLine = try XCTUnwrap(activeLine(app), "The line probe should outlast the run")
        let measured = endScrolls - startScrolls
        let lines = endLine - startLine
        print("ListeningLoopUITests: \(measured) follow scrolls over 100 sentences (\(lines) lines) at 3x")
        XCTAssertNotNil(reached, "100 sentences should play")
        XCTAssertEqual(outOfView, [], "The voice never meets the nav bar or the player")
        XCTAssertGreaterThan(lines, 0, "100 sentences run down the column")
        // R16's budget: 15 or fewer follow scrolls per 100 lines read. Per
        // sentence it can't hold for long sentences at any band that lands
        // the voice in the same place.
        XCTAssertLessThanOrEqual(Double(measured) * 100 / Double(max(lines, 1)), 15,
                                 "\(measured) scrolls over \(lines) lines")

        // Scrolled back from the voice: nothing moves for 30 s.
        let text = app.textViews["reader.text"].firstMatch
        text.swipeDown()
        text.swipeDown()
        let follow = app.buttons["reader.followVoice.down"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 5), "The Follow chip should point down at the voice")
        let awayScrolls = try XCTUnwrap(followScrollCount(app), "The follow probe should exist")
        let barTop = chapterLine(app).frame.minY
        pause(3, "the swipes coast to rest")
        let away = watchWhileAway(app, seconds: 30, barTop: barTop)
        XCTAssertEqual(try XCTUnwrap(followScrollCount(app), "The follow probe should exist"), awayScrolls,
                       "No follow scroll while the listener is away")
        XCTAssertEqual(away.moved, [], "The offset holds: a sentence's frame never changes while it plays")
        XCTAssertEqual(away.inView, [], "The voice stays below the screen: nothing brings the text to it")
        XCTAssertGreaterThanOrEqual(away.compared, 1,
                                    "No sentence read twice, so the offset went unseen (\(away.samples) readings in 30 s)")
        let first = try XCTUnwrap(away.first, "No steady reading while away")
        XCTAssertGreaterThan(try XCTUnwrap(away.last), first, "The voice kept reading while the listener was away")
        XCTAssertTrue(["playing", "buffering"].contains(stringValue(of: play)), "Still reading")
        XCTAssertTrue(follow.exists, "Following never re-engages by itself")

        follow.tap()
        XCTAssertTrue(holds(within: 1) { voiceIsInView(app) },
                      "The Follow chip brings the voice back, at \(String(describing: activeSentenceFrame(app)))")
    }
}
