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
}
