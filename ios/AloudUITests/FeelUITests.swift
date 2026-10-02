import XCTest

/// R20's haptics, read from the app's DEBUG log (`-uitest-haptic-log`
/// exposes it as debug.haptics): a tap that starts playback ticks once, a
/// pause once, the 1× detent and a speed preset once each, and an autoplay
/// never. Every launch goes through XCUIApplication.aloud, so it is muted;
/// the voice pref reset starts every run at 1×. Never run without the user's
/// OK.
final class FeelUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The temp model dir keeps the System voice, so playback starts fast.
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-haptic-log", "-uitest-temp-model-dir",
                                         "-uitest-reset-voice-pref", "-uitest-reset-library"] + arguments,
                                        allowAutoplay: true)
        app.launch()
        return app
    }

    private func launchReader() -> XCUIApplication {
        launch(["-uitest-seed-first-classic", "-uitest-open-first-doc"])
    }

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.play"].firstMatch
    }

    private func count(_ haptic: String, in app: XCUIApplication) -> Int {
        hapticLog(app).filter { $0 == haptic }.count
    }

    // MARK: - Play and pause

    func testAGridCardTapTicksOnce() {
        let app = launch(["-uitest-seed-first-classic"])
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The seeded classic's card")
        card.tap()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 60))
        XCTAssertEqual(hapticLog(app), ["play"], "The tap ticks; the autoplay it starts doesn't")
    }

    func testABookshelfRowTapTicksOnce() {
        let app = launch([])
        let more = app.buttons["library.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "The empty Library offers More classics")
        more.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The Bookshelf's search field")
        field.tap()
        field.typeText("amontillado")
        let row = app.buttons["bookshelf.row.1063"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 20), "One tap adds and opens the classic")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 60))
        XCTAssertEqual(hapticLog(app), ["play"])
    }

    /// The haptics logged since `mark` entries.
    private func haptics(since mark: Int, in app: XCUIApplication) -> [String] {
        Array(hapticLog(app).dropFirst(mark))
    }

    /// The Continue card: its circle ticks once per toggle, soft to play and
    /// light to pause, and its body ticks once when it opens the book
    /// playing, with nothing for the autoplay that follows.
    func testTheContinueCardTicksOncePerTap() {
        let app = launch(["-uitest-seed-first-classic"])
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The seeded classic's card")
        card.tap()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 60))
        play.tap()
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10))
        tapSystemBack(app)

        let circle = app.buttons["library.continue.play"].firstMatch
        XCTAssertTrue(circle.waitForExistence(timeout: 10), "The paused book is the hero")
        var mark = hapticLog(app).count
        circle.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: circle, timeout: 30), "The circle plays")
        XCTAssertEqual(haptics(since: mark, in: app), ["play"], "log: \(hapticLog(app))")

        mark = hapticLog(app).count
        circle.tap()
        XCTAssertTrue(waitForValue("paused", of: circle, timeout: 10), "The circle pauses")
        XCTAssertEqual(haptics(since: mark, in: app), ["pause"], "log: \(hapticLog(app))")

        mark = hapticLog(app).count
        app.buttons["library.continue"].firstMatch.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: playButton(app), timeout: 60),
                      "The body opens the book playing")
        XCTAssertEqual(haptics(since: mark, in: app), ["play"],
                       "The body ticks once; the autoplay it starts doesn't. log: \(hapticLog(app))")
    }

    func testAutoplayIsSilentAndThePlayButtonTicksPauseThenPlay() {
        let app = launchReader()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The opened book autoplays")
        XCTAssertEqual(hapticLog(app), [], "An autoplay is not a tap")

        play.tap()
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10))
        play.tap()
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 30))
        XCTAssertEqual(hapticLog(app), ["pause", "play"])
    }

    // MARK: - Speed

    /// The log isn't readable under the sheet, so it is counted before the
    /// sheet opens and after it closes: setting 0.8× leaves 1× (silent), and
    /// the slow drag up to 1.2× arrives at it once.
    func testDraggingTheSpeedSliderAcrossOneTicksOnce() {
        let app = launchReader()
        let before = count("detent", in: app)
        openListeningSheet(app)

        let slider = app.sliders["listening.speed.slider"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: Self.fraction(of: 0.8))
        XCTAssertLessThan(Self.rate(stringValue(of: slider)) ?? 1, 0.96, "got '\(stringValue(of: slider))'")

        let start = Self.point(on: slider, at: Self.rate(stringValue(of: slider)) ?? 0.8)
        let end = Self.point(on: slider, at: 1.2)
        start.press(forDuration: 0.4, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 80), thenHoldForDuration: 0.3)
        XCTAssertGreaterThan(Self.rate(stringValue(of: slider)) ?? 1, 1.04,
                             "The drag should cross 1×, got '\(stringValue(of: slider))'")

        dismissListeningSheet(app)
        XCTAssertEqual(count("detent", in: app) - before, 1, "log: \(hapticLog(app))")
    }

    func testAPresetTicksOnlyWhenItChangesTheSpeed() {
        let app = launchReader()
        let before = count("preset", in: app)
        openListeningSheet(app)

        let preset = app.buttons["listening.preset.1.5"].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        XCTAssertTrue(preset.isSelected || waitForSelected(preset))
        preset.tap()   // already 1.5×: no change, no tick

        dismissListeningSheet(app)
        XCTAssertEqual(count("preset", in: app) - before, 1, "log: \(hapticLog(app))")
    }

    // MARK: - Helpers

    private func openListeningSheet(_ app: XCUIApplication) {
        let chip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "The reader's voice · speed chip")
        chip.tap()
        XCTAssertTrue(app.staticTexts["listening.title"].firstMatch.waitForExistence(timeout: 10),
                      "The Listening sheet should open")
    }

    private func waitForSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    /// The app's speed range (SpeedScale.range).
    private static let speeds: ClosedRange<Double> = 0.5...3.0

    private static func fraction(of rate: Double) -> CGFloat {
        CGFloat((rate - speeds.lowerBound) / (speeds.upperBound - speeds.lowerBound))
    }

    /// "1.25×" → 1.25.
    private static func rate(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: "×", with: ""))
    }

    /// Where the thumb sits for `rate`: the track runs inside the slider's
    /// frame, inset by about half a thumb at each end.
    private static func point(on slider: XCUIElement, at rate: Double) -> XCUICoordinate {
        let inset: CGFloat = 14
        let x = inset + fraction(of: rate) * (slider.frame.width - 2 * inset)
        return slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: x, dy: 0))
    }
}
