import XCTest

/// R7 and R8: one voice and one speed for every book, picked in one
/// Listening view that the reader's chip and Settings both reach. Every
/// launch is muted and none allows autoplay; a voice pick still speaks a
/// sentence (a deliberate tap), silently.
final class ListeningUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// A seeded classic, opened in the reader on the System voice at 1×.
    private func launchReader(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classics", "1",
                                         "-uitest-open-first-doc", "-uitest-reset-voice-pref",
                                         "-uitest-temp-model-dir"] + extra)
        app.launch()
        return app
    }

    /// Taps the reader's voice · speed chip and waits for the sheet's title.
    private func openListeningSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let chip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "The reader's voice · speed chip", file: file, line: line)
        chip.tap()
        XCTAssertTrue(app.staticTexts["listening.title"].firstMatch.waitForExistence(timeout: 10),
                      "The Listening sheet should open", file: file, line: line)
    }

    /// The element's frame once two reads a quarter second apart agree. The
    /// sheet's content-sized detent settles after its first layout.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var frame = element.frame
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let next = element.frame
            if next == frame { break }
            frame = next
        }
        return frame
    }

    private func presets(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'listening.preset.'"))
    }

    /// Waits for `format` to hold on an element or a query.
    private func wait(for format: String, _ object: Any, timeout: TimeInterval = 10) -> Bool {
        wait(for: NSPredicate(format: format), object, timeout: timeout)
    }

    private func wait(for predicate: NSPredicate, _ object: Any, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A grid card's name: its label, "Title, Author, 6 hours 5 minutes",
    /// minus the length (or time-left, or finished) tail. The tail follows
    /// the app-wide speed, so only "Title, Author" still names the card after
    /// a speed change.
    private func cardTitle(_ label: String) -> String {
        guard let tail = label.range(of: #", (finished|\d+ (hours?|minutes?)( \d+ minutes?)?( left)?)$"#,
                                     options: .regularExpression) else { return label }
        return String(label[..<tail.lowerBound])
    }

    // MARK: - R7

    func testSpeedFollowsYouToTheNextBook() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classics", "2",
                                         "-uitest-reset-voice-pref", "-uitest-temp-model-dir"])
        app.launch()

        let cards = app.buttons.matching(identifier: "library.card")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20), "Two seeded classics")
        XCTAssertTrue(wait(for: "count == 2", cards), "Both seeded classics should be cards")
        // B is found again by its title, not its whole label: the time left
        // in the label follows the very speed change this test makes. The
        // card order can change too, once A has been opened.
        let labelA = cards.element(boundBy: 0).label
        let labelB = cards.element(boundBy: 1).label
        let prefixB = cardTitle(labelB)
        XCTAssertNotEqual(prefixB, labelB, "A card's label should read 'Title, Author, <length>', got '\(labelB)'")
        XCTAssertNotEqual(cardTitle(labelA), prefixB, "The two seeded classics should be different books")
        cards.element(boundBy: 0).tap()

        openListeningSheet(app)
        app.buttons["listening.preset.1.5"].firstMatch.tap()
        dismissListeningSheet(app)
        // A is loaded now, so it comes back as the Continue card; B stays a card.
        tapSystemBack(app)

        let cardB = app.buttons.matching(NSPredicate(format: "identifier == 'library.card' AND label BEGINSWITH %@",
                                                     prefixB + ", ")).firstMatch
        XCTAssertTrue(cardB.waitForExistence(timeout: 10), "Book B is still on the shelf")
        // The shelf's estimates run at the same one speed: B's time left shrank.
        XCTAssertTrue(wait(for: NSPredicate(format: "label != %@", labelB), cardB),
                      "Book B's time left should follow the new speed, still '\(cardB.label)'")
        cardB.tap()

        // Check it is B that opened: A also plays at 1.5× now, so the chip
        // alone can't tell the two books apart. The reader's title is B's
        // title, the start of "Title, Author".
        let title = app.staticTexts["reader.title"].firstMatch
        XCTAssertTrue(wait(for: NSPredicate(format: "label != '' AND %@ BEGINSWITH label", prefixB), title, timeout: 20),
                      "The reader should open book B, got '\(title.label)'")
        XCTAssertTrue(prefixB.hasPrefix(title.label), "'\(prefixB)' should start with the reader's title '\(title.label)'")
        let chip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(for: "label CONTAINS '1.5×'", chip),
                      "Book B should play at the speed picked in book A, got: \(chip.label)")
    }

    // MARK: - R8

    func testPresetsAreExactlyTheFiveAndCarrySelected() {
        let app = launchReader()
        openListeningSheet(app)

        let buttons = presets(app)
        // Shown as "1.25×", spoken in words (the description audit).
        XCTAssertEqual(buttons.allElementsBoundByIndex.map(\.label),
                       ["1", "1.25", "1.5", "2", "2.5"].map { "\($0) times speed" })

        let onePointFive = app.buttons["listening.preset.1.5"].firstMatch
        onePointFive.tap()
        XCTAssertTrue(wait(for: "selected == true", onePointFive), "The tapped preset carries .isSelected")
        let selected = buttons.allElementsBoundByIndex.filter(\.isSelected).map(\.identifier)
        XCTAssertEqual(selected, ["listening.preset.1.5"], "Only the tapped preset is selected")

        let slider = app.sliders["listening.speed.slider"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: slider), "1.5×")
    }

    func testVoiceRowsHaveNoNestedButtons() {
        let app = launchReader()
        openListeningSheet(app)

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "At least the System row")
        for row in rows.allElementsBoundByIndex {
            XCTAssertEqual(row.descendants(matching: .button).count, 0,
                           "\(row.identifier) should be one button with nothing nested")
        }
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'voice.preview.'"))
        XCTAssertEqual(previews.count, 0, "Per-row preview buttons are gone")
    }

    func testPickingAVoiceKeepsSheetOpen() {
        let app = launchReader()
        openListeningSheet(app)

        let system = app.buttons["voice.system"].firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 10))
        system.tap()
        XCTAssertFalse(waitForNonExistence(of: app.staticTexts["listening.title"].firstMatch, timeout: 1),
                       "Picking a voice leaves the sheet open for comparing")
    }

    func testSelectedVoiceVisibleOnOpen() throws {
        let modelDirectory = KokoroPlaybackUITest.modelDirectory
        guard FileManager.default.fileExists(atPath: modelDirectory + "/model.onnx") else {
            throw XCTSkip("Kokoro model files not present on host at \(modelDirectory)")
        }
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classics", "1",
                                         "-uitest-open-first-doc", "-uitest-reset-voice-pref",
                                         "-uitest-kokoro-model-path", modelDirectory])
        app.launch()

        let ids = ["am_michael", "aloud_velvet", "aloud_anchor", "aloud_ember", "am_fenrir", "am_puck", "af_heart",
                   "af_bella", "af_nicole", "af_sarah", "bf_emma"].map { "kokoro:" + $0 } + ["system"]
        for id in ids {
            openListeningSheet(app)
            let row = app.buttons["voice.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "voice.\(id) is listed")
            row.tap()
            dismissListeningSheet(app)

            openListeningSheet(app)
            XCTAssertTrue(wait(for: "hittable == true", app.buttons["voice.\(id)"].firstMatch, timeout: 5),
                          "The selected voice.\(id) should be on screen when the sheet opens")
            dismissListeningSheet(app)
        }
    }

    func testSettingsReachesSameListeningView() {
        let app = XCUIApplication.aloud(["-uitest-reset-voice-pref", "-uitest-temp-model-dir"])
        app.launch()

        let settings = app.buttons["library.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let listening = app.buttons["settings.listening"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.voice"].exists, "The separate Voice row is gone")
        XCTAssertFalse(app.buttons["settings.speed"].exists, "The separate Speed row is gone")
        listening.tap()

        XCTAssertTrue(app.buttons["listening.preset.1"].firstMatch.waitForExistence(timeout: 10))
        let readAsides = app.switches["listening.readAsides"].firstMatch
        XCTAssertTrue(readAsides.waitForExistence(timeout: 5))
        // skipBrackets defaults on, shown inverted: asides are not read.
        XCTAssertEqual(stringValue(of: readAsides), "0")
    }

    /// Clipping is audited on the Voice & speed page Settings pushes: the
    /// same ListeningView as the sheet. Inside the reader's content-sized
    /// sheet the clipping check flags lines that are whole on screen (the
    /// run's recording shows them); pushed, the same views pass. So the
    /// sheet's own audit leaves clipping to this one.
    func testVoiceAndSpeedPageClipsNothing() throws {
        for size in AuditTextSize.all {
            let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classics", "1",
                                             "-uitest-temp-model-dir"] + size.launchArguments)
            app.launch()
            let settings = app.buttons["library.settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 20))
            settings.tap()
            let row = app.buttons["settings.listening"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(app.buttons["model.download"].firstMatch.waitForExistence(timeout: 10))
            var issues: [String] = []
            try app.performAccessibilityAudit(for: .textClipped) { issue in
                if issue.element?.identifier.hasPrefix("debug.") == true { return true }
                issues.append(self.describe(issue))
                return true   // collected, so one failure lists them all
            }
            XCTAssertEqual(issues, [], "Voice & speed page at \(size.name)")
            app.terminate()
        }
    }

    func testListeningSheetAccessibilityAudit() throws {
        var previous: (size: AuditTextSize, height: CGFloat)?
        for size in AuditTextSize.all {
            let app = launchReader(size.launchArguments)
            openListeningSheet(app)
            let title = settledFrame(of: app.staticTexts["listening.title"].firstMatch)
            assertTextSizeTook(size, height: title.height, over: previous)
            previous = (size, title.height)
            // Only the sheet: the reader above and behind it has its own
            // audit, and the root's 1×1 DEBUG probes aren't UI. The sheet
            // starts at its grabber, just over the title.
            let sheetTop = title.minY - 24
            func isReader(_ element: XCUIElement) -> Bool {
                element.frame.minY < sheetTop
                    || ["reader.", "player.", "debug."].contains { element.identifier.hasPrefix($0) }
            }
            var issues: [String] = []
            func collect(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
                if let element = issue.element, isReader(element) { return true }
                issues.append(self.describe(issue))
                return true   // collected, so one failure lists them all
            }
            // The settled sheet first, then Dynamic Type on its own: that
            // audit steps the text size live and this sheet's detent follows
            // its content (R8), so the sheet resizes through every step.
            // Clipping is audited on the pushed page instead
            // (testVoiceAndSpeedPageClipsNothing): in this sheet the check
            // flags lines that are whole on screen, even at rest.
            try app.performAccessibilityAudit(for: [.contrast, .hitRegion,
                                                    .sufficientElementDescription], collect)
            try app.performAccessibilityAudit(for: .dynamicType, collect)
            XCTAssertEqual(issues, [], "Listening sheet at \(size.name)")
            app.terminate()
        }
    }
}
