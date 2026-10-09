import XCTest

/// R24 end to end: a book played to its end shows the colophon, Listen
/// again and More classics, plays one success haptic and announces "The
/// End"; a Finished book reopens there, paused; Listen again starts at the
/// top. Every launch goes through XCUIApplication.aloud, so the app is
/// muted, and uses the System voice (-uitest-temp-model-dir). Tests 1 and 3
/// start (muted) playback: run them only with the user's OK.
final class ColophonUITest: XCTestCase {

    private static let reset = "-uitest-reset-library"
    private static let hapticLog = "-uitest-haptic-log"
    private static let systemVoice = "-uitest-temp-model-dir"
    /// The offer counts listening across launches, so earlier tests in a run
    /// can leave it due; the card would then show the offer, not "finished".
    private static let freshOffer = "-uitest-reset-natural-voice-offer"
    private static let reopenFinished = [reset, freshOffer, "-uitest-seed-finished", hapticLog, systemVoice]
    private static let speaking = ["playing", "buffering"]

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers (this file only)

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.play"].firstMatch
    }

    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["reader.text"].firstMatch
    }

    private func moreClassics(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["reader.moreClassics"].firstMatch
    }

    /// Wait until the element's accessibility label equals `expected`.
    private func waitForLabel(_ expected: String, of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Re-checks `condition` until it holds or `timeout` passes.
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "poll")], timeout: 0.25)
        }
        return true
    }

    /// Opens the seeded Finished classic from its grid card: never autoplays.
    private func reopenTheFinishedBook(_ app: XCUIApplication) -> XCUIElement {
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the seeded Finished book is on the shelf")
        card.tap()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the reader opens")
        XCTAssertTrue(waitForLabel("Listen again", of: play, timeout: 15),
                      "Play reads Listen again at the end; got '\(play.label)'")
        return play
    }

    /// The colophon's on-screen frame once two reads a quarter second apart
    /// agree, polled for 3 s at most. While a colophon shows, the follow
    /// probe (`reader.activeSentence`) frames the colophon, not a sentence.
    private func settledColophonFrame(_ app: XCUIApplication) -> CGRect? {
        var frame = activeSentenceFrame(app)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "let the page come to rest")], timeout: 0.25)
            let next = activeSentenceFrame(app)
            if let next, next == frame { return next }
            frame = next
        }
        return frame
    }

    /// R2-09: the end block lands between the top chrome and the More
    /// classics chip, and the chip clears the player bar. `whole`: the
    /// colophon fits above the chip; else (the accessibility sizes, where it
    /// may show its top first) the chip never covers its first line.
    private func assertTheColophonClearsTheChrome(_ app: XCUIApplication, whole: Bool,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "the page shows", file: file, line: line)
        let chip = moreClassics(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "More classics shows at the end", file: file, line: line)
        // The player bar's top row: the bar starts at or above it.
        let barRow = app.descendants(matching: .any)["reader.chapterLine"].firstMatch
        XCTAssertTrue(barRow.waitForExistence(timeout: 5), "the player bar shows", file: file, line: line)
        guard let colophon = settledColophonFrame(app) else {
            XCTFail("the follow probe frames the colophon", file: file, line: line)
            return
        }
        let topChrome = app.navigationBars.firstMatch.frame.maxY
        XCTAssertGreaterThanOrEqual(colophon.minY, topChrome - 1,
                                    "the colophon's top \(colophon.minY) is under the top bar (\(topChrome))",
                                    file: file, line: line)
        if whole {
            XCTAssertLessThanOrEqual(colophon.maxY, chip.frame.minY + 1,
                                     "the colophon's foot \(colophon.maxY) is under the chip (\(chip.frame.minY))",
                                     file: file, line: line)
        } else {
            XCTAssertLessThan(colophon.minY, chip.frame.minY,
                              "the chip (\(chip.frame.minY)) covers the colophon's first line (\(colophon.minY))",
                              file: file, line: line)
        }
        XCTAssertLessThanOrEqual(chip.frame.maxY, barRow.frame.minY + 1,
                                 "the chip \(chip.frame) runs into the player bar (\(barRow.frame.minY))",
                                 file: file, line: line)
    }

    /// CritiqueCaptureTests.test07FinishedBook's path: the first classic,
    /// seeded Finished, opened from its card.
    private func reopenTheFinishedClassic(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.aloud([Self.reset, "-uitest-seed-first-classic", "-uitest-seed-finished",
                                         Self.freshOffer, Self.systemVoice] + extra)
        app.launch()
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the seeded Finished classic is on the shelf")
        card.tap()
        return app
    }

    // MARK: - Tests

    /// R2-09: a reopened Finished book lands with the whole colophon above
    /// More classics (shot 27 had the chip over the rule and the bar
    /// cutting "The End").
    func testAReopenedFinishedBookShowsTheWholeColophonAboveTheChip() {
        let app = reopenTheFinishedClassic()
        assertTheColophonClearsTheChrome(app, whole: true)
    }

    /// The same at an accessibility size, where the colophon may show its
    /// top first: the chip never covers its first line.
    func testAReopenedFinishedBookAtAnAccessibilitySizeKeepsTheColophonClearOfTheChip() {
        let app = reopenTheFinishedClassic(AuditTextSize.all[1].launchArguments)
        assertTheColophonClearsTheChrome(app, whole: false)
    }

    /// The 4-sentence text fixture opens playing and runs to its end.
    func testTheEndOfABookShowsTheColophon() {
        let app = XCUIApplication.aloud([Self.reset, Self.freshOffer, Self.hapticLog, "-uitest-open-fixture", "text",
                                         Self.systemVoice],
                                        allowAutoplay: true)
        app.launch()

        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Open-in opens the reader")
        XCTAssertTrue(waitForLabel("Listen again", of: play, timeout: 60),
                      "the book reaches its end; got '\(play.label)'")
        XCTAssertEqual(stringValue(of: play), "paused")

        XCTAssertTrue(readerText(app).label.hasPrefix("The End"),
                      "VoiceOver reads the colophon; got '\(readerText(app).label)'")

        let chip = moreClassics(app)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.isHittable)
        XCTAssertGreaterThanOrEqual(chip.frame.width, 44)
        XCTAssertGreaterThanOrEqual(chip.frame.height, 44)
        // R2-09: the live end lands as a reopen does, whole above the chip.
        assertTheColophonClearsTheChrome(app, whole: true)

        XCTAssertTrue(eventually(timeout: 5) { hapticLog(app).contains("finished") }, "\(hapticLog(app))")
        XCTAssertEqual(hapticLog(app).filter { $0 == "finished" }.count, 1, "one success: \(hapticLog(app))")
        XCTAssertTrue(waitForAnnouncement("The End", in: app, timeout: 5), "\(announcements(app))")

        chip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bookshelf.list"].firstMatch.waitForExistence(timeout: 10),
                      "More classics opens Classics")
        tapSystemBack(app)
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "Back from Classics is the Library")
        XCTAssertTrue(stringValue(of: hero).contains("finished"), "got '\(stringValue(of: hero))'")
        XCTAssertEqual(app.buttons["library.continue.play"].firstMatch.label, "Listen again")
    }

    func testAFinishedBookReopensAtTheColophon() {
        let app = XCUIApplication.aloud(Self.reopenFinished)
        app.launch()

        let play = reopenTheFinishedBook(app)
        XCTAssertEqual(stringValue(of: play), "paused")
        XCTAssertFalse(waitForValue(in: Self.speaking, of: play, timeout: 3), "a Finished book stays paused")
        XCTAssertEqual(stringValue(of: play), "paused")

        XCTAssertTrue(readerText(app).label.hasPrefix("The End"), "got '\(readerText(app).label)'")
        XCTAssertTrue(moreClassics(app).exists)
        XCTAssertFalse(hapticLog(app).contains("finished"), "a reopen is no end heard: \(hapticLog(app))")

        // At the end Forward 15 has nowhere to go, so it is dimmed (VoiceOver
        // says so); Back 15 restarts the last sentence, so it stays.
        let forward = app.buttons["player.forward15"].firstMatch
        let back = app.buttons["player.back15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        XCTAssertFalse(forward.isEnabled, "Forward 15 is dimmed at the end")
        XCTAssertTrue(back.isEnabled, "Back 15 still restarts the last sentence")
    }

    func testListenAgainPlaysFromTheFirstSentence() {
        let app = XCUIApplication.aloud(Self.reopenFinished)
        app.launch()

        let play = reopenTheFinishedBook(app)
        play.tap()

        XCTAssertTrue(waitForValue(in: Self.speaking, of: play, timeout: 15),
                      "Listen again plays; got '\(stringValue(of: play))'")
        let sentence = currentSentence(app)
        XCTAssertNotNil(sentence)
        XCTAssertLessThanOrEqual(sentence ?? .max, 2, "from the top, not the end")
        XCTAssertEqual(hapticLog(app), ["play"], "the tap's own soft impact, nothing else")
        XCTAssertTrue(waitForNonExistence(of: moreClassics(app), timeout: 5), "the end is left")
    }
}
