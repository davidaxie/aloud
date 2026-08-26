import XCTest

/// Feature-wave smoke: the Library's Continue Listening hero card appears
/// once listening progress exists and tapping it lands in the reader already
/// playing; the chapter drawer opens from the reader title and tapping a
/// chapter seeks the playhead. Deterministic via the existing UITestHooks
/// (seeded classic, id-equals-index sentence contract).
final class ContinueAndChaptersUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testContinueCardAutoplaysAndChapterDrawerSeeks() {
        let app = XCUIApplication()
        // A fresh shelf: without the reset, leftover container progress would
        // already surface the hero and hide the grid card this test starts from.
        app.launchArguments += ["-uitest-seed-first-classic", "-uitest-reset-library"]
        app.launch()

        // Open the seeded classic and create real listening progress.
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Seeded classic card should appear")
        card.tap()
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Reader text should appear")

        let next = app.buttons["player.next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        next.tap()
        next.tap()

        let sentenceReadout = app.descendants(matching: .any)["reader.sentence"].firstMatch
        XCTAssertTrue(sentenceReadout.waitForExistence(timeout: 5))
        XCTAssertNotEqual(stringValue(of: sentenceReadout), "0", "Position should have advanced")

        // Back to the Library: the hero card materializes from the progress.
        app.buttons["Back to Library"].firstMatch.tap()
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10),
                      "Continue Listening card should appear once progress exists")

        // The hero is lifted out of the grid, so it must carry the grid card's
        // management affordances: long-pressing it offers Rename and Delete.
        hero.press(forDuration: 1.2)
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 10),
                      "Long-pressing the hero should offer Rename")
        XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 5),
                      "Long-pressing the hero should offer Delete")

        // Dismiss the menu without acting on it, then carry on. Tap low on the
        // backdrop: the hero's context-menu preview sits at the TOP of the
        // shelf with the menu under it, and a tap up there lands on the status
        // bar (swallowed) or on the preview itself — neither dismisses.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        XCTAssertTrue(waitForNonExistence(of: rename, timeout: 10),
                      "Context menu should dismiss without renaming or deleting")

        // Tapping the hero lands in the reader ALREADY playing (autoplay).
        hero.tap()
        XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Reader should reopen")
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180),
                      "Continue card must start playback without another tap")

        // Pause for a deterministic chapter-seek assertion.
        playButton.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 10))
        XCTAssertNotEqual(stringValue(of: sentenceReadout), "0",
                          "Playhead should be past the document start before the chapter seek")

        // Chapter drawer opens from the title…
        let title = app.buttons["reader.chapters"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        // Query the first chapter BY IDENTIFIER, not `firstMatch`: the rows
        // live in a LazyVStack that `onAppear` scrolls to the current chapter,
        // so `firstMatch` resolves to the first row that happens to be
        // materialized. It is chapter 1 only while the playhead sits early in
        // the book — advance the setup and the same assertion would demand
        // sentence 0 of some mid-book chapter, reading as a seek bug rather
        // than the fixture drift it is.
        let firstChapter = app.buttons["chapters.row.1"].firstMatch
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10),
                      "Chapter drawer should list the book's first chapter")

        // …and tapping the FIRST chapter seeks to its start (sentence 0 by the
        // id-equals-index contract), dismissing the sheet.
        firstChapter.tap()
        XCTAssertTrue(readerText.waitForExistence(timeout: 10),
                      "Drawer should dismiss back to the reader")
        XCTAssertTrue(waitForValue("0", of: sentenceReadout, timeout: 10),
                      "Tapping the first chapter should cue its start sentence")
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 5),
                      "A seek while paused must stay paused")
    }
}
