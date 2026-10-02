import XCTest

extension XCUIApplication {

    /// The only way a UI test creates the app: always muted, autoplay off
    /// unless asked. `-uitest-mute` is always first, and
    /// `-uitest-allow-autoplay` lifts the autoplay suppression only — nothing
    /// un-mutes.
    ///
    /// The only place XCUIApplication() may appear.
    static func aloud(_ arguments: [String] = [], allowAutoplay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-mute"] + arguments + (allowAutoplay ? ["-uitest-allow-autoplay"] : [])
        return app
    }
}

/// The Dynamic Type sizes the PRD's accessibility audits run at (Large, AX3,
/// AX5). Each category is a UIContentSizeCategory raw value. UIKit ignores a
/// name it doesn't know and quietly renders the default size, so the names
/// are spelled once, here, and every audit checks that its size took effect
/// (`assertTextSizeTook`).
struct AuditTextSize {
    let name: String
    let category: String

    static let all = [
        AuditTextSize(name: "Large", category: "UICTContentSizeCategoryL"),
        AuditTextSize(name: "AX3", category: "UICTContentSizeCategoryAccessibilityXL"),
        AuditTextSize(name: "AX5", category: "UICTContentSizeCategoryAccessibilityXXXL"),
    ]

    var launchArguments: [String] { ["-UIPreferredContentSizeCategoryName", category] }
}

/// Shared helpers for every UI-test class. One copy only: a fix to the
/// waiter's semantics (predicate shape, polling, Optional-wrapped values on
/// a new runtime, …) lands everywhere at once instead of in whichever file
/// happened to flake.
extension XCTestCase {

    /// Wait until the element's accessibility `value` equals `expected`.
    func waitForValue(_ expected: String, of element: XCUIElement,
                      timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Wait until the element's accessibility `value` is any of `expected`
    /// (for example "playing" or "buffering").
    func waitForValue(in expected: [String], of element: XCUIElement,
                      timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value IN %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The element's accessibility `value` as a string ("" when absent).
    func stringValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    /// Wait until the element is gone. The positive counterpart is often not
    /// a valid substitute: a sheet leaves the screen behind it in the
    /// accessibility hierarchy, so "the reader is still there" says nothing
    /// about whether the sheet closed.
    func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Fails unless text measured at `size` is taller than the same text at
    /// the previous, smaller audit size. Without it, a content-size name
    /// UIKit doesn't recognize audits Large again and still passes.
    func assertTextSizeTook(_ size: AuditTextSize, height: CGFloat,
                            over previous: (size: AuditTextSize, height: CGFloat)?,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let previous else { return }
        XCTAssertGreaterThan(height, previous.height,
                             "Text at \(size.name) should be taller than at \(previous.size.name); "
                                + "is \(size.category) a real content-size category?",
                             file: file, line: line)
    }

    /// Whether an audit issue is a Dynamic Type issue on navigation-bar
    /// content. UIKit caps text scaling inside bars by design (a bar keeps
    /// its height at every size), so the audit calls a bar title "partially
    /// unsupported" however its font is built. Apple's answer for bar
    /// content is the Large Content Viewer, which every custom bar title
    /// opts into (`.accessibilityShowsLargeContentViewer()`). Any other
    /// issue type, and any Dynamic Type issue below the bar, still fails.
    func isNavigationBarTextScaling(_ issue: XCUIAccessibilityAuditIssue,
                                    in app: XCUIApplication) -> Bool {
        guard issue.auditType == .dynamicType, let element = issue.element else { return false }
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        return app.navigationBars.allElementsBoundByIndex.contains { $0.frame.contains(center) }
    }

    /// The system search field's prompt ("Title or author") reported as
    /// clipped: iOS draws that field, and the prompt fits its 370pt width with
    /// room to spare. Anything else that clips is still an issue.
    func isSystemSearchPromptClipping(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.auditType == .textClipped && issue.element?.elementType == .searchField
    }

    /// How many books the Library shows: grid cards plus the Continue card.
    func libraryCount(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                         ["library.card", "library.continue"])).count
    }

