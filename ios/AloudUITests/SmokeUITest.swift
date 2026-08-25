import XCTest

/// End-to-end smoke: seeded classic appears in the library, the reader opens
/// and plays audio, and the listening position survives a relaunch.
final class SmokeUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testSeededClassicPlaysAndRestoresPosition() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-seed-first-classic"]
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

        // Step forward deterministically so the saved position is non-zero.
        let next = app.buttons["player.next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        next.tap()
        next.tap()

        let sentenceReadout = app.descendants(matching: .any)["reader.sentence"].firstMatch
        XCTAssertTrue(sentenceReadout.waitForExistence(timeout: 5))
        let savedSentence = stringValue(of: sentenceReadout)
        XCTAssertNotEqual(savedSentence, "0", "Position should have advanced")

        // Background the app so the store flushes progress, then relaunch.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()

        // Reopen the same document and verify the position was restored.
        let cardAgain = app.buttons["library.card"].firstMatch
        XCTAssertTrue(cardAgain.waitForExistence(timeout: 15))
        cardAgain.tap()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 15))

        let restoredReadout = app.descendants(matching: .any)["reader.sentence"].firstMatch
        XCTAssertTrue(restoredReadout.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForValue(savedSentence, of: restoredReadout, timeout: 10),
            "Restored sentence should equal \(savedSentence), got \(stringValue(of: restoredReadout))"
        )
    }

    // MARK: - Helpers

    private func stringValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    private func waitForValue(_ expected: String, of element: XCUIElement,
                              timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
