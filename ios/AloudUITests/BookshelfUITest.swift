import XCTest

/// R9: the Bookshelf's rows are the action. Search, the three shelves, one
/// VoiceOver element per row, 'In library' for a renamed classic, and the
/// accessibility audit. Every launch goes through XCUIApplication.aloud, so
/// it is muted; only the one-tap test lifts the autoplay suppression.
final class BookshelfUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The empty Library's 'More classics' link.
    private func openBookshelfFromEmptyLibrary(_ app: XCUIApplication) {
        let more = app.buttons["library.moreClassics"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "The empty Library should offer More classics")
        more.tap()
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.waitForExistence(timeout: 10),
                      "The Bookshelf should be pushed")
    }

    /// The Library's + menu, once it holds a book.
    private func openBookshelfFromAddMenu(_ app: XCUIApplication) {
        let add = app.buttons["library.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let classics = app.buttons["Classics"].firstMatch
        XCTAssertTrue(classics.waitForExistence(timeout: 5), "The + menu should offer Classics")
        classics.tap()
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.waitForExistence(timeout: 10),
                      "The Bookshelf should be pushed")
    }

    private func search(_ app: XCUIApplication, for text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The search field is pinned")
        field.tap()
        if let current = field.value as? String, !current.isEmpty,
           current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// The keyboard's Search key, in the focused search field.
    private func pressSearchKey(_ app: XCUIApplication) {
        app.searchFields.firstMatch.typeText("\n")
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bookshelf.row."))
    }

    /// Reader → Classics → Library. An active search can hold the Classics
    /// bar in its search state, whose leading button ends the search; back
    /// out until the Library shows.
    private func backToLibrary(_ app: XCUIApplication) {
        tapSystemBack(app)
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.waitForExistence(timeout: 10))
        let libraryCard = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                           ["library.card", "library.continue"])).firstMatch
        for _ in 0..<2 where !libraryCard.waitForExistence(timeout: 2) {
            tapSystemBack(app)
        }
        XCTAssertTrue(libraryCard.waitForExistence(timeout: 10), "The Library should show again")
    }

    /// P051: the keyboard's Search key adds and plays the top result, as a
    /// tap on its row does. Muted; allowAutoplay so it can reach playing,
    /// and the temp model dir keeps the System voice, which starts fast.
    func testTheSearchKeyAddsAndPlaysTheTopResult() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-temp-model-dir"],
                                        allowAutoplay: true)
        app.launch()
        openBookshelfFromEmptyLibrary(app)
        search(app, for: "pride")
        let first = rows(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.hasPrefix("Pride and Prejudice, by Jane Austen, about"),
                      "Pride and Prejudice should rank first, got '\(first.label)'")

        pressSearchKey(app)
        let title = app.staticTexts["reader.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The Search key should open the top result")
        XCTAssertTrue(title.label.hasPrefix("Pride and Prejudice"), "got '\(title.label)'")
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60),
                      "The Search key should add, open and play, got '\(stringValue(of: play))'")

        backToLibrary(app)
        XCTAssertEqual(libraryCount(app), 1, "The Search key adds the book once")
    }

    /// P051: with nothing found the Search key leaves the screen as it was,
    /// and on a classic already in the library it opens that copy, adding
    /// none.
    func testTheSearchKeyIgnoresNoResultsAndReopensAnAddedCopy() {
        let app = XCUIApplication.aloud(["-uitest-seed-classic", "64317", "-uitest-reset-library"])
        app.launch()
        let seeded = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                      ["library.card", "library.continue"])).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 15), "The seeded Great Gatsby should be on the shelf")
        XCTAssertEqual(libraryCount(app), 1)
        openBookshelfFromAddMenu(app)

        search(app, for: "zzzz")
        let empty = app.descendants(matching: .any)["bookshelf.noResults"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        pressSearchKey(app)
        XCTAssertFalse(app.staticTexts["reader.title"].firstMatch.waitForExistence(timeout: 2),
                       "With no result the Search key opens nothing")
        XCTAssertTrue(empty.exists, "The no-results line stays")
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.exists, "Classics stays on screen")

        search(app, for: "gatsby")
        let first = rows(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.identifier, "bookshelf.row.64317", "The Great Gatsby should rank first")
        XCTAssertEqual(stringValue(of: first), "In library")
        pressSearchKey(app)
        let title = app.staticTexts["reader.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The Search key should open the added copy")
        XCTAssertTrue(title.label.hasPrefix("The Great Gatsby"), "got '\(title.label)'")

        backToLibrary(app)
        XCTAssertEqual(libraryCount(app), 1, "Opening an added classic must not add a second copy")
    }

    /// R1-32: with several books found the Search key plays none of them.
    /// It lowers the keyboard and leaves the query and every result on
    /// screen, so the listener picks one; nothing is added. Muted, and
    /// autoplay stays suppressed.
    func testTheSearchKeyWithSeveralResultsOnlyLowersTheKeyboard() {
        let app = XCUIApplication.aloud(["-uitest-seed-classic", "64317", "-uitest-reset-library"])
        app.launch()
        let seeded = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                      ["library.card", "library.continue"])).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 15), "The seeded Great Gatsby should be on the shelf")
        let before = libraryCount(app)
        openBookshelfFromAddMenu(app)

        search(app, for: "holmes")
        let found = rows(app)
        XCTAssertTrue(found.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "fixture: the keyboard is up while typing")
        pressSearchKey(app)

        XCTAssertFalse(app.staticTexts["reader.title"].firstMatch.waitForExistence(timeout: 2),
                       "With several results the Search key opens nothing")
        XCTAssertTrue(waitForNonExistence(of: app.keyboards.firstMatch, timeout: 5),
                      "The Search key lowers the keyboard")
        XCTAssertEqual(found.count, 4, "Every Sherlock Holmes book stays listed")
        for index in 0..<found.count {
            XCTAssertTrue(found.element(boundBy: index).isHittable, "Row \(index) should be reachable")
        }
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "holmes", "The query stays, to refine")
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.exists, "Classics stays on screen")

        for _ in 0..<3 where !seeded.waitForExistence(timeout: 2) {
            tapSystemBack(app)
        }
        XCTAssertTrue(seeded.waitForExistence(timeout: 10), "The Library should show again")
        XCTAssertEqual(libraryCount(app), before, "Nothing was added")
    }

    /// R1-36: back on Classics from the reader of the book playing, its row
    /// says so. Muted; allowAutoplay so it reaches playing, and the temp
    /// model dir keeps the System voice, which starts fast. Keeps a
    /// screenshot of the row.
    func testThePlayingClassicsRowSaysPlaying() {
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-temp-model-dir"],
                                        allowAutoplay: true)
        app.launch()
        openBookshelfFromEmptyLibrary(app)
        search(app, for: "pride")
        let row = app.buttons["bookshelf.row.1342"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60),
                      "One tap should add, open and play, got '\(stringValue(of: play))'")

        tapSystemBack(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Classics should show again")
        XCTAssertTrue(waitForValue("Playing", of: row, timeout: 5),
                      "The row of the book playing should say so, got '\(stringValue(of: row))'")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "classics-playing-row"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSearchPrideOneTapPlays() {
        // allowAutoplay: one tap must reach playing (still muted). The temp
        // model dir keeps a seeded Kokoro model out, so the System voice starts fast.
        let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-temp-model-dir"],
                                        allowAutoplay: true)
        app.launch()
        openBookshelfFromEmptyLibrary(app)
        search(app, for: "pride")

        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                     "bookshelf.row.")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.hasPrefix("Pride and Prejudice, by Jane Austen, about"),
                      "Pride and Prejudice should rank first, got '\(first.label)'")

        first.tap()
        let play = app.buttons["player.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "The reader should open")
        XCTAssertTrue(waitForValue("playing", of: play, timeout: 60),
                      "One tap should add, open and play, got '\(stringValue(of: play))'")
    }

    func testSectionsNoResultsAndOneElementRows() {
        let app = XCUIApplication.aloud(["-uitest-reset-library"])
        app.launch()
        openBookshelfFromEmptyLibrary(app)

        let shortShelf = app.descendants(matching: .any)["bookshelf.section.underAnHour"].firstMatch
        XCTAssertTrue(shortShelf.waitForExistence(timeout: 5))
        XCTAssertEqual(shortShelf.label, "Under an hour")

        search(app, for: "amontillado")
        let cask = app.buttons["bookshelf.row.1063"].firstMatch
        XCTAssertTrue(cask.waitForExistence(timeout: 5))
        XCTAssertEqual(cask.label, "The Cask of Amontillado, by Edgar Allan Poe, about 14 minutes")
        // One VoiceOver element: a Button reads as one, with the label above
        // (title, author, length). XCUITest on iOS 26 still lists a SwiftUI
        // Button's label Texts as its children, so their count says nothing
        // about VoiceOver; wrapping the row to hide them only nests a second
        // button inside it.
        XCTAssertEqual(cask.elementType, .button)

        search(app, for: "zzzz")
        let empty = app.descendants(matching: .any)["bookshelf.noResults"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "No classics match \u{201C}zzzz\u{201D}")
    }

    /// R3-05: the shelf map at the top of Classics takes one tap to Long
    /// reads, a hundred rows down, and leaves while a search shows.
    func testTheShelfMapJumpsToLongReads() {
        let app = XCUIApplication.aloud(["-uitest-reset-library"])
        app.launch()
        openBookshelfFromEmptyLibrary(app)

        let jump = app.buttons["bookshelf.jump.longReads"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "the shelf map names Long reads")
        XCTAssertTrue(jump.label.hasPrefix("Long reads, "), "got '\(jump.label)'")
        XCTAssertTrue(jump.label.hasSuffix(" books"), "got '\(jump.label)'")
        assertTouchTarget(jump, "bookshelf.jump.longReads")
        // Where the list's content starts, under the bars: the map's first
        // button, a padding below it. The scroll view itself runs up under
        // the bars, so its frame can't say where a landed heading sits.
        let firstJump = app.buttons["bookshelf.jump.underAnHour"].firstMatch
        XCTAssertTrue(firstJump.waitForExistence(timeout: 5))
        let contentTop = firstJump.frame.minY
        jump.tap()

        // Landed means the shelf's first book, Pride and Prejudice, sits
        // right under its heading at the top. A pinned heading shows at the
        // top anywhere in its shelf, so the heading alone can't tell a
        // landing from an overshoot deep into the shelf.
        let heading = app.descendants(matching: .any)["bookshelf.section.longReads"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let pride = app.buttons["bookshelf.row.1342"].firstMatch
        let landed = NSPredicate { _, _ in
            guard heading.exists, pride.exists, pride.isHittable else { return false }
            let top = heading.frame, book = pride.frame
            return abs(top.minY - contentTop) < 44
                && book.minY >= top.maxY - 1 && book.minY - top.maxY < 44
        }
        let settled = expectation(for: landed, evaluatedWith: nil)
        wait(for: [settled], timeout: 10)
        XCTAssertTrue(pride.isHittable, "Pride and Prejudice, first under the Long reads heading")

        search(app, for: "pride")
        XCTAssertTrue(app.buttons["bookshelf.row.1342"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bookshelf.jump.longReads"].exists, "no shelf map over search results")
    }

    func testRenamedClassicOpensExistingDocument() {
        let app = XCUIApplication.aloud(["-uitest-seed-first-classic", "-uitest-reset-library"])
        app.launch()

        // Rename the seeded classic (The Great Gatsby).
        let card = app.buttons["library.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Seeded classic card should appear")
        card.press(forDuration: 1.2)
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 10))
        rename.tap()
        // The alert focuses its field with the cursor after the current title.
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let current = stringValue(of: field)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
                       + "My Gatsby")
        app.alerts.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(of: field, timeout: 5))

        // Its row still knows it by Gutenberg id.
        openBookshelfFromAddMenu(app)
        search(app, for: "gatsby")
        let row = app.buttons["bookshelf.row.64317"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: row), "In library")
        row.tap()

        // The reader's title is one header, "Title, by Author" (P046).
        let renamedTitle = app.navigationBars.staticTexts.matching(
            NSPredicate(format: "identifier == 'reader.title' AND label BEGINSWITH %@", "My Gatsby, ")).firstMatch
        XCTAssertTrue(renamedTitle.waitForExistence(timeout: 15),
                      "The row should open the renamed document, not a new copy")

        // Reader → Bookshelf → Library. An active search can hold the
        // Bookshelf's bar in its search state, whose leading button ends the
        // search; back out until the Library shows. The opened book is
        // loaded, so it comes back as the Continue card (R18).
        tapSystemBack(app)
        XCTAssertTrue(app.scrollViews["bookshelf.list"].firstMatch.waitForExistence(timeout: 10))
        let libraryCard = app.buttons.matching(NSPredicate(format: "identifier IN %@",
                                                           ["library.card", "library.continue"])).firstMatch
        for _ in 0..<2 where !libraryCard.waitForExistence(timeout: 2) {
            tapSystemBack(app)
        }
        XCTAssertTrue(libraryCard.waitForExistence(timeout: 10))
        XCTAssertEqual(libraryCount(app), 1, "Opening a renamed classic must not add a second copy")
    }

    func testBookshelfAccessibilityAudit() throws {
        var previous: (size: AuditTextSize, height: CGFloat)?
        for size in AuditTextSize.all {
            var rowHeight: CGFloat = 0
            for scheme in ["-uitest-force-light", "-uitest-force-dark"] {
                let app = XCUIApplication.aloud(["-uitest-reset-library", scheme] + size.launchArguments)
                app.launch()
                openBookshelfFromEmptyLibrary(app)
                // The first row is the same book at every size, so its height
                // shows the size took, including the stacked layout at AX3/AX5.
                let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                                "bookshelf.row.")).firstMatch
                XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "The Bookshelf lists rows at \(size.name)")
                rowHeight = firstRow.frame.height
                assertTextSizeTook(size, height: rowHeight, over: previous)
                // The root's 1×1 DEBUG probes (debug.announcements) aren't UI,
                // and the bar caps its title's scaling by design: the title
                // shows the Large Content Viewer instead.
                var issues: [String] = []
                try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .contrast, .hitRegion]) { issue in
                    if issue.element?.identifier.hasPrefix("debug.") == true
                        || self.isNavigationBarTextScaling(issue, in: app)
                        || self.isSystemSearchPromptClipping(issue) { return true }
                    issues.append(self.describe(issue))
                    return true   // collected, so one failure lists them all
                }
                XCTAssertEqual(issues, [], "Bookshelf at \(size.name) (\(scheme))")
                app.terminate()
            }
            previous = (size, rowHeight)
        }
    }

    /// The two largest sizes below the accessibility ones, where the rows
    /// still set the trailing column beside the title and room is tightest.
    private static let largestSideBySide = [
        AuditTextSize(name: "xxLarge", category: "UICTContentSizeCategoryXXL"),
        AuditTextSize(name: "xxxLarge", category: "UICTContentSizeCategoryXXXL"),
    ]

    /// P052: at the largest side-by-side sizes no title, author or trailing
    /// status is clipped, with a classic in the library so a status shows
    /// beside the lengths.
    func testSideBySideRowsClipNothingAtTheLargestSizes() throws {
        var previous: (size: AuditTextSize, height: CGFloat)?
        for size in [AuditTextSize.all[0]] + Self.largestSideBySide {
            let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classic", "64317"]
                                            + size.launchArguments)
            app.launch()
            openBookshelfFromAddMenu(app)
            let firstRow = rows(app).firstMatch
            XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "Classics lists rows at \(size.name)")
            let height = firstRow.frame.height
            assertTextSizeTook(size, height: height, over: previous)
            previous = (size, height)

            // The shelves (lengths), then the added classic's row (a status)
            // above the keyboard.
            var issues: [String] = []
            try auditClipping(app, into: &issues)
            search(app, for: "gatsby")
            let added = app.buttons["bookshelf.row.64317"].firstMatch
            XCTAssertTrue(added.waitForExistence(timeout: 5))
            XCTAssertEqual(stringValue(of: added), "In library")
            try auditClipping(app, into: &issues)
            XCTAssertEqual(issues, [], "Classics rows at \(size.name)")
            app.terminate()
        }
    }

    private func auditClipping(_ app: XCUIApplication, into issues: inout [String]) throws {
        var found: [String] = []
        try app.performAccessibilityAudit(for: [.textClipped]) { issue in
            if issue.element?.identifier.hasPrefix("debug.") == true
                || self.isSystemSearchPromptClipping(issue) { return true }
            found.append(self.describe(issue))
            return true   // collected, so one failure lists them all
        }
        issues += found
    }

    /// P052's screenshots, opt-in like SilentScreensTests (pass
    /// `TEST_RUNNER_ALOUD_SHOTS_DIR=<dir>`): Classics in light and dark at
    /// the default size, xxLarge and AX3, with one classic in the library.
    /// Silent: muted, and nothing but the + menu is tapped.
    func testClassicsRowScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["ALOUD_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_ALOUD_SHOTS_DIR to capture silent screenshots.")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes = [AuditTextSize.all[0], Self.largestSideBySide[0], AuditTextSize.all[1]]
        for (schemeName, scheme) in [("light", "-uitest-force-light"), ("dark", "-uitest-force-dark")] {
            for size in sizes {
                let app = XCUIApplication.aloud(["-uitest-reset-library", "-uitest-seed-classic", "64317", scheme]
                                                + size.launchArguments)
                app.launch()
                openBookshelfFromAddMenu(app)
                _ = rows(app).firstMatch.waitForExistence(timeout: 5)
                sleep(1)
                let shot = XCUIScreen.main.screenshot().pngRepresentation
                FileManager.default.createFile(atPath: "\(dir)/classics-rows-\(schemeName)-\(size.name).png",
                                               contents: shot)
                app.terminate()
            }
        }
    }
}
