import XCTest

/// The Mac player bar in the real window (M9): every control present with a
/// Mac-sized hit region and Play at 44 pt; in The Cask of Amontillado, a
/// book without chapters, the chapter line names the book and its time
/// left; a click at 80% of the scrub moves the playhead, keeps the pause
/// and offers Undo jump, and ⌘Z returns to the sentence it left. Muted,
/// autoplay off, paused throughout. Runs only in the consented `AloudMacUI`
/// scheme.
final class MacPlayerBarUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// The first classic (The Cask of Amontillado), opened in the reader.
    private func launchReader() -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-reset-voice-pref",
                                         "-uitest-temp-model-dir",
                                         "-uitest-seed-first-classic", "-uitest-open-first-doc"])
        self.app = app
        launchAloud(app)
        XCTAssertTrue(app.buttons["player.play"].firstMatch.waitForExistence(timeout: 20), "the reader should open")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The sentence index from the DEBUG playhead probe's identifier.
    private func playhead(in app: XCUIApplication) -> Int? {
        let probe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'reader.sentence.'")).firstMatch
        guard probe.waitForExistence(timeout: 5) else { return nil }
        return Int(probe.identifier.dropFirst("reader.sentence.".count))
    }

    private func waitForPlayhead(in app: XCUIApplication, timeout: TimeInterval = 5,
                                 _ condition: (Int) -> Bool) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let sentence = playhead(in: app), condition(sentence) { return sentence }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    func testEveryControlIsThereAtAMacHitSize() {
        let app = launchReader()
        for identifier in ["reader.chapterLine", "player.scrub", "player.listening", "player.back15",
                           "player.play", "player.forward15", "player.sleep"] {
            let control = element(identifier, in: app)
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(identifier) is in the bar")
            XCTAssertGreaterThanOrEqual(control.frame.height.rounded(), 24, "\(identifier) height")
            if identifier != "player.scrub" && identifier != "reader.chapterLine" {
                XCTAssertGreaterThanOrEqual(control.frame.width.rounded(), 28, "\(identifier) width")
                XCTAssertGreaterThanOrEqual(control.frame.height.rounded(), 28, "\(identifier) height")
            }
        }
        let play = element("player.play", in: app)
        XCTAssertGreaterThanOrEqual(play.frame.width.rounded(), 44, "Play is the 44 pt circle")
        XCTAssertEqual(play.value as? String, "paused", "a UI-test launch never autoplays")
    }

    func testTheChapterLineNamesTheBookWithoutChapters() {
        let app = launchReader()
        let line = element("reader.chapterLine", in: app)
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.hasPrefix("The Cask of Amontillado"), line.label)
        XCTAssertTrue(line.label.contains("left"), line.label)
    }

    func testAClickAt80PercentSeeksOffersUndoAndCommandZRestores() {
        let app = launchReader()
        let scrub = element("player.scrub", in: app)
        XCTAssertTrue(scrub.waitForExistence(timeout: 5))
        guard let start = playhead(in: app) else { return XCTFail("no playhead probe") }

        scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).click()

        let undo = element("reader.undoJump", in: app)
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "a scrub click offers Undo jump")
        let landed = waitForPlayhead(in: app) { $0 > start }
        XCTAssertNotNil(landed, "the click moved the playhead toward 80% of the book")
        XCTAssertEqual(element("player.play", in: app).value as? String, "paused", "a scrub click keeps the pause")

        press(.undoJump, in: app)
        XCTAssertNotNil(waitForPlayhead(in: app) { $0 == start }, "⌘Z returns to the sentence it left")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: undo)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the chip leaves with the undo")
    }
}