    /// Taps the system back button (the leading navigation-bar button).
    func tapSystemBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Drags a sheet down by an element in its pinned header, all the way to
    /// the bottom of the screen. `swipeDown()` on a small label travels only
    /// that label's height, which is too short to dismiss a sheet.
    func dragSheetClosed(_ app: XCUIApplication, by header: XCUIElement) {
        guard header.exists else { return }
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Drags the Listening sheet down by its pinned title: a swipe over the
    /// list could scroll it instead of closing the sheet.
    func dismissListeningSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["listening.title"].firstMatch
        dragSheetClosed(app, by: title)
        XCTAssertTrue(waitForNonExistence(of: title, timeout: 10),
                      "The Listening sheet should close", file: file, line: line)
    }
}

/// DEBUG probes the app publishes on UI-test launches (R11, R12e, R16, R20).
/// The playhead lives in an identifier, never a value (R12e), so tests read
/// it only through these.
extension XCTestCase {

    /// The playhead probe: identifier "reader.sentence.<n>", label "Playhead".
    func sentenceProbe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.sentencePrefix))
            .firstMatch
    }

    /// The current sentence, or nil while no reader is showing.
    func currentSentence(_ app: XCUIApplication) -> Int? {
        let probe = sentenceProbe(app)
        guard probe.exists else { return nil }
        return Self.suffixNumber(of: probe.identifier, after: Self.sentencePrefix)
    }

    /// Wait until the playhead is on `sentence`.
    func waitForSentence(_ sentence: Int, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any)["\(Self.sentencePrefix)\(sentence)"].firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// Wait until the playhead satisfies `accept`; the sentence it was on,
    /// or nil on timeout.
    func waitForSentence(in app: XCUIApplication, timeout: TimeInterval,
                         where accept: (Int) -> Bool) -> Int? {
        var found: Int?
        poll(timeout: timeout) {
            guard let sentence = currentSentence(app), accept(sentence) else { return false }
            found = sentence
            return true
        }
        return found
    }

    /// Programmatic follow scrolls since the reader opened
    /// ("reader.followScrolls.<n>").
    func followScrollCount(_ app: XCUIApplication) -> Int? {
        let prefix = "reader.followScrolls."
        let probe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        guard probe.exists else { return nil }
        return Self.suffixNumber(of: probe.identifier, after: prefix)
    }

    /// The page line the active sentence's top sits on, counted from the
    /// top of the column ("reader.activeLine.<n>").
    func activeLine(_ app: XCUIApplication) -> Int? {
        let prefix = "reader.activeLine."
        let probe = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        guard probe.exists else { return nil }
        return Self.suffixNumber(of: probe.identifier, after: prefix)
    }

    /// One audit issue as a line a failure can act on: what, the element's
    /// identifier and label, and where it sits.
    func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let check = "audit \(issue.auditType.rawValue)"
        guard let element = issue.element else { return "\(issue.compactDescription) (\(check)) [no element]" }
        let f = element.frame
        return "\(issue.compactDescription) (\(check)) [\(element.identifier)] '\(element.label)' "
            + "(\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width))x\(Int(f.height)))"
    }

    /// The active sentence's frame on screen.
    func activeSentenceFrame(_ app: XCUIApplication) -> CGRect? {
        let probe = app.descendants(matching: .any)["reader.activeSentence"].firstMatch
        return probe.exists ? probe.frame : nil
    }

    /// Every VoiceOver announcement the app recorded, oldest first.
    func announcements(_ app: XCUIApplication) -> [String] {
        probeLines(app, identifier: "debug.announcements", separator: "\n")
    }

    /// Wait until `text` has been announced, matching a whole entry.
    func waitForAnnouncement(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) { announcements(app).contains(text) }
    }

    /// The transport haptics played, oldest first (needs -uitest-haptic-log).
    func hapticLog(_ app: XCUIApplication) -> [String] {
        probeLines(app, identifier: "debug.haptics", separator: ",")
    }

    // MARK: - Probe plumbing

    private static let sentencePrefix = "reader.sentence."

    private static func suffixNumber(of identifier: String, after prefix: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }

    private func probeLines(_ app: XCUIApplication, identifier: String, separator: Character) -> [String] {
        let probe = app.descendants(matching: .any)[identifier].firstMatch
        guard probe.exists else { return [] }
        return stringValue(of: probe).split(separator: separator).map(String.init)
    }

    /// Re-checks `condition` until it holds or `timeout` passes, letting the
    /// app run between snapshots. True when it held.
    @discardableResult
    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            guard Date() < deadline else { return false }
            // An expectation nobody fulfils: a wait that spins the run loop
            // and never fails the test.
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "poll")], timeout: 0.25)
        }
    }
}
