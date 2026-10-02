import XCTest

/// R17 on the shipped long books. Pepys' Diary: the scrub spans one month,
/// a plain tap never seeks, a 100pt drag does (and keeps the book paused),
/// a full-width drag stays inside the chapter, and each drag plays exactly
/// one release haptic. War and Peace: Contents groups its chapters under
/// "BOOK ONE: 1805" and friends, marks the current chapter, and a row is a
/// jump that offers Undo jump (R15).
///
/// Muted, and nothing plays: autoplay stays suppressed and no test taps
/// Play. Run only with the user's OK. The playhead is read through the
/// reader.sentence.<n> probe only.
final class ScrubAndContentsUITest: XCTestCase {

    /// Mid-month in June 1660 (the 19th), so drags land well away from it.
    private static let pepysPassage = "his bad condition and to get a place for him"

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Harness

    /// Opens one seeded classic in the reader, paused. The offer reset keeps
    /// the natural-voice offer out of the chapter line; the temp model
    /// directory keeps a seeded Kokoro model out.
    private func openReader(classic: Int, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.aloud(["-uitest-seed-classic", "\(classic)",
                                         "-uitest-reset-library", "-uitest-open-first-doc",
                                         "-uitest-temp-model-dir", "-uitest-reset-natural-voice-offer"] + extra)
        app.launch()
        // The first open extracts the whole book.
        XCTAssertTrue(app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 180),
                      "The reader should open")
        return app
    }

    private func openPepys(_ extra: [String] = []) -> (app: XCUIApplication, start: Int) {
        let app = openReader(classic: 4200, ["-uitest-seek-text", Self.pepysPassage] + extra)
        let start = waitForSentence(in: app, timeout: 30) { $0 > 0 }
        XCTAssertNotNil(start, "The seek-text hook should cue the playhead mid-book")
        return (app, start ?? 0)
    }

    /// Adjustable, so XCUITest reports it as a slider: query by identifier
    /// across every element type.
    private func scrubElement(in app: XCUIApplication) -> XCUIElement {
        let scrub = app.descendants(matching: .any)["player.scrub"].firstMatch
        XCTAssertTrue(scrub.waitForExistence(timeout: 10), "The scrub should exist")
        return scrub
    }

    private func point(_ fraction: CGFloat, on element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
    }

    /// A finger down on the track, dragged sideways by `dx` points.
    private func drag(_ element: XCUIElement, from fraction: CGFloat, by dx: CGFloat) {
        let start = point(fraction, on: element)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)))
    }

    private func drag(_ element: XCUIElement, from: CGFloat, to: CGFloat) {
        point(from, on: element).press(forDuration: 0.1, thenDragTo: point(to, on: element))
    }

    /// Lets the app run for `seconds` (an expectation nobody fulfils).
    private func idle(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "idle")], timeout: seconds)
    }

    /// "6 of 120" from the chapter line's label ("JUNE 1660, 6 of 120, …").
    private func chapterPosition(_ app: XCUIApplication) -> String? {
        let line = app.buttons["reader.chapterLine"].firstMatch
        guard line.waitForExistence(timeout: 10),
              let range = line.label.range(of: #"\d+ of \d+"#, options: .regularExpression) else { return nil }
        return String(line.label[range])
    }

    private func scrubReleases(_ app: XCUIApplication) -> Int {
        hapticLog(app).filter { $0 == "scrubRelease" }.count
    }

    // MARK: - Pepys: the scrub

    func testScrubSeeksOnlyOnASidewaysDragWithinTheChapter() {
        let (app, start) = openPepys()
        let scrub = scrubElement(in: app)
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(scrub.frame.height, 44, "The scrub's hit row is \(scrub.frame.height)pt tall")

        let chapter = chapterPosition(app)
        XCTAssertNotNil(chapter, "A dated month reads 'N of M' on the chapter line")

        // A plain tap does nothing (it used to teleport the playhead).
        point(0.8, on: scrub).tap()
        idle(1.5)
        XCTAssertEqual(currentSentence(app), start, "A tap at 80% of the scrub must not seek")

        // A 100pt drag seeks, and a paused book stays paused.
        drag(scrub, from: 0.5, by: 100)
        let dragged = waitForSentence(in: app, timeout: 10) { $0 != start }
        XCTAssertNotNil(dragged, "A 100pt drag should move the playhead")
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 5),
                      "A scrub keeps play/pause, got '\(stringValue(of: play))'")

        // The whole track is this month: a full-width drag advances without
        // leaving the chapter.
        let before = currentSentence(app) ?? start
        drag(scrub, from: 0.02, to: 0.98)
        XCTAssertNotNil(waitForSentence(in: app, timeout: 10) { $0 > before },
                        "A drag to 98% should advance past sentence \(before)")
        XCTAssertEqual(chapterPosition(app), chapter, "The scrub spans only the current chapter")
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 5))
    }

    func testEachDragPlaysOneReleaseHaptic() {
        let (app, start) = openPepys(["-uitest-haptic-log"])
        let scrub = scrubElement(in: app)
        let probe = app.descendants(matching: .any)["debug.haptics"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "-uitest-haptic-log should publish debug.haptics")
        XCTAssertEqual(scrubReleases(app), 0)

        point(0.8, on: scrub).tap()
        idle(1.5)
        XCTAssertEqual(scrubReleases(app), 0, "A tap is not a seek and plays nothing")

        drag(scrub, from: 0.5, by: 100)
        XCTAssertNotNil(waitForSentence(in: app, timeout: 10) { $0 != start })
        idle(0.5)
        XCTAssertEqual(scrubReleases(app), 1, "One drag, one tick: \(hapticLog(app))")

        drag(scrub, from: 0.9, by: -150)
        idle(1.5)
        XCTAssertEqual(scrubReleases(app), 2, "Each drag ticks once on release: \(hapticLog(app))")
    }

    // MARK: - War and Peace: Contents

    func testContentsGroupsChaptersAndARowOffersUndo() {
        let app = openReader(classic: 2600)
        let start = waitForSentence(in: app, timeout: 30) { _ in true }
        XCTAssertNotNil(start, "The playhead probe should report a sentence")

        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 10))
        chapterLine.tap()

        // XCUITest exposes no header trait; ContentsSheetAccessibilityTests
        // checks it. Here: the pinned section title is static text.
        let section = app.staticTexts["contents.section.0"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 10), "Contents should open with its first section header")
        XCTAssertTrue(section.label.hasPrefix("BOOK ONE: 1805"), "First section: '\(section.label)'")

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapters.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "Contents should list chapters")
        let selected = rows.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selected.exists, "The current chapter carries .isSelected")

        // The second row is a chapter the playhead isn't in.
        let target = rows.element(boundBy: 1)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertFalse(target.isSelected, "The playhead starts in the first chapter")
        target.tap()

        XCTAssertTrue(waitForNonExistence(of: section, timeout: 10), "A row pick closes Contents")
        XCTAssertNotNil(waitForSentence(in: app, timeout: 10) { $0 != start },
                        "A row pick moves the playhead")
        XCTAssertTrue(app.buttons["reader.undoJump"].firstMatch.waitForExistence(timeout: 5),
                      "A Contents pick offers Undo jump")
        XCTAssertTrue(waitForValue("paused", of: app.buttons["player.play"].firstMatch, timeout: 5),
                      "A Contents pick keeps play/pause")
    }
}
