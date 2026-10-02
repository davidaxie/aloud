import XCTest

/// End-to-end smoke: seeded classic appears in the library, the reader opens
/// and plays audio, and the listening position survives a relaunch.
final class SmokeUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testSeededClassicPlaysAndRestoresPosition() throws {
        // Reset wipes leftover container progress (which would otherwise
        // surface the seeded classic as the Continue Listening hero instead
        // of a grid card); it must NOT run again on the relaunch below,
        // which asserts the saved position survives.
        let app = XCUIApplication.aloud(["-uitest-seed-first-classic", "-uitest-reset-library"])
        app.launch()

        // Library shows the seeded classic card.
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Seeded classic card should appear")

        // Open the reader; the text column should render.
        card.tap()
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Reader text should appear")

        // Play, and wait for the engine to actually reach the playing state.
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.tap()
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 15),
                      "Playback should start within 15 s")

        // Pause.
        playButton.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 10),
                      "Playback should pause")

        // Skip forward deterministically so the saved position is non-zero.
        let forward = app.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        forward.tap()
        forward.tap()
        forward.tap()

        let savedSentence = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 > 0 },
                                          "Position should have advanced")

        // Background the app so the store flushes progress, then relaunch.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uitest-reset-library" }
        app.launch()

        // Reopen the same document and verify the position was restored.
        // With progress saved, the document now fronts the shelf as the
        // Continue Listening hero (it is excluded from the grid), so the
        // hero is the re-entry point. It does not autoplay here: this launch
        // has no -uitest-allow-autoplay, so the reader opens paused at the
        // saved sentence.
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 15),
                      "Saved progress should surface the Continue Listening hero")
        hero.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(
            waitForSentence(savedSentence, in: app, timeout: 10),
            "Restored sentence should equal \(savedSentence), got \(String(describing: currentSentence(app)))"
        )
    }
}
