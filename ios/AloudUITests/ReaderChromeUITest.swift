import XCTest

/// R6 reader chrome: identity on top (system back, title, Aa), every
/// frequent control in the bottom 40% (chapter line, scrub, voice · speed
/// chip, back 15, Play, forward 15, sleep chip), Contents with search pinned
/// above the chapters, and the restored edge swipe back.
///
/// No test taps Play: autoplay is suppressed (no -uitest-allow-autoplay) and
/// the app is muted, so every reader here rests paused. Run the layout test
/// on the 375×667, 390×844 and 440×956 simulators (iPhone SE, iPhone 16 and
/// iPhone 16 Pro Max class).
final class ReaderChromeUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Every launch clears listening time banked by earlier runs, so the
    /// natural-voice offer (which takes the chapter line's place after 60 s
    /// of playback) never hides reader.chapterLine.
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication.aloud(arguments + ["-uitest-reset-natural-voice-offer"])
        app.launch()
        return app
    }

    private func openSeededReader(_ seed: [String] = ["-uitest-seed-first-classic"]) -> XCUIApplication {
        let app = launch(seed + ["-uitest-reset-library", "-uitest-open-first-doc"])
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 15),
                      "The reader should open")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func chapterRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapters.row."))
    }

    private func wait(for format: String, _ argument: String, on element: XCUIElement,
                      timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Layout

    func testRestingChromeLayout() {
        let app = openSeededReader()

        XCTAssertFalse(app.buttons["reader.more"].exists, "The overflow menu is gone")

        let windowHeight = app.windows.firstMatch.frame.height
        let bottomControls = ["reader.chapterLine", "player.scrub", "player.listening",
                              "player.back15", "player.play", "player.forward15", "player.sleep"]
        for identifier in bottomControls {
            let control = element(identifier, in: app)
            XCTAssertTrue(control.waitForExistence(timeout: 10), "\(identifier) should exist")
            let frame = control.frame
            XCTAssertGreaterThanOrEqual(frame.minY, 0.6 * windowHeight,
                                        "\(identifier) should sit in the bottom 40% (minY \(frame.minY))")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(identifier) is \(frame.width)pt wide")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(identifier) is \(frame.height)pt tall")
        }

        // At rest: back, Aa, chapter line, chip, back 15, Play, forward 15,
        // sleep, plus the scrub.
        let buttons = app.buttons.allElementsBoundByIndex + app.popUpButtons.allElementsBoundByIndex
        let hittable = buttons.filter(\.isHittable).count
        let scrub = element("player.scrub", in: app)
        let scrubCounted = buttons.contains { $0.identifier == "player.scrub" }
        let controls = hittable + (scrub.isHittable && !scrubCounted ? 1 : 0)
        XCTAssertLessThanOrEqual(controls, 9, "\(controls) hittable controls at rest")

        XCTAssertTrue(app.staticTexts["reader.title"].firstMatch.exists,
                      "The title should be static text")
        XCTAssertFalse(app.buttons["reader.title"].exists, "The title is not a button")
    }

    // MARK: - Edge swipe

    func testEdgeSwipePopsToLibrary() {
        let app = launch(["-uitest-seed-first-classic", "-uitest-reset-library"])
        let book = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                    ["library.card", "library.continue"])).firstMatch
        let readerText = app.textViews["reader.text"].firstMatch

        for run in 1...20 {
            XCTAssertTrue(book.waitForExistence(timeout: 15), "Run \(run): a library card should show")
            book.tap()
            XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Run \(run): the reader should open")

            // From x = 4, inside the 8pt edge band the system back swipe owns.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 4, dy: 0))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)

            XCTAssertTrue(waitForNonExistence(of: readerText, timeout: 5),
                          "Run \(run): the edge swipe should pop the reader")
            XCTAssertTrue(book.waitForExistence(timeout: 5), "Run \(run): back on the Library")
        }
    }

    // MARK: - Sleep chip

    func testSleepTimerArmsInTwoTaps() {
        let app = openSeededReader()
        let chip = element("player.sleep", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 10))

        chip.tap()
        let thirty = app.buttons["30 minutes"].firstMatch
        XCTAssertTrue(thirty.waitForExistence(timeout: 5), "The sleep options should open")
        thirty.tap()
        // Paused, so the countdown holds at 30:00.
        XCTAssertTrue(wait(for: "label BEGINSWITH %@", "30:00", on: chip, timeout: 5),
                      "Armed chip should read 30:00, got \(chip.label)")

        chip.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.tap()
        XCTAssertTrue(wait(for: "label == %@", "Sleep timer", on: chip, timeout: 5),
                      "Disarmed chip should read Sleep timer, got \(chip.label)")
    }

    // MARK: - Contents

    func testContentsSearch() {
        let app = openSeededReader(["-uitest-seed-classic", "64317"])   // The Great Gatsby

        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 10))
        chapterLine.tap()
        let rows = chapterRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "Contents should list chapters")

        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Daisy")
        XCTAssertTrue(app.staticTexts["search.count"].firstMatch.waitForExistence(timeout: 10),
                      "Results should replace the list")
        XCTAssertTrue(waitForNonExistence(of: rows.firstMatch, timeout: 5),
                      "Chapter rows should give way to results")

        let clear = app.buttons["search.clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5),
                      "Clearing the query should bring the chapters back")

        field.tap()
        field.typeText("zzqxj")
        let empty = app.staticTexts["search.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: "label == %@", "No matches for \u{201C}zzqxj\u{201D}",
                           on: empty, timeout: 10),
                      "Got \(empty.label)")
    }

    func testChapterlessBook() {
        let app = openSeededReader(["-uitest-seed-classic", "1063"])   // The Cask of Amontillado

        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 10))
        XCTAssertTrue(chapterLine.label.hasPrefix("The Cask of Amontillado,"),
                      "A chapterless book names itself, got \(chapterLine.label)")
        XCTAssertTrue(chapterLine.label.contains("minutes left"), "Got \(chapterLine.label)")

        chapterLine.tap()
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Contents should open on search")
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 5), .completed,
                       "Search only: the field takes focus")
        XCTAssertFalse(chapterRows(in: app).firstMatch.exists, "No chapter list")
    }

    // MARK: - Skips

    func testSkipButtonsMoveWhilePaused() throws {
        let app = openSeededReader()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let start = try XCTUnwrap(waitForSentence(in: app, timeout: 10) { _ in true },
                                  "The playhead probe should appear")

        app.buttons["player.forward15"].firstMatch.tap()
        let afterForward = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 != start },
                                         "Forward 15 should move the playhead")
        XCTAssertGreaterThan(afterForward, start, "Forward 15 moved from \(start) to \(afterForward)")

        app.buttons["player.back15"].firstMatch.tap()
        let afterBack = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 != afterForward },
                                      "Back 15 should move the playhead")
        XCTAssertLessThan(afterBack, afterForward, "Back 15 moved from \(afterForward) to \(afterBack)")

        XCTAssertEqual(stringValue(of: play), "paused", "Skips keep the reader paused")
    }
}
