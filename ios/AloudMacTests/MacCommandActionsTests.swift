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

    /// No Contents panel yet (phase 1): Find and ⌃⌘S are off in the reader,
    /// so neither is a live key with nothing to show, and the title stays
    /// Show Contents.
    func testReaderWithoutAPanelOffersNoContentsOrFind() {
        let (_, base) = makeActions()
        XCTAssertEqual(base.hasContentsPanel, MacReaderScreen.hasContentsPanel,
                       "the reader says when its panel exists")
        var actions = base
        actions.hasContentsPanel = false
        actions.router.path = [.reader(UUID())]
        XCTAssertFalse(actions.isEnabled(.toggleContents))
        XCTAssertFalse(actions.isEnabled(.find))
        XCTAssertFalse(actions.perform(.toggleContents))
        XCTAssertFalse(actions.ui.isContentsShown)
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.showContents)
    }

    func testFindInTheReaderOpensContentsSearch() {
        let (_, base) = makeActions()
        var actions = base
        actions.hasContentsPanel = true
        actions.router.path = [.reader(UUID())]
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.showContents)
        XCTAssertTrue(actions.perform(.find))
        XCTAssertTrue(actions.ui.isContentsShown)
        XCTAssertEqual(actions.ui.searchFocus, .contents)
        XCTAssertEqual(actions.title(for: .toggleContents), MacMenuCopy.hideContents)
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
