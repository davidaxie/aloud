import XCTest

/// End-to-end proof that the Kokoro neural engine actually synthesizes and
/// plays: seeds a classic, points the app at a pre-downloaded model directory
/// (no network), switches to the "Heart" neural voice, waits through the
/// warm-up, and asserts real playback — still on the neural voice (a synthesis
/// failure would auto-fall back to the system voice and fail the final assert).
final class KokoroPlaybackUITest: XCTestCase {

    /// Host-Mac directory holding model.onnx + voices.bin. The simulator
    /// runtime can read host paths, so the app uses it directly via the
    /// -uitest-kokoro-model-path debug hook (survives test-runner reinstalls).
    private static let modelDirectory =
        "/private/tmp/claude-501/-Users-davidxie-Library-CloudStorage-OneDrive-Personal-CS-Aloud--claude-worktrees-aloud-extension-review-3acd07/4577d8ff-d6c0-41ab-b12e-aec62982e34e/scratchpad/kokoro/kokoro-multi-lang-v1_0"

    override func setUp() {
        continueAfterFailure = false
    }

    func testKokoroHeartVoiceSynthesizesAndPlays() throws {
        guard FileManager.default.fileExists(
            atPath: Self.modelDirectory + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(Self.modelDirectory)")
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-seed-first-classic",
            "-uitest-open-first-doc",
            "-uitest-reset-voice-pref",
            "-uitest-kokoro-model-path", Self.modelDirectory,
        ]
        app.launch()

        // Auto-opened reader.
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 20), "Reader should auto-open")

        // With the model installed and no stored preference, the default
        // voice is the deep neural narrator, Michael.
        let voiceChip = app.buttons["player.voice"].firstMatch
        XCTAssertTrue(voiceChip.waitForExistence(timeout: 10))
        XCTAssertTrue(voiceChip.label.contains("Michael"),
                      "Default voice with model installed should be Michael, got: \(voiceChip.label)")

        // Open the voice sheet and pick the neural "Heart" voice.
        voiceChip.tap()

        let heartRow = app.buttons["voice.kokoro:af_heart"].firstMatch
        XCTAssertTrue(heartRow.waitForExistence(timeout: 10),
                      "Kokoro Heart voice should be listed (model installed)")
        let switchStart = Date()
        heartRow.tap()

        // Sheet dismisses on selection; start playback. Warm-up (model load +
        // graph build) can take a while on first run — wait generously.
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(playButton.isHittable || playButton.waitForExistence(timeout: 5))
        playButton.tap()

        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180),
                      "Neural playback should reach 'playing' (warm-up included)")
        let secondsToAudible = Date().timeIntervalSince(switchStart)
        print("KOKORO-TIMING voice switch → playing: \(String(format: "%.1f", secondsToAudible)) s")

        // Still the neural voice — a warm-up/synthesis failure would have
        // fallen back to the system voice and changed the chip label.
        XCTAssertTrue(voiceChip.label.contains("Heart"),
                      "Voice should still be Kokoro Heart, got: \(voiceChip.label)")

        // Advance a sentence and confirm playback continues (next clip may
        // buffer briefly while it synthesizes).
        let next = app.buttons["player.next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 60),
                      "Playback should keep going after advancing a sentence")
        XCTAssertTrue(voiceChip.label.contains("Heart"),
                      "Voice should remain Kokoro Heart after advancing")
    }

    // MARK: - Helpers

    private func waitForValue(_ expected: String, of element: XCUIElement,
                              timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
