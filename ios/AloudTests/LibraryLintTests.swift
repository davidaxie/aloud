import XCTest

/// Source lints for the shelf (R12b, R12h, R18, R20). Reads the source tree
/// next to the tests; skips when the host can't read it.
final class LibraryLintTests: XCTestCase {

    private static let coverFile = "Library/BookCover.swift"
    private static let libraryFile = "Library/LibraryView.swift"
    /// Under ios/AloudMac.
    private static let macLibraryFile = "Library/MacLibraryView.swift"

    /// The text of `struct <name>` up to the next top-level declaration.
    private func body(ofStruct name: String, in text: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let start = text.range(of: "struct \(name):") else {
            XCTFail("struct \(name) not found", file: file, line: line)
            return ""
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// R12h: Smart Invert leaves every cover as drawn. There is one cover
    /// (R22), and every other cover draws through it.
    func testCoversIgnoreInvertColors() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.coverFile])[Self.coverFile])
        XCTAssertTrue(body(ofStruct: "BookCover", in: text).contains(".accessibilityIgnoresInvertColors()"),
                      "BookCover should set accessibilityIgnoresInvertColors")
    }

    /// R12b: magic tap reaches the hero from the shelf.
    func testLibraryHandlesMagicTap() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        XCTAssertTrue(text.contains(".accessibilityAction(.magicTap"))
    }

    /// R18: the shelf never redraws per sentence. Only its hero observes the
    /// controller, through an @ObservedObject handed down.
    func testLibraryDoesNotObservePlayback() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        XCTAssertFalse(text.contains("@EnvironmentObject private var playback"))
    }

    /// Rename's Save is off while the title is empty or only spaces: the
    /// store keeps the old title then (`DocumentStore.renamedTitle`), and
    /// Save closed the alert as if it had renamed the book. The Mac's Rename
    /// alert too (H048).
    func testRenameSaveIsOffWithoutATitle() throws {
        let ios = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        let mac = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot,
                                                       only: [Self.macLibraryFile])[Self.macLibraryFile])
        for (name, text) in [(Self.libraryFile, ios), (Self.macLibraryFile, mac)] {
            let save = try XCTUnwrap(text.range(of: "Button(\"Save\")"), "\(name): Rename's Save button")
            let cancel = try XCTUnwrap(text.range(of: "Button(\"Cancel\", role: .cancel) { renameTarget = nil }",
                                                  range: save.upperBound..<text.endIndex),
                                       "\(name): Rename's Cancel button")
            XCTAssertTrue(text[save.lowerBound..<cancel.lowerBound]
                            .contains(".disabled(DocumentStore.renamedTitle(renameText) == nil)"),
                          "\(name): Save should be disabled while the trimmed title is empty")
        }
    }

    /// R20: busy states hold still under Reduce Motion; no system spinner on
    /// the shelf or the Bookshelf.
    func testNoSpinnerOnTheShelves() throws {
        let shelves = try SourceTree.sources(only: ["Library", "Bookshelf"])
        XCTAssertEqual(SourceTree.files(containing: "ProgressView", in: shelves), [])
    }

    /// F026, the Mac shelf: every way a card opens its book stops a Continue
    /// circle load of another book first, as the iPhone shelf's `open` does.
    func testTheMacShelfOpensThroughReaderOpens() throws {
        let file = "Library/MacLibraryView.swift"
        let text = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot, only: [file])[file])
        let shelf = body(ofStruct: "MacLibraryView", in: text)
        XCTAssertTrue(shelf.contains("continuePlayback.readerOpens(document.id)\n        router.open(document)"),
                      "open(_:) should stop another book's circle load before it opens")
        // The only direct open left is a circle load that failed: it was
        // this book's, and it is over.
        let direct = shelf.components(separatedBy: "router.open(").count - 1
        XCTAssertEqual(direct, 2, "only open(_:) and the circle's onFailure call router.open")
        XCTAssertTrue(shelf.contains("onFailure: { router.open(document) }"))
    }

    /// F045, the Mac: the Continue hero and Space/Play with no book loaded
    /// pick by the controller's unattended stop, as the launch restore and
    /// remote Play do, so a book stopped in its last minute stays on offer.
    func testTheMacContinueBookHonoursTheStop() throws {
        let files = ["Library/MacLibraryView.swift", "Commands/MacCommandActions.swift"]
        let sources = try SourceTree.sources(in: SourceTree.macRoot, only: files)
        let library = try XCTUnwrap(sources[files[0]])
        XCTAssertTrue(library.contains("ShelfLayout(for: documents, loadedID: loadedID, stop: stop)"))
        XCTAssertEqual(library.components(separatedBy: "stop: model.playback.stopped").count - 1, 3,
                       "both store and controller publishes and the Library showing again")
        let commands = try XCTUnwrap(sources[files[1]])
        XCTAssertTrue(commands.contains("loadedID: playback.document?.id,\n                                                 stop: playback.stopped)"),
                      "continueBook should pass the controller's stop")
    }

    /// J014: a plain button hit-tests only what its label draws, so the
    /// card claims its whole cell; its width is DocumentCardLayoutTests'.
    func testTheCardIsTappableAcrossItsCell() throws {
        let path = "Library/DocumentCardView.swift"
        let text = try XCTUnwrap(try SourceTree.sources(only: [path])[path])
        let body = body(ofStruct: "DocumentCardView", in: text)
        let shape = try XCTUnwrap(body.range(of: ".contentShape(Rectangle())"))
        let frame = try XCTUnwrap(body.range(of: ".frame(maxWidth: .infinity, alignment: .leading)"))
        let element = try XCTUnwrap(body.range(of: ".accessibilityElement(children: .combine)"))
        XCTAssertLessThan(frame.lowerBound, shape.lowerBound, "the shape covers the full-width frame")
        XCTAssertLessThan(shape.lowerBound, element.lowerBound)
    }

    /// J017: Voice Control answers to a book's title on every card, on the
    /// iPhone and the Mac, and on the Continue card (before its overlay, so
    /// the circle keeps its own Play or Pause name).
    func testEveryCardAnswersVoiceControlByTitle() throws {
        let shared = ["Library/LibraryView.swift", "Library/ContinueListeningCard.swift"]
        let app = try SourceTree.sources(only: shared)
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: ["Library/MacLibraryCard.swift"])
        let grid = ".accessibilityInputLabels(DocumentCardView.inputLabels(for: document))"
        XCTAssertTrue(try XCTUnwrap(app[shared[0]]).contains(grid), "the iPhone grid card")
        XCTAssertTrue(try XCTUnwrap(mac["Library/MacLibraryCard.swift"]).contains(grid), "the Mac grid card")
        let card = try XCTUnwrap(app[shared[1]])
        let labels = try XCTUnwrap(card.range(of: ".accessibilityInputLabels(ContinueListeningCopy.inputLabels(title: document.title))"))
        let overlay = try XCTUnwrap(card.range(of: ".overlayPreferenceValue("))
        XCTAssertLessThan(labels.lowerBound, overlay.lowerBound)
    }

    /// J018, R12g: the Mac's Continue card offers VoiceOver the grid cards'
    /// three actions under the iPhone's names; the Mac's menu wording (Open,
    /// Rename…) stays in its context menu.
    func testTheMacContinueCardOffersTheGridCardsVoiceOverActions() throws {
        let card = try XCTUnwrap(try SourceTree.sources(only: ["Library/ContinueListeningCard.swift"])["Library/ContinueListeningCard.swift"])
        XCTAssertTrue(card.contains(".accessibilityActions { actions }"))
        XCTAssertTrue(card.contains(".contextMenu { menu }"), "the menu is its own builder")
        let files = ["Library/MacLibraryCard.swift", Self.macLibraryFile]
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: files)
        let grid = body(ofStruct: "MacLibraryCard", in: try XCTUnwrap(mac[files[0]]))
        XCTAssertTrue(grid.contains("MacDocumentActions(document: document, perform: perform)"))
        let library = try XCTUnwrap(mac[files[1]])
        let hero = try XCTUnwrap(library.range(of: "MacContinueHero(document: hero,"))
        let call = library[hero.lowerBound...].prefix(1200)
        let actions = try XCTUnwrap(call.range(of: "MacDocumentActions(document: hero,"))
        let menu = try XCTUnwrap(call.range(of: "} menu: {"))
        let menuItems = try XCTUnwrap(call.range(of: "MacDocumentMenu(document: hero,"))
        XCTAssertLessThan(actions.lowerBound, menu.lowerBound, "VoiceOver gets the grid's list")
        XCTAssertLessThan(menu.lowerBound, menuItems.lowerBound, "the menu keeps the Mac's wording")
    }

    /// L014: a keyboard user reaches Rename and Mark as Finished as they do
    /// Delete: Edit's book items act on the focused grid card or Continue
    /// card, which publishes all three (Mark as Finished only while there
    /// is something left to mark), so none needs the context menu.
    func testTheFocusedMacCardOffersEditsBookItems() throws {
        let files = ["Library/MacLibraryCard.swift", Self.macLibraryFile, "Commands/AloudCommands.swift"]
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: files)
        let cardFile = try XCTUnwrap(mac[files[0]])
        let grid = body(ofStruct: "MacLibraryCard", in: cardFile)
        XCTAssertTrue(grid.contains(".macBookCommands(for: document, perform: perform)"), "the grid card")
        let library = try XCTUnwrap(mac[files[1]])
        XCTAssertTrue(library.contains(".macBookCommands(for: hero) { perform($0, on: hero) }"), "the Continue card")
        XCTAssertFalse(library.contains(".focusedValue(\\.macDeleteBook)"), "Delete alone would leave the others out")

        let helper = try XCTUnwrap(cardFile.range(of: "func macBookCommands(for document: LibraryDocument,"))
        let published = cardFile[helper.upperBound...].prefix(700)
        XCTAssertTrue(published.contains("focusedValue(\\.macRenameBook) { perform(.rename) }"), String(published))
        XCTAssertTrue(published.contains(".focusedValue(\\.macMarkFinished, markFinished)"), String(published))
        XCTAssertTrue(published.contains("DocumentAction.available(for: document).contains(.markFinished)"),
                      "a Finished book has nothing to mark")
        XCTAssertTrue(published.contains(".focusedValue(\\.macDeleteBook) { perform(.delete) }"), String(published))

        let commands = try XCTUnwrap(mac[files[2]])
        let edit = try XCTUnwrap(commands.range(of: "CommandGroup(after: .pasteboard) {"))
        let items = commands[edit.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(items.contains("item(.renameBook)\n            item(.markFinished)\n            item(.deleteBook)"),
                      "beside Delete Book…: \(items)")
        for (key, value) in [("macRenameBook", "renameBook"), ("macMarkFinished", "markFinished")] {
            XCTAssertTrue(commands.contains("@FocusedValue(\\.\(key)) private var \(value)"), key)
            XCTAssertTrue(commands.contains("actions.\(value) = \(value)"), value)
            XCTAssertTrue(commands.contains("case .\(value): return \(value) != nil"), value)
        }
    }

    /// L019: both Classics screens shelve by the time their rows show, at
    /// the app-wide speed, never by the 1× shelving under rate-aware rows.
    func testTheClassicsScreensShelveAtTheirRowsSpeed() throws {
        let phonePath = "Bookshelf/BookshelfView.swift"
        let macPath = "Library/MacClassicsView.swift"
        let phone = try SourceTree.sources(only: [phonePath])
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: [macPath])
        for (path, text) in [(phonePath, try XCTUnwrap(phone[phonePath])), (macPath, try XCTUnwrap(mac[macPath]))] {
            XCTAssertTrue(text.contains("bookshelfIndex.shelves(rate: model.globalRate)"), path)
            XCTAssertFalse(text.contains("bookshelfIndex.shelves)"), "\(path) shelves at 1×")
            XCTAssertFalse(text.contains("bookshelfIndex.shelves."), "\(path) shelves at 1×")
            XCTAssertTrue(text.contains("book.listeningMinutes(rate: rate)"), "\(path)'s rows use the shelves' measure")
        }
    }

    /// L015: Return on the Mac Continue card's focused circle plays or
    /// pauses in place, as Space does, instead of bubbling up to the card's
    /// Return, which opens the reader.
    func testReturnOnTheMacContinueCircleTogglesInPlace() throws {
        let path = "Library/ContinueListeningCard.swift"
        let seamPath = "Platform/PlatformViewModifiers.swift"
        let sources = try SourceTree.sources(only: [path, seamPath])
        let card = try XCTUnwrap(sources[path])
        let start = try XCTUnwrap(card.range(of: "private var circle: some View {"))
        let circle = card[start.upperBound...].prefix(1200)
        XCTAssertTrue(circle.contains(".returnKeyActsOnMac(onTogglePlayback)"), "the circle takes Return itself")

        // The seam: a no-op on the iPhone (no card Return there), the key
        // handled on the Mac so the card's Return never sees it.
        let seam = try XCTUnwrap(sources[seamPath])
        let mac = try XCTUnwrap(seam.range(of: "#elseif os(macOS)"))
        let macHalf = seam[mac.upperBound...]
        let macFunc = try XCTUnwrap(macHalf.range(of: "func returnKeyActsOnMac("))
        let macBody = macHalf[macFunc.upperBound...].prefix(200)
        XCTAssertTrue(macBody.contains("onKeyPress(.return)"), String(macBody))
        XCTAssertTrue(macBody.contains("action()"), String(macBody))
        XCTAssertTrue(macBody.contains("return .handled"), "the card's Return never sees it")
        let iosHalf = seam[..<mac.lowerBound]
        let iosFunc = try XCTUnwrap(iosHalf.range(of: "func returnKeyActsOnMac("))
        XCTAssertFalse(iosHalf[iosFunc.upperBound...].prefix(160).contains("onKeyPress"), "the iPhone's is a no-op")
    }

    /// J020: the bar caps its text size, so the Library's title, like every
    /// other bar title, shows large on a long press.
    func testTheLibraryTitleOffersTheLargeContentViewer() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        let item = try XCTUnwrap(text.range(of: "ToolbarItem(placement: .navigationBarLeading) {"))
        let title = text[item.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(title.contains("Text(\"Aloud\")"), String(title))
        XCTAssertTrue(title.contains(".accessibilityShowsLargeContentViewer()"), String(title))
    }

    /// F045: every shelf the Library derives hears the controller's
    /// unattended stop, so its hero is the book the shortcut and remote Play
    /// would continue (`DocumentStore.isAtItsEnd`).
    func testTheShelfHearsTheUnattendedStop() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        let derivations = text.components(separatedBy: .newlines).filter { $0.contains("ShelfLayout(for:") }
        XCTAssertEqual(derivations.count, 2, "the lint reads both derivations")
        for line in derivations {
            XCTAssertTrue(line.contains("stop: model.playback.stopped"), line)
        }
    }

    /// L011: while library.json can't be read, both Libraries show the
    /// standing notice over whatever the shelf shows (the first-run screen,
    /// or the books that still decode). Before, neither read the store's
    /// state, and the shelf looked as if every book were gone.
    func testBothLibrariesShowTheUnreadableLibraryNotice() throws {
        let ios = try SourceTree.sources(only: [Self.libraryFile])
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: [Self.macLibraryFile])
        let shared = try SourceTree.sources(only: ["Library/EmptyLibraryView.swift"])
        for text in [try XCTUnwrap(ios[Self.libraryFile]), try XCTUnwrap(mac[Self.macLibraryFile])] {
            let body = try XCTUnwrap(text.range(of: "var body: some View {").map { String(text[$0.upperBound...]) })
            let inset = try XCTUnwrap(body.range(of: ".safeAreaInset(edge: .top"), "pinned above the shelf")
            let gate = try XCTUnwrap(body.range(of: "if !store.isIndexReadable {"))
            let notice = try XCTUnwrap(body.range(of: "UnreadableLibraryNotice("))
            XCTAssertTrue(inset.upperBound < gate.lowerBound && gate.upperBound < notice.lowerBound,
                          "the inset shows the notice only while the index can't be read")
            let branch = try XCTUnwrap(body.range(of: "if store.documents.isEmpty {"))
            XCTAssertTrue(branch.lowerBound < inset.lowerBound, "over the empty screen and the shelf alike")
        }
        let notice = body(ofStruct: "UnreadableLibraryNotice", in: try XCTUnwrap(shared["Library/EmptyLibraryView.swift"]))
        XCTAssertTrue(notice.contains("Text(UnreadableLibraryCopy.title)"))
        XCTAssertTrue(notice.contains("Text(UnreadableLibraryCopy.detail)"))
        XCTAssertTrue(notice.contains(".accessibilityElement(children: .combine)"), "read as one")
    }
}
