import XCTest

/// End-to-end proof that the Kokoro neural engine actually synthesizes and
/// plays: seeds a classic, points the app at a pre-downloaded model directory
/// (no network), picks the "Heart" neural voice in the Listening sheet, waits
/// through the warm-up, and asserts real playback — still on the neural voice
/// (a synthesis failure would auto-fall back to the system voice and fail the
/// final assert).
///
/// There is no per-book voice memory any more: the one app-wide voice
/// persists across launches, and -uitest-reset-voice-pref clears it, so every
/// run starts on the default.
final class KokoroPlaybackUITest: XCTestCase {

    /// Host-Mac directory holding model.onnx + voices.bin. The simulator
    /// runtime can read host paths, so the app uses it directly via the
    /// -uitest-kokoro-model-path debug hook (survives test-runner reinstalls).
    /// ListeningUITests uses the same model.
    static let modelDirectory =
        "/private/tmp/claude-501/-Users-davidxie-Library-CloudStorage-OneDrive-Personal-CS-Aloud--claude-worktrees-aloud-extension-review-3acd07/4577d8ff-d6c0-41ab-b12e-aec62982e34e/scratchpad/kokoro/kokoro-multi-lang-v1_0"

    override func setUp() {
        continueAfterFailure = false
    }

    func testKokoroHeartVoiceSynthesizesAndPlays() throws {
        guard FileManager.default.fileExists(
            atPath: Self.modelDirectory + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(Self.modelDirectory)")
        }

        let app = XCUIApplication.aloud([
            // A fresh library too, not just fresh listening prefs, so no
            // earlier run's state leaks into the seeded classic.
            "-uitest-reset-library",
            "-uitest-seed-first-classic",
            "-uitest-open-first-doc",
            "-uitest-reset-voice-pref",
            "-uitest-kokoro-model-path", Self.modelDirectory,
        ])
        app.launch()

        // Auto-opened reader.
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 20), "Reader should auto-open")

        // With the model installed and no stored preference, the default
        // voice is the deep neural narrator, Michael.
        let listeningChip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(listeningChip.waitForExistence(timeout: 10))
        XCTAssertTrue(listeningChip.label.contains("Michael"),
                      "Default voice with model installed should be Michael, got: \(listeningChip.label)")

        // Open the Listening sheet and pick the neural "Heart" voice.
        listeningChip.tap()

        let heartRow = app.buttons["voice.kokoro:af_heart"].firstMatch
        XCTAssertTrue(heartRow.waitForExistence(timeout: 10),
                      "Kokoro Heart voice should be listed (model installed)")
        let switchStart = Date()
        heartRow.tap()

        // The sheet stays open, and the pick re-speaks the cued sentence in
        // Heart once (muted): reaching "playing" proves neural synthesis,
        // warm-up included, and the audition hands back "paused".
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180),
                      "The pick should re-speak the cued sentence in Heart (warm-up included)")
        let secondsToAudible = Date().timeIntervalSince(switchStart)
        print("KOKORO-TIMING voice switch → playing: \(String(format: "%.1f", secondsToAudible)) s")
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 60),
                      "The audition should return to paused after its one sentence")

        dismissListeningSheet(app)
        XCTAssertTrue(playButton.isHittable || playButton.waitForExistence(timeout: 5))
        playButton.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 60),
                      "Neural playback should reach 'playing'")

        // Still the neural voice — a warm-up/synthesis failure would have
        // fallen back to the system voice and changed the chip label.
        XCTAssertTrue(listeningChip.label.contains("Heart"),
                      "Voice should still be Kokoro Heart, got: \(listeningChip.label)")

        // Skip ahead and confirm playback continues (the next clip may
        // buffer briefly while it synthesizes).
        let forward = app.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        forward.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 60),
                      "Playback should keep going after skipping forward")
        XCTAssertTrue(listeningChip.label.contains("Heart"),
                      "Voice should remain Kokoro Heart after skipping forward")
    }
}
