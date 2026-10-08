import XCTest

/// R4's first-run promise: a fresh install with no seed hooks, one tap on
/// the featured classic, and the System voice is reading. Muted like every
/// UI test; autoplay is opted in because it is what's under test.
final class FirstRunUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testFirstRunReachesPlayingInOneTap() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-reset-voice-pref",
                                         "-uitest-temp-model-dir", "-uitest-reset-natural-voice-offer"],
                                        allowAutoplay: true)
        app.launch()

        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 15), "The empty Library should feature a classic")
        XCTAssertTrue(featured.label.hasPrefix("Start with a classic, The Cask of Amontillado, Edgar Allan Poe, "),
                      "Featured label: \(featured.label)")
        XCTAssertFalse(app.buttons["library.add"].exists, "+ appears only once the library holds a book")
        XCTAssertEqual(app.alerts.count, 0, "Nothing stands between launch and the first sentence")

        let tapped = Date()
        featured.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 15),
                      "One tap should reach playing; got \(stringValue(of: play))")
        // The p50 ≤ 3 s budget is measured on the floor device, not here.
        print(String(format: "FIRSTRUN-TIMING tap→playing: %.2f s", Date().timeIntervalSince(tapped)))

        let listening = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 5))
        XCTAssertTrue(listening.label.hasPrefix("System"),
                      "A fresh install reads in the System voice; got \(listening.label)")
    }
}
