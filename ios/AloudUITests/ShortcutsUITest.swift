import XCTest

/// R26 end to end, without the system: `-uitest-shortcut` runs a shortcut's
/// action as the last launch step, the way Siri or the Action button would,
/// in a muted launch through XCUIApplication.aloud. No test here reaches the
/// shortcuts through the system: a system-launched Aloud would not be muted.
///
/// testContinueShortcutPlaysWithoutOpeningTheReader starts MUTED playback,
/// so it runs only with the user's OK. The sleep tests never play.
final class ShortcutsUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Continue listening

    func testContinueShortcutPlaysWithoutOpeningTheReader() {
        // Launch 1: real progress on the seeded classic, then paused on the shelf.
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-temp-model-dir",
                                         "-uitest-seed-first-classic", "-uitest-reset-natural-voice-offer"],
                                        allowAutoplay: true)
        app.launch()
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The seeded classic's card should appear")
        card.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The card opens the book playing")
        // Past the first sentence: at 0% the book wouldn't be the Continue
        // book after a relaunch.
        let forward = app.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.tap()
        forward.tap()
        tapSystemBack(app)
        let circle = app.buttons["library.continue.play"].firstMatch
        XCTAssertTrue(circle.waitForExistence(timeout: 10))
        circle.tap()
        XCTAssertTrue(waitForValue("paused", of: circle, timeout: 10), "The circle pauses")
        // Backgrounding flushes the debounced progress write before the kill.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()

        // Launch 2: nothing is loaded and autoplay is suppressed; only the
        // shortcut's action can start the book.
        let relaunched = XCUIApplication.aloud(["-uitest-temp-model-dir", "-uitest-reset-natural-voice-offer",
                                                "-uitest-haptic-log", "-uitest-shortcut", "continue"])
        relaunched.launch()
        let relaunchedCircle = relaunched.buttons["library.continue.play"].firstMatch
        XCTAssertTrue(relaunchedCircle.waitForExistence(timeout: 15), "The Continue card should show")
        XCTAssertTrue(waitForValue("playing", of: relaunchedCircle, timeout: 15),
                      "The shortcut plays the Continue book, got '\(stringValue(of: relaunchedCircle))'")
        XCTAssertFalse(relaunched.buttons["player.play"].exists, "The reader never opened")
        XCTAssertEqual(hapticLog(relaunched), [], "A start from a pocket buzzes nothing")
    }

    // MARK: - Set sleep timer

    func testSleepShortcutArmsTheReaderChip() {
        assertSleepShortcut("sleep-30", showsChip: "30:00, sleep timer")
    }

    /// The Great Gatsby has chapters, so End of chapter reads as such once
    /// the reader's book has loaded.
    func testSleepShortcutAtChapterEndArmsTheReaderChip() {
        assertSleepShortcut("sleep-chapter", showsChip: "Chapter end, sleep timer")
    }

    /// Opens the seeded classic paused (autoplay is suppressed, so nothing
    /// plays and a minute timer never counts down) with the shortcut run at
    /// launch, and reads the reader's sleep chip.
    private func assertSleepShortcut(_ name: String, showsChip label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-first-classic",
                                         "-uitest-open-first-doc", "-uitest-temp-model-dir",
                                         "-uitest-shortcut", name])
        app.launch()
        let chip = app.descendants(matching: .any)["player.sleep"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "The reader should open", file: file, line: line)
        let labelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: chip)
        XCTAssertEqual(XCTWaiter().wait(for: [labelled], timeout: 10), .completed,
                       "The chip should read '\(label)', got '\(chip.label)'", file: file, line: line)
        XCTAssertEqual(stringValue(of: app.buttons["player.play"].firstMatch), "paused",
                       "Arming the timer plays nothing", file: file, line: line)
    }
}
