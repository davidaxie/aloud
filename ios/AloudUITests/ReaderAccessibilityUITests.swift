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
        // One header naming the book and its author (P046).
        XCTAssertEqual(title.label, "The Great Gatsby, by F. Scott Fitzgerald")
        XCTAssertFalse(app.buttons["reader.title"].exists, "The title is not a button")
    }

    /// P042: a long press on a sentence offers exactly the page's menu and
    /// moves nothing; dismissing it leaves the playhead where it was.
    func testALongPressOffersThePagesMenuAndMovesNothing() {
        let app = openGatsby()
        let probe = sentenceProbe(app)
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let before = probe.identifier
        let text = app.textViews["reader.text"].firstMatch
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.2)
        for title in ["Play from Here", "Copy", "Look Up", "Share\u{2026}"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5), "The menu should offer \(title)")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(app.buttons["Look Up"].firstMatch.waitForNonExistence(timeout: 5), "The menu should close")
        XCTAssertEqual(sentenceProbe(app).identifier, before, "Dismissing the menu moves nothing")
    }

    /// P050: a reader that can't load says so and offers one way back. In
    /// VoiceOver's order the two lines come first, then the button; the
    /// icon is hidden. The button returns to the Library.
    func testAFailedLoadReadsItsLinesThenOffersTheWayBack() throws {
        let app = XCUIApplication.aloud(["-uitest-seed-classic", "64317", "-uitest-reset-library",
                                         "-uitest-open-first-doc", "-uitest-fail-reader-load"])
        app.launch()
        let back = app.buttons["reader.backToLibrary"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "The failure state should offer the way back")
        XCTAssertFalse(app.textViews["reader.text"].exists, "Nothing loaded")
        XCTAssertGreaterThanOrEqual(back.frame.height, 44, "The way back is a 44 pt target")

        let title = "Couldn't open this document"
        let detail = "It may be damaged or a scanned document."
        var order: [String] = []
        func visit(_ element: XCUIElementSnapshot) {
            if element.identifier == "reader.backToLibrary" {
                order.append(element.identifier)
                return
            }
            if element.elementType == .staticText, [title, detail].contains(element.label) {
                order.append(element.label)
            }
            element.children.forEach(visit)
        }
        visit(try app.snapshot())
        XCTAssertEqual(order, [title, detail, "reader.backToLibrary"], "The lines, then the way back")
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        let icons = app.images.allElementsBoundByIndex.filter {
            $0.frame.minY >= barBottom && $0.frame.maxY <= back.frame.minY
        }
        XCTAssertEqual(icons.map(\.label), [], "The icon is hidden from VoiceOver")

        back.tap()
        let shelf = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["library.card", "library.continue"]))
        XCTAssertTrue(shelf.firstMatch.waitForExistence(timeout: 10), "The button returns to the Library")
        XCTAssertFalse(back.exists)
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
