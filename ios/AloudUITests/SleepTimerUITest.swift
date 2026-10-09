import XCTest

/// R19 (and R1's promise that the timer outlives the reader), end to end: a
/// 1 min timer (`-uitest-sleep-one-minute`) offers "+15 min" from 45 s, stops
/// by 60 ± 5 s with the stopped line, "Back 5 min" and the announcement;
/// "+15 min" keeps it playing; leaving the reader doesn't disarm it; a book
/// without chapters offers End of book; and End of book and End of chapter
/// each say how long that is (R1-27).
///
/// Every launch is muted (`XCUIApplication.aloud`). All but the last two let
/// autoplay run for a minute or more: never run them without the user's OK.
final class SleepTimerUITest: XCTestCase {

    /// Deep in The Great Gatsby (the first classic), so 5 minutes back stays
    /// inside the book.
    private static let deepPassage = "Her voice is full of money"

    override func setUp() {
        continueAfterFailure = false
    }

    /// The first classic opened and speaking. The offer reset keeps listening
    /// banked by earlier runs from bringing the natural-voice offer early.
    private func launchPlaying(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-sleep-one-minute", "-uitest-reset-library",
                                         "-uitest-seed-first-classic", "-uitest-open-first-doc",
                                         "-uitest-temp-model-dir", "-uitest-reset-natural-voice-offer"] + extra,
                                        allowAutoplay: true)
        app.launch()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "Autoplay should start")
        return app
    }

    /// Two taps: the chip, then the test-only "1 minute". Returns when it was armed.
    private func armOneMinute(_ app: XCUIApplication) -> Date {
        let chip = element("player.sleep", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let oneMinute = app.buttons["1 minute"].firstMatch
        XCTAssertTrue(oneMinute.waitForExistence(timeout: 5), "The sleep options should open")
        oneMinute.tap()
        return Date()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func wait(for format: String, _ argument: String, on element: XCUIElement,
                      timeout: TimeInterval) -> Bool {
        wait(for: NSPredicate(format: format, argument), on: element, timeout: timeout)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: max(timeout, 1)) == .completed
    }

    private func seconds(since start: Date) -> TimeInterval {
        Date().timeIntervalSince(start)
    }

    // MARK: - Fade, stop, Back 5 min

    func testOneMinuteTimerFadesStopsAndBacksUpFiveMinutes() throws {
        let app = launchPlaying(["-uitest-seek-text", Self.deepPassage])
        let chip = element("player.sleep", in: app)
        let play = app.buttons["player.play"].firstMatch
        let start = armOneMinute(app)

        XCTAssertTrue(wait(for: "label == %@", "Add 15 minutes", on: chip, timeout: 48 - seconds(since: start)),
                      "The chip should offer +15 min by 48 s, got '\(chip.label)'")
        let fadeAt = seconds(since: start)
        XCTAssertGreaterThanOrEqual(fadeAt, 42, "The fade starts at 45 ± 3 s, not \(fadeAt) s")

        XCTAssertTrue(waitForValue("paused", of: play, timeout: max(65 - seconds(since: start), 1)),
                      "Silent by 60 ± 5 s")
        let stopAt = seconds(since: start)
        XCTAssertGreaterThanOrEqual(stopAt, 55, "The stop comes at 60 ± 5 s, not \(stopAt) s")

        let line = element("reader.chapterLine", in: app)
        XCTAssertTrue(wait(for: "label == %@", "Paused by sleep timer", on: line, timeout: 5),
                      "The chapter line says why, got '\(line.label)'")
        let back = element("reader.back5min", in: app)
        XCTAssertTrue(back.exists, "Back 5 min sits on the stopped line")
        XCTAssertTrue(waitForAnnouncement("Paused by sleep timer", in: app, timeout: 5))
        XCTAssertTrue(wait(for: "label == %@", "Sleep timer", on: chip, timeout: 5),
                      "The stop disarms the timer, got '\(chip.label)'")

        let stoppedAt = try XCTUnwrap(currentSentence(app), "The playhead probe")
        back.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 10), "Back 5 min plays")
        let rewound = waitForSentence(in: app, timeout: 5) { $0 < stoppedAt }
        XCTAssertNotNil(rewound, "Back 5 min lands earlier than sentence \(stoppedAt)")
        XCTAssertTrue(wait(for: "label != %@", "Paused by sleep timer", on: line, timeout: 5),
                      "Playing again clears the reason")
    }

    // MARK: - +15 min

    func testPlusFifteenDuringTheFadeKeepsPlaying() {
        let app = launchPlaying()
        let chip = element("player.sleep", in: app)
        _ = armOneMinute(app)

        XCTAssertTrue(wait(for: "label == %@", "Add 15 minutes", on: chip, timeout: 50),
                      "The chip should offer +15 min during the fade, got '\(chip.label)'")
        chip.tap()

        // The chip shows "15:00", but VoiceOver (and so XCUITest) reads the
        // shared spoken label, `SleepTimer.chipSpokenLabel`: the time left in
        // words, rounded up, so anything from 15:00 down to 14:01 says 15.
        XCTAssertTrue(wait(for: "label == %@", "15 minutes left, sleep timer", on: chip, timeout: 5),
                      "The timer reads 15 minutes, got '\(chip.label)'")
        XCTAssertEqual(stringValue(of: app.buttons["player.play"].firstMatch), "playing")
    }

    // MARK: - Outliving the reader

    func testTheTimerOutlivesTheReader() {
        let app = launchPlaying()
        let start = armOneMinute(app)
        tapSystemBack(app)

        let card = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The Continue card names the book")
        XCTAssertTrue(wait(for: "value CONTAINS %@", "Paused by sleep timer", on: card,
                           timeout: 66 - seconds(since: start)),
                      "The stop happens on the Library too, got '\(stringValue(of: card))'")
        let stopAt = seconds(since: start)
        XCTAssertGreaterThanOrEqual(stopAt, 55, "The stop comes at 60 ± 5 s, not \(stopAt) s")
        XCTAssertTrue(waitForAnnouncement("Paused by sleep timer", in: app, timeout: 5))
    }

    // MARK: - End of book

    func testABookWithoutChaptersOffersEndOfBook() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classic", "1063",
                                         "-uitest-open-first-doc"])   // The Cask of Amontillado
        app.launch()
        let chip = element("player.sleep", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()

        // The title first, so a missing item fails apart from a missing time.
        let endOfBook = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "End of book")).firstMatch
        XCTAssertTrue(endOfBook.waitForExistence(timeout: 5), "A book without chapters offers End of book")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "End of chapter")).firstMatch.exists)
        attachDescription(of: endOfBook, named: "End of book item")

        // R1-27, R2-23: the item's label says how long that is, spelled out.
        // The book's minutes come from a detached build that can finish
        // after the chip is first tapped, so a menu built before them is
        // closed and opened once more.
        var timed = timedItem("End of book", in: app)
        if !timed.waitForExistence(timeout: 5) {
            chip.tap()
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            chip.tap()
            timed = timedItem("End of book", in: app)
            _ = timed.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(timed.exists, "End of book speaks the book's remaining time: " + described(endOfBook))
    }

    // MARK: - End of chapter

    /// R1-27's main case: in a chaptered book (The Great Gatsby, opened
    /// muted, nothing playing) End of chapter says how long the rest of the
    /// chapter is, spelled out, in the label VoiceOver speaks (R2-22).
    func testEndOfChapterShowsHowLongTheChapterIs() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-first-classic",
                                         "-uitest-open-first-doc"])
        app.launch()
        // The chapter line shows once the book's chapters are read.
        XCTAssertTrue(app.buttons["reader.chapterLine"].firstMatch.waitForExistence(timeout: 20),
                      "The chaptered book opens")
        let chip = element("player.sleep", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()

        // The title first, so a missing item fails apart from a missing time.
        let endOfChapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "End of chapter"))
            .firstMatch
        XCTAssertTrue(endOfChapter.waitForExistence(timeout: 5), "A chaptered book offers End of chapter")
        // Where the time lands (label, value or nowhere), for the record.
        attachDescription(of: endOfChapter, named: "End of chapter item")

        let timed = timedItem("End of chapter", in: app)
        XCTAssertTrue(timed.waitForExistence(timeout: 5),
                      "End of chapter speaks the chapter's remaining time: " + described(endOfChapter))
    }

    // MARK: - Menu items

    /// The menu item titled `title` whose label also spells out a time
    /// ("37 minutes", "2 hours 5 minutes").
    private func timedItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label MATCHES %@",
                                         title, ".*\\d+ (minute|hour).*")).firstMatch
    }

    /// The item's label and value, for a failure message.
    private func described(_ item: XCUIElement) -> String {
        guard item.exists else { return "the item is gone" }
        return "label '\(item.label)', value '\(stringValue(of: item))'"
    }

    /// The item's accessibility tree, kept with the result.
    private func attachDescription(of item: XCUIElement, named name: String) {
        guard item.exists else { return }
        let attachment = XCTAttachment(string: item.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
