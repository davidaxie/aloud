import XCTest
@testable import Aloud

/// What the menus and keys do, over the shared functions: the pure steps,
/// and the commands on a muted rig's controller.
@MainActor
final class MacCommandActionsTests: XCTestCase {

    // MARK: - Pure rules

    func testSpeedStepsMoveOnePresetAndStopAtTheEnds() {
        XCTAssertEqual(MacCommandActions.steppedRate(from: 1, faster: true), 1.25)
        XCTAssertEqual(MacCommandActions.steppedRate(from: 2, faster: true), 2.5)
        XCTAssertNil(MacCommandActions.steppedRate(from: 2.5, faster: true), "Faster stops at 2.5×")
        XCTAssertNil(MacCommandActions.steppedRate(from: 3, faster: true))
        XCTAssertEqual(MacCommandActions.steppedRate(from: 1.25, faster: false), 1)
        XCTAssertNil(MacCommandActions.steppedRate(from: 1, faster: false), "Slower stops at 1×")
        XCTAssertNil(MacCommandActions.steppedRate(from: 0.75, faster: false))
        // Off a preset: the nearest preset that way.
        XCTAssertEqual(MacCommandActions.steppedRate(from: 1.1, faster: true), 1.25)
        XCTAssertEqual(MacCommandActions.steppedRate(from: 1.1, faster: false), 1)
        XCTAssertEqual(MacCommandActions.steppedRate(from: 3, faster: false), 2.5)
    }

    func testTextSizeStepsStopAtTheEnds() {
        XCTAssertEqual(MacCommandActions.steppedTextSize(from: 2, bigger: true), 3)
        XCTAssertEqual(MacCommandActions.steppedTextSize(from: 2, bigger: false), 1)
        XCTAssertNil(MacCommandActions.steppedTextSize(from: 0, bigger: false))
        XCTAssertNil(MacCommandActions.steppedTextSize(from: ReaderTextSize.steps.count - 1, bigger: true))
    }

    func testPlaceFollowsTheStack() {
        let id = UUID()
        XCTAssertEqual(MacPlace(path: []), .library)
        XCTAssertEqual(MacPlace(path: [.bookshelf]), .classics)
        XCTAssertEqual(MacPlace(path: [.bookshelf, .reader(id)]), .reader(id))
    }

    // MARK: - On the controller

