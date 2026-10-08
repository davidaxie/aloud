import XCTest

/// R17 on the shipped long books. Pepys' Diary: the scrub spans one month,
/// a plain tap never seeks, a 100pt drag does (and keeps the book paused),
/// a full-width drag stays inside the chapter, and each drag plays exactly
/// one release haptic. War and Peace: Contents groups its chapters under
/// "BOOK ONE: 1805" and friends, marks the current chapter, and a row is a
/// jump that plays from there and offers Undo jump (R15, P025). Then the
/// parity batch's Contents (P024-P033): half height shows the newest stop
/// and the chapters, a picked search comes back, the Search key and Cancel
/// let the keyboard go, and the chapter line's menu goes straight to search.
///
/// Muted throughout: autoplay stays suppressed, and only a Contents pick
/// (or the error test's Play) plays, silently. Run only with the user's OK.
/// The playhead is read through the reader.sentence.<n> probe only.
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

    /// Opens Contents from the chapter line.
    @discardableResult
    private func openContents(_ app: XCUIApplication) -> XCUIElement {
        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 10))
        chapterLine.tap()
        let title = app.staticTexts["contents.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Contents should open")
        return title
    }

    /// Drags Contents closed by its title, from either height: a drag to
    /// the bottom of the screen (`dragSheetClosed`), not `swipeDown()`,
    /// which on the title label travels only the label's height and never
    /// moves the sheet.
    private func closeContents(_ app: XCUIApplication) {
        let title = app.staticTexts["contents.title"].firstMatch
        for _ in 0..<3 where title.exists {
            dragSheetClosed(app, by: title)
            _ = waitForNonExistence(of: title, timeout: 3)
        }
        XCTAssertFalse(title.exists, "Contents should close on a swipe")
    }

    /// Grows Contents to full height: its title dragged to the top of the
    /// screen, as a finger on the grabber would. `swipeUp()` on the title
    /// travels only the label's height and leaves the sheet at half height.
    private func growContents(_ app: XCUIApplication) {
        let title = app.staticTexts["contents.title"].firstMatch
        guard title.exists else { return }
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
    }

    /// Kept with the result, for the visual check (silent: a screenshot).
    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Sampled every tenth of a second: an `XCTNSPredicateExpectation`
    /// evaluates about once a second, so a short timeout read the keyboard
    /// once, at its end, wherever its exit animation had got to.
    private func keyboardGone(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.keyboards.count > 0 {
            guard Date() < deadline else { return false }
            idle(0.1)
        }
        return true
    }

    private func hasKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                                                object: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    /// An empty field reads as nothing or as its placeholder.
    private func isEmpty(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return value.isEmpty || value == field.placeholderValue
    }

    private func chapterRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chapters.row."))
    }

    private func resultRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.result."))
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
        let undo = app.buttons["reader.undoJump"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "A Contents pick offers Undo jump")
        // P025: a pick from a pause plays from there (muted), as a sentence
        // tap and the Mac do.
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: play, timeout: 8),
                      "A Contents pick plays from there, got '\(stringValue(of: play))'")
        undo.tap()
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10), "Undo jump restores the pause")
        if let start {
            XCTAssertTrue(waitForSentence(start, in: app, timeout: 10), "and the sentence it left")
        }
    }

    // MARK: - War and Peace: the parity batch's Contents

    /// P024: with four stops, half height shows the newest stop and the
    /// chapters below it, without a scroll; the earlier-stops toggle comes
    /// with the grown sheet. Run on 375x667, 390x844 and 440x956 simulators.
    func testHalfHeightShowsTheNewestStopAndTheChapters() {
        let app = openReader(classic: 2600, ["-uitest-seed-places", "4"])
        openContents(app)
        let size = app.windows.firstMatch.frame.size
        let screen = "\(Int(size.width))x\(Int(size.height))"

        let header = app.staticTexts["places.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The stops lead the list")
        XCTAssertTrue(header.isHittable, "\(screen): the stops' header shows at half height")
        // The toggle waits for the sheet to grow, so the first chapter
        // clears the fold on the smallest screen.
        let more = app.buttons["places.more"].firstMatch
        XCTAssertFalse(more.exists, "\(screen): no earlier-stops toggle at half height")
        let rows = chapterRows(app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Contents lists chapters")
        let visible = rows.allElementsBoundByIndex.prefix(8).contains { $0.isHittable }
        XCTAssertTrue(visible, "\(screen): a chapter row shows at half height without a scroll")
        keepScreenshot(app, "contents-half-height-\(screen)")

        growContents(app)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Grown, the earlier stops wait behind the toggle")
    }

    /// R1-21: after a book has been listened to, the newest stop and the
    /// playhead share a late chapter, so Contents opens on that chapter at
    /// half height, its current row in view without a scroll (War and
    /// Peace: 365 chapters, the stops seeded through it, the book resumed
    /// at the newest).
    func testContentsOpensOnTheCurrentChapterAfterAListen() {
        let app = openReader(classic: 2600, ["-uitest-seed-places", "4", "-uitest-playhead-at-newest-place"])
        openContents(app)
        let header = app.staticTexts["places.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "The stops still lead the list")
        let current = chapterRows(app).matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), "The current chapter carries .isSelected")
        let firstRow = chapterRows(app).firstMatch
        XCTAssertNotEqual(current.identifier, firstRow.identifier, "The playhead is in a late chapter")
        // The 150 ms repeat of the scroll settles before the check.
        let hittable = NSPredicate(format: "hittable == true")
        let landed = XCTNSPredicateExpectation(predicate: hittable, object: current)
        XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 5), .completed,
                       "At half height, unscrolled, the current chapter's row is in view")
        keepScreenshot(app, "contents-opens-on-current-chapter")
    }

    /// P029: a picked result's search comes back on reopening, the pick
    /// marked and the next hit a tap away; clearing it forgets it.
    func testAPickedSearchComesBackForTheNextHit() {
        let app = openReader(classic: 2600)
        openContents(app)
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Natasha")
        XCTAssertTrue(app.staticTexts["search.count"].firstMatch.waitForExistence(timeout: 20))
        let second = resultRows(app).element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let picked = second.identifier
        second.tap()
        XCTAssertTrue(waitForNonExistence(of: field, timeout: 10), "A pick closes Contents")

        openContents(app)
        XCTAssertEqual(field.value as? String, "Natasha", "The search comes back")
        let mark = app.buttons[picked].firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 20), "Its results come back")
        XCTAssertTrue(mark.isSelected, "The last pick is marked")
        XCTAssertTrue(keyboardGone(app, timeout: 2), "Reopened with the keyboard down")
        let ids = resultRows(app).allElementsBoundByIndex.map(\.identifier)
        let index = ids.firstIndex(of: picked)
        XCTAssertNotNil(index, "The pick is among the results: \(ids)")
        if let index, index + 1 < ids.count {
            XCTAssertTrue(app.buttons[ids[index + 1]].firstMatch.isHittable, "The next hit is a tap away")
        }
        keepScreenshot(app, "contents-remembered-search")

        app.buttons["search.clear"].firstMatch.tap()
        XCTAssertTrue(chapterRows(app).firstMatch.waitForExistence(timeout: 5), "Clearing brings the chapters back")
        closeContents(app)
        openContents(app)
        XCTAssertTrue(isEmpty(field), "A cleared search is forgotten, got '\(field.value ?? "")'")
        XCTAssertTrue(chapterRows(app).firstMatch.waitForExistence(timeout: 5))
    }

    /// P030: the keyboard's Search key scans at once and drops the keyboard,
    /// leaving the pick to the listener.
    func testTheSearchKeyScansAndDropsTheKeyboard() {
        let app = openReader(classic: 2600)
        openContents(app)
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Pierre\n")
        // The field lets go at once and the keyboard's exit animation
        // follows; each sample is a whole-app snapshot, taken while some
        // 1,900 "Pierre" hits land, so the keyboard gets two seconds (a
        // keyboard the Search key left up would still be up at any length).
        XCTAssertTrue(keyboardGone(app, timeout: 2), "The Search key drops the keyboard")
        XCTAssertTrue(app.staticTexts["search.count"].firstMatch.waitForExistence(timeout: 10),
                      "and the results land")
        XCTAssertTrue(app.staticTexts["contents.title"].firstMatch.exists, "Contents stays open")
    }

    /// P031: Cancel backs out of a search with nothing found: the field
    /// empties, the keyboard goes and the chapters come back.
    func testCancelBacksOutOfASearch() {
        let app = openReader(classic: 2600)
        openContents(app)
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["search.empty"].firstMatch.waitForExistence(timeout: 20))
        let cancel = app.buttons["search.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Cancel shows beside the focused field")
        cancel.tap()
        XCTAssertTrue(keyboardGone(app, timeout: 2), "Cancel drops the keyboard")
        XCTAssertTrue(isEmpty(field), "Cancel empties the field, got '\(field.value ?? "")'")
        XCTAssertTrue(chapterRows(app).firstMatch.waitForExistence(timeout: 5), "The chapters are back")
        XCTAssertFalse(cancel.exists, "Cancel shows only while the field has focus")
    }

    /// P031 in a book with search only: Cancel leaves an empty field and a
    /// sheet a swipe closes.
    func testCancelInASearchOnlyBookLetsTheSheetClose() {
        let app = openReader(classic: 1063)   // The Cask of Amontillado
        openContents(app)
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(hasKeyboardFocus(field, timeout: 5), "Search only: the field takes focus")
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["search.empty"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["search.cancel"].firstMatch.tap()
        XCTAssertTrue(keyboardGone(app, timeout: 2))
        XCTAssertTrue(isEmpty(field))
        closeContents(app)
    }

    /// P033: the chapter line's long-press menu offers Contents and the
    /// search, which opens at full height with the field focused.
    func testTheChapterLinesMenuGoesStraightToSearch() {
        let app = openReader(classic: 2600)
        let line = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.press(forDuration: 1.2)
        let search = app.buttons["Search This Book"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The menu offers the search")
        XCTAssertTrue(app.buttons["Contents"].firstMatch.exists, "and Contents")
        keepScreenshot(app, "chapter-line-menu")
        search.tap()
        let field = app.textFields["search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(hasKeyboardFocus(field, timeout: 5), "The search opens focused")
        XCTAssertGreaterThan(app.keyboards.count, 0, "with the keyboard up (which grows the sheet)")
        keepScreenshot(app, "contents-search-from-the-menu")
    }

    /// At AX3 the player bar caps the chapter line, so its long press is the
    /// Large Content Viewer's: the menu steps aside there. The viewer's HUD
    /// is outside the accessibility tree; only the menu's absence is read.
    func testAtAX3TheChapterLinesLongPressIsTheViewers() {
        let app = openReader(classic: 2600, ["-UIPreferredContentSizeCategoryName",
                                             "UICTContentSizeCategoryAccessibilityXL"])
        let line = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        line.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["Search This Book"].firstMatch.waitForExistence(timeout: 3),
                       "No menu at AX3: the long press shows the line in the viewer")
        keepScreenshot(app, "chapter-line-long-press-ax3")
    }

    /// P033: during a playback error the line's tap retries, and its
    /// long-press menu still opens Contents. Plays muted until the fault.
    func testTheErrorLineKeepsContentsInItsMenu() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-first-classic",
                                         "-uitest-open-first-doc", "-uitest-reset-natural-voice-offer",
                                         "-uitest-temp-model-dir", "-uitest-fault", "synthesis",
                                         "-uitest-fault-after", "3"], allowAutoplay: true)
        app.launch()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60), "The book should start playing")
        let line = app.descendants(matching: .any)["reader.chapterLine"].firstMatch
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@",
                                                                       "Playback stopped"), object: line)
        XCTAssertEqual(XCTWaiter().wait(for: [stopped], timeout: 60), .completed,
                       "The fault should stop playback, got '\(line.label)'")
        line.press(forDuration: 1.2)
        let contents = app.buttons["Contents"].firstMatch
        XCTAssertTrue(contents.waitForExistence(timeout: 5), "The error line's menu offers Contents")
        contents.tap()
        XCTAssertTrue(app.staticTexts["contents.title"].firstMatch.waitForExistence(timeout: 10),
                      "Contents opens during the error")
    }
}
