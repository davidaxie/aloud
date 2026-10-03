import XCTest

/// R4 and R10 end to end: the empty Library's shape, the + menu, every entry
/// point opening a book playing with no further tap, a Finished book staying
/// paused, and the import overlay, its Cancel and its fixed failure copy.
/// Every launch is muted (XCUIApplication.aloud). Launches that assert
/// playing opt into autoplay and use the System voice.
final class LibraryEntryUITests: XCTestCase {

    private let reset = "-uitest-reset-library"
    private let seed = "-uitest-seed-first-classic"
    private let systemVoice = "-uitest-temp-model-dir"
    private let speaking = ["playing", "buffering"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["reader.text"].firstMatch
    }

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.play"].firstMatch
    }

    private func overlay(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["import.overlay"].firstMatch
    }

    private func anyCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                         ["library.card", "library.continue"])).firstMatch
    }

    /// The reader is up and speaking, with no tap after the open.
    private func assertOpensSpeaking(_ app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open", file: file, line: line)
        XCTAssertTrue(waitForValue(in: speaking, of: play, timeout: 15),
                      "Opening should start it speaking; got \(stringValue(of: play))",
                      file: file, line: line)
    }

    // MARK: - Empty Library

    func testEmptyLibraryShape() {
        let app = XCUIApplication.aloud([reset])
        app.launch()

        for identifier in ["library.featured", "library.moreClassics", "library.addFile"] {
            let element = app.buttons[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(identifier) should show")
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(identifier) is a 44pt target")
        }
        XCTAssertFalse(app.buttons["library.add"].exists, "No + until the library holds a book")
        let privacy = app.staticTexts.matching(NSPredicate(format: "label == %@",
                                                           "Everything stays on your device."))
        XCTAssertEqual(privacy.count, 1, "The privacy line shows exactly once")
    }

    func testAddMenuHasExactlyTwoItems() {
        let app = XCUIApplication.aloud([seed, reset])
        app.launch()

        let add = app.buttons["library.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "+ shows once the library holds a book")
        add.tap()
        XCTAssertTrue(app.buttons["Classics"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["From Files\u{2026}"].firstMatch.exists)
        for retired in ["Scan pages", "Paste text", "Soon"] {
            XCTAssertFalse(app.buttons[retired].exists, "'\(retired)' is gone")
            XCTAssertFalse(app.staticTexts[retired].exists, "'\(retired)' is gone")
        }
    }

    // MARK: - Every entry point opens playing (R4)

    func testGridCardOpensPlaying() {
        let app = XCUIApplication.aloud([seed, reset, systemVoice], allowAutoplay: true)
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        assertOpensSpeaking(app)
    }

    func testBookshelfRowOpensPlaying() {
        let app = XCUIApplication.aloud([reset, systemVoice], allowAutoplay: true)
        app.launch()

        let more = app.buttons["library.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("amontillado")
        let row = app.buttons["bookshelf.row.1063"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        assertOpensSpeaking(app)
    }

    func testFilesImportOpensPlaying() {
        let app = XCUIApplication.aloud([reset, systemVoice, "-uitest-pick-fixture", "text"],
                                        allowAutoplay: true)
        app.launch()

        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "The import should open the reader")
        assertOpensSpeaking(app)
        tapSystemBack(app)
        XCTAssertTrue(anyCard(app).waitForExistence(timeout: 10))
        XCTAssertEqual(libraryCount(app), 1)
    }

    func testOpenInOpensPlayingAndDedupes() {
        let app = XCUIApplication.aloud([reset, systemVoice, "-uitest-open-fixture", "pdf"],
                                        allowAutoplay: true)
        app.launch()

        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "Open-in should open the reader")
        assertOpensSpeaking(app)
        app.terminate()

        // The same file again: the reader opens on the copy already shelved.
        let again = XCUIApplication.aloud(["-uitest-open-fixture", "pdf"])
        again.launch()
        XCTAssertTrue(readerText(again).waitForExistence(timeout: 15), "The duplicate should open the reader")
        tapSystemBack(again)
        XCTAssertTrue(anyCard(again).waitForExistence(timeout: 10))
        XCTAssertEqual(libraryCount(again), 1, "Opening the same file twice adds one book")
    }

    func testFinishedBookOpensPaused() {
        let app = XCUIApplication.aloud([reset, "-uitest-seed-finished"], allowAutoplay: true)
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10))
        XCTAssertFalse(waitForValue(in: speaking, of: play, timeout: 3),
                       "A Finished book stays paused at its end")
        XCTAssertEqual(stringValue(of: play), "paused")
    }

    // MARK: - Import overlay (R10)

    func testCancelMidImportLeavesLibraryUnchanged() {
        let app = XCUIApplication.aloud([reset, "-uitest-slow-import", "-uitest-open-fixture", "text"])
        app.launch()

        let cancel = app.buttons["import.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        // A hundredth of a point absorbs the float error of a frame read in
        // window coordinates (43.99999999999994); any real shrink still fails.
        XCTAssertGreaterThanOrEqual(cancel.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44 - 0.01)
        cancel.tap()
        XCTAssertTrue(waitForNonExistence(of: overlay(app), timeout: 5))
        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        XCTAssertTrue(featured.isHittable)
        XCTAssertEqual(libraryCount(app), 0, "A cancelled import adds nothing")
        XCTAssertFalse(readerText(app).exists, "A cancelled import never opens")
    }

    func testOverlayHidesTheShelfFromAccessibility() {
        let app = XCUIApplication.aloud([reset, seed, "-uitest-slow-import", "-uitest-open-fixture", "text"])
        app.launch()

        XCTAssertTrue(overlay(app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["library.card"].exists, "The shelf is hidden under the overlay")
        XCTAssertFalse(app.buttons["library.add"].exists, "The nav bar is hidden under the overlay")
        app.buttons["import.cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.card"].firstMatch.waitForExistence(timeout: 10),
                      "The shelf returns once the overlay goes")
    }

    func testFailureUsesFixedCopy() {
        let app = XCUIApplication.aloud([reset, "-uitest-open-fixture", "pdf-blank"])
        app.launch()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertEqual(alert.label, "This PDF has no readable text.")
        XCTAssertTrue(alert.staticTexts["Try a PDF with selectable text."].exists)
        let leaked = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Error Domain"))
        XCTAssertEqual(leaked.count, 0, "An error's own text never reaches the screen")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForNonExistence(of: alert, timeout: 5))
        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        XCTAssertTrue(featured.isHittable)
    }

    // MARK: - Delete to empty

    func testDeletingEveryBookReturnsTheEmptyState() {
        let app = XCUIApplication.aloud([seed, reset])
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.press(forDuration: 1.2)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        // The confirmation is up once its message shows; its Delete is then
        // the only one on screen.
        let message = app.staticTexts["This removes the document and its listening progress."]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        app.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(app.buttons["library.featured"].firstMatch.waitForExistence(timeout: 10),
                      "An empty Library shows the featured classic again")
        XCTAssertFalse(app.buttons["library.add"].exists, "No + once the last book is gone")
    }
}
