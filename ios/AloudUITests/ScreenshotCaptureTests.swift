import XCTest

/// Dev-only screenshot driver: walks library → reader → Listening sheet →
/// Aa sheet → sleep menu → Contents, and writes PNGs to the host directory named by the ALOUD_SHOTS_DIR
/// test-runner environment variable. Skipped entirely when the variable is
/// absent (i.e. in normal test runs).
///
/// Launches WITHOUT the kokoro-model-path override so the Listening sheet's
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
        let app = XCUIApplication.aloud([
            "-uitest-seed-first-classic",
            "-uitest-reset-voice-pref",   // fresh-install default: Michael at 1×
            "-uitest-reset-library",      // fresh shelf: grid card, no leftover hero
        ])
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

        // This launch doesn't autoplay, so start playback by hand.
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()
        // Default voice is neural Michael now — allow for engine warm-up.
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180))
        sleep(2)
        // Make sure the highlighted sentence is on-screen (a restored
        // position can leave the voice off screen with the Follow chip
        // showing; its identifier carries the arrow's direction).
        let followChip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "reader.followVoice")).firstMatch
        if followChip.exists {
            followChip.tap()
            sleep(2)
        }
        save(shot(), to: shotsDir + "/05-reader-bronze.png")

        // 06 — Listening sheet's voices (proves detectExisting() flipped to
        // .installed from the seeded container — no launch-arg model override
        // in this test): exactly 8 neural rows, one System row, and Michael as
        // the fresh-install default.
        let listeningChip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(listeningChip.waitForExistence(timeout: 5))
        // Michael is the default only once the natural voice is installed;
        // this capture needs a simulator seeded with the model, like
        // KokoroPlaybackUITest, and skips without one.
        guard listeningChip.label.contains("Michael") else {
            throw XCTSkip("The natural voice isn't installed in this simulator (got: \(listeningChip.label))")
        }
        listeningChip.tap()
        let michaelRow = app.buttons["voice.kokoro:am_michael"].firstMatch
        XCTAssertTrue(michaelRow.waitForExistence(timeout: 10),
                      "Neural section must be present — seeded container should detect as installed")
        sleep(1)   // sheet animation settle
        save(shot(), to: shotsDir + "/06-voice-sheet.png")

        // One scrolling detent holds the whole roster: exactly 8 neural rows
        // + 1 System row.
        let neuralRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'voice.kokoro:'"))
        XCTAssertEqual(neuralRows.count, 8,
                       "Curated roster must be exactly 8 neural voices")
        let systemRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'voice.' AND NOT (identifier BEGINSWITH 'voice.kokoro:')"))
        XCTAssertEqual(systemRows.count, 1,
                       "Exactly one System-voice row expected")

        // 07 (dark reader) is captured outside this test with
        // `xcrun simctl ui <udid> appearance dark` + a plain launch —
        // XCUIDevice.shared.appearance does not reliably restyle the app
        // on this runtime.
        dismissListeningSheet(app)

        // 08 — The same Listening sheet, for its speed numeral, presets and
        // slider.
        listeningChip.tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        save(shot(), to: shotsDir + "/08-speed-sheet.png")
        dismissListeningSheet(app)

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

        // 10 — The sleep chip's menu.
        let sleepChip = app.buttons["player.sleep"].firstMatch
        XCTAssertTrue(sleepChip.waitForExistence(timeout: 5))
        sleepChip.tap()
        sleep(1)
        save(shot(), to: shotsDir + "/10-sleep-menu.png")
        // Close the menu on the backdrop above it, without arming anything.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()

        // 11 — Skip-brackets demo: relaunch cued at a chapter-2 sentence with
        // an embedded parenthetical aside ("Just as Tom and Myrtle (after the
        // first drink …) reappeared, …"), which autoplays. The aside stays
        // visible and highlighted in the pill but is not spoken (skip is
        // default-on).
        app.terminate()
        let app2 = XCUIApplication.aloud([
            "-uitest-seed-first-classic",
            "-uitest-open-first-doc",
            "-uitest-seek-text", "after the first drink",
        ], allowAutoplay: true)
        app2.launch()
        let readerText2 = app2.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText2.waitForExistence(timeout: 20),
                      "Reader should auto-open on the seeded classic")
        let playButton2 = app2.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton2.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("playing", of: playButton2, timeout: 180),
                      "Playback should start on the parenthetical sentence")
        // Shoot immediately: the pill is on the parenthetical sentence right
        // as playback starts (later, accessibility snapshots force full text
        // layout and briefly shift content under the viewport).
        save(shot(), to: shotsDir + "/11-reader-skip-brackets.png")

        // 12 — Library with the Continue Listening hero card. The deep-seeked
        // position above created real progress, so leaving the reader
        // materializes the hero above the grid.
        playButton2.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton2, timeout: 10))
        tapSystemBack(app2)
        let hero = app2.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10),
                      "Continue Listening hero should appear once progress exists")
        sleep(2)   // cover art + layout settle
        save(shot(), to: shotsDir + "/12-continue-card.png")

        // 13 — Contents, opened from the chapter line. Enter through the hero
        // (autoplay), pause for a calm shot, then open Contents.
        hero.tap()
        XCTAssertTrue(readerText2.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForValue("playing", of: playButton2, timeout: 180),
                      "Continue card must start playback on its own")
        playButton2.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton2, timeout: 10))
        let chapterLine = app2.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 5))
        chapterLine.tap()
        let chapterRows = app2.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chapters.row.'"))
        XCTAssertTrue(chapterRows.firstMatch.waitForExistence(timeout: 10))
        sleep(1)   // sheet presentation + unanimated scroll settle
        save(shot(), to: shotsDir + "/13-chapter-drawer.png")

        // 14 — Search in the same Contents sheet, with live results ("Daisy"
        // is all over the seeded Gatsby). The field is pinned above the
        // chapters, so there is nothing to dismiss first.
        let searchField = app2.textFields["search.field"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        app2.typeText("Daisy")
        let matchCount = app2.staticTexts["search.count"].firstMatch
        XCTAssertTrue(matchCount.waitForExistence(timeout: 10),
                      "Debounced scan should surface a match count")
        sleep(1)
        save(shot(), to: shotsDir + "/14-search-sheet.png")
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
