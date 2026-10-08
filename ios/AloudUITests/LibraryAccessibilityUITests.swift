import XCTest

/// R12f/R12g/R25 on the shelf: card and featured labels name the author and
/// spell out durations in one of three forms, and every card (the hero too)
/// offers Rename, Mark as finished and Delete. Muted through
/// XCUIApplication.aloud; no launch allows autoplay and nothing taps Play.
final class LibraryAccessibilityUITests: XCTestCase {

    /// The Cask of Amontillado on a fresh shelf, at 1×.
    private static let caskShelf = ["-uitest-reset-library", "-uitest-seed-classic", "1063",
                                    "-uitest-reset-voice-pref", "-uitest-temp-model-dir"]
    private static let caskPrefix = "The Cask of Amontillado, Edgar Allan Poe, "

    override func setUp() {
        continueAfterFailure = false
    }

    private func caskCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["library.card"].firstMatch
    }

    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    /// Dismisses an open context menu without choosing anything: a tap low
    /// on the backdrop, clear of the preview at the top of the shelf.
    private func dismissMenu(_ app: XCUIApplication, waitingFor item: XCUIElement) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        XCTAssertTrue(waitForNonExistence(of: item, timeout: 10), "The context menu should close")
    }

    /// An unstarted card reads its whole length, spelled out (R25).
    func testCardLabelNamesTheAuthor() {
        let app = XCUIApplication.aloud(Self.caskShelf)
        app.launch()

        let card = caskCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The seeded classic's card should appear")
        XCTAssertEqual(card.label, Self.caskPrefix + "14 minutes")
    }

    /// R25's three card states, and R24's Finished card, as VoiceOver reads
    /// them: an unstarted length, a finished book, and time left once a
    /// book has moved. Pride and Prejudice moves by a Contents pick, which
    /// plays from there (P025, muted); the test pauses it before going back.
    func testCardsReadTheirThreeStates() {
        let app = XCUIApplication.aloud(["-uitest-reset-library",
                                         "-uitest-seed-classic", "1063", "-uitest-seed-classic", "1342",
                                         "-uitest-seed-finished",   // the catalog's first book, The Great Gatsby
                                         "-uitest-reset-voice-pref", "-uitest-temp-model-dir",
                                         // No banked listening, so no natural-voice offer takes the hero's line.
                                         "-uitest-reset-natural-voice-offer"])
        app.launch()

        let cask = card(labelled: "The Cask of Amontillado, ", in: app)
        XCTAssertTrue(cask.waitForExistence(timeout: 20), "The Cask's card should appear")
        XCTAssertEqual(cask.label, "The Cask of Amontillado, Edgar Allan Poe, 14 minutes")
        let gatsby = card(labelled: "The Great Gatsby, ", in: app)
        XCTAssertTrue(gatsby.waitForExistence(timeout: 10), "The finished Gatsby's card should appear")
        XCTAssertEqual(gatsby.label, "The Great Gatsby, F. Scott Fitzgerald, finished")

        let pride = card(labelled: "Pride and Prejudice, ", in: app)
        XCTAssertTrue(pride.waitForExistence(timeout: 10), "Pride and Prejudice's card should appear")
        pride.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertEqual(stringValue(of: play), "paused", "autoplay is suppressed")

        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 15))
        chapterLine.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chapters.row.'"))
        XCTAssertTrue(rows.element(boundBy: 2).waitForExistence(timeout: 10), "Contents lists the chapters")
        rows.element(boundBy: 2).tap()
        XCTAssertTrue(waitForNonExistence(of: rows.element(boundBy: 2), timeout: 10), "The pick closes Contents")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 10),
                      "a chapter pick plays from there, got '\(stringValue(of: play))'")
        play.tap()
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10), "paused before going back")
        tapSystemBack(app)

        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "The loaded book is the hero")
        XCTAssertTrue(stringValue(of: hero).hasSuffix(" left"), "hero value: \(stringValue(of: hero))")
        XCTAssertFalse(stringValue(of: hero).contains("%"), "hero value: \(stringValue(of: hero))")
        for gridCard in app.buttons.matching(identifier: "library.card").allElementsBoundByIndex {
            XCTAssertFalse(gridCard.label.contains("%"), "card label: \(gridCard.label)")
        }
    }

    private func card(labelled prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'library.card' AND label BEGINSWITH %@",
                                         prefix)).firstMatch
    }

    func testMarkAsFinishedFromTheContextMenu() {
        let app = XCUIApplication.aloud(Self.caskShelf)
        app.launch()

        let card = caskCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.press(forDuration: 1.2)
        let finish = menuItem("Mark as finished", in: app)
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "Long-press offers Mark as finished")
        XCTAssertTrue(menuItem("Rename", in: app).exists)
        XCTAssertTrue(menuItem("Delete", in: app).exists)
        finish.tap()

        XCTAssertTrue(waitForNonExistence(of: finish, timeout: 10))
        let finished = app.buttons.matching(NSPredicate(format: "identifier == 'library.card' AND label ENDSWITH %@",
                                                        "finished")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 10), "card label: \(caskCard(app).label)")
        XCTAssertTrue(finished.label.hasPrefix(Self.caskPrefix))

        finished.press(forDuration: 1.2)
        let rename = menuItem("Rename", in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        XCTAssertTrue(menuItem("Delete", in: app).exists)
        XCTAssertFalse(menuItem("Mark as finished", in: app).exists, "A Finished book has nothing to mark")
        dismissMenu(app, waitingFor: rename)
    }

    func testMarkingTheHeroFinishedRetiresIt() {
        let app = XCUIApplication.aloud(Self.caskShelf)
        app.launch()

        // Opening the book loads it (paused, no autoplay), so it comes back as the hero.
        let card = caskCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(app.buttons["player.play"].firstMatch.waitForExistence(timeout: 15), "The reader should open")
        tapSystemBack(app)
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "The loaded book is the hero")

        hero.press(forDuration: 1.2)
        let finish = menuItem("Mark as finished", in: app)
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "The hero offers Mark as finished too")
        finish.tap()

        XCTAssertTrue(waitForNonExistence(of: hero, timeout: 10), "A Finished book is no longer the hero")
        XCTAssertTrue(caskCard(app).waitForExistence(timeout: 10), "It goes back to the grid")
        XCTAssertTrue(caskCard(app).label.hasSuffix("finished"), "card label: \(caskCard(app).label)")
    }

    func testFeaturedClassicLabelSpellsOutItsLength() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-reset-voice-pref"])
        app.launch()

        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 15), "The empty Library shows the featured classic")
        XCTAssertEqual(featured.label, "The Cask of Amontillado, Edgar Allan Poe, 14 minutes")
    }
}
