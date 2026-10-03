import XCTest

/// M12 end to end on the Mac: every stop the listener didn't ask for names
/// its reason on the chapter line, still names it after a while, is
/// recorded for VoiceOver, and one click on Play goes on from the sentence
/// it stopped at. The causes: the headphones going away, the Mac going to
/// sleep, a synthesis failure, critical heat, and Aloud quitting mid-speech.
///
/// Faults come from the app's DEBUG hooks: `-uitest-fault <kind>` fires 3 s
/// into playback (`-uitest-fault-after 3`). A lost route goes through the
/// live `MacAudioOutputMonitor` as a private device giving way to a public
/// one, synthesis fails on cue, and the thermal state is set; quitting
/// mid-speech is a live-session marker seeded before launch. Every launch
/// goes through `XCUIApplication.aloud`, so it is muted; autoplay is allowed
/// so the book is speaking when the fault lands. Runs only in the consented
/// `AloudMacUI` scheme.
final class MacStopsUITests: XCTestCase {

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

    // MARK: - Injected causes

    func testHeadphonesDisconnectedStopsWithItsReason() {
        assertStopsHonestly(fault: "route", reason: "Paused, headphones disconnected")
    }

    /// `will-sleep` posts the workspace's willSleep notification in the app,
    /// as the system does; the Mac itself stays awake.
    func testTheMacGoingToSleepStopsWithItsReason() {
        assertStopsHonestly(fault: "will-sleep", reason: "Paused, your Mac went to sleep")
    }

    func testASynthesisFailureStopsWithTryAgain() {
        assertStopsHonestly(fault: "synthesis", reason: "Playback stopped",
                            stopped: ["stopped, playback error"], playLabel: "Try again")
    }

    func testCriticalHeatStopsWithItsReason() {
        assertStopsHonestly(fault: "thermal-critical", reason: "Paused, your Mac is too hot")
    }

    // MARK: - Quit mid-speech

    func testQuittingMidListenIsReportedAtTheNextLaunch() {
        // Launch 1: a book on the shelf. The live-session hook marks the
        // library's first book when the model is built, before launch-time
        // seeding, so it needs a second launch.
        let seed = XCUIApplication.aloud(MacSuite.fresh + ["-uitest-seed-first-classic"])
        app = seed
        launchAloud(seed)
        XCTAssertTrue(MacSuite(app: seed).element("library.card").waitForExistence(timeout: 30),
                      "the seeded classic is on the shelf")
        seed.terminate()

        // Launch 2: the marker a crash or a force quit leaves mid-sentence.
        // No autoplay, so opening the book keeps the reason up.
        let app = XCUIApplication.aloud(["-uitest-seed-live-session", "-uitest-temp-model-dir"])
        self.app = app
        launchAloud(app)
        let suite = MacSuite(app: app)
        let reason = "Stopped when Aloud quit unexpectedly"
        let card = suite.element("library.continue")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the book with progress is the Continue card")
        XCTAssertTrue(suite.poll(timeout: 10) { suite.text(card).contains(reason) },
                      "the card mirrors the reason, got '\(suite.text(card))'")
        XCTAssertTrue(suite.poll(timeout: 10) { suite.announcements.contains(reason) }, "VoiceOver hears '\(reason)'")

        card.click()
        let line = suite.element("reader.chapterLine")
        XCTAssertTrue(suite.poll(timeout: 20) { line.exists && line.label == reason },
                      "the chapter line names the reason, got '\(line.label)'")
        XCTAssertEqual(suite.playValue, "paused", "a UI-test launch never autoplays")
        suite.play.click()
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 30),
                      "one click plays, got '\(suite.playValue ?? "nil")'")
        XCTAssertTrue(suite.poll(timeout: 10) { line.label != reason }, "Play clears the reason")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - Helpers

    /// Plays The Cask of Amontillado, lets the fault stop it, then checks the
    /// reason on the chapter line, its announcement, that it and the
    /// playhead hold for 15 s, and that one click on Play goes on from the
    /// stopped sentence (or the next, if that one was ending; never a rewind
    /// or a restart) and clears the reason.
    private func assertStopsHonestly(fault: String, reason: String, stopped: Set<String> = ["paused"],
                                     playLabel: String = "Play",
                                     file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication.aloud(MacSuite.firstClassicReader + ["-uitest-fault", fault,
                                                                        "-uitest-fault-after", "3"],
                                        allowAutoplay: true)
        self.app = app
        launchAloud(app, file: file, line: line)
        let suite = MacSuite(app: app)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "the reader opens", file: file, line: line)
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60), "the book starts playing", file: file, line: line)
        XCTAssertTrue(suite.waitForPlay(stopped, timeout: 60),
                      "the fault stops playback, got '\(suite.playValue ?? "nil")'", file: file, line: line)
        XCTAssertEqual(suite.play.label, playLabel, file: file, line: line)

        let chapterLine = suite.element("reader.chapterLine")
        XCTAssertTrue(suite.poll(timeout: 10) { chapterLine.label == reason },
                      "the chapter line names the reason, got '\(chapterLine.label)'", file: file, line: line)
        XCTAssertTrue(suite.poll(timeout: 10) { suite.announcements.contains(reason) },
                      "VoiceOver hears '\(reason)'", file: file, line: line)
        let stoppedAt = suite.playhead
        XCTAssertNotNil(stoppedAt, file: file, line: line)

        // The reason is a state, not a toast: it holds until the next Play.
        suite.idle(15)
        XCTAssertEqual(chapterLine.label, reason, "the reason holds until the next Play", file: file, line: line)
        XCTAssertTrue(stopped.contains(suite.playValue ?? ""), "still stopped", file: file, line: line)
        XCTAssertEqual(suite.playhead, stoppedAt, "the playhead holds", file: file, line: line)

        suite.play.click()
        XCTAssertTrue(suite.waitForPlay(["playing", "buffering"], timeout: 30),
                      "one click plays, got '\(suite.playValue ?? "nil")'", file: file, line: line)
        if let stoppedAt, let resumed = suite.playhead {
            XCTAssertTrue((stoppedAt...stoppedAt + 1).contains(resumed),
                          "resumed at \(resumed), stopped at \(stoppedAt)", file: file, line: line)
        }
        XCTAssertTrue(suite.poll(timeout: 10) { chapterLine.label != reason }, "Play clears the reason",
                      file: file, line: line)
        XCTAssertEqual(suite.beeps, 0, file: file, line: line)
    }
}
