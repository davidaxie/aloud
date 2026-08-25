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

    func testCaptureScreens() throws {
        // Opt-in via env var, or — since TEST_RUNNER_ env passthrough is
        // unreliable — via a host-side marker file next to the shots
        // (the simulator runtime reads host Mac paths directly, same
        // mechanism KokoroPlaybackUITest uses for the model directory):
        // the marker file's contents are the absolute shots directory path.
        let markerPath = "/private/tmp/aloud-shots-request.txt"
        let requested = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"]
            ?? (try? String(contentsOfFile: markerPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let shotsDir = requested, !shotsDir.isEmpty else {
            throw XCTSkip("ALOUD_SHOTS_DIR not set and no marker file — screenshot capture is opt-in")
        }

        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-seed-first-classic"]
        app.launch()

        // 04 — Library with the seeded classic card.
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        sleep(2)   // let cover art and layout settle
        save(shot(), to: shotsDir + "/04-library-bronze.png")

        // 05 — Reader, playing (sentence highlight + player bar).
        card.tap()
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 15))
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 20))
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

        // 06 — Voice sheet with the neural section (proves detectExisting()
        // flipped to .installed from the seeded container — no launch-arg
        // model override in this test).
        let voiceChip = app.buttons["player.voice"].firstMatch
        XCTAssertTrue(voiceChip.waitForExistence(timeout: 5))
        voiceChip.tap()
        let heartRow = app.buttons["voice.kokoro:af_heart"].firstMatch
        XCTAssertTrue(heartRow.waitForExistence(timeout: 10),
                      "Neural section must be present — seeded container should detect as installed")
        sleep(1)   // sheet animation settle
        save(shot(), to: shotsDir + "/06-voice-sheet.png")

        // 07 (dark reader) is captured outside this test with
        // `xcrun simctl ui <udid> appearance dark` + a plain launch —
        // XCUIDevice.shared.appearance does not reliably restyle the app
        // on this runtime.
        app.swipeDown(velocity: .fast)   // dismiss the sheet
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
    }

    // MARK: - Helpers

    private func shot() -> Data {
        XCUIScreen.main.screenshot().pngRepresentation
    }

    private func save(_ data: Data, to path: String) {
        XCTAssertNoThrow(try data.write(to: URL(fileURLWithPath: path)),
                         "Should write screenshot to \(path)")
    }

    private func waitForValue(_ expected: String, of element: XCUIElement,
                              timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
