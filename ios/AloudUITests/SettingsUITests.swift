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

    /// The identifiers of the buttons, switches and segmented controls under
    /// `prefix`, sorted.
    private func controlIdentifiers(withPrefix prefix: String, in app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let controls = app.buttons.matching(predicate).allElementsBoundByIndex
            + app.switches.matching(predicate).allElementsBoundByIndex
            + app.segmentedControls.matching(predicate).allElementsBoundByIndex
        return Set(controls.map(\.identifier)).sorted()
    }

    /// The System / Light / Dark control: one segmented control for
    /// VoiceOver, named Appearance (P039).
    private func schemeControl(_ app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["appearance.scheme"].firstMatch
    }

    /// One of its three choices, by its visible name.
    private func schemeChoice(_ label: String, in app: XCUIApplication) -> XCUIElement {
        schemeControl(app).buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    /// "appearance.textSize.larger" → "appearance.textSize": one control group.
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
            let system = self.schemeChoice("System", in: app)
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
        let dark = schemeChoice("Dark", in: app)
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
        let dark = schemeChoice("Dark", in: app)
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
        // Done is the sheet's chrome (it leaves the page live, P037), not one
        // of the view's controls: the pushed page has none.
        XCTAssertTrue(app.buttons["appearance.done"].firstMatch.exists, "The Aa sheet carries Done")
        let sheetControls = controlIdentifiers(withPrefix: "appearance.", in: app).filter { $0 != "appearance.done" }
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

    // MARK: - iPhone parity, batch B5

    /// P037: the Aa sheet leaves the page live behind it. A tap on the
    /// reader's bar above it (never the text, which would play) no longer
    /// closes it, A+ changes the size with the sheet still open, and Done
    /// closes it. The sheet passes the audit.
    func testTheAaSheetLeavesThePageLiveAndDoneClosesIt() throws {
        let app = launch(["-uitest-reset-library", "-uitest-seed-first-classic", "-uitest-temp-model-dir",
                          "-aloud.prefs.v1.textSize", "2"])
        openBook(app)
        let aa = app.buttons["reader.appearance"].firstMatch
        XCTAssertTrue(aa.waitForExistence(timeout: 20))
        aa.tap()
        let title = app.staticTexts["appearance.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The Aa sheet should open")
        let done = app.buttons["appearance.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(done.frame.height, 44, "Done is a full touch target")
        XCTAssertEqual(done.label, "Done")

        // Without a scrim, a tap above the sheet reaches the page, not a dismiss.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
        XCTAssertFalse(waitForNonExistence(of: title, timeout: 2), "A tap outside no longer closes the Aa sheet")

        let size = app.descendants(matching: .any)["appearance.textSize.value"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.label, "Text size")
        XCTAssertEqual(stringValue(of: size), "19 point")
        app.buttons["appearance.textSize.larger"].firstMatch.tap()
        XCTAssertTrue(waitForValue("21 point", of: size, timeout: 5), "A+ steps 19 to 21 pt, live")
        XCTAssertTrue(title.exists, "The sheet stays open while the page reflows")

        let sheetTop = title.frame.minY - 24
        var issues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription]) { issue in
            // Only the sheet: the live page behind it has its own audit.
            if let element = issue.element,
               element.frame.minY < sheetTop
                || ["reader.", "player.", "debug."].contains(where: { element.identifier.hasPrefix($0) }) {
                return true
            }
            issues.append(self.describe(issue))
            return true   // collected, so one failure lists them all
        }
        XCTAssertEqual(issues, [], "The Aa sheet")

        // The bar under the sheet is out of VoiceOver's reach while it's up:
        // its Voice chip would ask for a second sheet iOS refuses.
        let voiceChip = app.buttons["player.listening"].firstMatch
        XCTAssertFalse(voiceChip.exists, "The covered player bar is hidden from VoiceOver")

        done.tap()
        XCTAssertTrue(waitForNonExistence(of: title, timeout: 10), "Done closes the Aa sheet")
        XCTAssertTrue(voiceChip.waitForExistence(timeout: 5), "The bar is back once the sheet goes")
        voiceChip.tap()
        let listening = app.staticTexts["listening.title"].firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 10), "The Voice chip still opens its sheet")
        dismissListeningSheet(app)
    }

    /// P039 at accessibility sizes: the stacked System / Light / Dark
    /// capsules are three elements in a group named Appearance, each framed
    /// on its own capsule (a segmented control laid its segments side by
    /// side across the stack, so a tap on its Dark could land on System),
    /// with its place in the three; a tap on Dark picks Dark.
    func testStackedAppearanceChoicesAreEachTheirOwnElement() {
        let app = launch(["-uitest-temp-model-dir",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let scheme = app.descendants(matching: .any)["appearance.scheme"].firstMatch
        func choice(_ label: String) -> XCUIElement {
            scheme.buttons.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
        }
        addTeardownBlock {
            let system = choice("System")
            if system.exists, !system.isSelected { system.tap() }
        }
        openSettings(app)
        app.buttons["settings.appearance"].firstMatch.tap()
        XCTAssertTrue(scheme.waitForExistence(timeout: 10), "The scheme group")

        let choices = ["System", "Light", "Dark"].map(choice)
        for _ in 0..<6 where !choices[2].isHittable { app.swipeUp() }
        XCTAssertTrue(choices.allSatisfy(\.exists), "Each choice is its own element")
        XCTAssertEqual(scheme.label, "Appearance")
        let frames = choices.map(\.frame)
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.maxY, lower.minY + 1, "Stacked: \(upper) over \(lower)")
        }
        for frame in frames {
            XCTAssertGreaterThan(frame.width, scheme.frame.width * 0.8, "Each spans its own capsule: \(frame)")
        }
        XCTAssertEqual(choices[2].value as? String, "3 of 3")

        choices[2].tap()
        XCTAssertTrue(wait(for: "selected == true", on: choices[2]), "Dark should be selected")
        XCTAssertFalse(choices[0].isSelected, "System no longer is")
    }

    /// P039: VoiceOver hears System / Light / Dark as one segmented control
    /// named Appearance (so each choice says its place in the three), and a
    /// choice persists across a relaunch. The size readout is one element,
    /// "Text size" with its value, which the shared step rule moves.
    func testAppearanceIsOneSegmentedControlAndSizeOneElement() {
        var app = launch(["-uitest-temp-model-dir"])
        // Whichever launch is running at the end puts System back.
        addTeardownBlock {
            let system = self.schemeChoice("System", in: app)
            if system.exists, !system.isSelected { system.tap() }
        }
        openSettings(app)
        app.buttons["settings.appearance"].firstMatch.tap()

        let scheme = schemeControl(app)
        XCTAssertTrue(scheme.waitForExistence(timeout: 10), "One segmented control")
        XCTAssertEqual(scheme.label, "Appearance")
        XCTAssertEqual(scheme.buttons.count, 3, "System, Light and Dark")
        let dark = schemeChoice("Dark", in: app)
        dark.tap()
        XCTAssertTrue(wait(for: "selected == true", on: dark), "Dark should be selected")

        let size = app.descendants(matching: .any)["appearance.textSize.value"].firstMatch
        XCTAssertTrue(size.exists)
        XCTAssertEqual(size.label, "Text size")
        XCTAssertTrue(stringValue(of: size).hasSuffix(" point"), "got '\(stringValue(of: size))'")

        app.terminate()
        app = launch(["-uitest-temp-model-dir"])
        openSettings(app)
        app.buttons["settings.appearance"].firstMatch.tap()
        XCTAssertTrue(schemeControl(app).waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: "selected == true", on: schemeChoice("Dark", in: app)),
                      "The choice persists (appearanceRaw)")
    }

    /// P040: the root's rows say their values, title first: the size and
    /// scheme, and, while the natural voice isn't installed, that it is
    /// available. Exactly three rows stay.
    func testTheRootRowsSayTheirValues() {
        let app = launch(["-uitest-temp-model-dir", "-aloud.prefs.v1.textSize", "2",
                          "-aloud.prefs.v1.appearance", "system"])
        openSettings(app)
        XCTAssertEqual(controlIdentifiers(withPrefix: "settings.", in: app),
                       ["settings.appearance", "settings.licenses", "settings.listening"])
        XCTAssertEqual(app.buttons["settings.appearance"].firstMatch.label,
                       "Text & appearance, 19 point, System appearance")
        let listening = app.buttons["settings.listening"].firstMatch.label
        XCTAssertTrue(listening.hasPrefix("Voice & speed, "), listening)
        XCTAssertTrue(listening.hasSuffix(", Natural voice available, 353 MB"),
                      "The natural voice is named while it isn't installed; got '\(listening)'")
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
            XCTAssertTrue(schemeControl(app).waitForExistence(timeout: 10))
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
