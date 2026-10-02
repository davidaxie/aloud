import XCTest

/// R18: the Continue card is the one playback surface outside the reader.
/// Backing out of a playing book shows its true state, the circle plays and
/// pauses in place without opening the reader, the loaded book is the hero
/// even at 0%, and after a relaunch one circle tap starts the book.
///
/// Muted through XCUIApplication.aloud. Starts playback, so it runs only
/// with the user's OK.
final class ContinueCardUITest: XCTestCase {

    /// One seeded classic (The Great Gatsby), the System voice, and no
    /// banked listening time, so no offer takes the subtitle.
    private static let freshShelf = ["-uitest-reset-library", "-uitest-temp-model-dir",
                                     "-uitest-seed-first-classic", "-uitest-reset-natural-voice-offer"]
    private static let heroLabel = "Continue listening, The Great Gatsby, F. Scott Fitzgerald"
    private static let speaking = ["playing", "buffering"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func heroCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["library.continue"].firstMatch
    }

    private func playCircle(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["library.continue.play"].firstMatch
    }

    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["reader.text"].firstMatch
    }

    /// Opens the seeded classic from its grid card and waits for the reader.
    private func openSeededCard(_ app: XCUIApplication) -> XCUIElement {
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The seeded classic's card should appear")
        card.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        return play
    }

    func testCircleTogglesInPlaceAfterBackingOut() {
        let app = XCUIApplication.aloud(Self.freshShelf, allowAutoplay: true)
        app.launch()
        let play = openSeededCard(app)
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The card opens the book playing")

        tapSystemBack(app)
        let circle = playCircle(app)
        XCTAssertTrue(waitForValue("playing", of: circle, timeout: 2),
                      "The hero shows the book speaking at once, got '\(stringValue(of: circle))'")
        XCTAssertEqual(circle.label, "Pause")
        let hero = heroCard(app)
        XCTAssertEqual(hero.label, Self.heroLabel)
        XCTAssertTrue(stringValue(of: hero).hasPrefix("playing"), "hero value: \(stringValue(of: hero))")

        circle.tap()
        XCTAssertTrue(waitForValue("paused", of: circle, timeout: 5), "The circle pauses")
        XCTAssertEqual(circle.label, "Play")
        XCTAssertFalse(readerText(app).exists, "The circle never opens the reader")
        XCTAssertTrue(app.buttons["library.settings"].exists, "Still on the Library")
        XCTAssertFalse(stringValue(of: hero).hasPrefix("playing"), "hero value: \(stringValue(of: hero))")

        circle.tap()
        XCTAssertTrue(waitForValue(in: Self.speaking, of: circle, timeout: 15), "The circle plays again")
        XCTAssertFalse(readerText(app).exists, "Still on the Library")
    }

    func testZeroPercentLoadedBookIsTheHero() {
        // No autoplay: the reader loads the book and leaves it paused at 0%.
        let app = XCUIApplication.aloud(Self.freshShelf)
        app.launch()
        let play = openSeededCard(app)
        XCTAssertEqual(stringValue(of: play), "paused")

        tapSystemBack(app)
        XCTAssertTrue(heroCard(app).waitForExistence(timeout: 10), "The loaded book is the hero, even at 0%")
        XCTAssertFalse(app.buttons["library.card"].exists, "It is lifted out of the grid")
        XCTAssertEqual(playCircle(app).label, "Play")
        XCTAssertEqual(stringValue(of: playCircle(app)), "paused")
        // An unstarted hero reads its length (R25): no percent, no "left".
        let value = stringValue(of: heroCard(app))
        XCTAssertFalse(value.contains("%"), "hero value: \(value)")
        XCTAssertFalse(value.hasSuffix("left"), "hero value: \(value)")
    }

    func testAfterRelaunchOneCircleTapPlaysWithoutOpening() {
        // Launch 1: make real progress, pause, and leave it on the shelf.
        let app = XCUIApplication.aloud(Self.freshShelf, allowAutoplay: true)
        app.launch()
        let play = openSeededCard(app)
        XCTAssertTrue(waitForValue(in: Self.speaking, of: play, timeout: 60))
        let forward = app.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.tap()
        forward.tap()
        play.tap()
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10))
        tapSystemBack(app)
        XCTAssertTrue(heroCard(app).waitForExistence(timeout: 10))
        // Background first so the progress is flushed, then relaunch without a reset.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()

        // Launch 2: nothing is loaded; the hero is the book with progress.
        // No autoplay: only the circle's own tap can start it.
        let relaunched = XCUIApplication.aloud(["-uitest-temp-model-dir"])
        relaunched.launch()
        let circle = playCircle(relaunched)
        XCTAssertTrue(circle.waitForExistence(timeout: 15), "Saved progress surfaces the hero")
        XCTAssertEqual(circle.label, "Play")
        XCTAssertEqual(heroCard(relaunched).label, Self.heroLabel)

        circle.tap()
        XCTAssertTrue(waitForValue(in: Self.speaking, of: circle, timeout: 15),
                      "One tap loads and plays the book, got '\(stringValue(of: circle))'")
        XCTAssertFalse(readerText(relaunched).waitForExistence(timeout: 2), "The circle never opens the reader")
        XCTAssertTrue(relaunched.buttons["library.settings"].exists)
    }
}
