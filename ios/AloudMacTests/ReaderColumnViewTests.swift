import AppKit
import SwiftUI
import XCTest
@testable import Aloud

/// M14 and M15 on the Mac's book page (`ReaderColumnView`): TextKit 2 stays
/// on and the page is read-only with no find bar; the column keeps its 33 em
/// measure; moving the highlight never edits the text; a click on a
/// sentence plays from it, and a click on a coasting page only stops it; a
/// drag selects and copies without moving the playhead; the right-click menu
/// is Play from Here, Copy and Look Up; no key selector reaches the end of
/// the responder chain (the alert sound); a user scroll stops following
/// until Follow the voice; and Reduce Motion never glides.
///
/// Each page lives in an offscreen window that is never ordered in, so
/// nothing shows. The one controller is the muted rig, autoplay suppressed.
@MainActor
final class ReaderColumnViewTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var rig: PlaybackTestRig?

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        // A click started the muted rig: leave no chain running into the
        // next test.
        rig?.controller.pause(rampsOut: false)
        rig = nil
        super.tearDown()
    }

    // MARK: - TextKit 2, read-only (M14)

    /// The page never leaves TextKit 2, whatever it does: building, moving
    /// the highlight and the underline, a click, the right-click menu, the
    /// scroll keys, the colophon and a new text size. AppKit posts the switch
    /// notification if anything asks this view for the TextKit 1 layout
    /// object, and its `textLayoutManager` is nil from then on.
    func testTextKit2StaysOnAndThePageIsReadOnly() throws {
        let page = try makePage(sentences: 120, active: 3)
        let textView = page.textView
        XCTAssertNotNil(textView.textLayoutManager, "TextKit 2 after setup")
        let switches = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextView.didSwitchToNSLayoutManagerNotification, object: textView, queue: nil) { _ in
                switches.count += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        page.update(activeSentence: 4, activeWord: 1)
        page.update(activeSentence: 30)
        let clicked = try page.singleLineSentence(near: 6)
        let point = try page.point(inSentence: clicked)
        textView.onClickLanded?()
        textView.onClickEnded?(point, 1, false)
        let rightClick = try page.rightClick(at: point)
        _ = textView.menu(for: rightClick)
        textView.doCommand(by: #selector(NSResponder.scrollPageDown(_:)))
        page.update(activeSentence: 31, colophon: ReaderColophon(title: "Column", author: nil, words: 900, rate: 1))
        page.update(activeSentence: 31, fontSize: 23)

        XCTAssertEqual(switches.count, 0, "nothing asked for TextKit 1")
        XCTAssertNotNil(textView.textLayoutManager, "TextKit 2 after use")
        XCTAssertNotNil(textView.textContentStorage)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.usesFindBar, "⌘F is Contents search, never the find bar")
        XCTAssertFalse(textView.isIncrementalSearchingEnabled)
        XCTAssertFalse(textView.isFieldEditor)
        XCTAssertFalse(textView.usesFontPanel)
        XCTAssertFalse(textView.usesRuler)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.allowsUndo)
        XCTAssertFalse(textView.drawsBackground, "the paper behind it is the theme's")
    }

    /// At 1000 × 760 the column measures at most 33 em at every size step,
    /// inside the 32 pt gutters, and the live text container takes that
    /// measure, centered, at each one (an odd leftover never puts it a
    /// point past the measure).
    func testTheColumnIsAtMost33EmAtEverySize() throws {
        for step in ReaderTextSize.steps.indices {
            let size = ReaderTextSize.points(forStep: step)
            let column = ReaderColumnMetrics.columnWidth(forWidth: 1000, fontSize: size)
            XCTAssertLessThanOrEqual(column, 33 * size, "step \(step)")
            XCTAssertLessThanOrEqual(column, 1000 - 2 * Theme.Space.xxl, "step \(step)")
            XCTAssertGreaterThanOrEqual(ReaderColumnMetrics.sideInset(forWidth: 1000, fontSize: size),
                                        Theme.Space.xxl, "step \(step)")
        }
        XCTAssertEqual(ReaderColumnMetrics.columnWidth(forWidth: 1000, fontSize: 19), 627, "33 em at 19 pt")
        XCTAssertEqual(ReaderColumnMetrics.columnWidth(forWidth: 500, fontSize: 19), 460, "20 pt gutters below 600")

        let page = try makePage(sentences: 12, active: 0, size: NSSize(width: 1000, height: 760))
        let textView = page.textView
        for step in ReaderTextSize.steps.indices {
            let size = ReaderTextSize.points(forStep: step)
            page.update(activeSentence: 0, fontSize: size)
            // As a tile does once a scroller settles: a legacy scroller
            // showing up narrows the clip view.
            page.coordinator.updateGeometry()
            let visible = page.scrollView.contentView.bounds.width
            let container = try XCTUnwrap(textView.textContainer)
            XCTAssertLessThanOrEqual(container.size.width, 33 * size, "step \(step): at most 33 em")
            XCTAssertEqual(container.size.width, ReaderColumnMetrics.columnWidth(forWidth: visible, fontSize: size),
                           accuracy: 1, "step \(step): the measure")
            XCTAssertEqual(textView.textContainerInset.width * 2 + container.size.width, visible, accuracy: 0.5,
                           "step \(step): the column is centered")
        }
        XCTAssertEqual(textView.textContainerInset.height, ReaderColumnMetrics.topInset)
    }

    // MARK: - The highlight (M14)

    /// Moving the sentence highlight and the word underline draws in the
    /// layer beneath the text: 0 text-storage edits.
    func testAHighlightMoveEditsTheTextStorageZeroTimes() throws {
        let page = try makePage(sentences: 120, active: 0)
        let storage = try XCTUnwrap(page.textView.textStorage)
        let edits = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
                edits.count += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        for id in [1, 2, 3, 9, 40, 41] {
            page.update(activeSentence: id)
        }
        for token in [0, 2, 4, 6] {
            page.update(activeSentence: 41, activeWord: token)
        }
        page.update(activeSentence: 42, activeWord: -1)

        XCTAssertEqual(edits.count, 0, "the highlight never touches textStorage")
        XCTAssertEqual(page.coordinator.activeSentence, 42)
        XCTAssertEqual(page.coordinator.activeWordToken, -1)
    }

    // MARK: - Click to play (R15)

    /// A click inside sentence N maps to N through the shared layout and
    /// plays from it; a double-click and a drag (each leaves a selection)
    /// play nothing more.
    func testAClickInASentencePlaysFromIt() throws {
        let page = try makePage(sentences: 60, active: 0)
        let id = try page.singleLineSentence(near: 9)
        let point = try page.point(inSentence: id)
        XCTAssertEqual(page.coordinator.sentence(at: point), id)

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertEqual(page.played.ids, [id])

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 2, true)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, true)
        XCTAssertEqual(page.played.ids, [id], "a selection is not a click to play")
    }

    /// The play-from path itself: a click while paused starts the book at
    /// the clicked sentence (`.buffering` or `.playing` at that id).
    func testAClickWhilePausedPlaysFromThatSentence() throws {
        let rig = makeRig(sentences: 30)
        let page = try makePage(content: rig.content, active: 0) { id in
            ReaderColumnView.playFromSentence(id, on: rig.controller)
        }
        let id = try page.singleLineSentence(near: 12)
        XCTAssertNotEqual(rig.controller.currentSentence, id)

        let point = try page.point(inSentence: id)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertEqual(rig.controller.currentSentence, id)
        XCTAssertTrue([.buffering, .playing].contains(rig.controller.status), "\(rig.controller.status)")
    }

    /// A click on a page still coasting from momentum only stops it: the
    /// playhead stays where it was. The next still click plays.
    func testAClickWhileCoastingOnlyStopsTheScroll() throws {
        let rig = makeRig(sentences: 30)
        let page = try makePage(content: rig.content, active: 0) { id in
            ReaderColumnView.playFromSentence(id, on: rig.controller)
        }
        let before = rig.controller.currentSentence
        let id = try page.singleLineSentence(near: 12)
        let point = try page.point(inSentence: id)

        page.coordinator.isCoasting = { _ in true }
        page.textView.onClickLanded?()
        page.coordinator.isCoasting = { _ in false }
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertEqual(rig.controller.currentSentence, before, "a click on moving text only stops it")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertEqual(rig.controller.currentSentence, id)
    }

    /// The scroll view's own account of a coast: momentum moving the page,
    /// and for a moment after it stops (the touch of the click that stops
    /// it can end the momentum before the mouse-down arrives). A wheel
    /// with no phases is no coast.
    func testACoastCountsUntilAMomentAfterItStops() throws {
        let scrollView = ReaderScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var clock: TimeInterval = 1_000
        scrollView.now = { clock }
        XCTAssertFalse(scrollView.isCoastingOrJustStopped)

        scrollView.scrollWheel(with: try Self.wheel(lines: -1))
        XCTAssertFalse(scrollView.isCoastingOrJustStopped, "a mouse's wheel never coasts")

        scrollView.scrollWheel(with: try Self.wheel(lines: -1, momentum: .begin))
        scrollView.scrollWheel(with: try Self.wheel(lines: -1, momentum: .continuous))
        XCTAssertTrue(scrollView.isCoasting)
        scrollView.scrollWheel(with: try Self.wheel(lines: 0, momentum: .end))
        XCTAssertFalse(scrollView.isCoasting)
        XCTAssertTrue(scrollView.isCoastingOrJustStopped, "a click this soon only stops the page")

        clock += ReaderScrollView.coastGrace + 0.01
        XCTAssertFalse(scrollView.isCoastingOrJustStopped, "a still page plays the next click")

        // A click stops the next coast: the momentum still arriving is
        // dropped, so the page stays still and a click on it plays.
        scrollView.scrollWheel(with: try Self.wheel(lines: -1, momentum: .begin))
        XCTAssertTrue(scrollView.isCoasting)
        scrollView.stopCoasting()
        scrollView.scrollWheel(with: try Self.wheel(lines: -3, momentum: .continuous))
        XCTAssertFalse(scrollView.isCoastingOrJustStopped, "dropped momentum moves nothing")
        XCTAssertTrue(scrollView.inMomentum, "the fingers are still off the trackpad")
        scrollView.scrollWheel(with: try Self.wheel(lines: 0, momentum: .end))
        XCTAssertFalse(scrollView.inMomentum)
    }

    /// A drag selects (no play), and ⌘C's pasteboard write is the plain text
    /// of the selection; the playhead never moves. A private pasteboard, so
    /// the test leaves the clipboard alone.
    func testADragSelectsAndCopiesWithoutMovingThePlayhead() throws {
        let page = try makePage(sentences: 40, active: 0)
        let id = try page.singleLineSentence(near: 7)
        let point = try page.point(inSentence: id)
        page.textView.setSelectedRange(page.coordinator.sentenceRanges[id])
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, page.textView.hasSelection)
        XCTAssertTrue(page.textView.hasSelection)
        XCTAssertEqual(page.played.ids, [])

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.davidxie.AloudMacTests.column.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let types = page.textView.writablePasteboardTypes
        XCTAssertFalse(types.isEmpty, "a selection copies")
        XCTAssertEqual(types.filter { $0.rawValue.contains("Rich Text") || $0.rawValue.contains("RTF") }, [],
                       "plain text, never the page's colors")
        XCTAssertTrue(page.textView.writeSelection(to: pasteboard, types: types))
        XCTAssertEqual(pasteboard.types?.filter { $0.rawValue.contains("rtf") || $0.rawValue.contains("RTF") }, [],
                       "nothing rich on the pasteboard")
        XCTAssertEqual(pasteboard.string(forType: .string), ReaderTypography.typeset(page.content.sentences[id].text))
        XCTAssertEqual(page.coordinator.activeSentence, 0)
        XCTAssertEqual(page.played.ids, [])
    }

    /// Lets one turn of the main queue run: a follow glide sets off one turn
    /// after the update that asks for it (`startGlide`), outside SwiftUI's
    /// pass, and a new page's opening placement runs on a task. Queued
    /// behind them, so they have run by then.
    func nextMainTurn() {
        let turn = expectation(description: "a turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
    }

    // MARK: - The right-click menu (M14)

    /// Exactly Play from Here, Copy and Look Up: no Speech, no submenus.
    /// Play from Here plays the sentence under the pointer; Copy waits for a
    /// selection.
    func testTheContextMenuIsPlayFromHereCopyAndLookUp() throws {
        let page = try makePage(sentences: 40, active: 0)
        let id = try page.singleLineSentence(near: 5)
        // On the sentence's first word ("Sentence"), so Look Up has a word.
        let point = try page.point(inFirstWordOf: id)
        let rightClick = try page.rightClick(at: point)
        let menu = try XCTUnwrap(page.textView.menu(for: rightClick))

        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.action), [#selector(ReaderNSTextView.playFromHereFromMenu(_:)),
                                             #selector(NSText.copy(_:)),
                                             #selector(ReaderNSTextView.lookUpFromMenu(_:))])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "Play from Here")
        XCTAssertEqual(items[1].title, "Copy")
        XCTAssertEqual(items[2].title, "Look Up \u{201C}Sentence\u{201D}", "the word under the pointer")
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil }, "no Speech ▸ or any other submenu")
        let actions = menu.items.compactMap { $0.action.map(NSStringFromSelector) }
        XCTAssertFalse(actions.contains { $0.contains("Speaking") }, "no Start Speaking")
        XCTAssertFalse(menu.items.contains { $0.title.contains("Speech") })

        XCTAssertTrue(items[0].isEnabled)
        XCTAssertEqual(items[0].tag, id, "the sentence under the pointer")
        XCTAssertFalse(items[1].isEnabled, "Copy waits for a selection")
        XCTAssertTrue(items[2].isEnabled, "a word to look up")

        page.textView.playFromHereFromMenu(items[0])
        XCTAssertEqual(page.played.ids, [id])

        page.textView.setSelectedRange(page.coordinator.sentenceRanges[id])
        let selected = page.textView.contextMenu(at: point).items.filter { !$0.isSeparatorItem }
        XCTAssertTrue(selected[1].isEnabled, "Copy with a selection")

        // Should a Speech item reach any menu, the page refuses it (never
        // called here: unfenced, it would speak).
        let speak = NSMenuItem(title: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)),
                               keyEquivalent: "")
        XCTAssertFalse(page.textView.validateUserInterfaceItem(speak), "the page never speaks")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        XCTAssertTrue(page.textView.validateUserInterfaceItem(copy), "the rest validates as AppKit's")
    }

    // MARK: - Keys and silence (M11, testing §1.2(e))

    /// Every selector a key reads as stops at the page: none goes on up the
    /// chain, so none reaches `noResponder(for:)` and the alert sound, and
    /// nothing is typed, deleted or moved.
    func testUnhandledSelectorsNeverReachTheChain() throws {
        let page = try makePage(sentences: 20, active: 0)
        let textView = page.textView
        let spy = ResponderSpy()
        textView.nextResponder = spy
        let text = textView.string
        let selection = textView.selectedRange()
        #if DEBUG
        let beeps = MacTestSilence.beepAttempts
        #endif

        let selectors = ["insertNewline:", "insertLineBreak:", "deleteBackward:", "deleteForward:", "deleteWordBackward:",
                         "moveLeft:", "moveRight:", "moveWordLeft:", "moveWordRight:", "moveToBeginningOfLine:",
                         "moveToEndOfLine:", "moveToLeftEndOfLine:", "moveToRightEndOfLine:", "transpose:",
                         "complete:", "capitalizeWord:", "uppercaseWord:", "yank:", "insertTabIgnoringFieldEditor:",
                         "centerSelectionInVisibleArea:", "noop:", "aloudSelectorNoOneHas:"]
        for name in selectors {
            textView.doCommand(by: NSSelectorFromString(name))
        }
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Space with no router tail to take it: swallowed, never typed.
        textView.keyDown(with: MacShortcutsTests.key(" ", code: 49, window: page.window))

        XCTAssertEqual(spy.calls, [], "no selector went on up the chain")
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.selectedRange(), selection)
        #if DEBUG
        XCTAssertEqual(MacTestSilence.beepAttempts, beeps)
        #endif

        // Esc goes to whoever takes it, through tryToPerform, which ends at
        // the chain's end without a sound.
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(spy.calls, ["try:cancelOperation:"])
    }

    /// Space, ← and → are the app's: `MacKeyRouter` runs them at once while
    /// the read-only page has focus, and the page never sees them. ⌘← and
    /// ⌘→ go on to the menus. One that reaches the page anyway goes to the
    /// router's tail, which runs its command.
    func testThePlainKeysReachTheAppsCommands() throws {
        let page = try makePage(sentences: 20, active: 0)
        let textView = page.textView
        XCTAssertTrue(page.window.makeFirstResponder(textView))
        var performed: [MacCommand] = []
        let router = MacKeyRouter { command in
            performed.append(command)
            return true
        }
        let text = textView.string

        XCTAssertNil(router.handle(MacShortcutsTests.key(" ", code: 49, window: page.window), in: page.window))
        XCTAssertNil(router.handle(MacShortcutsTests.arrow(left: true, window: page.window), in: page.window))
        XCTAssertNil(router.handle(MacShortcutsTests.arrow(left: false, window: page.window), in: page.window))
        XCTAssertEqual(performed, [.playPause, .back15, .forward15])
        let chapter = MacShortcutsTests.arrow(left: true, flags: .command, window: page.window)
        XCTAssertTrue(router.handle(chapter, in: page.window) === chapter, "⌘← is the menu's")

        textView.nextResponder = router.tail
        textView.keyDown(with: MacShortcutsTests.key(" ", code: 49, window: page.window))
        XCTAssertEqual(performed, [.playPause, .back15, .forward15, .playPause])
        XCTAssertEqual(textView.string, text, "nothing typed")
    }

    // MARK: - Calm follow (M15, R16)

    /// A gesture stops following, and nothing brings it back while the
    /// voice is out of view: a new sentence doesn't scroll. Follow the voice
    /// (a new follow request, as Play, a jump and the chip make) re-engages
    /// and brings the sentence into the band.
    func testAUserScrollDetachesFollowingUntilFollowTheVoice() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(page.activeSentenceIsInTheBand(), "a fresh column starts on the voice")

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scrollView)
        XCTAssertFalse(coordinator.isFollowing, "a gesture takes the scroll")
        page.scrollView.contentView.setBoundsOrigin(.zero)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: page.scrollView)
        XCTAssertFalse(coordinator.isFollowing, "the voice is out of view")
        XCTAssertEqual(coordinator.voiceOffscreen, .down, "the chip points down to the voice")

        let scrolls = coordinator.programmaticScrollCount
        page.update(activeSentence: 151)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "detached: a new sentence never scrolls")
        XCTAssertEqual(page.offset, 0)

        page.update(activeSentence: 151, followRequest: 1)
        XCTAssertTrue(coordinator.isFollowing, "Follow the voice re-engages")
        XCTAssertNil(coordinator.voiceOffscreen)
        XCTAssertTrue(page.activeSentenceIsInTheBand())
    }

    /// A scroll no gesture announced (a wheel without phases, VoiceOver) and
    /// the scroll keys detach following too; neither counts as a follow
    /// scroll.
    func testAScrollWithoutAGestureAndTheScrollKeysDetachFollowing() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)
        let scrolls = coordinator.programmaticScrollCount

        page.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: page.offset + 400))
        XCTAssertFalse(coordinator.isFollowing, "the clip view moved under no scroll of ours")

        page.update(activeSentence: 150, followRequest: 1)
        XCTAssertTrue(coordinator.isFollowing)
        let before = page.offset
        page.textView.doCommand(by: #selector(NSResponder.scrollPageDown(_:)))
        XCTAssertFalse(coordinator.isFollowing, "Page Down is the reader scrolling")
        XCTAssertGreaterThan(page.offset, before)

        page.update(activeSentence: 150, followRequest: 2)
        XCTAssertTrue(coordinator.isFollowing)
        page.textView.doCommand(by: #selector(NSResponder.scrollToBeginningOfDocument(_:)))
        XCTAssertFalse(coordinator.isFollowing, "Home is the reader scrolling")
        XCTAssertEqual(page.offset, 0)
        XCTAssertGreaterThan(coordinator.programmaticScrollCount, scrolls, "the two re-engages placed the voice")
    }

    /// The next sentence leaves the band within one viewport: under Reduce
    /// Motion the page moves there at once, with no glide; otherwise it
    /// glides. Either way, one follow scroll.
    func testReduceMotionProducesNoGlide() throws {
        for reduceMotion in [true, false] {
            let page = try makePage(sentences: 300, active: 100, size: NSSize(width: 800, height: 500),
                                    reduceMotion: reduceMotion)
            let coordinator = page.coordinator
            nextMainTurn()   // the opening placement runs first, as when a book opens
            XCTAssertTrue(page.activeSentenceIsInTheBand())
            let next = try page.firstSentenceBelowTheBand(after: 100)
            let scrolls = coordinator.programmaticScrollCount
            let glides = coordinator.glideCount

            page.update(activeSentence: next)
            XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "one follow scroll")
            nextMainTurn()   // a glide sets off one turn after the update asking for it
            if reduceMotion {
                XCTAssertEqual(coordinator.glideCount, glides, "Reduce Motion never glides")
                XCTAssertFalse(coordinator.isGliding)
                XCTAssertTrue(page.activeSentenceIsInTheBand(), "placed at once")
            } else {
                XCTAssertEqual(coordinator.glideCount, glides + 1, "a move within one viewport glides")
            }
        }
    }

    /// Follow the voice (or Play) while a finger holds the page never
    /// fights it; once the fingers lift and only momentum moves the page,
    /// following takes the scroll back as on the iPhone: the coast stops,
    /// its remaining momentum is dropped, and the voice is in the band.
    func testFollowingTakesTheScrollBackFromMomentumButNeverFromAFinger() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scrollView)
        page.scrollView.contentView.setBoundsOrigin(.zero)
        XCTAssertFalse(coordinator.isFollowing)

        page.update(activeSentence: 150, followRequest: 1)
        XCTAssertEqual(page.offset, 0, "a finger on the trackpad keeps the page")

        page.scrollView.scrollWheel(with: try Self.wheel(lines: -1, momentum: .begin))
        XCTAssertTrue(page.scrollView.inMomentum, "the fingers lifted; momentum moves the page")
        page.update(activeSentence: 150, followRequest: 2)
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(page.activeSentenceIsInTheBand(), "following took the scroll back")
        XCTAssertFalse(page.scrollView.isCoasting, "the coast stopped")

        let placed = page.offset
        page.scrollView.scrollWheel(with: try Self.wheel(lines: -3, momentum: .continuous))
        XCTAssertEqual(page.offset, placed, "the rest of the momentum is dropped")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: page.scrollView)
        XCTAssertTrue(coordinator.isFollowing, "the voice is in view as the scroll ends")
    }

    /// A mouse's wheel (no phases, so no live scroll announces it) during
    /// a glide stops the glide and detaches following, like any user scroll.
    func testAWheelWithoutPhasesStopsAGlideAndDetachesFollowing() throws {
        let page = try makePage(sentences: 300, active: 100, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        nextMainTurn()   // the opening placement runs first
        let next = try page.firstSentenceBelowTheBand(after: 100)
        let glides = coordinator.glideCount
        page.update(activeSentence: next)
        nextMainTurn()
        XCTAssertEqual(coordinator.glideCount, glides + 1, "a follow glide set off")

        page.scrollView.scrollWheel(with: try Self.wheel(lines: -2))
        XCTAssertFalse(coordinator.isGliding, "the wheel stopped the glide")
        XCTAssertFalse(coordinator.isFollowing, "the wheel took the scroll")
    }

    /// A resize is never the reader scrolling: whatever AppKit does to keep
    /// the clip view on the page as the window grows or narrows, following
    /// holds. Here at the end of the book, where a taller window clamps
    /// the offset.
    func testAResizeNeverDetachesFollowing() throws {
        let page = try makePage(sentences: 300, active: 299, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)

        page.window.setContentSize(NSSize(width: 800, height: 760))
        XCTAssertTrue(coordinator.isFollowing, "taller")
        page.window.setContentSize(NSSize(width: 600, height: 760))
        XCTAssertTrue(coordinator.isFollowing, "narrower")
        page.window.setContentSize(NSSize(width: 1000, height: 500))
        XCTAssertTrue(coordinator.isFollowing, "wider and shorter")
        XCTAssertNil(coordinator.voiceOffscreen, "no Follow chip")
    }

    /// Text scrolled up under the toolbar is reported once, a turn later,
    /// for the screen's hairline.
    func testTextUnderTheToolbarIsReported() throws {
        let page = try makePage(sentences: 120, active: 0)
        let reported = expectation(description: "text under the toolbar")
        var values: [Bool] = []
        page.coordinator.parent.onTextUnderTopBar = { under in
            values.append(under)
            if under { reported.fulfill() }
        }
        page.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 200))
        page.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 260))
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(values, [true], "one report for the change")
    }

    // MARK: - The colophon (R24)

    /// At the end the "· · ·" mark becomes the colophon in one tail edit,
    /// fading in through a paper veil.
    func testTheColophonFadesInAtTheEnd() throws {
        let page = try makePage(sentences: 30, active: 29)
        let storage = try XCTUnwrap(page.textView.textStorage)
        let ranges = page.coordinator.sentenceRanges
        XCTAssertTrue(storage.string.hasSuffix("· · ·"))

        page.update(activeSentence: 29, colophon: ReaderColophon(title: "Column", author: "A. Writer",
                                                                 words: 900, rate: 1))
        XCTAssertNotNil(page.coordinator.shownColophon)
        XCTAssertTrue(storage.string.contains(ColophonCopy.theEnd))
        XCTAssertEqual(page.coordinator.sentenceRanges, ranges, "every sentence range holds")
        XCTAssertNotNil(page.coordinator.colophonVeil, "it fades in")
    }

    // MARK: - Helpers

    /// Counts notifications; AppKit posts them on the main thread.
    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    /// The sentences a page played, in order.
    private final class PlayLog {
        var ids: [Int] = []
    }

    /// Records whatever reaches the responder after the page.
    private final class ResponderSpy: NSResponder {
        var calls: [String] = []
        override func doCommand(by selector: Selector) { calls.append("doCommand:\(NSStringFromSelector(selector))") }
        override func noResponder(for eventSelector: Selector) {
            calls.append("noResponder:\(NSStringFromSelector(eventSelector))")
        }
        override func keyDown(with event: NSEvent) { calls.append("keyDown") }
        override func insertText(_ insertString: Any) { calls.append("insertText") }
        override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
            calls.append("try:\(NSStringFromSelector(action))")
            return false
        }
    }

    /// One page in its window, and the inputs it was last given.
    @MainActor
    private final class Page {
        let window: NSWindow
        let scrollView: ReaderScrollView
        let coordinator: ReaderColumnView.Coordinator
        let played: PlayLog
        private(set) var view: ReaderColumnView

        init(window: NSWindow, scrollView: ReaderScrollView, coordinator: ReaderColumnView.Coordinator,
             played: PlayLog, view: ReaderColumnView) {
            self.window = window
            self.scrollView = scrollView
            self.coordinator = coordinator
            self.played = played
            self.view = view
        }

        var textView: ReaderNSTextView { coordinator.textView! }
        var content: DocContent { view.content }
        var offset: CGFloat { scrollView.contentView.bounds.origin.y }

        /// The same page with new inputs, handed to the coordinator as
        /// SwiftUI's update would.
        func update(activeSentence: Int, activeWord: Int = -1, followRequest: Int? = nil,
                    fontSize: CGFloat? = nil, colophon: ReaderColophon? = nil) {
            view = ReaderColumnView(content: view.content, isChapterBook: view.isChapterBook,
                                    fontSize: fontSize ?? view.fontSize, activeSentence: activeSentence,
                                    activeWord: activeWord, followRequest: followRequest ?? view.followRequest,
                                    colophon: colophon ?? view.colophon, voiceOffscreen: .constant(nil),
                                    onPlaySentence: view.onPlaySentence)
            coordinator.update(to: view)
        }

        /// A sentence at or after `id` that sits on one line, so its rect's
        /// middle is its own text.
        func singleLineSentence(near id: Int) throws -> Int {
            let line = ReaderPageStyle(fontSize: view.fontSize).lineHeight
            for candidate in id..<content.sentences.count {
                if let rect = coordinator.rect(forSentence: candidate), rect.height <= line + 1 {
                    return candidate
                }
            }
            throw XCTSkip("no one-line sentence after \(id)")
        }

        func point(inSentence id: Int) throws -> CGPoint {
            let rect = try XCTUnwrap(coordinator.rect(forSentence: id))
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        /// The middle of sentence `id`'s first word ("Sentence", eight
        /// letters), measured through the shared layout.
        func point(inFirstWordOf id: Int) throws -> CGPoint {
            let manager = try XCTUnwrap(textView.textLayoutManager)
            let layout = ReaderColumnLayout(textLayoutManager: manager, origin: textView.textContainerOrigin)
            let word = NSRange(location: coordinator.sentenceRanges[id].location, length: 8)
            let rect = try XCTUnwrap(layout.boundingRect(for: word))
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        /// A right mouse-down at `point` (page coordinates), as AppKit asks
        /// for the menu.
        func rightClick(at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(point, to: nil),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func activeSentenceIsInTheBand() -> Bool {
            guard let rect = coordinator.measureActiveSentenceRect(), let viewport = coordinator.viewport() else {
                return false
            }
            return FollowBand.contains(rect, in: viewport)
        }

        /// The first sentence after `id` that has left the band but starts
        /// inside the viewport: a follow move of less than one viewport.
        func firstSentenceBelowTheBand(after id: Int) throws -> Int {
            let viewport = try XCTUnwrap(coordinator.viewport())
            for candidate in (id + 1)..<content.sentences.count {
                guard let rect = coordinator.rect(forSentence: candidate) else { continue }
                if rect.minY >= viewport.maxY { break }
                if !FollowBand.contains(rect, in: viewport) { return candidate }
            }
            throw XCTSkip("no sentence leaves the band within the viewport after \(id)")
        }
    }

    /// A scroll-wheel event of `lines`, with no gesture phase; with a
    /// momentum phase it is a coast's.
    private static func wheel(lines: Int32, momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: lines, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// The muted rig with `sentences` loaded, paused at 0; autoplay
    /// suppressed.
    private func makeRig(sentences: Int) -> (controller: PlaybackController, content: DocContent) {
        let rig = PlaybackTestRig(sentences: sentences, autoplaySuppressed: true)
        self.rig = rig
        let content = PlaybackTestRig.makeContent(hash: "mac-column-rig", count: sentences, wordsPerSentence: 6)
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "mac-column-rig", sentences: sentences),
                            content: content)
        return (rig.controller, content)
    }

    /// A page of `sentences` in paragraphs of four, at 19 pt.
    private func makePage(sentences: Int, active: Int, size: NSSize = NSSize(width: 1000, height: 600),
                          reduceMotion: Bool = false) throws -> Page {
        try makePage(content: Self.content(count: sentences), active: active, size: size,
                     reduceMotion: reduceMotion)
    }

    /// A page in an offscreen window (never ordered in), built, measured and
    /// placed on its active sentence. `onPlay` replaces the play log's own
    /// record (which keeps recording either way).
    private func makePage(content: DocContent, active: Int, size: NSSize = NSSize(width: 1000, height: 600),
                          reduceMotion: Bool = false, onPlay: ((Int) -> Void)? = nil) throws -> Page {
        let log = PlayLog()
        let view = ReaderColumnView(content: content, fontSize: 19, activeSentence: active, activeWord: -1,
                                    voiceOffscreen: .constant(nil), onPlaySentence: { id in
                                        log.ids.append(id)
                                        onPlay?(id)
                                    })
        let coordinator = view.makeCoordinator()
        coordinator.reduceMotion = { reduceMotion }
        coordinator.isCoasting = { _ in false }
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)

        coordinator.update(to: view)
        coordinator.updateGeometry()
        // TextKit's estimate reaches the end, so the landing isn't clamped.
        _ = coordinator.rect(forSentence: content.sentences.count - 1)
        coordinator.placeActiveSentence()
        XCTAssertNotNil(coordinator.textView?.textLayoutManager)
        return Page(window: window, scrollView: scrollView, coordinator: coordinator, played: log, view: view)
    }

    /// `count` sentences of eight words, four to a paragraph, on one page.
    private static func content(count: Int) -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for start in stride(from: 0, to: count, by: 4) {
            let end = min(start + 4, count)
            paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: start..<end, page: 0))
            for id in start..<end {
                sentences.append(Sentence(id: id, text: "Sentence \(id) reads a few plain words aloud.",
                                          para: paragraphs.count - 1, page: 0))
            }
        }
        return DocContent(title: "Column", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                          contentHash: "mac-column-\(count)")
    }
}
