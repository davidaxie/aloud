import XCTest

/// R5's natural-voice offer, end to end: never on a fresh install, after a
/// minute of listening it shows in the chapter line and on the Continue card,
/// 'Not now' survives a relaunch (the Listening sheet still offers the
/// download), and on cellular nothing is requested before the prompt is
/// confirmed. The install switch itself is covered by VoiceHandoffTests.
///
/// Muted through XCUIApplication.aloud. Every launch passes
/// -uitest-temp-model-dir, so a model seeded in the simulator container
/// never hides the not-installed state and is never deleted.
final class NaturalVoiceOfferUITest: XCTestCase {

    private static let offerText = "Natural voice · 353 MB, once"
    /// The offer as VoiceOver says it on the Continue card.
    private static let spokenOfferText = "Natural voice, 353 MB, once"
    private static let cellularPrompt = "Download 353 MB on cellular?"

    /// An empty shelf with one seeded classic, an unanswered offer and no model.
    private static let freshShelf = ["-uitest-reset-library", "-uitest-reset-natural-voice-offer",
                                     "-uitest-temp-model-dir", "-uitest-seed-first-classic"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func offerRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["naturalVoice.offer"].firstMatch
    }

    private func openCard(_ identifier: String, in app: XCUIApplication) {
        let card = app.buttons[identifier].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "\(identifier) should appear")
        card.tap()
        XCTAssertTrue(app.buttons["player.play"].firstMatch.waitForExistence(timeout: 15),
                      "the reader should open")
    }

    func testFreshInstallReachesAudioWithNoOffer() {
        let app = XCUIApplication.aloud(Self.freshShelf, allowAutoplay: true)
        app.launch()

        openCard("library.card", in: app)
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 30), "first audio with no extra tap")

        XCTAssertFalse(offerRow(app).exists, "never offered before a minute of listening")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(play.isHittable, "no sheet covers the player")
    }

    func testOfferAfterAMinuteAndNotNowPersists() {
        let app = XCUIApplication.aloud(["-uitest-listened-seconds", "58"] + Self.freshShelf,
                                        allowAutoplay: true)
        app.launch()

        // Two more seconds of playback cross the 60 s mark.
        openCard("library.card", in: app)
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 30))
        let offer = offerRow(app)
        XCTAssertTrue(offer.waitForExistence(timeout: 30), "the offer appears after 60 s of playback")
        XCTAssertEqual(stringValue(of: play), "playing", "the offer never stops playback")
        XCTAssertEqual(offer.label, Self.offerText)

        // The Continue card's subtitle points to it. The subtitle is the
        // card's value; its label names the book.
        tapSystemBack(app)
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertTrue(stringValue(of: hero).contains(Self.spokenOfferText),
                      "Continue card: \(stringValue(of: hero))")

        hero.tap()
        let notNow = app.buttons["naturalVoice.offer.notNow"].firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        notNow.tap()
        XCTAssertTrue(waitForNonExistence(of: offer, timeout: 5), "'Not now' dismisses the offer")

        // Pause first: killed mid-speech, the relaunch would report "Stopped
        // when iOS closed Aloud", and that stop outranks the offer in the
        // slot, hiding it whatever the answer was.
        let speaking = app.buttons["player.play"].firstMatch
        if waitForValue(in: ["playing", "buffering"], of: speaking, timeout: 2) { speaking.tap() }
        XCTAssertTrue(waitForValue("paused", of: speaking, timeout: 10), "paused before leaving")

        // Background first so progress and the answer are flushed, then relaunch
        // with no reset.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        let relaunched = XCUIApplication.aloud(["-uitest-temp-model-dir"])
        relaunched.launch()

        openCard("library.continue", in: relaunched)
        // The one slot holds either the offer or the chapter line; wait for
        // whichever comes, so a lost answer fails on the persistence check
        // below rather than on the chapter line the offer displaced.
        let slot = relaunched.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["naturalVoice.offer", "reader.chapterLine"]))
            .firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 10), "the reader's message slot should show")
        // The wait covers the offer arriving with the model state, a beat
        // after the reader opens.
        XCTAssertFalse(offerRow(relaunched).waitForExistence(timeout: 3),
                       "'Not now' persists across a relaunch")
        // And only the answer hid it: the slot shows the position line
        // ("…, 8 minutes left in chapter"), so no stop or notice outranks
        // the offer.
        let chapterLine = relaunched.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.exists, "the chapter line should fill the slot")
        XCTAssertTrue(chapterLine.label.contains(" left"),
                      "the slot should show the position, got '\(chapterLine.label)'")
        let listening = relaunched.buttons["player.listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 5))
        listening.tap()
        XCTAssertTrue(relaunched.buttons["model.download"].firstMatch.waitForExistence(timeout: 10),
                      "the Listening sheet still offers the download")
    }

    func testCellularPromptSendsNothingUntilConfirmed() {
        let app = XCUIApplication.aloud(["-uitest-expensive-network", "-uitest-listened-seconds", "60"]
                                        + Self.freshShelf)
        app.launch()

        openCard("library.card", in: app)
        let download = app.buttons["naturalVoice.offer.download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()

        // The confirmation dialog's title, whether it renders as a sheet or an alert.
        let title = app.staticTexts[Self.cellularPrompt].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "'\(Self.cellularPrompt)' should be asked first")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            // Presented as a popover, the dialog has no Cancel row: tap outside it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        XCTAssertTrue(waitForNonExistence(of: title, timeout: 5))

        XCTAssertFalse(app.descendants(matching: .any)["model.progress"].exists, "no download started")
        let downloading = NSPredicate(format: "label BEGINSWITH %@", "Downloading natural voice")
        XCTAssertEqual(app.descendants(matching: .any).matching(downloading).count, 0)
        XCTAssertTrue(offerRow(app).exists, "cancelling leaves the offer unanswered")
    }
}
