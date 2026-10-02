import XCTest

/// R12 on the reader screen as XCUITest sees it: the title names the book,
/// the scrub reads the playhead's position like the chapter line, and no
/// value anywhere carries a sentence index (R12e). No autoplay, and nothing
/// here taps Play.
final class ReaderAccessibilityUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Great Gatsby, paused in the reader.
    private func openGatsby() -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-seed-classic", "64317", "-uitest-reset-library",
                                         "-uitest-open-first-doc", "-uitest-reset-natural-voice-offer",
                                         "-uitest-temp-model-dir"])
        app.launch()
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 15),
                      "The reader should open")
        return app
    }

    func testTheTitleIsTheBookAsStaticText() {
        let app = openGatsby()
        let title = app.staticTexts["reader.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The title should be static text")
        XCTAssertEqual(title.label, "The Great Gatsby")
        XCTAssertFalse(app.buttons["reader.title"].exists, "The title is not a button")
    }

    func testTheScrubReadsThePositionLikeTheChapterLine() {
        let app = openGatsby()
        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 10))
        let position = chapterLine.label
        XCTAssertNotNil(position.range(of: #"^.+, \d+ of \d+, .+ left in chapter$"#, options: .regularExpression),
                        "Got '\(position)'")

        // Adjustable, so XCUITest reports it as a slider.
        let scrub = app.descendants(matching: .any)["player.scrub"].firstMatch
        XCTAssertTrue(scrub.waitForExistence(timeout: 10))
        XCTAssertEqual(scrub.elementType, .slider)
        XCTAssertEqual(stringValue(of: scrub), position)
    }

    func testNoValueCarriesASentenceIndex() throws {
        let app = openGatsby()

        let probe = sentenceProbe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertNotNil(probe.identifier.range(of: #"^reader\.sentence\.\d+$"#, options: .regularExpression),
                        "Got '\(probe.identifier)'")
        XCTAssertEqual(stringValue(of: probe), "", "The playhead lives in the identifier only")

        var numbered: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            if let value = element.value as? String, value.last?.isNumber == true {
                numbered.append("\(element.identifier): \(value)")
            }
            element.children.forEach(visit)
        }
        visit(try app.snapshot())
        XCTAssertEqual(numbered, [], "No value on the reader screen ends in a number")

        let text = app.textViews["reader.text"].firstMatch
        XCTAssertEqual(stringValue(of: text), "", "The column's value is never the book")
        XCTAssertFalse(text.label.isEmpty, "The column reads the playhead's sentence")
        XCTAssertLessThan(text.label.count, 1_000)
    }
}