    func testSpaceTogglesTheLoadedBook() async {
        let (rig, actions) = makeActions()
        rig.loadDefault()
        XCTAssertTrue(actions.isEnabled(.playPause))
        XCTAssertEqual(actions.title(for: .playPause), MacMenuCopy.play)

        let router = MacKeyRouter { actions.perform($0) }
        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49), in: nil))
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing, "Space played")
        XCTAssertEqual(actions.title(for: .playPause), MacMenuCopy.pause)

        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49), in: nil))
        let paused = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(paused, "Space paused")
    }

    func testNothingToPlayDisablesTheTransport() {
        let (_, actions) = makeActions()
        for command: MacCommand in [.playPause, .back15, .forward15, .previousChapter, .nextChapter, .sleepTimer] {
            XCTAssertFalse(actions.isEnabled(command), "\(command)")
            XCTAssertFalse(actions.perform(command), "\(command) does nothing, silently")
        }
    }

    func testSkipsUseTheOneSkip() {
        let (rig, actions) = makeActions(sentences: 40)
        rig.loadDefault(at: 20)
        let expected = PlaybackController.skipTarget(from: 20, seconds: PlaybackController.skipInterval,
                                                     sentenceCount: 40,
                                                     wordsPerMinute: LibraryDocument.spokenWordsPerMinute,
                                                     words: { _ in 3 })
        XCTAssertTrue(actions.perform(.forward15))
        XCTAssertEqual(rig.controller.currentSentence, expected)
        XCTAssertTrue(actions.perform(.back15))
        XCTAssertLessThan(rig.controller.currentSentence, expected)
        XCTAssertFalse(rig.controller.isActive, "a skip keeps the pause")
    }

    func testSpeedKeysStepAndAnnounce() {
        let (rig, base) = makeActions()
        var heard: [String] = []
        var actions = base
        actions.announce = { heard.append($0) }
        XCTAssertFalse(actions.isEnabled(.slower), "Slower is off at 1×")
        XCTAssertTrue(actions.perform(.faster))
        XCTAssertEqual(rig.controller.rate, 1.25)
        XCTAssertEqual(heard, [ListeningCopy.spokenRate(1.25)])
        XCTAssertTrue(actions.perform(.slower))
        XCTAssertEqual(rig.controller.rate, 1)
    }

    func testWindowCommandsFollowThePlace() {
        let (_, actions) = makeActions()
        XCTAssertFalse(actions.isEnabled(.find), "the Library has no search")
        XCTAssertFalse(actions.isEnabled(.back))
        XCTAssertFalse(actions.isEnabled(.toggleContents))

        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(actions.place, .classics)
        XCTAssertEqual(actions.ui.searchFocus, .classics, "Add a Classic lands in the search")

        actions.ui.searchFocus = nil
        XCTAssertTrue(actions.perform(.find))
        XCTAssertEqual(actions.ui.searchFocus, .classics)

        XCTAssertTrue(actions.perform(.back))
        XCTAssertEqual(actions.place, .library)
    }

    /// ⇧⌘O from a reader opened from Classics goes back to that Classics,
    /// in one move, never stacking a second one. From a reader opened from
    /// the Library it pushes Classics, and in Classics it stays.
    func testAddAClassicNeverStacksASecondClassics() {
        let (_, actions) = makeActions()
        let router = actions.router
        let book = UUID(), other = UUID()

        router.path = [.bookshelf, .reader(book)]
        let generation = router.navigationGeneration
        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(router.path, [.bookshelf], "back to the Classics the reader came from")
        XCTAssertEqual(router.navigationGeneration, generation &+ 1, "one move")
        XCTAssertEqual(actions.ui.searchFocus, .classics)

        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(router.path, [.bookshelf], "in Classics it stays")
        XCTAssertEqual(router.navigationGeneration, generation &+ 1)

        router.path = [.reader(other), .bookshelf, .reader(book)]
        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(router.path, [.reader(other), .bookshelf], "the nearest Classics, the one Back reaches")

        router.path = [.reader(book)]
        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(router.path, [.reader(book), .bookshelf], "no Classics below: it pushes one")
    }

    // MARK: - Contents (M16)

    func testFindInTheReaderOpensContentsSearch() {
        let (_, actions) = makeActions()
        actions.router.path = [.reader(UUID())]
        XCTAssertTrue(actions.isEnabled(.find))
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.showContents)
        XCTAssertTrue(actions.perform(.find))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.ui.searchFocus, .contents)
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.hideContents)

        // ⌘F with the panel up keeps it, and asks for the field again.
        actions.ui.searchFocus = nil
        XCTAssertTrue(actions.perform(.find))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.ui.searchFocus, .contents)
    }

    func testShowContentsTogglesInTheReaderOnly() {
        let (_, actions) = makeActions()
        XCTAssertFalse(actions.isEnabled(.toggleContents), "the Library has no Contents")
        XCTAssertFalse(actions.perform(.toggleContents))
        XCTAssertFalse(actions.ui.isContentsShown)

        actions.router.path = [.reader(UUID())]
        XCTAssertTrue(actions.isEnabled(.toggleContents))
        XCTAssertTrue(actions.perform(.toggleContents))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.hideContents)
        XCTAssertNil(actions.ui.searchFocus, "showing Contents leaves focus where it was")
        XCTAssertTrue(actions.perform(.toggleContents))
        XCTAssertFalse(actions.ui.isContentsShown)
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.showContents)

        actions.router.path = [.bookshelf]
        XCTAssertFalse(actions.isEnabled(.toggleContents), "nor do Classics")
    }

    /// Classics' ⌘F stays its toolbar search, and leaves Contents alone.
    func testFindInClassicsStaysClassicsSearch() {
        let (_, actions) = makeActions()
        actions.router.path = [.bookshelf]
        XCTAssertTrue(actions.perform(.find))
        XCTAssertEqual(actions.ui.searchFocus, .classics)
        XCTAssertFalse(actions.ui.isContentsShown)
    }

    /// A Contents row's jump is the shared one: ⌘Z (Undo Jump) is live
    /// after it and puts the sentence and the pause back.
    func testUndoJumpAfterAContentsJump() async {
        let (rig, actions) = makeActions(sentences: 40)
        rig.loadDefault(at: 3)
        XCTAssertFalse(actions.isEnabled(.undoJump))
        MacContents.jump(rig.controller, to: 30, origin: .chapter)
        XCTAssertEqual(rig.controller.currentSentence, 30)
        XCTAssertTrue(actions.isEnabled(.undoJump))
        XCTAssertTrue(actions.perform(.undoJump))
        XCTAssertEqual(rig.controller.currentSentence, 3)
        let paused = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(paused, "the listener was paused there")
        XCTAssertFalse(actions.isEnabled(.undoJump), "spent")
    }

    func testTextSizeKeysWriteTheOnePreference() {
        let (rig, base) = makeActions()
        var actions = base
        actions.defaults = rig.defaults
        rig.defaults.set(ReaderTextSize.steps.count - 1, forKey: ReaderTextSize.prefKey)
        XCTAssertFalse(actions.isEnabled(.biggerText))
        XCTAssertTrue(actions.perform(.smallerText))
        XCTAssertEqual(rig.defaults.integer(forKey: ReaderTextSize.prefKey), ReaderTextSize.steps.count - 2)
    }

    func testFocusBorneCommandsNeedTheirScreen() {
        let (_, base) = makeActions()
        XCTAssertFalse(base.isEnabled(.followVoice))
        XCTAssertFalse(base.isEnabled(.deleteBook))
        var followed = 0
        var actions = base
        actions.followVoice = { followed += 1 }
        XCTAssertTrue(actions.perform(.followVoice))
        XCTAssertEqual(followed, 1)
    }

    /// A command that acts in the main window brings it back first, closed
    /// or minimized: Add from Files…'s panel, a pushed Classics or a
    /// focused field never waits in a window no one can see. Playback's
    /// commands act wherever the window is.
    func testWindowCommandsBringTheWindowBackFirst() {
        let (rig, base) = makeActions()
        rig.loadDefault()
        var actions = base
        let router = base.router
        var shownWith: [LibraryRouter.RootPresentation?] = []
        actions.showMainWindow = { shownWith.append(router.rootPresentation) }
        var settingsOpened = 0
        actions.openSettings = { settingsOpened += 1 }

        XCTAssertTrue(actions.perform(.addFromFiles))
        XCTAssertEqual(shownWith, [nil], "the window comes back before the panel is asked for")
        XCTAssertEqual(actions.router.rootPresentation, .filePicker)

        XCTAssertTrue(actions.perform(.addClassic))
        XCTAssertEqual(shownWith.count, 2)
        XCTAssertEqual(actions.router.path, [.bookshelf])
        XCTAssertTrue(actions.perform(.find))
        XCTAssertTrue(actions.perform(.back))
        XCTAssertEqual(shownWith.count, 4, "Find and Back too")

        XCTAssertTrue(actions.perform(.voiceAndSpeed))
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(shownWith.count, 4, "Voice & Speed… away from the reader is the Settings window")
        XCTAssertTrue(actions.perform(.forward15))
        XCTAssertEqual(shownWith.count, 4, "a skip plays on wherever the window is")
        for command: MacCommand in [.playPause, .back15, .forward15, .faster, .slower, .sleepTimer, .undoJump] {
            XCTAssertFalse(actions.needsMainWindow(command), "\(command)")
        }
    }

    /// Playback ▸ Sleep Timer: picking the checked duration again re-arms it
    /// from the top, as the player bar's chip does (a checked Toggle's
    /// click sets false).
    func testPickingTheArmedSleepItemAgainReArmsIt() {
        var picked: [SleepTimer.Option] = []
        let armed = AloudCommands.sleepToggle(.minutes(30), selection: .minutes(30)) { picked.append($0) }
        XCTAssertTrue(armed.wrappedValue, "the armed one is checked")
        armed.wrappedValue = false
        XCTAssertEqual(picked, [.minutes(30)], "re-picked, so re-armed")

        let other = AloudCommands.sleepToggle(.minutes(15), selection: .minutes(30)) { picked.append($0) }
        XCTAssertFalse(other.wrappedValue)
        other.wrappedValue = true
        XCTAssertEqual(picked, [.minutes(30), .minutes(15)])
    }

    /// Classics' Find on macOS 14 focuses the toolbar's search field
    /// through the window: a search item's own field, or one inside an
    /// item's view; none in a toolbar without one.
    func testTheToolbarSearchFieldIsFound() {
        let plain = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("plain"))
        let search = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
        XCTAssertTrue(MacToolbarSearch.field(in: [plain, search]) === search.searchField)

        let hosted = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("hosted"))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let field = NSSearchField(frame: container.bounds)
        container.addSubview(field)
        hosted.view = container
        XCTAssertTrue(MacToolbarSearch.field(in: [plain, hosted]) === field)

        XCTAssertNil(MacToolbarSearch.field(in: [plain]))
        XCTAssertFalse(MacToolbarSearch.focus(in: nil))
    }

    // MARK: - Helpers

    private func makeActions(sentences: Int = 12) -> (PlaybackTestRig, MacCommandActions) {
        let rig = PlaybackTestRig(sentences: sentences)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-commands-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore(indexURL: folder.appendingPathComponent("library.json"),
                                  notifications: NotificationCenter())
        var actions = MacCommandActions(playback: rig.controller, router: LibraryRouter(), store: store,
                                        sleepTimer: SleepTimer(defaults: rig.defaults),
                                        continuePlayback: ContinuePlayback(), ui: MacUIState())
        actions.announce = { _ in }
        return (rig, actions)
    }
}
