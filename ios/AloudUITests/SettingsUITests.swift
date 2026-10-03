import XCTest

/// R21: Settings is three rows and a footer; Dark is three taps away from
/// the Library and from a book; the Aa sheet and the Settings page show one
/// view of three controls; both screens pass the accessibility audit at
/// Large, AX3 and AX5; and the download can't leave the user stuck (too
/// little space, damaged voice files).
///
/// Every launch is muted (`XCUIApplication.aloud`); only the damaged-model
/// test lets autoplay run. Never run without the user's OK.
final class SettingsUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = [], allowAutoplay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication.aloud(arguments, allowAutoplay: allowAutoplay)
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["library.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), file: file, line: line)
        settings.tap()
        XCTAssertTrue(app.buttons["settings.listening"].firstMatch.waitForExistence(timeout: 10),
                      "Settings should open", file: file, line: line)
    }

    /// The seeded classic's reader, from its card (one tap).
    private func openBook(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                    ["library.card", "library.continue"])).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The seeded classic", file: file, line: line)
        card.tap()
    }

    /// The identifiers of the buttons and switches under `prefix`, sorted.
    private func controlIdentifiers(withPrefix prefix: String, in app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let controls = app.buttons.matching(predicate).allElementsBoundByIndex
            + app.switches.matching(predicate).allElementsBoundByIndex
        return Set(controls.map(\.identifier)).sorted()
    }

    /// "appearance.scheme.dark" → "appearance.scheme": one control group.
    private func group(_ identifier: String) -> String {
        identifier.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private func wait(for format: String, on element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A test that picks Dark puts System back, so later launches aren't dark.
    private func restoreSystemAppearance(after app: XCUIApplication) {
        addTeardownBlock {
            let system = app.buttons["appearance.scheme.system"].firstMatch
            if system.exists, !system.isSelected { system.tap() }
        }
    }

    private func auditIssues(_ app: XCUIApplication) throws -> [String] {
        var issues: [String] = []
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .contrast,
                                                .hitRegion, .sufficientElementDescription]) { issue in
            // The root's 1×1 DEBUG probes (debug.announcements) aren't UI.
            if issue.element?.identifier.hasPrefix("debug.") == true { return true }
            // The bar caps its title's scaling by design; the title shows the
            // Large Content Viewer instead.
            if self.isNavigationBarTextScaling(issue, in: app) { return true }
            issues.append(self.describe(issue))
            return true   // collected, so one failure lists them all
        }
        return issues
    }

    // MARK: - Three rows and a footer

    func testSettingsIsThreeRowsAndAFooter() {
        let app = launch(["-uitest-temp-model-dir"])
        openSettings(app)

        XCTAssertEqual(controlIdentifiers(withPrefix: "settings.", in: app),
                       ["settings.appearance", "settings.licenses", "settings.listening"])
        XCTAssertEqual(app.switches.count, 0, "Every preference lives on a pushed page")

        let privacy = app.staticTexts["settings.privacy"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertEqual(privacy.label, "Everything stays on your device.")
        let version = app.staticTexts["settings.version"].firstMatch
        XCTAssertTrue(version.exists)
        XCTAssertTrue(version.label.hasPrefix("Version "), "got '\(version.label)'")

        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Auto-scroll' OR label CONTAINS 'Word highlight'"))
            .count, 0, "Auto-scroll is gone and Word highlight has one home")
    }

    // MARK: - Dark in three taps

    func testDarkIsThreeTapsFromTheLibrary() {
        let app = launch(["-uitest-temp-model-dir"])
        restoreSystemAppearance(after: app)

        let settings = app.buttons["library.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()                                                   // 1
        let appearance = app.buttons["settings.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()                                                 // 2
        let dark = app.buttons["appearance.scheme.dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 10))
        dark.tap()                                                       // 3

        XCTAssertTrue(wait(for: "selected == true", on: dark), "Dark should be selected")
        XCTAssertEqual(app.staticTexts["appearance.title"].firstMatch.label, "Text & appearance")
    }

    func testDarkIsThreeTapsFromABook() {
        let app = launch(["-uitest-reset-library", "-uitest-seed-first-classic", "-uitest-temp-model-dir"])
        restoreSystemAppearance(after: app)

        openBook(app)                                                    // 1
        let aa = app.buttons["reader.appearance"].firstMatch
        XCTAssertTrue(aa.waitForExistence(timeout: 20))
        aa.tap()                                                         // 2
        let dark = app.buttons["appearance.scheme.dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 10))
        dark.tap()                                                       // 3

        XCTAssertTrue(wait(for: "selected == true", on: dark), "Dark should be selected")
    }

    // MARK: - One view, three controls

    func testTheAaSheetAndTheSettingsPageShowTheSameThreeControls() {
        let app = launch(["-uitest-reset-library", "-uitest-seed-first-classic", "-uitest-temp-model-dir"])
        openBook(app)
        let aa = app.buttons["reader.appearance"].firstMatch
        XCTAssertTrue(aa.waitForExistence(timeout: 20))
        aa.tap()

        let title = app.staticTexts["appearance.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The Aa sheet should open")
        XCTAssertEqual(title.label, "Text & appearance")
        let sheetControls = controlIdentifiers(withPrefix: "appearance.", in: app)
        let groups = Set(sheetControls.map(group))
        XCTAssertLessThanOrEqual(groups.count, 4, "The Aa view has 4 or fewer controls")
        XCTAssertEqual(groups, ["appearance.scheme", "appearance.textSize", "appearance.wordHighlight"])

        dragSheetClosed(app, by: title)
        XCTAssertTrue(waitForNonExistence(of: title, timeout: 10), "The Aa sheet should close")
        tapSystemBack(app)
        openSettings(app)
        app.buttons["settings.appearance"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["appearance.title"].firstMatch.waitForExistence(timeout: 10))

        XCTAssertEqual(controlIdentifiers(withPrefix: "appearance.", in: app), sheetControls,
                       "Settings pushes the same view the Aa sheet presents")
    }

    // MARK: - Accessibility

    func testSettingsAndAppearanceAccessibilityAudit() throws {
        var previous: (size: AuditTextSize, height: CGFloat)?
        for size in AuditTextSize.all {
            let app = launch(["-uitest-temp-model-dir"] + size.launchArguments)
            openSettings(app)
            let row = app.buttons["settings.listening"].firstMatch.frame
            assertTextSizeTook(size, height: row.height, over: previous)
            previous = (size, row.height)
            XCTAssertEqual(try auditIssues(app), [], "Settings at \(size.name)")

            app.buttons["settings.appearance"].firstMatch.tap()
            XCTAssertTrue(app.buttons["appearance.scheme.dark"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(try auditIssues(app), [], "Text & appearance at \(size.name)")
            app.terminate()
        }
    }

    // MARK: - The download can't leave the user stuck

    func testTooLittleSpaceShowsTheSpaceLineAndDownloadsNothing() {
        let app = launch(["-uitest-temp-model-dir", "-uitest-low-disk"])
        openSettings(app)
        app.buttons["settings.listening"].firstMatch.tap()

        let download = app.buttons["model.download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10), "The natural-voice card")
        for _ in 0..<6 where !download.isHittable { app.swipeUp() }
        download.tap()

        let failure = app.buttons["model.failure"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "The space line replaces the card's button")
        XCTAssertEqual(failure.label, "Not enough space, need 707 MB free")
        XCTAssertFalse(app.descendants(matching: .any)["model.progress"].firstMatch.waitForExistence(timeout: 3),
                       "Nothing was downloaded")
    }

    func testDamagedVoiceFilesFallBackToSystem() {
        let app = launch(["-uitest-damaged-model", "-uitest-reset-library", "-uitest-reset-voice-pref",
                          "-uitest-seed-classics", "1", "-uitest-open-first-doc"], allowAutoplay: true)
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "The reader should open")
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 30), "Autoplay should start")

        let chip = app.buttons["player.listening"].firstMatch
        XCTAssertTrue(wait(for: "label BEGINSWITH 'System'", on: chip, timeout: 30),
                      "Damaged files fall back to System, got '\(chip.label)'")
        chip.tap()
        XCTAssertTrue(app.staticTexts["listening.title"].firstMatch.waitForExistence(timeout: 10))
        let failure = app.buttons["model.failure"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10), "The card says what happened")
        XCTAssertEqual(failure.label, "Voice files damaged, Download again")
    }
}
