import UIKit
import XCTest

/// R4 and R10 end to end: the empty Library's shape, the + menu, every entry
/// point opening a book playing with no further tap, a Finished book staying
/// paused, and the import overlay, its Cancel and its fixed failure copy.
/// Every launch is muted (XCUIApplication.aloud). Launches that assert
/// playing opt into autoplay and use the System voice.
final class LibraryEntryUITests: XCTestCase {

    private let reset = "-uitest-reset-library"
    private let seed = "-uitest-seed-first-classic"
    private let systemVoice = "-uitest-temp-model-dir"
    private let speaking = ["playing", "buffering"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["reader.text"].firstMatch
    }

    private func playButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["player.play"].firstMatch
    }

    private func overlay(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["import.overlay"].firstMatch
    }

    private func anyCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                         ["library.card", "library.continue"])).firstMatch
    }

    /// The reader is up and speaking, with no tap after the open.
    private func assertOpensSpeaking(_ app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open", file: file, line: line)
        XCTAssertTrue(waitForValue(in: speaking, of: play, timeout: 15),
                      "Opening should start it speaking; got \(stringValue(of: play))",
                      file: file, line: line)
    }

    // MARK: - Empty Library

    func testEmptyLibraryShape() {
        let app = XCUIApplication.aloud([reset])
        app.launch()

        for identifier in ["library.featured", "library.moreClassics", "library.addFile"] {
            let element = app.buttons[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(identifier) should show")
            assertTouchTarget(element, identifier)
        }
        XCTAssertFalse(app.buttons["library.add"].exists, "No + until the library holds a book")
        let privacy = app.staticTexts.matching(NSPredicate(format: "label == %@",
                                                           "Everything stays on your device."))
        XCTAssertEqual(privacy.count, 1, "The privacy line shows exactly once")
    }

    /// R10 with P017: Classics, From Files… and then Paste Text, which
    /// follows the clipboard (off while it holds no text), so only its
    /// presence is checked here.
    func testAddMenuHasExactlyThreeItems() {
        let app = XCUIApplication.aloud([seed, reset])
        app.launch()

        let add = app.buttons["library.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "+ shows once the library holds a book")
        add.tap()
        XCTAssertTrue(app.buttons["Classics"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["From Files\u{2026}"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Paste Text"].firstMatch.exists, "the clipboard's text, last")
        for retired in ["Scan pages", "Soon"] {
            XCTAssertFalse(app.buttons[retired].exists, "'\(retired)' is gone")
            XCTAssertFalse(app.staticTexts[retired].exists, "'\(retired)' is gone")
        }
    }

    // MARK: - Every entry point opens playing (R4)

    func testGridCardOpensPlaying() {
        let app = XCUIApplication.aloud([seed, reset, systemVoice], allowAutoplay: true)
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        assertOpensSpeaking(app)
    }

    func testBookshelfRowOpensPlaying() {
        let app = XCUIApplication.aloud([reset, systemVoice], allowAutoplay: true)
        app.launch()

        let more = app.buttons["library.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("amontillado")
        let row = app.buttons["bookshelf.row.1063"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        assertOpensSpeaking(app)
    }

    func testFilesImportOpensPlaying() {
        let app = XCUIApplication.aloud([reset, systemVoice, "-uitest-pick-fixture", "text"],
                                        allowAutoplay: true)
        app.launch()

        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "The import should open the reader")
        assertOpensSpeaking(app)
        tapSystemBack(app)
        XCTAssertTrue(anyCard(app).waitForExistence(timeout: 10))
        XCTAssertEqual(libraryCount(app), 1)
    }

    func testOpenInOpensPlayingAndDedupes() {
        let app = XCUIApplication.aloud([reset, systemVoice, "-uitest-open-fixture", "pdf"],
                                        allowAutoplay: true)
        app.launch()

        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "Open-in should open the reader")
        assertOpensSpeaking(app)
        app.terminate()

        // The same file again: the reader opens on the copy already shelved.
        let again = XCUIApplication.aloud(["-uitest-open-fixture", "pdf"])
        again.launch()
        XCTAssertTrue(readerText(again).waitForExistence(timeout: 15), "The duplicate should open the reader")
        tapSystemBack(again)
        XCTAssertTrue(anyCard(again).waitForExistence(timeout: 10))
        XCTAssertEqual(libraryCount(again), 1, "Opening the same file twice adds one book")
    }

    func testFinishedBookOpensPaused() {
        let app = XCUIApplication.aloud([reset, "-uitest-seed-finished"], allowAutoplay: true)
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let play = playButton(app)
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForValue("paused", of: play, timeout: 10))
        XCTAssertFalse(waitForValue(in: speaking, of: play, timeout: 3),
                       "A Finished book stays paused at its end")
        XCTAssertEqual(stringValue(of: play), "paused")
    }

    // MARK: - Import overlay (R10)

    func testCancelMidImportLeavesLibraryUnchanged() {
        let app = XCUIApplication.aloud([reset, "-uitest-slow-import", "-uitest-open-fixture", "text"])
        app.launch()

        let cancel = app.buttons["import.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        assertTouchTarget(cancel, "import.cancel")
        cancel.tap()
        XCTAssertTrue(waitForNonExistence(of: overlay(app), timeout: 5))
        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        XCTAssertTrue(featured.isHittable)
        XCTAssertEqual(libraryCount(app), 0, "A cancelled import adds nothing")
        XCTAssertFalse(readerText(app).exists, "A cancelled import never opens")
    }

    /// P015: a small text file is added before the overlay's 0.8 s delay,
    /// so no scrim flashes and + never leaves the bar; the book still
    /// opens, as a pick does (R4). + shows only once the seeded book is on
    /// the shelf, and the reader's push slides the bar out before the book
    /// has loaded, so + is checked from its first sighting until the
    /// reader starts coming in.
    func testAQuickAddNeverShowsTheOverlay() {
        let app = XCUIApplication.aloud([reset, seed, systemVoice, "-uitest-pick-fixture", "text"])
        app.launch()

        let add = app.buttons["library.add"].firstMatch
        var plusSeen = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !readerText(app).exists {
            XCTAssertFalse(overlay(app).exists, "a quick add shows no overlay")
            // Read + first: a push starting after this read still shows
            // in the reader check below it.
            let plusHittable = add.isHittable
            if plusSeen, !plusHittable {
                XCTAssertTrue(readerIsComing(app), "+ left the bar during a quick add")
            }
            plusSeen = plusSeen || plusHittable
            usleep(100_000)
        }
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "the picked file opens")
        XCTAssertFalse(overlay(app).exists)
    }

    /// The reader is on its way in: pushed (its bar's Aa), or loaded.
    private func readerIsComing(_ app: XCUIApplication) -> Bool {
        app.buttons["reader.appearance"].firstMatch.exists || readerText(app).exists
    }

    /// P015: a slow add shows the overlay once the delay has passed, and
    /// Cancel still works.
    func testASlowAddShowsTheOverlayAfterTheDelay() {
        let app = XCUIApplication.aloud([reset, seed, "-uitest-slow-import", "-uitest-open-fixture", "text"])
        app.launch()

        XCTAssertTrue(overlay(app).waitForExistence(timeout: 15), "past 0.8 s the overlay shows")
        let cancel = app.buttons["import.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(waitForNonExistence(of: overlay(app), timeout: 5))
        XCTAssertTrue(app.buttons["library.add"].firstMatch.waitForExistence(timeout: 5), "+ is back")
    }

    func testOverlayHidesTheShelfFromAccessibility() {
        let app = XCUIApplication.aloud([reset, seed, "-uitest-slow-import", "-uitest-open-fixture", "text"])
        app.launch()

        XCTAssertTrue(overlay(app).waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["library.card"].exists, "The shelf is hidden under the overlay")
        XCTAssertFalse(app.buttons["library.add"].exists, "The nav bar is hidden under the overlay")
        app.buttons["import.cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.card"].firstMatch.waitForExistence(timeout: 10),
                      "The shelf returns once the overlay goes")
    }

    func testFailureUsesFixedCopy() {
        let app = XCUIApplication.aloud([reset, "-uitest-open-fixture", "pdf-blank"])
        app.launch()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertEqual(alert.label, "This PDF has no readable text.")
        XCTAssertTrue(alert.staticTexts["Try a PDF with selectable text."].exists)
        let leaked = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Error Domain"))
        XCTAssertEqual(leaked.count, 0, "An error's own text never reaches the screen")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForNonExistence(of: alert, timeout: 5))
        let featured = app.buttons["library.featured"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        XCTAssertTrue(featured.isHittable)
    }

    // MARK: - Paste Text (P017)

    /// Text copied in another app (here, the test runner) is added from
    /// + > Paste Text once the system's paste prompt is allowed: one book,
    /// titled from the first line, opened. Pasting the same text again
    /// opens that book and adds no second copy.
    func testPasteTextAddsTheClipboardOnceAndOpensIt() {
        let title = "A Pasted Article"
        UIPasteboard.general.string = """
            \(title)

            The first paragraph of an article copied to listen to later. It runs on for a second sentence.

            A second paragraph closes it.
            """
        addTeardownBlock { UIPasteboard.general.items = [] }
        let app = XCUIApplication.aloud([reset, seed, systemVoice])
        app.launch()

        let add = app.buttons["library.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "+ shows once the library holds a book")
        XCTAssertTrue(waitForLibraryCount(1, in: app, timeout: 10), "the seeded classic")

        pasteFromTheAddMenu(app)
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 20), "the pasted text opens")
        let readerTitle = app.descendants(matching: .any)["reader.title"].firstMatch
        XCTAssertTrue(readerTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(readerTitle.label, title, "titled from its first line")
        tapSystemBack(app)
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLibraryCount(2, in: app, timeout: 10), "one book added; got \(libraryCount(app))")

        pasteFromTheAddMenu(app)
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 20), "the same text opens its book")
        XCTAssertEqual(readerTitle.label, title)
        tapSystemBack(app)
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(waitForLibraryCount(3, in: app, timeout: 3), "a second paste adds no copy")
        XCTAssertEqual(libraryCount(app), 2)
    }

    /// + > Paste Text, then Allow on the system's paste prompt if it asks
    /// (it can't when the simulator already allows pasting from the runner).
    private func pasteFromTheAddMenu(_ app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["library.add"].firstMatch.tap()
        let paste = app.buttons["Paste Text"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(paste.isEnabled, "the clipboard holds text, so Paste Text is on", file: file, line: line)
        paste.tap()
        // The prompt is the system's, served outside the app, whose main
        // thread waits on the answer: look for it there first.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allows = [springboard.buttons["Allow Paste"].firstMatch, app.buttons["Allow Paste"].firstMatch]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let allow = allows.first(where: { $0.exists }) {
                allow.tap()
                return
            }
            if readerText(app).exists { return }
            usleep(200_000)
        }
    }

    private func waitForLibraryCount(_ count: Int, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if libraryCount(app) == count { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    // MARK: - The shelf's foot (R1-05, R2-03, R2-05)

    /// Once a book is on the shelf, the empty Library's links stay at its
    /// foot: More classics is a 44pt link that pushes Classics, and the
    /// featured classic is gone. With nothing on the clipboard there is no
    /// Paste among them.
    func testTheShelfKeepsItsLinksAtItsFoot() {
        UIPasteboard.general.items = []
        let app = XCUIApplication.aloud([reset, seed])
        app.launch()

        XCTAssertTrue(anyCard(app).waitForExistence(timeout: 15), "the seeded book")
        XCTAssertFalse(app.buttons["library.featured"].exists, "no featured classic once there is a book")
        let more = app.buttons["library.shelf.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More classics at the shelf's foot")
        assertTouchTarget(more, "library.shelf.moreClassics")
        XCTAssertTrue(app.buttons["library.shelf.addFile"].firstMatch.exists, "Add a file beside it")
        XCTAssertFalse(app.descendants(matching: .any)["library.shelf.pasteText"].exists,
                       "no Paste with nothing to paste")
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bookshelf.list"].firstMatch.waitForExistence(timeout: 10),
                      "More classics pushes Classics")
    }

    /// R2-03: with text on the clipboard the shelf's foot offers the
    /// system's paste control too, a 44pt link that adds the text with no
    /// Allow Paste prompt.
    func testTheShelfsFootPastesWhileTheClipboardHoldsText() {
        UIPasteboard.general.string = """
            A Note From The Shelf

            One paragraph to listen to, pasted from the foot of a shelf that holds a book.
            """
        addTeardownBlock { UIPasteboard.general.items = [] }
        let app = XCUIApplication.aloud([reset, seed, systemVoice])
        app.launch()

        XCTAssertTrue(anyCard(app).waitForExistence(timeout: 15), "the seeded book")
        let paste = app.descendants(matching: .any)["library.shelf.pasteText"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "Paste at the shelf's foot while there is text")
        if !paste.isHittable { app.swipeUp() }
        XCTAssertTrue(paste.isHittable)
        assertTouchTarget(paste, "library.shelf.pasteText")
        paste.tap()
        // The secure control reads the text with no prompt: the system's
        // Allow Paste never shows, where + > Paste Text's would.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.buttons["Allow Paste"].firstMatch.waitForExistence(timeout: 2),
                       "no Allow Paste prompt")
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 20), "the pasted text opens")
        tapSystemBack(app)
        XCTAssertTrue(waitForLibraryCount(2, in: app, timeout: 10), "one book added; got \(libraryCount(app))")
    }

    /// R2-05: with only a Continue card on the shelf, the links sit one
    /// step under it, as they sit under a grid, not two.
    func testTheLinksSitOneStepUnderALoneContinueCard() {
        UIPasteboard.general.items = []
        let app = XCUIApplication.aloud([reset, seed, systemVoice])
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the seeded book")
        card.tap()
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 15), "the reader opens")
        tapSystemBack(app)
        // The loaded book is the Continue card; the grid is empty.
        let hero = app.buttons["library.continue"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 10), "the opened book is the Continue card")
        XCTAssertFalse(app.buttons["library.card"].exists, "nothing else on the shelf")
        let addFile = app.buttons["library.shelf.addFile"].firstMatch
        XCTAssertTrue(addFile.waitForExistence(timeout: 5))
        let gap = addFile.frame.minY - hero.frame.maxY
        XCTAssertEqual(gap, 32, accuracy: 2, "one heroToGrid step under the card; got \(gap)")
    }

    // MARK: - The empty Library's paste control (R1-06)

    /// With text on the clipboard the empty Library shows the system's
    /// paste control, a 44pt link that reads the text without a prompt and
    /// adds it as a book.
    func testTheEmptyLibraryPastesThroughTheSystemControl() {
        UIPasteboard.general.string = """
            A Pasted Note

            One paragraph to listen to, long enough to be a book of its own.
            """
        addTeardownBlock { UIPasteboard.general.items = [] }
        let app = XCUIApplication.aloud([reset, systemVoice])
        app.launch()

        let paste = app.descendants(matching: .any)["library.pasteText"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 15), "the paste control shows while the clipboard has text")
        XCTAssertTrue(paste.isHittable)
        assertTouchTarget(paste, "library.pasteText")
        paste.tap()
        XCTAssertTrue(readerText(app).waitForExistence(timeout: 20), "the pasted text opens")
        tapSystemBack(app)
        XCTAssertTrue(waitForLibraryCount(1, in: app, timeout: 10), "one book added; got \(libraryCount(app))")
    }

    // MARK: - Delete to empty

    func testDeletingEveryBookReturnsTheEmptyState() {
        let app = XCUIApplication.aloud([seed, reset])
        app.launch()

        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.press(forDuration: 1.2)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        // The confirmation is up once its message shows; its Delete is then
        // the only one on screen. The seeded book is a classic, so it says
        // it can come back (R1-11).
        let message = app.staticTexts["This removes the book and your place in it. You can add it again from Classics."]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        app.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(app.buttons["library.featured"].firstMatch.waitForExistence(timeout: 10),
                      "An empty Library shows the featured classic again")
        XCTAssertFalse(app.buttons["library.add"].exists, "No + once the last book is gone")
    }
}
