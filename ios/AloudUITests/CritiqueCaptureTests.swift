import XCTest

/// Dev-only screenshot walk for design critique: every main screen and state,
/// in light, dark and large text. Opt-in like ScreenshotCaptureTests: the
/// shots directory comes from ALOUD_SHOTS_DIR, or from a fresh marker file at
/// `markerPath` whose contents are the directory. Skipped otherwise, so a
/// normal test run never writes anything. Every launch is muted
/// (`XCUIApplication.aloud`), and a missing step is noted in notes.txt and
/// skipped rather than failing the walk.
final class CritiqueCaptureTests: XCTestCase {

    private static let markerPath = "/private/tmp/aloud-critique-request.txt"
    private static let markerMaxAge: TimeInterval = 2 * 60 * 60

    private static let shotsDir: String? = {
        if let env = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"], !env.isEmpty { return env }
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: markerPath),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < markerMaxAge,
              let text = try? String(contentsOfFile: markerPath, encoding: .utf8) else { return nil }
        let dir = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }()

    private var dir = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let shots = Self.shotsDir else {
            throw XCTSkip("No shots directory: critique capture is opt-in")
        }
        dir = shots
    }

    // MARK: - Library

    func test01EmptyLibraryAndClassics() {
        let app = launch(["-uitest-reset-library", "-uitest-force-light"])
        guard wait(app.buttons["library.addFile"], "empty library") else { return }
        snap("01-library-empty")
        let more = app.buttons["library.moreClassics"]
        guard wait(more, "More classics link") else { return }
        more.tap()
        guard wait(app.descendants(matching: .any)["bookshelf.list"], "Classics list") else { return }
        settle()
        snap("02-classics")
        let field = app.searchFields.firstMatch
        if wait(field, "Classics search field") {
            field.tap()
            app.typeText("Holmes")
            settle()
            snap("03-classics-search")
        }
    }

    func test02LibraryShelf() {
        shelf(dark: false, prefix: "04")
    }

    func test03LibraryShelfDark() {
        shelf(dark: true, prefix: "06")
    }

    private func shelf(dark: Bool, prefix: String) {
        let app = launch(["-uitest-reset-library", "-uitest-seed-classics", "5",
                          dark ? "-uitest-force-dark" : "-uitest-force-light"])
        guard wait(app.buttons["library.card"].firstMatch, "shelf cards") else { return }
        settle(2)
        snap("\(prefix)-library-shelf\(dark ? "-dark" : "")")
        // The long-press menu on a card.
        app.buttons["library.card"].firstMatch.press(forDuration: 1.2)
        settle()
        snap("\(nextName(prefix))-library-card-menu\(dark ? "-dark" : "")")
    }

    // MARK: - Reader

    func test04Reader() {
        let app = openReader(["-uitest-force-light", "-uitest-seed-places", "6"])
        guard let app else { return }
        snap("10-reader")

        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        if wait(chapterLine, "chapter line") {
            chapterLine.tap()
            if wait(app.descendants(matching: .any)["contents.title"].firstMatch, "Contents sheet") {
                settle()
                snap("11-contents-half")
                app.descendants(matching: .any)["contents.title"].firstMatch.swipeUp()
                settle()
                snap("12-contents-full")
                closeSheet(app, header: app.descendants(matching: .any)["contents.title"].firstMatch)
            }
        }

        let voice = app.buttons["player.listening"].firstMatch
        if wait(voice, "voice chip") {
            voice.tap()
            let title = app.staticTexts["listening.title"].firstMatch
            if wait(title, "Voice & speed sheet") {
                settle()
                snap("13-voice-sheet")
                title.swipeUp()
                settle()
                snap("14-voice-sheet-full")
                closeSheet(app, header: title)
            }
        }

        let aa = app.buttons["reader.appearance"].firstMatch
        if wait(aa, "Aa button") {
            aa.tap()
            if wait(app.descendants(matching: .any)["appearance.scheme"].firstMatch, "Aa sheet") {
                settle()
                snap("15-aa-sheet")
                let done = app.buttons["appearance.done"].firstMatch
                if done.exists { done.tap() } else { closeSheet(app, header: app.staticTexts["appearance.title"].firstMatch) }
                settle()
            }
        }

        let sleepChip = app.buttons["player.sleep"].firstMatch
        if wait(sleepChip, "sleep chip") {
            sleepChip.tap()
            settle()
            snap("16-sleep-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            settle()
        }

        let text = app.textViews["reader.text"].firstMatch
        if text.exists {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
            settle()
            snap("17-sentence-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
            settle()
        }

        // Settings, from the Library.
        let back = app.buttons["reader.back"].firstMatch
        if back.exists { back.tap() } else { tapSystemBack(app) }
        let settings = app.buttons["library.settings"].firstMatch
        if wait(settings, "Settings button") {
            settle()
            snap("18-library-continue")
            settings.tap()
            settle()
            snap("19-settings")
            let listening = app.buttons["settings.listening"].firstMatch
            if wait(listening, "Settings › Voice") {
                listening.tap()
                settle()
                snap("20-settings-voice")
                tapSystemBack(app)
                settle()
            }
            let licenses = app.buttons["settings.licenses"].firstMatch
            if wait(licenses, "Settings › Licenses") {
                licenses.tap()
                settle()
                snap("21-licenses")
            }
        }
    }

    func test05ReaderDark() {
        guard let app = openReader(["-uitest-force-dark", "-uitest-seed-places", "3"]) else { return }
        snap("22-reader-dark")
        let chapterLine = app.buttons["reader.chapterLine"].firstMatch
        if wait(chapterLine, "chapter line (dark)") {
            chapterLine.tap()
            if wait(app.descendants(matching: .any)["contents.title"].firstMatch, "Contents (dark)") {
                settle()
                snap("23-contents-dark")
            }
        }
    }

    func test06ReaderLargeText() {
        if openReader(["-uitest-force-light", "-UIPreferredContentSizeCategoryName",
                       "UICTContentSizeCategoryXXL"]) != nil {
            snap("24-reader-xxlarge")
        }
        if openReader(["-uitest-force-light", "-UIPreferredContentSizeCategoryName",
                       "UICTContentSizeCategoryAccessibilityL"]) != nil {
            snap("25-reader-ax3")
        }
    }

    func test07FinishedBook() {
        let app = launch(["-uitest-reset-library", "-uitest-seed-first-classic", "-uitest-seed-finished",
                          "-uitest-force-light"])
        guard wait(app.buttons["library.card"].firstMatch, "finished card") else { return }
        settle()
        snap("26-library-finished")
        app.buttons["library.card"].firstMatch.tap()
        if wait(app.textViews["reader.text"].firstMatch, "finished reader", timeout: 120) {
            settle(2)
            snap("27-reader-finished")
        }
    }

    func test08ReaderPlaying() {
        guard let app = openReader(["-uitest-force-light"]) else { return }
        let play = app.buttons["player.play"].firstMatch
        guard wait(play, "Play") else { return }
        play.tap()
        // The natural voice warms up first on a simulator; muted throughout.
        if waitForValue(in: ["playing"], of: play, timeout: 150) {
            settle(3)
            snap("28-reader-playing")
            play.tap()
        } else {
            note("Play never reached playing (value: \(stringValue(of: play)))")
            snap("28-reader-play-pending")
        }
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication.aloud(arguments)
        app.launch()
        return app
    }

    /// The seeded Gatsby, opened straight into the reader.
    private func openReader(_ extra: [String]) -> XCUIApplication? {
        let app = launch(["-uitest-reset-library", "-uitest-seed-first-classic",
                          "-uitest-open-first-doc"] + extra)
        guard wait(app.textViews["reader.text"].firstMatch, "reader", timeout: 120) else { return nil }
        settle(2)
        return app
    }

    @discardableResult
    private func wait(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        note("missing: \(what) in \(name)")
        return false
    }

    private func closeSheet(_ app: XCUIApplication, header: XCUIElement) {
        guard header.exists else { return }
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)
        settle()
    }

    private func settle(_ seconds: UInt32 = 1) { sleep(seconds) }

    private func nextName(_ prefix: String) -> String {
        String(format: "%02d", (Int(prefix) ?? 0) + 1)
    }

    private func snap(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }

    private func note(_ line: String) {
        let path = dir + "/notes.txt"
        let entry = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
