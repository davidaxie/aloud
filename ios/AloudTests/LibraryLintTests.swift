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
        let feedPath = "Library/ShelfFeed.swift"
        let feedSources = try SourceTree.sources(only: [feedPath])
        let feed = try XCTUnwrap(feedSources[feedPath])
        XCTAssertTrue(feed.contains("ShelfLayout(for: documents, loadedID: loadedID, stop: stop)"),
                      "the shared feed builds the shelf with the stop")
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
        let item = body(ofStruct: "PaperTitleItem", in: text)
        let mark = try XCTUnwrap(item.range(of: "private var wordmark: some View {"))
        let title = item[mark.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(title.contains("Text(\"Aloud\")"), String(title))
        XCTAssertTrue(title.contains(".accessibilityShowsLargeContentViewer()"), String(title))
        XCTAssertTrue(title.contains(".accessibilityAddTraits(.isHeader)"), String(title))
        XCTAssertTrue(title.contains(".accessibilityAction(.magicTap)"), String(title))
        XCTAssertTrue(text.contains("PaperTitleItem(isHidden: overlayRevealed, onMagicTap: magicTap)"))
    }

    /// P014: on iOS 26 every bar item sits on a shared glass capsule, which
    /// drew the wordmark as a button. The leading item opts out there, and
    /// only there; both branches place the same wordmark.
    func testTheWordmarkSitsOnThePaper() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        let item = body(ofStruct: "PaperTitleItem", in: text)
        XCTAssertTrue(item.contains("ToolbarContent"), "a toolbar content of its own")
        let modern = try XCTUnwrap(item.range(of: "if #available(iOS 26.0, *) {"))
        let otherwise = try XCTUnwrap(item.range(of: "} else {", range: modern.upperBound..<item.endIndex))
        let ios26 = item[modern.upperBound..<otherwise.lowerBound]
        XCTAssertTrue(ios26.contains("ToolbarItem(placement: .navigationBarLeading) { wordmark }"))
        XCTAssertTrue(ios26.contains(".sharedBackgroundVisibility(.hidden)"), String(ios26))
        let earlier = item[otherwise.upperBound...].prefix(120)
        XCTAssertTrue(earlier.contains("ToolbarItem(placement: .navigationBarLeading) { wordmark }"))
        XCTAssertFalse(earlier.contains("sharedBackgroundVisibility"))
        XCTAssertFalse(SwiftLiterals.code(in: text).contains("scrollEdgeEffectStyle"),
                       "the bar stays the opaque paper ShelfScrollEdge sets")
    }

    /// P014: the gear and + are one ink and one weight, so the trailing
    /// group reads as one control.
    func testTheGearAndPlusShareOneInk() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        for name in ["private var settingsButton: some View {", "private var addMenu: some View {"] {
            let start = try XCTUnwrap(text.range(of: name), name)
            let control = text[start.upperBound...].prefix(1400)
            let image = try XCTUnwrap(control.range(of: "Image(systemName:"), name)
            let face = control[image.lowerBound...].prefix(220)
            XCTAssertTrue(face.contains(".font(Theme.font(.body).weight(.semibold))"), "\(name) \(face)")
            XCTAssertTrue(face.contains(".foregroundStyle(Theme.text)"), "\(name) \(face)")
        }
    }

    /// P015: a quick add shows nothing. The root reveals the overlay only
    /// once the add has run past the delay, keyed on the add as a whole,
    /// and hides the stack only while it is up; the shelf and its bar
    /// items follow the revealed state, not the add, and the Mac waits the
    /// same delay.
    func testTheShelfHidesOnlyUnderARevealedOverlay() throws {
        let root = "App/RootView.swift"
        let sources = try SourceTree.sources(only: [Self.libraryFile, root])
        let library = try XCTUnwrap(sources[Self.libraryFile])
        XCTAssertFalse(SwiftLiterals.code(in: library).contains("importer.isImporting"),
                       "the shelf follows the revealed overlay")
        XCTAssertTrue(library.contains("@Environment(\\.importOverlayRevealed) private var overlayRevealed"))
        XCTAssertTrue(library.contains(".accessibilityHidden(overlayRevealed)"))
        XCTAssertTrue(library.contains("if !overlayRevealed {\n                    settingsButton"))

        let rootView = try XCTUnwrap(sources[root])
        XCTAssertTrue(rootView.contains(".task(id: importer.isImporting) { await revealOnceSlow() }"))
        XCTAssertTrue(rootView.contains("ImportOverlayReveal.revealsAfterDelay(isBusy: { importer.isImporting })"))
        XCTAssertTrue(rootView.contains(".environment(\\.importOverlayRevealed, overlayShows)"))
        XCTAssertTrue(rootView.contains(".accessibilityHidden(overlayShows)"))
        XCTAssertFalse(rootView.contains(".accessibilityHidden(importer.isImporting)"))
        XCTAssertTrue(rootView.contains("if isOverlayRevealed, case .importing(let name, let progress) = importer.phase {"))
        XCTAssertTrue(rootView.contains("private var overlayShows: Bool { isOverlayRevealed && importer.isImporting }"),
                      "never a shelf reachable under a visible scrim, nor one hidden once the add ends")

        let macPath = "Library/MacImportOverlay.swift"
        let macSources = try SourceTree.sources(in: SourceTree.macRoot, only: [macPath])
        let mac = try XCTUnwrap(macSources[macPath])
        XCTAssertTrue(mac.contains("static let revealDelay: Duration = ImportOverlayReveal.delay"))
    }

    /// P016: the Files picker takes several at once, through the shared
    /// batch path; a file that fails among them is named in the alert.
    func testFilesPicksSeveralAtOnce() throws {
        let root = "App/RootView.swift"
        let sources = try SourceTree.sources(only: [Self.libraryFile, root])
        let library = try XCTUnwrap(sources[Self.libraryFile])
        let picker = try XCTUnwrap(library.range(of: ".fileImporter(isPresented: presented(.filePicker),"))
        let call = library[picker.lowerBound...].prefix(600)
        XCTAssertTrue(call.contains("allowsMultipleSelection: true"), String(call))
        XCTAssertTrue(call.contains("importer.handlePicks(result)"), String(call))
        XCTAssertTrue(try XCTUnwrap(sources[root]).contains(".alert(importer.failureTitle ?? \"\""))
    }

    /// P017: the + menu ends with the clipboard's text, off while there is
    /// none, and the text is read only on a tap; the empty Library offers
    /// the same as a link, which stays UIKit-free (the Mac compiles it).
    func testThePlusMenuEndsWithPasteText() throws {
        let empty = "Library/EmptyLibraryView.swift"
        let sources = try SourceTree.sources(only: [Self.libraryFile, empty])
        let library = try XCTUnwrap(sources[Self.libraryFile])
        let menu = try XCTUnwrap(library.range(of: "private var addMenu: some View {"))
        let items = library[menu.upperBound...].prefix(900)
        let shared = try XCTUnwrap(items.range(of: "ForEach(LibraryAddMenuItem.allCases, id: \\.self) { item in"))
        let paste = try XCTUnwrap(items.range(of: "Label(PasteTextAction.menuTitle, systemImage: PasteTextAction.systemImage)"))
        XCTAssertLessThan(shared.lowerBound, paste.lowerBound, "after the shared two")
        XCTAssertTrue(items[paste.upperBound...].prefix(80).contains(".disabled(!clipboardHasText)"))
        // RootView rebuilds LibraryView on every import progress tick, and a
        // @State initial value runs each time: no pasteboard query there.
        XCTAssertTrue(library.contains("@State private var clipboardHasText = false"))
        let appear = try XCTUnwrap(library.range(of: ".onAppear {"))
        XCTAssertTrue(library[appear.upperBound...].prefix(200).contains("refreshClipboard()"))
        XCTAssertEqual(items.components(separatedBy: "Button {").count - 1, 2, "exactly the ForEach's and Paste's")
        let tap = try XCTUnwrap(library.range(of: "private func pasteText() {"))
        let body = library[tap.upperBound...].prefix(260)
        XCTAssertTrue(body.contains("UIPasteboard.general.string"), String(body))
        XCTAssertTrue(body.contains("importer.importText(text)"), String(body))

        let emptyView = try XCTUnwrap(sources[empty])
        XCTAssertTrue(emptyView.contains("var onPasteText: (() -> Void)? = nil"))
        XCTAssertTrue(emptyView.contains("if let onPasteText {\n            link(PasteTextAction.linkTitle"))
        XCTAssertFalse(emptyView.contains("import UIKit"))
        XCTAssertFalse(SwiftLiterals.code(in: emptyView).contains("UIPasteboard"))
    }

    /// P018: the shelf's gaps are PhoneShelfMetrics', so captions stand
    /// clear of the next row's covers; the gutter and the AX column stay.
    func testTheShelfKeepsItsRhythm() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        XCTAssertTrue(text.contains("LazyVGrid(columns: columns, spacing: PhoneShelfMetrics.rowSpacing)"))
        XCTAssertTrue(text.contains("VStack(spacing: PhoneShelfMetrics.heroToGrid)"))
        XCTAssertTrue(text.contains(".padding(.top, PhoneShelfMetrics.topPadding)"))
        XCTAssertTrue(text.contains(".padding(.horizontal, PhoneShelfMetrics.gutter)"))
        XCTAssertTrue(text.contains("GridItem(.flexible(), spacing: metrics.columnSpacing), count: metrics.columns)"))
        XCTAssertTrue(text.contains("isAccessibilitySize: dynamicTypeSize.isAccessibilitySize"))
    }

    /// P019: books press onto a paper plate (the grid, the featured
    /// classic and, through the seam, the Continue card), never the plain
    /// style's fade; the Mac keeps its hover plate; long presses lift
    /// rounded cards. The Continue card takes the plate without the shrink:
    /// its play circle is placed from outside the button and would stay
    /// full size over a shrinking body.
    func testBooksPressOntoAPlate() throws {
        let paths = [Self.libraryFile, "Library/EmptyLibraryView.swift", "Library/ContinueListeningCard.swift",
                     "Platform/PlatformViewModifiers.swift", "Theme/PressStyles.swift"]
        let s = try SourceTree.sources(only: paths)
        let library = try XCTUnwrap(s[paths[0]])
        XCTAssertTrue(library.contains(".buttonStyle(ShelfPlateButtonStyle())"))
        XCTAssertFalse(library.contains(".buttonStyle(.plain)"))
        let preview = try XCTUnwrap(library.range(of: ".contentShape(.contextMenuPreview,"))
        let lift = library[preview.lowerBound...].prefix(200)
        XCTAssertTrue(lift.contains("RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))"), String(lift))
        XCTAssertTrue(lift.contains(".contextMenu {"), String(lift))
        let empty = try XCTUnwrap(s[paths[1]])
        let featured = try XCTUnwrap(empty.range(of: "private func featuredButton(for book: BookshelfBook) -> some View {"))
        let button = empty[featured.upperBound...].prefix(900)
        XCTAssertTrue(button.contains(".buttonStyle(ShelfPlateButtonStyle(radius: Theme.Radius.lg))"), String(button))
        XCTAssertTrue(button.contains("TransportHaptics.emit(.play)"), "the haptic stays")
        let card = try XCTUnwrap(s[paths[2]])
        XCTAssertTrue(card.contains(".shelfCardPressStyle(radius: Theme.Radius.lg, scales: false)"))
        XCTAssertTrue(card.contains(".contextMenuPreviewCorners(Theme.Radius.lg)\n        .contextMenu { menu }"))
        let seam = try XCTUnwrap(s[paths[3]])
        let mac = try XCTUnwrap(seam.range(of: "#elseif os(macOS)"))
        let macPress = try XCTUnwrap(seam[mac.upperBound...].range(of: "func shelfCardPressStyle("))
        XCTAssertTrue(seam[macPress.upperBound...].prefix(160).contains("buttonStyle(.plain)"),
                      "the Mac's card keeps its own hover plate")
        let iosPress = try XCTUnwrap(seam[..<mac.lowerBound].range(of: "func shelfCardPressStyle("))
        let iosBody = seam[iosPress.upperBound...].prefix(200)
        XCTAssertTrue(iosBody.contains("scales: Bool = true) -> some View {"), String(iosBody))
        XCTAssertTrue(iosBody.contains("ShelfPlateButtonStyle(radius: radius, scales: scales)"), String(iosBody))
        let pressSignature = "func shelfCardPressStyle(radius: CGFloat = Theme.Radius.md, scales: Bool = true)"
        XCTAssertEqual(seam.components(separatedBy: pressSignature).count - 1, 2,
                       "both halves of the seam take the same parameters")
        let press = try XCTUnwrap(s[paths[4]])
        XCTAssertTrue(press.contains("ShelfPlateButtonStyle.scale(isPressed: isPressed && scales,"),
                      "a style with scales off draws the plate alone")
    }

    /// P020: the iPhone's shelf goes through the shared feed, so the
    /// covered Library builds nothing per sentence and rebuilds once on
    /// return, as the Mac's does.
    func testTheCoveredShelfIsNotRebuilt() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        XCTAssertTrue(text.contains("@State private var feed = ShelfFeed()"))
        XCTAssertFalse(text.contains("ShelfLayout(for:"), "no shelf built outside the feed")
        XCTAssertEqual(text.components(separatedBy: "libraryShows: shows) }").count - 1, 2, "both publishes")
        let shown = try XCTUnwrap(text.range(of: ".onChange(of: router.path.isEmpty) { _, shows in"))
        XCTAssertTrue(text[shown.upperBound...].prefix(200).contains("$0.libraryShown(store.documents"))
        // An interactive back swipe shows the Library before the path
        // empties: the stale shelf is rebuilt as it appears, too.
        let appear = try XCTUnwrap(text.range(of: ".onAppear {"))
        XCTAssertTrue(text[appear.upperBound...].prefix(160).contains("feedShelf { $0.libraryShown(store.documents"),
                      String(text[appear.upperBound...].prefix(160)))
        XCTAssertLessThan(appear.lowerBound, shown.lowerBound, "beside the completed pop's rebuild")
        let macSources = try SourceTree.sources(in: SourceTree.macRoot, only: [Self.macLibraryFile])
        let mac = try XCTUnwrap(macSources[Self.macLibraryFile])
        XCTAssertTrue(mac.contains("@State private var shelfFeed = ShelfFeed()"))
        XCTAssertFalse(mac.contains("struct MacShelfFeed"), "one feed, in the shared core")
        XCTAssertTrue(mac.contains("ShelfLayout.focusAfterRemoving(target.id, in: shelf)"), "one focus rule too")
        XCTAssertFalse(mac.contains("static func focusAfterRemoving("))
    }

    /// P021: the opaque bar gets a hairline once the shelf scrolls under
    /// it, none at rest; only where the bar is opaque paper (iOS 26), since
    /// earlier bars draw their own.
    func testTheBarRuleFadesInOnScroll() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        let edge = body(ofStruct: "ShelfScrollEdge", in: text)
        let modern = try XCTUnwrap(edge.range(of: "if #available(iOS 26.0, *) {"))
        let otherwise = try XCTUnwrap(edge.range(of: "} else {", range: modern.upperBound..<edge.endIndex))
        let ios26 = edge[modern.upperBound..<otherwise.lowerBound]
        XCTAssertTrue(ios26.contains(".toolbarBackground(.visible, for: .navigationBar)"), "the bar stays opaque")
        XCTAssertTrue(ios26.contains(".onScrollGeometryChange(for: Bool.self)"))
        XCTAssertTrue(ios26.contains("ShelfEdgeRule.shows(contentOffsetY: geometry.contentOffset.y"))
        XCTAssertTrue(ios26.contains(".overlay(alignment: .top) { rule }"))
        XCTAssertTrue(edge.contains(".fill(Theme.Stroke.hairlineColor)"))
        XCTAssertTrue(edge.contains(".frame(height: Theme.Stroke.hairlineWidth)"))
        XCTAssertTrue(edge.contains(".opacity(scrolledUnder ? 1 : 0)"))
        XCTAssertTrue(edge.contains("reduceMotion ? nil : .easeOut(duration: Theme.Motion.press)"))
        XCTAssertFalse(SwiftLiterals.code(in: edge).contains("scrollEdgeEffectStyle"))

        // Opt-in: the shelves draw it; the other screens sharing the opaque
        // bar (Settings, Licenses, the voice page, the appearance sheet) don't.
        XCTAssertTrue(edge.contains("var showsScrollRule = false"))
        let optIn = try XCTUnwrap(ios26.range(of: "if showsScrollRule {"))
        let scrollWatch = try XCTUnwrap(ios26.range(of: ".onScrollGeometryChange(for: Bool.self)"))
        XCTAssertLessThan(optIn.lowerBound, scrollWatch.lowerBound, "no scroll watch where the rule is off")
        XCTAssertTrue(text.contains(".modifier(ShelfScrollEdge(showsScrollRule: true))"), "the Library's grid")
        let shelves = ["Library/EmptyLibraryView.swift": ".shelfScrollEdge(rule: true)",
                       "Bookshelf/BookshelfView.swift": ".modifier(ShelfScrollEdge(showsScrollRule: true))"]
        let others = ["Settings/SettingsView.swift", "Settings/LicensesView.swift",
                      "Settings/ListeningView.swift", "Reader/AppearanceSheet.swift"]
        let edges = try SourceTree.sources(only: Array(shelves.keys) + others)
        for (path, call) in shelves {
            let source = try XCTUnwrap(edges[path], path)
            XCTAssertTrue(source.contains(call), path)
        }
        for path in others {
            let source = try XCTUnwrap(edges[path], path)
            XCTAssertTrue(source.contains("ScrollEdge("), "\(path) still sets the opaque bar")
            XCTAssertFalse(source.contains("showsScrollRule: true"), path)
            XCTAssertFalse(source.contains("rule: true"), path)
        }
        let seamPath = "Platform/PlatformViewModifiers.swift"
        let seamSources = try SourceTree.sources(only: [seamPath])
        let seam = try XCTUnwrap(seamSources[seamPath])
        XCTAssertTrue(seam.contains("modifier(ShelfScrollEdge(ground: ground, showsScrollRule: rule))"))
        XCTAssertEqual(seam.components(separatedBy: "func shelfScrollEdge(ground: Color = Theme.bg, rule: Bool = false)").count - 1,
                       2, "both halves of the seam take the rule")
    }

    /// P022: after a Delete VoiceOver lands on a neighbour, read off the
    /// shelf before the book leaves it, and after Mark as finished on the
    /// Continue card it follows the book to its grid card. The grid is
    /// lazy, so the shelf scrolls the card in before focus moves: a card
    /// it hasn't built yet can't take focus.
    func testVoiceOverFocusFollowsDeleteAndFinish() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        XCTAssertTrue(text.contains("@AccessibilityFocusState private var voFocus: UUID?"))
        XCTAssertTrue(text.contains(".accessibilityFocused($voFocus, equals: document.id)"), "every grid card")
        XCTAssertTrue(text.contains("focus: $voFocus,"), "the Continue card")
        XCTAssertTrue(text.contains(".voiceOverFocus(focus)"))
        let neighbour = try XCTUnwrap(text.range(of: "let next = ShelfLayout.focusAfterRemoving(target.id, in: shelf)"))
        let delete = try XCTUnwrap(text.range(of: "if let failure = model.deleteDocument(target) {"))
        XCTAssertLessThan(neighbour.lowerBound, delete.lowerBound, "read before the book leaves the shelf")
        XCTAssertTrue(text[delete.upperBound...].prefix(160).contains("moveVoiceOverFocus(to: next)"))
        XCTAssertTrue(text.contains("if wasHero { moveVoiceOverFocus(to: document.id) }"))
        XCTAssertTrue(text.contains("ScrollViewReader { proxy in"))
        XCTAssertTrue(text.contains(".accessibilityFocused($voFocus, equals: document.id)\n"
                                    + "                // What a VoiceOver hand-off scrolls to (`pendingFocus`).\n"
                                    + "                .id(document.id)"), "every grid card is a scroll target")
        XCTAssertTrue(text.contains("contextMenuActions(for: hero)\n                    }\n                    .id(hero.id)"),
                      "the Continue card is one too")
        let move = try XCTUnwrap(text.range(of: "private func moveVoiceOverFocus(to card: UUID?) {"))
        let moveBody = text[move.upperBound...].prefix(220)
        XCTAssertTrue(moveBody.contains("pendingFocus = card"), String(moveBody))
        XCTAssertFalse(moveBody.contains("voFocus ="), "focus moves only after the scroll")
        let onChange = try XCTUnwrap(text.range(of: ".onChange(of: pendingFocus) { _, id in"))
        XCTAssertTrue(text[onChange.upperBound...].prefix(160).contains("landVoiceOverFocus(on: id, proxy: proxy)"))
        let handoff = try XCTUnwrap(text.range(of: "private func landVoiceOverFocus(on id: UUID, proxy: ScrollViewProxy) {"))
        let handoffBody = text[handoff.upperBound...].prefix(400)
        let scroll = try XCTUnwrap(handoffBody.range(of: "proxy.scrollTo(id, anchor: .center)"), String(handoffBody))
        let focus = try XCTUnwrap(handoffBody.range(of: "voFocus = id"), String(handoffBody))
        XCTAssertLessThan(scroll.lowerBound, focus.lowerBound, "scrolled in before VoiceOver lands")
        XCTAssertTrue(text.contains("PlaybackController.postAnnouncement(\"Marked as finished\""), "still said")
    }

    /// P023: Delete sits in its own section of the long-press menu; the
    /// VoiceOver actions stay one flat list.
    func testDeleteHasItsOwnMenuSection() throws {
        let s = try SourceTree.sources(only: [Self.libraryFile])
        let text = try XCTUnwrap(s[Self.libraryFile])
        XCTAssertTrue(text.contains(".accessibilityActions { documentActions(for: document) }"))
        XCTAssertTrue(text.contains(".contextMenu { contextMenuActions(for: document) }"))
        XCTAssertTrue(text.contains("} menu: {\n                        contextMenuActions(for: hero)"))
        let menu = try XCTUnwrap(text.range(of: "private func contextMenuActions(for document: LibraryDocument) -> some View {"))
        let body = text[menu.upperBound...].prefix(300)
        XCTAssertTrue(body.contains("ForEach(DocumentAction.menuSections(for: document)"), String(body))
        XCTAssertTrue(body.contains("Section {"), String(body))
    }

    /// F045: every shelf the Library derives hears the controller's
    /// unattended stop, so its hero is the book the shortcut and remote Play
    /// would continue (`DocumentStore.isAtItsEnd`).
    func testTheShelfHearsTheUnattendedStop() throws {
        let text = try XCTUnwrap(try SourceTree.sources(only: [Self.libraryFile])[Self.libraryFile])
        let derivations = text.components(separatedBy: .newlines).filter { $0.contains("feedShelf { $0.") }
        XCTAssertEqual(derivations.count, 4,
                       "both publishes, the Library appearing (a back swipe's start) and the pop completing")
        for line in derivations {
            XCTAssertTrue(line.contains("stop: model.playback.stopped"), line)
        }
        let feedPath = "Library/ShelfFeed.swift"
        let feedSources = try SourceTree.sources(only: [feedPath])
        let feed = try XCTUnwrap(feedSources[feedPath])
        XCTAssertTrue(feed.contains("layout = ShelfLayout(for: documents, loadedID: loadedID, stop: stop)"))
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
