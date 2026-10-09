import AppKit
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
        XCTAssertEqual(ReaderTextSize.stepped(from: 2, bigger: true), 3)
        XCTAssertEqual(ReaderTextSize.stepped(from: 2, bigger: false), 1)
        XCTAssertNil(ReaderTextSize.stepped(from: 0, bigger: false))
        XCTAssertNil(ReaderTextSize.stepped(from: ReaderTextSize.steps.count - 1, bigger: true))
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

    /// After a playback error, a skip leaves the status paused while the
    /// chapter line still offers "tap to try again". The menu's Play/Pause
    /// turned back to Play beside it; it keeps Try Again, as the bar's
    /// circle does, until the stop clears (H050).
    func testAPlaybackErrorKeepsTryAgainAfterASkip() async {
        let (rig, actions) = makeActions(sentences: 40, failing: { _ in true })
        rig.loadDefault()
        rig.controller.play()
        let errored = await rig.waitUntil(5) { rig.controller.status == .error }
        XCTAssertTrue(errored)
        XCTAssertEqual(actions.title(for: .playPause), MacMenuCopy.tryAgain)

        XCTAssertTrue(actions.perform(.forward15))
        XCTAssertEqual(rig.controller.status, .paused, "the skip leaves the status paused")
        XCTAssertEqual(rig.controller.stopReason(for: rig.document.id), .playbackError, "the error stop stays")
        XCTAssertEqual(actions.title(for: .playPause), MacMenuCopy.tryAgain)
    }

    func testNothingToPlayDisablesTheTransport() {
        let (_, actions) = makeActions()
        for command: MacCommand in [.playPause, .back15, .forward15, .previousChapter, .nextChapter, .sleepTimer] {
            XCTAssertFalse(actions.isEnabled(command), "\(command)")
            XCTAssertFalse(actions.perform(command), "\(command) does nothing, silently")
        }
    }

    /// R1-42: Forward 15 is enabled only where a skip would move, so the
    /// Playback menu, the Dock menu and → agree with the bar's dimmed
    /// glyph on the last sentence; Back 15 stays, and Forward comes back
    /// once there is somewhere to go.
    func testForward15IsDisabledWhereItCannotMove() {
        let (rig, actions) = makeActions(sentences: 12)
        rig.loadDefault(at: 10)
        XCTAssertTrue(actions.isEnabled(.forward15), "one sentence left to reach")

        rig.controller.seek(to: 11, andPlay: false)
        XCTAssertFalse(rig.controller.canSkipForward)
        XCTAssertFalse(actions.isEnabled(.forward15), "the last sentence: nowhere to go")
        XCTAssertFalse(MacCommandState(actions: actions).snapshot.isEnabled(.forward15), "the menu item greys out")
        XCTAssertFalse(actions.perform(.forward15), "→ is swallowed")
        XCTAssertEqual(rig.controller.currentSentence, 11)
        XCTAssertTrue(actions.isEnabled(.back15), "Back 15 stays")

        XCTAssertTrue(actions.perform(.back15))
        XCTAssertLessThan(rig.controller.currentSentence, 11)
        XCTAssertTrue(actions.isEnabled(.forward15), "and Forward 15 comes back")
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

    /// L014: Edit's Rename Book… and Mark as Finished, like Delete Book…,
    /// act on the focused card's book and are off without one, so a
    /// keyboard user reaches all three without the context menu. Under
    /// Rename or the Delete confirmation, none asks for a second alert.
    func testEditsBookItemsActOnTheFocusedCard() {
        let (_, base) = makeActions()
        let bookItems: [MacCommand] = [.renameBook, .markFinished, .markUnfinished, .deleteBook]
        for command in bookItems {
            XCTAssertFalse(base.isEnabled(command), "\(command) with no focused card")
            XCTAssertFalse(base.perform(command), "\(command) with no focused card")
            XCTAssertEqual(command.menu, .edit, "\(command) sits beside Delete Book…")
            XCTAssertTrue(command.actsOnFocusedBook, "\(command)")
        }
        XCTAssertNil(MacCommand.renameBook.shortcut)
        XCTAssertNil(MacCommand.markFinished.shortcut)
        XCTAssertNil(MacCommand.markUnfinished.shortcut)
        XCTAssertEqual(MacCommand.renameBook.title, MacMenuCopy.renameBook)
        XCTAssertEqual(MacCommand.markFinished.title, MacMenuCopy.markFinished)
        XCTAssertEqual(DocumentAction.markFinished.menuTitle, MacMenuCopy.markFinished, "the context menu's wording")
        // R2-06: a Finished book's card and Edit menu say the reverse.
        XCTAssertEqual(MacCommand.markUnfinished.title, MacMenuCopy.markUnfinished)
        XCTAssertEqual(DocumentAction.markUnfinished.menuTitle, MacMenuCopy.markUnfinished, "the context menu's wording")

        var actions = base
        var performed: [String] = []
        actions.renameBook = { performed.append("rename") }
        actions.markFinished = { performed.append("finish") }
        actions.markUnfinished = { performed.append("unfinish") }
        actions.deleteBook = { performed.append("delete") }
        for command in bookItems {
            XCTAssertTrue(actions.isEnabled(command), "\(command)")
            XCTAssertTrue(actions.perform(command), "\(command)")
        }
        XCTAssertEqual(performed, ["rename", "finish", "unfinish", "delete"])

        let router = actions.router
        for alert: LibraryRouter.RootPresentation in [.rename, .deleteConfirmation, .deleteFailed] {
            router.rootPresentation = alert
            for command in bookItems {
                XCTAssertFalse(actions.perform(command), "\(command) under \(alert)")
            }
            XCTAssertEqual(router.rootPresentation, alert, "the alert stays up")
            router.dismissRootPresentation(alert)
        }
        XCTAssertEqual(performed.count, 3, "nothing ran under an alert")
    }

    /// Under Rename or the Delete confirmation, ⌘O would swap the alert for
    /// the open panel and SwiftUI would close it without its Save, losing
    /// the typed title (H025). The commands that act in the main window
    /// wait for the alert; playback's don't.
    func testMainWindowCommandsWaitForARootAlert() {
        let (rig, base) = makeActions()
        rig.loadDefault()
        var actions = base
        var deletes = 0
        actions.deleteBook = { deletes += 1 }
        let router = actions.router
        for alert: LibraryRouter.RootPresentation in [.rename, .deleteConfirmation, .deleteFailed] {
            router.rootPresentation = alert
            for command: MacCommand in [.addFromFiles, .addClassic, .find, .toggleContents, .back, .deleteBook] {
                XCTAssertFalse(actions.isEnabled(command), "\(command) under \(alert)")
                XCTAssertFalse(actions.perform(command), "\(command) under \(alert)")
            }
            XCTAssertEqual(router.rootPresentation, alert, "the alert stays up")
            XCTAssertEqual(router.path, [], "nothing pushed under it")
            XCTAssertTrue(actions.isEnabled(.forward15), "playback plays on")
            router.dismissRootPresentation(alert)
        }
        XCTAssertEqual(deletes, 0)
        XCTAssertTrue(actions.isEnabled(.addFromFiles))
        XCTAssertTrue(actions.isEnabled(.deleteBook))
        router.rootPresentation = .filePicker
        XCTAssertTrue(actions.isEnabled(.addClassic), "the open panel is no alert")
    }

    /// ⌘← restarts the first chapter once 3 s of its opening sentence has
    /// played (R14). No published change marks that moment, so the menus
    /// refresh for it: Previous Chapter comes on while that sentence still
    /// plays (J034). Before, it stayed grey until the next sentence.
    func testPreviousChapterComesOnThreeSecondsIntoTheFirstChapter() async throws {
        let (rig, actions) = makeActions(sentences: 8, clipDuration: 6)
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for id in 0..<8 {
            let chapter = id / 4
            sentences.append(Sentence(id: id, text: id % 4 == 0 ? "Chapter \(chapter + 1)." : "Line \(id) reads on.",
                                      para: id, page: chapter + 1))
            paragraphs.append(Paragraph(id: id, sentenceIDs: id..<(id + 1), page: chapter + 1))
        }
        let content = DocContent(title: "Restart", pageCount: 2, sentences: sentences, paragraphs: paragraphs,
                                 contentHash: "mac-chapter-restart")
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: content.contentHash, sentences: 8),
                            content: content)
        let state = MacCommandState(actions: actions)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(rig.controller.currentSentence, 0)
        XCTAssertFalse(state.snapshot.isEnabled(.previousChapter), "nothing before chapter 1, under 3 s in")

        for _ in 0..<60 where !state.snapshot.isEnabled(.previousChapter) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(rig.controller.currentSentence, 0, "still the opening sentence")
        XCTAssertGreaterThan(rig.controller.currentSentenceElapsed, PlaybackController.restartThreshold)
        XCTAssertTrue(state.snapshot.isEnabled(.previousChapter), "past 3 s, ⌘← restarts the chapter")
        rig.controller.pause()
    }

    /// ⌘W closes a window that can close, a popover's included, and never
    /// asks an alert, a sheet or a window behind a modal panel: there
    /// performClose finds no close button and plays the alert sound (J031).
    /// Nothing here is shown: performClose is never called.
    func testCloseWindowClosesOnlyAWindowThatCloses() {
        let frame = NSRect(x: 0, y: 0, width: 40, height: 30)
        let main = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let buttonless = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = SheetWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let popover = SelfClosingWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: true)
        for window in [main, buttonless, sheet, popover] { window.isReleasedWhenClosed = false }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.layout()

        XCTAssertTrue(MacCommandActions.windowToClose(key: main, modal: nil) === main)
        XCTAssertTrue(MacCommandActions.windowToClose(key: popover, modal: nil) === popover,
                      "a popover's window closes itself")
        XCTAssertNil(MacCommandActions.windowToClose(key: nil, modal: nil), "no window, nothing")
        XCTAssertNil(MacCommandActions.windowToClose(key: alert.window, modal: nil), "an alert's panel")
        XCTAssertNil(MacCommandActions.windowToClose(key: buttonless, modal: nil), "no close button")
        XCTAssertNil(MacCommandActions.windowToClose(key: sheet, modal: nil), "a sheet")
        XCTAssertNil(MacCommandActions.windowToClose(key: main, modal: buttonless), "behind a modal panel")
    }

    /// File ▸ Close is off with no window ⌘W could close: the main window
    /// closed or minimized while a book plays, Aloud still in front. It was
    /// always on, and then did nothing (K027). Nothing here is shown.
    func testCloseIsOffWithNoWindowToClose() {
        let frame = NSRect(x: 0, y: 0, width: 40, height: 30)
        let main = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let buttonless = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        for window in [main, buttonless] { window.isReleasedWhenClosed = false }
        let (rig, base) = makeActions()
        rig.loadDefault()
        var actions = base

        actions.windows = { (nil, nil) }
        XCTAssertFalse(actions.isEnabled(.closeWindow), "no key window, nothing to close")
        XCTAssertFalse(actions.perform(.closeWindow))
        XCTAssertFalse(MacCommandState(actions: actions).snapshot.isEnabled(.closeWindow), "the menu item greys out")
        XCTAssertTrue(actions.isEnabled(.forward15), "playback's commands play on")
        actions.windows = { (buttonless, nil) }
        XCTAssertFalse(actions.isEnabled(.closeWindow), "no close button")
        actions.windows = { (main, buttonless) }
        XCTAssertFalse(actions.isEnabled(.closeWindow), "behind a modal panel")

        actions.windows = { (main, nil) }
        XCTAssertTrue(actions.isEnabled(.closeWindow))
        XCTAssertTrue(MacCommandState(actions: actions).snapshot.isEnabled(.closeWindow))
    }

    /// The menu snapshot follows an alert opening and closing.
    func testTheMenuSnapshotFollowsARootAlert() async throws {
        let (_, actions) = makeActions()
        let state = MacCommandState(actions: actions)
        XCTAssertTrue(state.snapshot.isEnabled(.addFromFiles))
        actions.router.rootPresentation = .rename
        for _ in 0..<100 where state.snapshot.isEnabled(.addFromFiles) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.snapshot.isEnabled(.addFromFiles), "Add from Files… greys out under Rename")
        actions.router.dismissRootPresentation(.rename)
        for _ in 0..<100 where !state.snapshot.isEnabled(.addFromFiles) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(state.snapshot.isEnabled(.addFromFiles))
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

    /// A window AppKit shows as a sheet.
    private final class SheetWindow: NSWindow {
        override var isSheet: Bool { true }
    }

    /// A window that closes itself, as a popover's does.
    private final class SelfClosingWindow: NSWindow {
        override func performClose(_ sender: Any?) { close() }
    }

    private func makeActions(sentences: Int = 12, clipDuration: TimeInterval = 0.25,
                             failing: (@Sendable (String) -> Bool)? = nil) -> (PlaybackTestRig, MacCommandActions) {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration, failing: failing)
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
