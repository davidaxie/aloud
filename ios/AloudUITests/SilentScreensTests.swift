import XCTest

/// Silent visual check of every Phase 2 surface, plus R22's shelf covers
/// and R24's colophon, in light and dark.
///
/// Opt-in: runs only when `ALOUD_SHOTS_DIR` reaches the runner (pass
/// `TEST_RUNNER_ALOUD_SHOTS_DIR=<dir>` to xcodebuild); otherwise it skips.
/// Never makes a sound: the app is launched muted with autoplay suppressed
/// (`XCUIApplication.aloud`), and the walk never touches Play, a Library
/// card, the Continue hero or its circle, the skip buttons, a sentence in
/// the text, or a voice row in the Listening sheet.
final class SilentScreensTests: XCTestCase {

    private var dir = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let dir = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ALOUD_SHOTS_DIR to capture silent screenshots.")
        }
        self.dir = dir
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func testLight() {
        walk(prefix: "light", scheme: "-uitest-force-light")
        walkReader(prefix: "light", scheme: "-uitest-force-light")
        walkShelf(prefix: "light", scheme: "-uitest-force-light")
        walkEnd(prefix: "light", scheme: "-uitest-force-light")
    }
    func testDark() {
        walk(prefix: "dark", scheme: "-uitest-force-dark")
        walkReader(prefix: "dark", scheme: "-uitest-force-dark")
        walkShelf(prefix: "dark", scheme: "-uitest-force-dark")
        walkEnd(prefix: "dark", scheme: "-uitest-force-dark")
    }

    /// R22's one cover at its real sizes: a picked PDF becomes the hero (a
    /// 64pt cover, too narrow for type, so ground and rule) over three seeded
    /// classics' 2:3 typographic covers; then the same shelf at AX3. Nothing
    /// is tapped but the reader's back button.
    private func walkShelf(prefix: String, scheme: String) {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classics", "3",
                                         "-uitest-pick-fixture", "pdf", "-uitest-temp-model-dir", scheme])
        app.launch()
        // The picked PDF opens paused (autoplay is suppressed in UI tests).
        // Back only from the reader: on the Library the leading bar button
        // is something else.
        if app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30) {
            tapSystemBack(app)
        }
        _ = app.descendants(matching: .any)["library.card"].firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        save("\(prefix)-23-shelf-covers")
        app.terminate()

        // No reset, so the same library comes back, now at AX3.
        let large = XCUIApplication.aloud(["-uitest-temp-model-dir", scheme]
                                          + AuditTextSize.all[1].launchArguments)
        large.launch()
        _ = large.descendants(matching: .any)["library.card"].firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        save("\(prefix)-24-shelf-covers-ax3")
        large.terminate()
    }

    /// R24's colophon, for its type in light and dark: a Finished book
    /// reopens paused at its end, and nothing is tapped.
    private func walkEnd(prefix: String, scheme: String) {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-finished",
                                         "-uitest-open-first-doc", "-uitest-temp-model-dir", scheme])
        app.launch()
        _ = app.textViews["reader.text"].firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        save("\(prefix)-25-colophon")
        app.terminate()
    }

    /// A chaptered book seeded directly (no Classics scroll), with a stop
    /// left over from "iOS closed Aloud": the Continue card's stop mirror,
    /// the reader's stopped line, then a paused Contents pick for the Undo
    /// chip, the Listening sheet, the sleep menu and Aa. All silent: the
    /// book stays paused throughout.
    private func walkReader(prefix: String, scheme: String) {
        // The live-session hook marks the library's first book at app init,
        // before launch-time seeding runs: seed in one launch, then mark.
        let seed = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classic", "64317",
                                          "-uitest-temp-model-dir", scheme])
        seed.launch()
        _ = seed.descendants(matching: .any)["library.card"].firstMatch.waitForExistence(timeout: 30)
        seed.terminate()

        let app = XCUIApplication.aloud(["-uitest-seed-live-session", "-uitest-temp-model-dir", scheme])
        app.launch()
        let card = app.buttons["library.continue"].firstMatch
        _ = card.waitForExistence(timeout: 30)
        sleep(2)
        save("\(prefix)-16-continue-stopped")

        // Never tap the card: its body resumes playback. Relaunch straight
        // into the reader instead (open-first-doc never plays: autoplay is
        // suppressed in UI-test launches).
        // The stop persists, so the relaunch needs no second marker.
        app.terminate()
        app.launchArguments = ["-uitest-mute", "-uitest-open-first-doc", "-uitest-temp-model-dir", scheme]
        app.launch()
        let text = app.textViews["reader.text"].firstMatch
        _ = text.waitForExistence(timeout: 30)
        sleep(2)
        save("\(prefix)-17-reader-stopped")

        tapIfPresent(app.buttons["reader.chapterLine"].firstMatch)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chapters.row.'"))
        if rows.firstMatch.waitForExistence(timeout: 10) {
            sleep(1)
            save("\(prefix)-18-contents")
            let third = rows.element(boundBy: 2)
            if third.exists { third.tap() }
            sleep(2)
            save("\(prefix)-19-undo-chip")
        }

        tapIfPresent(app.buttons["player.listening"].firstMatch)
        _ = app.staticTexts["listening.title"].firstMatch.waitForExistence(timeout: 10)
        sleep(1)
        save("\(prefix)-20-listening")
        dismissSheet(app, by: app.staticTexts["listening.title"].firstMatch)

        let sleepChip = app.buttons["player.sleep"].firstMatch
        if sleepChip.waitForExistence(timeout: 5) {
            sleepChip.tap()
            sleep(1)
            save("\(prefix)-21-sleep-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
            sleep(1)
        }

        tapIfPresent(app.buttons["reader.appearance"].firstMatch)
        sleep(1)
        save("\(prefix)-22-aa")
        app.terminate()
    }

    private func walk(prefix: String, scheme: String) {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-temp-model-dir", scheme])
        app.launch()

        // First run: the featured classic, its links and the privacy line.
        let featured = app.buttons["library.featured"].firstMatch
        _ = featured.waitForExistence(timeout: 10)
        sleep(1)
        save("\(prefix)-01-empty")

        // One tap adds it and opens the reader (paused: autoplay is suppressed).
        featured.tap()
        let text = app.textViews["reader.text"].firstMatch
        _ = text.waitForExistence(timeout: 60)
        sleep(2)
        save("\(prefix)-02-reader-chapterless")

        // A chapterless book's Contents is search only.
        tapIfPresent(app.buttons["reader.chapterLine"].firstMatch)
        sleep(2)
        save("\(prefix)-03-contents-search-only")
        dismissSheet(app, by: app.staticTexts["contents.title"].firstMatch)

        tapSystemBack(app)
        _ = app.buttons["library.add"].firstMatch.waitForExistence(timeout: 10)
        sleep(1)
        save("\(prefix)-04-library-one-book")

        // The + menu, then Classics.
        tapIfPresent(app.buttons["library.add"].firstMatch)
        sleep(1)
        save("\(prefix)-05-add-menu")
        tapIfPresent(app.buttons["Classics"].firstMatch)
        _ = app.descendants(matching: .any)["bookshelf.list"].firstMatch.waitForExistence(timeout: 10)
        sleep(1)
        save("\(prefix)-06-classics")

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("pride")
            sleep(2)
            save("\(prefix)-07-classics-search")
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
            app.buttons["Cancel"].firstMatch.tapIfExists()
            sleep(1)
        }

        // A row adds and opens a chaptered book (scroll until it's on screen).
        let row = app.descendants(matching: .any)["bookshelf.row.64317"].firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        if row.exists && row.isHittable {
            row.tap()
            _ = text.waitForExistence(timeout: 90)
            sleep(3)
            save("\(prefix)-08-reader-chapters")

            tapIfPresent(app.buttons["reader.chapterLine"].firstMatch)
            sleep(2)
            save("\(prefix)-09-contents")
            dismissSheet(app, by: app.staticTexts["contents.title"].firstMatch)

            tapIfPresent(app.buttons["player.listening"].firstMatch)
            _ = app.staticTexts["listening.title"].firstMatch.waitForExistence(timeout: 10)
            sleep(1)
            save("\(prefix)-10-listening")
            if app.staticTexts["listening.title"].exists { dismissListeningSheet(app) }

            let sleepChip = app.buttons["player.sleep"].firstMatch
            if sleepChip.waitForExistence(timeout: 5) {
                sleepChip.tap()
                sleep(1)
                save("\(prefix)-11-sleep-menu")
                // Close the menu on the nav bar, never on the text (a tap
                // there would seek).
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap()
                sleep(1)
            }

            tapIfPresent(app.buttons["reader.appearance"].firstMatch)
            sleep(1)
            save("\(prefix)-12-aa")
            dismissSheet(app, by: app.staticTexts["Text size"].firstMatch)
        }

        // Back to the Library, then Settings and Voice & speed.
        for _ in 0..<3 where !app.buttons["library.settings"].exists {
            tapSystemBack(app)
            sleep(1)
        }
        sleep(1)
        save("\(prefix)-13-library")
        tapIfPresent(app.buttons["library.settings"].firstMatch)
        sleep(2)
        save("\(prefix)-14-settings")
        tapIfPresent(app.buttons["settings.listening"].firstMatch)
        sleep(2)
        save("\(prefix)-15-voice-and-speed")
        app.terminate()
    }

    private func tapIfPresent(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { element.tap() }
    }

    /// Drags a sheet away by its title (never a row), and waits until it's
    /// gone: the first drag may only lower the keyboard.
    private func dismissSheet(_ app: XCUIApplication, by title: XCUIElement) {
        for _ in 0..<3 where title.exists {
            dragSheetClosed(app, by: title)
            _ = waitForNonExistence(of: title, timeout: 3)
        }
        sleep(1)
    }

    private func save(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        FileManager.default.createFile(atPath: dir + "/" + name + ".png", contents: data)
    }
}

private extension XCUIElement {
    func tapIfExists() { if exists { tap() } }
}
