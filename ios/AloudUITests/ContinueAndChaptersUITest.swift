import XCTest

/// Feature-wave smoke: the Library's Continue Listening hero card appears
/// once listening progress exists, and tapping it resumes the paused book
/// where it left off; Contents opens from the chapter line and tapping a
/// chapter seeks the playhead. Deterministic via the existing UITestHooks
/// (seeded classic, id-equals-index sentence contract).
final class ContinueAndChaptersUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testContinueCardAutoplaysAndChapterDrawerSeeks() throws {
        // A fresh shelf: without the reset, leftover container progress would
        // already surface the hero and hide the grid card this test starts from.
        // allowAutoplay: the test asserts the hero's autoplay (still muted).
        // The offer reset drops listening time banked by earlier runs: past
        // 60 s the natural-voice offer takes the chapter line's place. The
        // temp model dir keeps a seeded Kokoro model out, so the System voice
        // reaches playing without a warm-up.
        let app = XCUIApplication.aloud(["-uitest-seed-first-classic", "-uitest-reset-library",
                                         "-uitest-reset-natural-voice-offer", "-uitest-temp-model-dir"],
                                        allowAutoplay: true)
        app.launch()

        // Open the seeded classic: the grid card starts it playing (R4).
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Seeded classic card should appear")
        card.tap()
        let readerText = app.textViews["reader.text"].firstMatch
        XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Reader text should appear")
        let playButton = app.buttons["player.play"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: playButton, timeout: 60),
                      "The grid card should start playback, got '\(stringValue(of: playButton))'")

        // Create real listening progress.
        let forward = app.buttons["player.forward15"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.tap()
        forward.tap()
        forward.tap()

        // Pause before leaving. Nothing pauses on the way back to the
        // Library, and a book still speaking makes the hero's autoplay a
        // no-op, so the playing check below would pass without the card
        // doing anything. Paused, the card itself has to resume the book.
        playButton.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 10), "The book should pause")
        let pausedSentence = try XCTUnwrap(waitForSentence(in: app, timeout: 5) { $0 > 0 },
                                           "Position should have advanced")

        // Back to the Library: the hero card materializes from the progress.
        tapSystemBack(app)
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

        // Tapping the hero resumes the paused book without another tap.
        hero.tap()
        XCTAssertTrue(readerText.waitForExistence(timeout: 15), "Reader should reopen")
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("playing", of: playButton, timeout: 180),
                      "Continue card must resume playback without another tap")

        // Pause for a deterministic chapter-seek assertion.
        playButton.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 10))
        // It resumed where it paused, not from the start. The rest was far
        // under the 5-minute resume-rewind threshold, and playing only moves
        // forward. This also puts the playhead past sentence 0 before the
        // chapter seek.
        let resumedSentence = currentSentence(app) ?? -1
        XCTAssertGreaterThanOrEqual(resumedSentence, pausedSentence,
                                    "The Continue card should resume at sentence \(pausedSentence), not restart")

        // Contents opens from the chapter line…
        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        XCTAssertTrue(chapterLine.waitForExistence(timeout: 5))
        chapterLine.tap()
        // Query the first chapter BY IDENTIFIER, not `firstMatch`: the rows
        // live in a LazyVStack that `onAppear` scrolls to the current chapter,
        // so `firstMatch` resolves to the first row that happens to be
        // materialized. It is chapter 1 only while the playhead sits early in
        // the book — advance the setup and the same assertion would demand
        // sentence 0 of some mid-book chapter, reading as a seek bug rather
        // than the fixture drift it is.
        let firstChapter = app.buttons["chapters.row.1"].firstMatch
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10),
                      "Contents should list the book's first chapter")

        // …and tapping the FIRST chapter seeks to its start (sentence 0 by the
        // id-equals-index contract), dismissing the sheet. The pick also
        // plays from there (P025, muted), and Gatsby's sentence 0 is the
        // chapter heading "I": one word, spoken and passed within a second,
        // before a probe read after the sheet closes can catch it. So the
        // cue is read as the playhead back at the chapter's opening, on the
        // heading or the six-second line after it, polled from the moment
        // of the tap; the resume point sits past both, and playing only
        // moves forward, so only the seek can bring it there.
        XCTAssertGreaterThan(resumedSentence, 1,
                             "The playhead should be past the first chapter's opening before the seek")
        firstChapter.tap()
        let cued = waitForSentence(in: app, timeout: 10) { $0 <= 1 }
        XCTAssertNotNil(cued, "Tapping the first chapter should cue its start sentence, "
                        + "got \(currentSentence(app).map(String.init) ?? "none")")
        XCTAssertTrue(waitForNonExistence(of: app.staticTexts["contents.title"].firstMatch, timeout: 10),
                      "Contents should dismiss back to the reader")
        XCTAssertTrue(readerText.exists, "The reader shows again")
        // P025: a Contents pick plays from there, even from a pause (muted).
        XCTAssertTrue(waitForValue(in: ["playing", "buffering"], of: playButton, timeout: 10),
                      "A chapter pick plays from its start, got '\(stringValue(of: playButton))'")
        playButton.tap()
        XCTAssertTrue(waitForValue("paused", of: playButton, timeout: 10))
    }
}
