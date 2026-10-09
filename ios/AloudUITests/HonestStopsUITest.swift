import XCTest

/// R11 end to end: every stop the listener didn't ask for names its reason
/// on the chapter line, is still naming it a minute later, is announced, and
/// one tap plays on from the same place; every change they didn't ask for
/// shows its notice while the audio continues.
///
/// Faults come from the app's DEBUG hooks: `-uitest-fault <kind>` fires 3 s
/// into playback (`-uitest-fault-after 3`). Route changes and interruptions
/// are posted the way iOS posts them, synthesis fails on cue, and the thermal
/// state is set; iOS closing the app is a live-session marker seeded before
/// launch. Every launch goes through XCUIApplication.aloud, so it is muted.
/// Never run without the user's OK.
final class HonestStopsUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// A fresh shelf with one classic, opened and speaking. The offer reset
    /// keeps the natural-voice offer out of the chapter line.
    private static let book = ["-uitest-reset-library", "-uitest-seed-first-classic",
                               "-uitest-open-first-doc", "-uitest-reset-natural-voice-offer"]
    /// No model: the System voice starts without a warm-up.
    private static let systemVoice = book + ["-uitest-temp-model-dir"]

    private func launch(fault: String, _ arguments: [String] = systemVoice) -> XCUIApplication {
        let app = XCUIApplication.aloud(arguments + ["-uitest-fault", fault, "-uitest-fault-after", "3"],
                                        allowAutoplay: true)
        app.launch()
        return app
    }

    /// Michael, from the host's model files (no download); skips without them.
    private func launchNaturalVoice(fault: String) throws -> XCUIApplication {
        let model = KokoroPlaybackUITest.modelDirectory
        guard FileManager.default.fileExists(atPath: model + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(model)")
        }
        return launch(fault: fault, Self.book + ["-uitest-reset-voice-pref", "-uitest-kokoro-model-path", model])
    }

    // MARK: - Stopped

    func testHeadphonesDisconnectedStopsWithItsReason() {
        assertStopsHonestly(fault: "route", reason: "Paused, headphones disconnected")
    }

    func testAnInterruptionThatNeverGivesTheAudioBackStopsWithItsReason() {
        assertStopsHonestly(fault: "interruption", reason: "Paused by a call or another app")
    }

    func testASynthesisFailureStopsWithTryAgain() {
        assertStopsHonestly(fault: "synthesis", reason: "Playback stopped, tap to try again",
                            stoppedValue: NSPredicate(format: "value CONTAINS 'stopped'"), playLabel: "Try again")
    }

    func testCriticalHeatStopsWithItsReason() {
        assertStopsHonestly(fault: "thermal-critical", reason: "Paused, iPhone is too hot")
    }

    func testIOSClosingAloudMidListenIsReportedAtTheNextLaunch() {
        // Launch 1: listening progress, so the Library has a Continue card.
        let first = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-first-classic",
                                           "-uitest-open-first-doc", "-uitest-temp-model-dir"])
        first.launch()
        let forward = first.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 20), "The reader should open")
        for _ in 0..<3 { forward.tap() }
        XCTAssertNotNil(waitForSentence(in: first, timeout: 10) { $0 > 0 }, "Skipping forward moves the playhead")
        idle(4)   // the shelf writes progress 2 s behind
        first.terminate()

        // Launch 2: the live-session marker iOS leaves when it ends the app
        // mid-sentence. No autoplay, so opening the book keeps the reason up.
        let app = XCUIApplication.aloud(["-uitest-seed-live-session", "-uitest-temp-model-dir"])
        app.launch()
        let closed = "Stopped when iOS closed Aloud"
        let card = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The book with progress is the Continue card")
        XCTAssertTrue(wait(for: NSPredicate(format: "value CONTAINS %@", closed), card, timeout: 10),
                      "The card mirrors the reason, got '\(stringValue(of: card))'")
        XCTAssertTrue(waitForAnnouncement(closed, in: app, timeout: 10), "VoiceOver hears '\(closed)'")

        card.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", closed), chapterLine(app), timeout: 20),
                      "The chapter line names the reason, got '\(chapterLine(app).label)'")
        let play = playButton(app)
        play.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 30),
                      "One tap plays, got '\(stringValue(of: play))'")
    }

    // MARK: - Recovered or changed

    func testAnInterruptionThatGivesTheAudioBackResumesWithoutAReason() {
        let app = launch(fault: "interruption-resume")
        let play = playButton(app)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The book should start playing")
        // The interruption holds the audio for one second.
        XCTAssertTrue(sawValue("paused", of: play, within: 15), "The interruption should pause playback")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 5),
                      "The audio comes back on its own within 5 s")

        let line = chapterLine(app)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertFalse(line.label.hasPrefix("Paused"), "No reason once the audio is back, got '\(line.label)'")
            idle(0.25)
        }
        XCTAssertFalse(announcements(app).contains("Paused by a call or another app"),
                       "An interruption that gave the audio back is never announced")
    }

    func testAnUnreadableSentenceIsSkippedWhilePlaying() {
        let app = launch(fault: "skip")
        let play = playButton(app)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The book should start playing")
        let skipped = "Skipped a sentence the voice couldn\u{2019}t read"
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", skipped), chapterLine(app), timeout: 60),
                      "The chapter line shows the notice, got '\(chapterLine(app).label)'")
        XCTAssertEqual(stringValue(of: play), "playing", "The audio continues under the notice")
        XCTAssertTrue(waitForAnnouncement(skipped, in: app, timeout: 5))
    }

    func testANaturalVoiceFailureFallsBackToSystemWhilePlaying() throws {
        let app = try launchNaturalVoice(fault: "warmup")
        let fellBack = "Natural voice unavailable, using System"
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", fellBack), chapterLine(app), timeout: 120),
                      "The chapter line shows the fallback, got '\(chapterLine(app).label)'")
        XCTAssertTrue(waitForValue("playing", of: playButton(app), timeout: 8),
                      "The System voice reads on while the notice shows")
        XCTAssertTrue(listeningChip(app).label.hasPrefix("System"), "got '\(listeningChip(app).label)'")
        XCTAssertTrue(waitForAnnouncement(fellBack, in: app, timeout: 5))
    }

    func testHeatSwitchesToTheSystemVoiceWhilePlaying() throws {
        let app = try launchNaturalVoice(fault: "thermal-serious")
        let chip = listeningChip(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        XCTAssertTrue(chip.label.hasPrefix("Michael"), "With the model, the default voice is Michael, got '\(chip.label)'")
        let play = playButton(app)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 180), "Michael should start (warm-up included)")

        let cooling = "Using the System voice while iPhone cools"
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", cooling), chapterLine(app), timeout: 60),
                      "The chapter line shows the cooling notice, got '\(chapterLine(app).label)'")
        XCTAssertEqual(stringValue(of: play), "playing", "The switch never stops the audio")
        XCTAssertTrue(chip.label.hasPrefix("System"), "got '\(chip.label)'")
        XCTAssertTrue(waitForAnnouncement(cooling, in: app, timeout: 5))
    }

    // MARK: - Helpers

    /// Plays, lets the fault stop playback, and checks the reason a minute
    /// later: on the chapter line, announced, the playhead unmoved, and one
    /// tap playing on from that sentence (or the one after, if the sentence
    /// was ending; never a rewind or a restart).
    private func assertStopsHonestly(fault: String, reason: String,
                                     stoppedValue: NSPredicate = NSPredicate(format: "value == 'paused'"),
                                     playLabel: String = "Play",
                                     file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(fault: fault)
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 20), "The reader should open", file: file, line: line)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The book should start playing",
                      file: file, line: line)
        XCTAssertTrue(wait(for: stoppedValue, play, timeout: 60),
                      "The fault should stop playback, got '\(stringValue(of: play))'", file: file, line: line)
        XCTAssertEqual(play.label, playLabel, file: file, line: line)
        XCTAssertTrue(waitForAnnouncement(reason, in: app, timeout: 10), "VoiceOver hears '\(reason)'",
                      file: file, line: line)
        let stoppedAt = currentSentence(app)
        XCTAssertNotNil(stoppedAt, file: file, line: line)

        idle(60)
        XCTAssertEqual(chapterLine(app).label, reason, "The reason holds until the next Play", file: file, line: line)
        XCTAssertTrue(stoppedValue.evaluate(with: play), "Still stopped, got '\(stringValue(of: play))'",
                      file: file, line: line)
        XCTAssertEqual(currentSentence(app), stoppedAt, file: file, line: line)

        play.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 30),
                      "One tap plays, got '\(stringValue(of: play))'", file: file, line: line)
        if let stoppedAt, let resumed = currentSentence(app) {
            XCTAssertTrue((stoppedAt...stoppedAt + 1).contains(resumed),
                          "Resumed at \(resumed), stopped at \(stoppedAt)", file: file, line: line)
        }
        XCTAssertTrue(wait(for: NSPredicate(format: "label != %@", reason), chapterLine(app), timeout: 10),
                      "Play clears the reason", file: file, line: line)
    }

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.play"].firstMatch
    }

    private func chapterLine(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reader.chapterLine"].firstMatch
    }

    private func listeningChip(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.listening"].firstMatch
    }

    private func wait(for predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Re-reads as fast as snapshots allow: for a state that lasts about a
    /// second, which a predicate expectation's polling can miss.
    private func sawValue(_ value: String, of element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stringValue(of: element) == value { return true }
        }
        return false
    }

    /// Lets the app run for `seconds` (an expectation nobody fulfils).
    private func idle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "idle")], timeout: seconds)
    }
}
