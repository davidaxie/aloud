import XCTest

/// Dev-only screenshot driver: walks library → reader → voice sheet → dark
/// reader and writes PNGs to the host directory named by the ALOUD_SHOTS_DIR
/// test-runner environment variable. Skipped entirely when the variable is
/// absent (i.e. in normal test runs).
///
/// Launches WITHOUT the kokoro-model-path override so the voice sheet's
/// neural section doubles as proof that ModelManager.detectExisting() finds
/// the files seeded into the app container.
final class ScreenshotCaptureTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Host-side marker file the screenshot RUNNER writes immediately before
    /// each capture invocation (fallback for when TEST_RUNNER_ env
    /// passthrough is unreliable): its contents are the absolute shots
    /// directory path. Per-invocation intent, not machine state — the test
    /// consumes (deletes) it on read, and ignores markers older than
    /// 30 minutes so a stale leftover can never silently convert a normal
    /// test run into a screenshot run.
    private static let markerPath = "/private/tmp/aloud-shots-request.txt"
    private static let markerMaxAge: TimeInterval = 30 * 60

    func testCaptureScreens() throws {
        // Opt-in via env var (preferred: TEST_RUNNER_ALOUD_SHOTS_DIR on the
        // xcodebuild invocation), or via the fresh host-side marker file
        // (the simulator runtime reads host Mac paths directly, same
        // mechanism KokoroPlaybackUITest uses for the model directory).
        let requested = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"]
            ?? Self.consumeMarker()
        guard let shotsDir = requested, !shotsDir.isEmpty else {
            throw XCTSkip("ALOUD_SHOTS_DIR not set and no fresh marker file — screenshot capture is opt-in")
        }

        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-seed-first-classic",
            "-uitest-reset-voice-pref",   // fresh-install default: Michael
        ]
        app.launch()

        // 04 — Library with the seeded classic card.
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        sleep(2)   // let cover art and layout settle
        save(shot(), to: shotsDir + "/04-library-bronze.png")

        // 05 — Reader, playing: the calm sentence pill ONLY (word highlight
        // is off by default — no per-word emphasis anywhere in the shot).
        card.tap()
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 15))

        // Normalize leftover container state: pin the rate to 1× so every
        // shot (player chip, speed sheet, time-left) is stable across runs.
        let speedChipEarly = app.buttons["player.speed"].firstMatch
        XCTAssertTrue(speedChipEarly.waitForExistence(timeout: 5))
        if !speedChipEarly.label.contains("1×") {
            speedChipEarly.tap()
            let preset = app.buttons["1×"].firstMatch
            XCTAssertTrue(preset.waitForExistence(timeout: 5))
            preset.tap()
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(readerText.waitForExistence(timeout: 10))
        }

        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()
        // Default voice is neural Michael now — allow for engine warm-up.
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180))
        sleep(2)
        // Make sure the highlighted sentence is on-screen (a restored
        // position can leave the auto-scroll mid-flight with the
        // "Return to playhead" chip showing).
        let returnChip = app.buttons["Return to playhead"].firstMatch
        if returnChip.exists {
            returnChip.tap()
            sleep(2)
        }
        save(shot(), to: shotsDir + "/05-reader-bronze.png")

        // 06 — Curated voice sheet (proves detectExisting() flipped to
        // .installed from the seeded container — no launch-arg model override
        // in this test): exactly 8 neural rows, one System-voice footer, and
        // Michael as the fresh-install default.
        let voiceChip = app.buttons["player.voice"].firstMatch
        XCTAssertTrue(voiceChip.waitForExistence(timeout: 5))
        XCTAssertTrue(voiceChip.label.contains("Michael"),
                      "Fresh-install default voice should be Michael, got: \(voiceChip.label)")
        voiceChip.tap()
        let michaelRow = app.buttons["voice.kokoro:am_michael"].firstMatch
        XCTAssertTrue(michaelRow.waitForExistence(timeout: 10),
                      "Neural section must be present — seeded container should detect as installed")
        sleep(1)   // sheet animation settle
        save(shot(), to: shotsDir + "/06-voice-sheet.png")

        // Expand to the large detent so the whole curated roster is in the
        // hierarchy, then pin it: exactly 8 neural rows + 1 system footer row.
        app.swipeUp()   // medium → large detent
        sleep(1)
        let neuralRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'voice.kokoro:'"))
        XCTAssertEqual(neuralRows.count, 8,
                       "Curated roster must be exactly 8 neural voices")
        let systemRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'voice.' AND NOT (identifier BEGINSWITH 'voice.kokoro:') AND NOT (identifier BEGINSWITH 'voice.preview.')"))
        XCTAssertEqual(systemRows.count, 1,
                       "Exactly one System-voice footer row expected")

        // 07 (dark reader) is captured outside this test with
        // `xcrun simctl ui <udid> appearance dark` + a plain launch —
        // XCUIDevice.shared.appearance does not reliably restyle the app
        // on this runtime.
        app.swipeDown(velocity: .fast)   // large → medium (or straight out)
        if michaelRow.exists {
            app.swipeDown(velocity: .fast)   // medium → dismissed
        }
        XCTAssertTrue(readerText.waitForExistence(timeout: 10))

        // 08 — Speed sheet (large slider + presets + live time-left).
        let speedChip = app.buttons["player.speed"].firstMatch
        XCTAssertTrue(speedChip.waitForExistence(timeout: 5))
        speedChip.tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        save(shot(), to: shotsDir + "/08-speed-sheet.png")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(readerText.waitForExistence(timeout: 10))

        // 09 — Aa appearance sheet (text size + scheme).
        let aaButton = app.buttons["reader.appearance"].firstMatch
        XCTAssertTrue(aaButton.waitForExistence(timeout: 5))
        aaButton.tap()
        XCTAssertTrue(app.buttons["appearance.scheme.system"].firstMatch
            .waitForExistence(timeout: 10))
        sleep(1)
        save(shot(), to: shotsDir + "/09-appearance-sheet.png")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(readerText.waitForExistence(timeout: 10))

        // 10 — Sleep timer menu under "…".
        let moreButton = app.buttons["reader.more"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        sleep(1)
        save(shot(), to: shotsDir + "/10-sleep-menu.png")

        // 11 — Skip-brackets demo: relaunch cued at a chapter-2 sentence with
        // an embedded parenthetical aside ("Just as Tom and Myrtle (after the
        // first drink …) reappeared, …") and play it. The aside stays visible
        // and highlighted in the pill but is not spoken (skip is default-on).
        app.terminate()
        let app2 = XCUIApplication()
        app2.launchArguments += [
            "-uitest-seed-first-classic",
            "-uitest-open-first-doc",
            "-uitest-seek-text", "after the first drink",
        ]
        app2.launch()
        let readerText2 = app2.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText2.waitForExistence(timeout: 20),
                      "Reader should auto-open on the seeded classic")
        let playButton2 = app2.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton2.waitForExistence(timeout: 10))
        sleep(2)   // let the deep-seek centering settle while cued
        playButton2.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton2, timeout: 180),
                      "Playback should start on the parenthetical sentence")
        // Shoot immediately: the pill is on the parenthetical sentence right
        // as playback starts (later, accessibility snapshots force full text
        // layout and briefly shift content under the viewport).
        save(shot(), to: shotsDir + "/11-reader-skip-brackets.png")
    }

    // MARK: - Helpers

    /// Read-and-delete the runner's marker file. Deleting even a stale
    /// marker keeps the machine clean; only a fresh one opts in.
    private static func consumeMarker() -> String? {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: markerPath),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        defer { try? fm.removeItem(atPath: markerPath) }   // consume on read
        guard Date().timeIntervalSince(modified) < markerMaxAge else { return nil }
        return (try? String(contentsOfFile: markerPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shot() -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }

    private func save(_ data: Data, to path: String) {
        XCTAssertNoThrow(try data.write(to: URL(fileURLWithPath: path)),
                         "Should write screenshot to \(path)")
    }
}
