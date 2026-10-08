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
        settleClick(on: page)
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
    /// plays from it, once the double-click interval is out; a double-click
    /// and a drag (each leaves a selection) play nothing more.
    func testAClickInASentencePlaysFromIt() throws {
        let page = try makePage(sentences: 60, active: 0)
        let id = try page.singleLineSentence(near: 9)
        let point = try page.point(inSentence: id)
        XCTAssertEqual(page.coordinator.sentence(at: point), id)
        XCTAssertEqual(page.view.makeCoordinator().clickPlayDelay(),
                       min(NSEvent.doubleClickInterval, ReaderColumnView.clickPlayHoldLimit),
                       "a click waits for the system's double-click interval, capped")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertTrue(page.coordinator.isClickPlayPending, "a second click may still come")
        XCTAssertEqual(page.played.ids, [])
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [id])

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 2, true)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, true)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [id], "a selection is not a click to play")
    }

    /// A click shows at once where it will play: the highlight moves to the
    /// clicked sentence as the button comes up while the audio waits, and
    /// the wait is half a second at most, however slow the system's
    /// double-click speed (L022). A key, or the second click of a
    /// double-click, puts the highlight back on the voice.
    func testAHeldClickShowsItsSentenceAtOnceAndHoldsTheAudioBriefly() throws {
        XCTAssertEqual(ReaderColumnView.clickPlayHold(doubleClickInterval: 5), ReaderColumnView.clickPlayHoldLimit,
                       "a slow double-click speed never holds a click for seconds")
        XCTAssertEqual(ReaderColumnView.clickPlayHold(doubleClickInterval: 0.3), 0.3, "a quick one is kept")
        XCTAssertLessThanOrEqual(ReaderColumnView.clickPlayHoldLimit, 0.5)

        let page = try makePage(sentences: 60, active: 0)
        page.coordinator.clickPlayDelay = { 60 }   // held for the whole test
        let id = try page.singleLineSentence(near: 9)
        let point = try page.point(inSentence: id)

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertTrue(page.coordinator.isClickPlayPending)
        XCTAssertEqual(page.coordinator.highlightedSentence, id, "the clicked sentence shows at once")
        XCTAssertEqual(page.coordinator.activeSentence, 0, "the voice is where it was")
        page.update(activeSentence: 1)
        XCTAssertEqual(page.coordinator.highlightedSentence, id, "the voice moving on keeps the held click's cue")
        XCTAssertEqual(page.played.ids, [])

        page.coordinator.otherInputArrived()
        XCTAssertFalse(page.coordinator.isClickPlayPending)
        XCTAssertEqual(page.coordinator.highlightedSentence, 1, "dropped: the highlight is the voice's again")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertEqual(page.coordinator.highlightedSentence, id)
        page.textView.onClickLanded?()   // a double-click's second click
        XCTAssertFalse(page.coordinator.isClickPlayPending)
        XCTAssertEqual(page.coordinator.highlightedSentence, 1)
        XCTAssertEqual(page.played.ids, [])
    }

    /// A double-click selects a word and a triple-click a paragraph (for
    /// Copy or Look Up), and neither plays: AppKit ends the first click of
    /// each as a plain one, with nothing selected yet, and its play waits
    /// out the double-click interval, which the next click landing cancels.
    func testADoubleOrTripleClickSelectsWithoutPlaying() throws {
        let page = try makePage(sentences: 60, active: 0)
        let id = try page.singleLineSentence(near: 9)
        let point = try page.point(inSentence: id)

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 2, true)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [], "a double-click selects, never plays")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 2, true)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 3, true)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [], "nor does a triple-click")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [id], "a lone click still plays")
    }

    /// A Force Click looks the word up and never plays (J022). AppKit ends
    /// it as a plain click with nothing selected, so its Look Up marks the
    /// click, whether that comes while the button is down or after the
    /// click ended and its play is held. The next plain click plays.
    func testAForceClickLooksUpWithoutPlaying() throws {
        let page = try makePage(sentences: 60, active: 0)
        let id = try page.singleLineSentence(near: 9)
        let point = try page.point(inSentence: id)
        XCTAssertNotNil(page.textView.onLookUpGesture, "the coordinator hears Look Up")

        page.textView.onClickLanded?()
        page.textView.onLookUpGesture?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertFalse(page.coordinator.isClickPlayPending, "looked up while the button was down")
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [])

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertTrue(page.coordinator.isClickPlayPending)
        page.textView.onLookUpGesture?()
        XCTAssertFalse(page.coordinator.isClickPlayPending, "looked up while its play was held")
        XCTAssertFalse(page.coordinator.isWatchingForOtherInput)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [])

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [id], "the next plain click plays")
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
        settleClick(on: page)
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
        XCTAssertFalse(page.coordinator.isClickPlayPending)
        XCTAssertEqual(rig.controller.currentSentence, before, "a click on moving text only stops it")

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        settleClick(on: page)
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

    /// ⌘C across a chapter's opening (or a PDF page's mark, or the
    /// colophon) quotes the words: the rule paragraph between them is an
    /// attachment, and neither its U+FFFC nor the line it stood on reaches
    /// the pasteboard (H054). A private pasteboard, so the test leaves the
    /// clipboard alone.
    func testACopyAcrossARuleParagraphQuotesOnlyTheWords() {
        let textView = ReaderNSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let text = NSMutableAttributedString(string: "Last sentence.\nChapter Two\n")
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "\nFirst line of chapter two."))
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: text.length))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.davidxie.AloudMacTests.rule.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "Last sentence.\nChapter Two\nFirst line of chapter two.")
        XCTAssertEqual(ReaderColumnText.quotable("words\n\u{FFFC}"), "words\n", "a selection ending on the rule")
        XCTAssertEqual(ReaderColumnText.quotable("plain words"), "plain words")
    }

    /// ⌘A then ⌘C on a finished PDF quotes its sentences only: no page
    /// numeral between pages 1 and 2, no end mark, no colophon (L023).
    func testACopyLeavesOutPageNumeralsAndTheColophon() {
        let sentences = [Sentence(id: 0, text: "Last words of page one.", para: 0, page: 1),
                         Sentence(id: 1, text: "First words of page two.", para: 1, page: 2)]
        let paragraphs = [Paragraph(id: 0, sentenceIDs: 0..<1, page: 1),
                          Paragraph(id: 1, sentenceIDs: 1..<2, page: 2)]
        let content = DocContent(title: "Pages", pageCount: 2, sentences: sentences, paragraphs: paragraphs,
                                 contentHash: "mac-copy-furniture")
        let colophon = ReaderColophon(title: "Pages", author: "A. Writer", words: 165 * 72, rate: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.davidxie.AloudMacTests.furniture.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        for colophon in [nil, colophon] {
            let built = ReaderColumnText.makeAttributedString(content: content, fontSize: 19, isChapterBook: false,
                                                              colophon: colophon, bold: false, ink: .live())
            XCTAssertTrue(built.string.string.contains("\n2\n"), "the page numeral is on the page")
            let textView = ReaderNSTextView(usingTextLayoutManager: true)
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            textView.textStorage?.setAttributedString(built.string)
            textView.setSelectedRange(NSRange(location: 0, length: built.string.length))

            pasteboard.clearContents()
            XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
            XCTAssertEqual(pasteboard.string(forType: .string), "Last words of page one.\nFirst words of page two.\n",
                           colophon == nil ? "no numeral, no end mark" : "no numeral, no colophon")
        }
    }

    /// The mouse button held on the page (a click, or a drag selection
    /// AppKit is tracking) holds it as a finger on the trackpad does: the
    /// voice leaving the band moves nothing under the pointer, so the
    /// selection ends where the pointer is. As the button comes up, the
    /// page follows the voice, once (H020).
    func testAHeldMouseButtonKeepsThePageUntilItComesUp() throws {
        let page = try makePage(sentences: 300, active: 100, size: NSSize(width: 800, height: 500),
                                reduceMotion: true)
        let coordinator = page.coordinator
        nextMainTurn()   // the opening placement runs first, as when a book opens
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        let next = try page.firstSentenceBelowTheBand(after: 100)
        let held = page.offset
        let scrolls = coordinator.programmaticScrollCount

        page.textView.isMouseHeld = true
        page.update(activeSentence: next)
        nextMainTurn()
        XCTAssertEqual(page.offset, held, "the page holds still under the pointer")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
        XCTAssertFalse(page.activeSentenceIsInTheBand())
        XCTAssertTrue(coordinator.isFollowing, "a held button is not a scroll away")

        page.textView.isMouseHeld = false
        page.textView.onMouseReleased?()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "one follow, as the button comes up")
        XCTAssertTrue(page.activeSentenceIsInTheBand())
        page.textView.onMouseReleased?()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "nothing kept back, nothing more")
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

    /// Lets a single click's held play run: the rig's double-click interval
    /// is 0, so it runs on the main queue's next turns.
    private func settleClick(on page: Page) {
        let deadline = Date().addingTimeInterval(2)
        while page.coordinator.isClickPlayPending, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(page.coordinator.isClickPlayPending, "the click's play ran")
    }

    /// A click's held play gives way to what the listener does before it
    /// plays: a pause (Space, the bar's Pause) or a jump (⌘→, Undo Jump)
    /// stands, and a key or a click elsewhere drops it. With nothing in
    /// between it plays (G008).
    func testAHeldClickGivesWayToAPauseOrAJump() throws {
        let rig = makeRig(sentences: 30)
        let page = try makePage(content: rig.content, active: 0) { id in
            ReaderColumnView.playFromSentence(id, on: rig.controller)
        }
        page.coordinator.parent.transportStamp = { ReaderColumnView.transportStamp(of: rig.controller) }
        let id = try page.singleLineSentence(near: 12)
        let point = try page.point(inSentence: id)

        ReaderColumnView.playFromSentence(0, on: rig.controller)
        XCTAssertTrue(rig.controller.isListenerPlaying)
        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertTrue(page.coordinator.isClickPlayPending)
        rig.controller.pause()
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [], "the pause stands")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNotEqual(rig.controller.currentSentence, id)

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        rig.controller.jump(to: 25, origin: .chapter)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [], "the jump stands")
        XCTAssertEqual(rig.controller.currentSentence, 25)
        XCTAssertFalse(rig.controller.isListenerPlaying)

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        XCTAssertTrue(page.coordinator.isWatchingForOtherInput, "keys and clicks elsewhere are watched")
        page.coordinator.otherInputArrived()
        XCTAssertFalse(page.coordinator.isClickPlayPending, "a key or a click elsewhere drops it")
        XCTAssertFalse(page.coordinator.isWatchingForOtherInput)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [])

        page.textView.onClickLanded?()
        page.textView.onClickEnded?(point, 1, false)
        settleClick(on: page)
        XCTAssertEqual(page.played.ids, [id], "with nothing in between, the click plays")
        XCTAssertEqual(rig.controller.currentSentence, id)
        XCTAssertFalse(page.coordinator.isWatchingForOtherInput, "the watch ends with the click")
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

    /// Look Up takes a phrase, never a passage (J025): past
    /// `lookUpSelectionLimit` (⌘A) or across a paragraph, the selection
    /// gives way to the word under the pointer. The panel is placed from
    /// the first character alone, never by laying out the whole range.
    func testLookUpTakesAPhraseNeverThePage() throws {
        let page = try makePage(sentences: 40, active: 0)
        let id = try page.singleLineSentence(near: 5)
        let point = try page.point(inFirstWordOf: id)
        let storage = try XCTUnwrap(page.textView.textStorage)
        let ranges = page.coordinator.sentenceRanges
        let sentence = ranges[id]

        page.textView.setSelectedRange(sentence)
        XCTAssertEqual(page.textView.lookUpRange(at: point), sentence, "a sentence is a phrase")

        page.textView.selectAll(nil)
        XCTAssertGreaterThan(page.textView.selectedRange().length, ReaderNSTextView.lookUpSelectionLimit)
        let word = try XCTUnwrap(page.textView.lookUpRange(at: point))
        XCTAssertEqual(storage.attributedSubstring(from: word).string, "Sentence", "the word under the pointer")
        let menu = page.textView.contextMenu(at: point).items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(menu[2].title, "Look Up \u{201C}Sentence\u{201D}")

        // From the paragraph's start into the next one: short, but a passage.
        let opening = id - id % 4
        let across = NSUnionRange(ranges[opening], ranges[opening + 4])
        XCTAssertLessThanOrEqual(across.length, ReaderNSTextView.lookUpSelectionLimit)
        page.textView.setSelectedRange(across)
        let inside = try XCTUnwrap(page.textView.lookUpRange(at: point))
        XCTAssertEqual(storage.attributedSubstring(from: inside).string, "Sentence", "not across a paragraph")

        let measured = RangeLog()
        page.textView.baselineOrigin = { range in
            measured.ranges.append(range)
            return nil   // no panel in a test
        }
        let lookUp = NSMenuItem()
        lookUp.representedObject = NSValue(range: NSRange(location: 0, length: storage.length))
        page.textView.lookUpFromMenu(lookUp)
        XCTAssertEqual(measured.ranges, [NSRange(location: 0, length: 1)], "measured from its first character")
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

    /// Every key the system's bindings read as extending the selection
    /// does, for Copy: ⌘⇧ and ⌃⇧ with ← and → to the line's ends, ⇧Page Up
    /// and ⇧Page Down (and ⌃⇧V), ⌃⇧B/F and ⌃⌥⇧B/F. None is swallowed, none
    /// goes on up the chain, and the text never changes.
    func testTheSelectionKeysExtendTheSelection() throws {
        let page = try makePage(sentences: 20, active: 0)
        let textView = page.textView
        let spy = ResponderSpy()
        textView.nextResponder = spy
        let text = textView.string
        // Inside sentence 9's first word, so mid-line.
        let caret = NSRange(location: page.coordinator.sentenceRanges[9].location + 4, length: 0)

        let selectors = ["moveToLeftEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
                         "pageUpAndModifySelection:", "pageDownAndModifySelection:",
                         "moveBackwardAndModifySelection:", "moveForwardAndModifySelection:",
                         "moveWordBackwardAndModifySelection:", "moveWordForwardAndModifySelection:"]
        for name in selectors {
            let selector = NSSelectorFromString(name)
            XCTAssertTrue(ReaderNSTextView.selectionCommands.contains(selector), name)
            textView.setSelectedRange(caret)
            textView.doCommand(by: selector)
            XCTAssertGreaterThan(textView.selectedRange().length, 0, "\(name) extends the selection")
        }
        XCTAssertEqual(spy.calls, [], "no selector went on up the chain")
        XCTAssertEqual(textView.string, text)
    }

    /// A book opened deep in its text leaves the hidden caret at the text's
    /// start. The first ⇧↓ (or ⌘⇧→, ⇧Page Down) selects from the passage
    /// on screen instead, never jumping the page back to the book's first
    /// lines: ⇧↓ and ⌘⇧→ keep the page, and following too (L021).
    /// L021: the caret goes to the first word shown, past a line break or
    /// a rule paragraph the visible range can open on.
    func testTheCaretGoesToTheFirstWordShown() {
        let text = "end.\n\u{FFFC}\n  Next line" as NSString
        XCTAssertEqual(ReaderNSTextView.firstWord(in: text, within: NSRange(location: 4, length: text.length - 4)), 9)
        XCTAssertEqual(ReaderNSTextView.firstWord(in: text, within: NSRange(location: 0, length: text.length)), 0)
        XCTAssertEqual(ReaderNSTextView.firstWord(in: text, within: NSRange(location: 4, length: 3)), 4,
                       "no word in range: its start")
    }

    func testASelectionKeyStartsFromThePassageOnScreen() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 800, height: 500))
        let coordinator = page.coordinator
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertGreaterThan(page.offset, 0, "the page is deep in the book")
        for (name, keepsThePage) in [("moveDownAndModifySelection:", true),
                                     ("moveToRightEndOfLineAndModifySelection:", true),
                                     ("pageDownAndModifySelection:", false)] {
            page.textView.setSelectedRange(NSRange(location: 0, length: 0))
            let before = page.offset
            page.textView.doCommand(by: NSSelectorFromString(name))
            let selection = page.textView.selectedRange()
            XCTAssertGreaterThan(selection.length, 0, "\(name) selects")
            XCTAssertGreaterThan(selection.location, coordinator.sentenceRanges[100].location,
                                 "\(name) selects from the passage on screen, never the book's start")
            XCTAssertGreaterThanOrEqual(page.offset, before - 1, "\(name) never jumps back to the start")
            guard keepsThePage else { continue }
            XCTAssertEqual(page.offset, before, accuracy: 1, "\(name) keeps the page")
            XCTAssertTrue(coordinator.isFollowing, "\(name) is no scroll of the reader's")
        }
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

    /// A book opening puts the keyboard on its text, a turn later: the
    /// scroll keys work at once, with no click (which plays) to focus the
    /// page. A field being typed in keeps it (⌘F's search, opened while the
    /// text loaded).
    func testABookOpeningPutsTheKeyboardOnTheText() throws {
        let page = try makePage(sentences: 60, active: 0)
        let offset = page.offset
        nextMainTurn()
        XCTAssertTrue(page.window.firstResponder === page.textView, "the page has the keys")
        XCTAssertEqual(page.offset, offset, accuracy: 0.5, "taking focus never scrolls")
        XCTAssertEqual(page.played.ids, [])

        let view = ReaderColumnView(content: Self.content(count: 20), fontSize: 19, activeSentence: 0,
                                    activeWord: -1, voiceOffscreen: .constant(nil), onPlaySentence: { _ in })
        let coordinator = view.makeCoordinator()
        coordinator.isCoasting = { _ in false }
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = container
        scrollView.frame = NSRect(x: 0, y: 0, width: 1000, height: 560)
        container.addSubview(scrollView)
        let field = NSSearchField(frame: NSRect(x: 20, y: 568, width: 240, height: 24))
        container.addSubview(field)
        _ = window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field is being edited")
        XCTAssertTrue(editor.isFieldEditor)

        coordinator.update(to: view)
        nextMainTurn()
        XCTAssertTrue(window.firstResponder === editor, "the field keeps the keyboard")
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

    /// A sentence taller than the band parks its top on the landing line;
    /// once its spoken word would fall below the band, following keeps the
    /// word's line in the band, so the end of a long sentence is never read
    /// off the page (F031, the iPhone's `FollowBand.followed`).
    func testASentenceTallerThanTheBandKeepsItsSpokenWordInTheBand() throws {
        let page = try makePage(content: Self.tallSentenceBook(), active: 6,
                                size: NSSize(width: 800, height: 500), reduceMotion: true)
        let coordinator = page.coordinator
        nextMainTurn()   // the opening placement runs first, as when a book opens
        let viewport = try XCTUnwrap(coordinator.viewport())
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertTrue(FollowBand.isTall(sentence, in: viewport), "taller than the band")
        XCTAssertGreaterThan(sentence.maxY, viewport.maxY, "its end starts below the page")
        XCTAssertTrue(page.activeSentenceIsInTheBand(), "parked on the landing line")
        let scrolls = coordinator.programmaticScrollCount

        page.update(activeSentence: 6, activeWord: 0)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "its first word reads where it is parked")

        var spoken = 0
        for token in 0..<600 {
            page.update(activeSentence: 6, activeWord: token)
            guard let word = coordinator.activeWordRect(), let now = coordinator.viewport() else { continue }
            spoken += 1
            XCTAssertLessThanOrEqual(word.maxY, now.minY + FollowBand.bottom * now.height + 1,
                                     "token \(token) is read below the band")
            XCTAssertGreaterThanOrEqual(word.minY, now.minY - 1, "token \(token) is read above the page")
        }
        XCTAssertGreaterThan(spoken, 200, "every word of the sentence was spoken")
        XCTAssertGreaterThan(coordinator.programmaticScrollCount, scrolls, "following tracked the word")
        XCTAssertTrue(coordinator.isFollowing)
    }

    // MARK: - Word ticks and tall sentences (audit loop 2: G002, G003, G006)

    /// G002: a word tick never moves a sentence that fits. A drag that
    /// leaves the spoken sentence in view but above the band follows again,
    /// and the page then stays put until the next sentence.
    func testWordTicksNeverPullBackASentenceThatFitsAfterADrag() throws {
        let page = try makePage(sentences: 300, active: 150, size: NSSize(width: 800, height: 500),
                                reduceMotion: true)
        let coordinator = page.coordinator
        XCTAssertTrue(page.activeSentenceIsInTheBand())

        let viewport = try XCTUnwrap(coordinator.viewport())
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        // The sentence's top to 3% of the viewport: in view, above the band.
        drag(page, toY: page.offset + sentence.minY - (viewport.minY + 0.03 * viewport.height))
        XCTAssertTrue(coordinator.isFollowing, "the voice is in view")
        XCTAssertFalse(page.activeSentenceIsInTheBand())

        let (scrolls, offset) = (coordinator.programmaticScrollCount, page.offset)
        for token in 0..<16 {
            page.update(activeSentence: 150, activeWord: token)
        }
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "no word tick follows a sentence that fits")
        XCTAssertEqual(page.offset, offset)

        page.update(activeSentence: 151)
        XCTAssertGreaterThan(coordinator.programmaticScrollCount, scrolls, "the next sentence follows")
        XCTAssertTrue(page.activeSentenceIsInTheBand())
    }

    /// G002 in a tall sentence: after a drag that leaves the spoken word in
    /// view, the page stays put until the voice moves on to its next line,
    /// and a drag back to the sentence's start that hides the word doesn't
    /// follow again: the chip points at the word.
    func testATallSentenceWaitsForTheNextLineAfterADragAndJudgesTheWord() throws {
        let page = try makeTallPage()
        let coordinator = page.coordinator
        let word = try speakToAFollowedLine(page)
        XCTAssertTrue(try spokenWordIsInTheBand(page))

        // Drag the text down until the word sits at 80%: in view, below the band.
        var viewport = try XCTUnwrap(coordinator.viewport())
        var rect = try XCTUnwrap(coordinator.spokenWordRect())
        drag(page, toY: page.offset - (viewport.minY + 0.80 * viewport.height - rect.minY))
        XCTAssertTrue(coordinator.isFollowing, "the spoken word is in view")
        XCTAssertFalse(try spokenWordIsInTheBand(page))

        // The next word, on the same line: nothing moves.
        let (scrolls, offset) = (coordinator.programmaticScrollCount, page.offset)
        page.update(activeSentence: 6, activeWord: 2 * (word + 1))
        let line = try XCTUnwrap(coordinator.spokenWordRect()).minY
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a word on the same line stays put")
        XCTAssertEqual(page.offset, offset)

        // The voice moves on to its next line: following brings it back.
        var next = word + 2
        while abs(try XCTUnwrap(coordinator.spokenWordRect()).minY - line) < 0.5 {
            page.update(activeSentence: 6, activeWord: 2 * next)
            next += 1
        }
        XCTAssertGreaterThan(coordinator.programmaticScrollCount, scrolls, "the next line follows")
        XCTAssertTrue(try spokenWordIsInTheBand(page))

        // On to the sentence's last words, far enough below its top that the
        // page can leave the word below it with the sentence still in view
        // (nearer the top, a drag back would stop at the top of the book).
        for _ in 0..<400 {
            let before = try XCTUnwrap(coordinator.spokenWordRect())
            page.update(activeSentence: 6, activeWord: 2 * (next + 1))
            guard let after = coordinator.spokenWordRect(), after != before else { break }
            next += 1
        }
        page.update(activeSentence: 6, activeWord: 2 * next)   // its last word, not past it

        // Back toward the sentence's start, which leaves the sentence in
        // view and puts the spoken word below the page.
        viewport = try XCTUnwrap(coordinator.viewport())
        rect = try XCTUnwrap(coordinator.spokenWordRect())
        drag(page, toY: page.offset - (viewport.maxY - rect.minY + 20))
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertNil(FollowBand.direction(of: sentence, in: try XCTUnwrap(coordinator.viewport())),
                     "the sentence is still in view")
        XCTAssertFalse(coordinator.isFollowing, "the spoken word is not")
        XCTAssertEqual(coordinator.voiceOffscreen, .down)
        let held = page.offset
        page.update(activeSentence: 6, activeWord: 2 * next)
        XCTAssertEqual(page.offset, held, "the reader keeps the start of the sentence")
    }

    /// G003: with Word highlight off nothing is underlined, yet following
    /// still tracks the spoken word (`followWord`) through a sentence taller
    /// than the band.
    func testATallSentenceFollowsTheSpokenWordWithTheUnderlineOff() throws {
        let page = try makeTallPage()
        let coordinator = page.coordinator
        let startY = page.offset
        for word in 0..<220 {
            page.update(activeSentence: 6, activeWord: -1, followWord: 2 * word)
            let rect = try XCTUnwrap(coordinator.spokenWordRect())
            let viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertLessThanOrEqual(rect.maxY, viewport.minY + FollowBand.bottom * viewport.height + 1,
                                     "word \(word) is read below the band")
            XCTAssertGreaterThanOrEqual(rect.minY, viewport.minY - 1, "word \(word) is read above the page")
        }
        XCTAssertGreaterThan(page.offset, startY, "the page moved up with the voice")
        XCTAssertNil(coordinator.activeWordRect(), "no underline is drawn")
        XCTAssertTrue(coordinator.isFollowing)
    }

    /// G003 on the Mac host: the playback's word ticker runs while playing
    /// with Word highlight off, at the coarse follow rate, so
    /// `currentWord` still reaches the page's follow; the full rate only
    /// feeds the tint.
    func testTheWordTickerRunsForFollowingWithTheHighlightOff() {
        let rig = PlaybackTestRig(sentences: 4)
        self.rig = rig
        let controller = rig.controller
        controller.wordHighlightEnabled = false
        controller.wordTimingStatusChanged(.playing)
        XCTAssertEqual(controller.wordTiming.tickerRate, WordKaraokeState.followFramesPerSecond)
        controller.wordHighlightEnabled = true
        controller.wordTimingStatusChanged(.playing)
        XCTAssertEqual(controller.wordTiming.tickerRate, WordKaraokeState.tintFramesPerSecond)
        controller.wordTimingStatusChanged(.paused)
        XCTAssertEqual(controller.wordTiming.tickerRate, 0, "no ticker while paused")
        controller.wordHighlightEnabled = false
    }

    /// G006: Play from a pause in the tail of a tall sentence keeps the
    /// spoken word where following left it: no move up to the sentence's
    /// top that would put the word below the page.
    func testPlayFromAPauseInATallSentenceKeepsTheSpokenWordInTheBand() throws {
        let page = try makeTallPage()
        let coordinator = page.coordinator
        let word = try speakToAFollowedLine(page)
        let (scrolls, offset) = (coordinator.programmaticScrollCount, page.offset)
        // Play bumps the follow request; the voice is where it paused.
        page.update(activeSentence: 6, activeWord: 2 * word, followRequest: 1)
        nextMainTurn()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the word is already in the band")
        XCTAssertEqual(page.offset, offset)
        XCTAssertTrue(try spokenWordIsInTheBand(page))
    }

    /// G006: Follow the voice (the chip, ⌘J), and a placement without
    /// motion, mid tall sentence land the spoken word in the band, not the
    /// sentence's top with the word below the page.
    func testFollowTheVoiceOrAPlacementMidTallSentenceLandsTheSpokenWord() throws {
        let page = try makeTallPage()
        let coordinator = page.coordinator
        let viewport = try XCTUnwrap(coordinator.viewport())
        let word = try speakToAFollowedLine(page, underline: false, past: 0.5 * viewport.height)

        // Scrolled away to the top of the book: the word is below the page.
        drag(page, toY: 0)
        XCTAssertEqual(FollowBand.direction(of: try XCTUnwrap(coordinator.spokenWordRect()),
                                            in: try XCTUnwrap(coordinator.viewport())), .down)
        XCTAssertFalse(coordinator.isFollowing)
        page.update(activeSentence: 6, followWord: 2 * word, followRequest: 1)
        nextMainTurn()
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(try spokenWordIsInTheBand(page), "Follow the voice lands the spoken word")

        // Placed again without motion, as a fresh column is.
        coordinator.placeActiveSentence()
        nextMainTurn()
        XCTAssertTrue(try spokenWordIsInTheBand(page), "a placement lands the spoken word")
    }

    /// G006 for the Mac's re-layout anchor: a new text size mid tall
    /// sentence keeps the spoken word where following left it, not the
    /// sentence's top on the landing line with the word below the page.
    func testATextSizeStepMidTallSentenceKeepsTheSpokenWord() throws {
        let page = try makeTallPage()
        let coordinator = page.coordinator
        let viewport = try XCTUnwrap(coordinator.viewport())
        let word = try speakToAFollowedLine(page, past: 0.5 * viewport.height)
        XCTAssertTrue(try spokenWordIsInTheBand(page))

        page.update(activeSentence: 6, activeWord: 2 * word,
                    fontSize: ReaderTextSize.points(forStep: ReaderTextSize.defaultStep + 1))
        XCTAssertGreaterThan(coordinator.builtFontSize, 19, "rebuilt at the larger size")
        XCTAssertTrue(try spokenWordIsInTheBand(page), "the anchor is the spoken word")
        for _ in 0..<(2 * ReaderFollowEngine.placementPassLimit + 2) {
            page.textView.needsLayout = true
            page.textView.layoutSubtreeIfNeeded()
            coordinator.handleLayout()
        }
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(try spokenWordIsInTheBand(page), "the spoken word keeps its place")
        XCTAssertNil(coordinator.voiceOffscreen)
    }

    /// The tall book's sentence 6 on an 800 × 500 page under Reduce Motion,
    /// so every follow move lands at once. Its tokens alternate word and
    /// space: word n is token 2n.
    private func makeTallPage() throws -> Page {
        let page = try makePage(content: Self.tallSentenceBook(), active: 6,
                                size: NSSize(width: 800, height: 500), reduceMotion: true)
        nextMainTurn()   // the opening placement runs first, as when a book opens
        let sentence = try XCTUnwrap(page.coordinator.measureActiveSentenceRect())
        XCTAssertTrue(FollowBand.isTall(sentence, in: try XCTUnwrap(page.coordinator.viewport())))
        return page
    }

    /// Speaks sentence 6's words from the first (underlined only with
    /// `underline`) until following has moved the page more than `past`
    /// with the voice and the word has just moved onto a new line. Returns
    /// that word.
    private func speakToAFollowedLine(_ page: Page, underline: Bool = true, past: CGFloat = 1) throws -> Int {
        let startY = page.offset
        var lineY: CGFloat?
        for word in 0..<220 {
            page.update(activeSentence: 6, activeWord: underline ? 2 * word : -1, followWord: 2 * word)
            let rect = try XCTUnwrap(page.coordinator.spokenWordRect())
            defer { lineY = rect.minY }
            if let lineY, abs(rect.minY - lineY) > 0.5, page.offset > startY + past { return word }
        }
        throw XCTSkip("following never tracked the word that far on this host")
    }

    private func spokenWordIsInTheBand(_ page: Page) throws -> Bool {
        let viewport = try XCTUnwrap(page.coordinator.viewport())
        return FollowBand.contains(try XCTUnwrap(page.coordinator.spokenWordRect()), in: viewport)
    }

    /// A gesture that moves the page to `y` and lets go.
    private func drag(_ page: Page, toY y: CGFloat) {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scrollView)
        page.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: page.scrollView)
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

    /// The ranges Look Up measured.
    private final class RangeLog {
        var ranges: [NSRange] = []
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
    /// R1-19: at the end of the book the sentence fill and its mark fade
    /// out under the colophon, and are back at once when it clears; the
    /// highlighted sentence itself never moves.
    func testTheHighlightFadesUnderTheColophonAndComesBack() throws {
        let page = try makePage(sentences: 40, active: 39)
        XCTAssertEqual(page.coordinator.highlightOpacity?.sentence, 1)
        page.update(activeSentence: 39, colophon: ReaderColophon(title: "Column", author: nil, words: 900, rate: 1))
        XCTAssertEqual(page.coordinator.highlightOpacity?.sentence, 0, "no fill under the colophon")
        XCTAssertEqual(page.coordinator.highlightOpacity?.mark, 0, "and no mark")
        XCTAssertEqual(page.coordinator.highlightedSentence, 39, "the sentence is still the active one")

        page.coordinator.setColophon(nil, animated: true)   // Listen again, Back 15, a jump or Undo
        XCTAssertEqual(page.coordinator.highlightOpacity?.sentence, 1, "back at once")
        XCTAssertEqual(page.coordinator.highlightOpacity?.mark, 1)
    }

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
        /// SwiftUI's update would. The spoken word `followWord` is the
        /// underlined `activeWord` unless given, as with Word highlight on.
        func update(activeSentence: Int, activeWord: Int = -1, followWord: Int? = nil,
                    followRequest: Int? = nil, fontSize: CGFloat? = nil, colophon: ReaderColophon? = nil) {
            view = ReaderColumnView(content: view.content, isChapterBook: view.isChapterBook,
                                    fontSize: fontSize ?? view.fontSize, activeSentence: activeSentence,
                                    activeWord: activeWord, followWord: followWord ?? activeWord,
                                    followRequest: followRequest ?? view.followRequest,
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
        // A single click plays on the next turns, not half a second on.
        coordinator.clickPlayDelay = { 0 }
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

    /// Twelve one-sentence paragraphs; the seventh is 220 words long, far
    /// taller than the band at 19 pt in an 800 × 500 window.
    private static func tallSentenceBook() -> DocContent {
        let long = (0..<220).map { "word\($0)" }.joined(separator: " ") + "."
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for id in 0..<12 {
            let text = id == 6 ? long : "Sentence \(id) reads a few plain words aloud."
            sentences.append(Sentence(id: id, text: text, para: id, page: 0))
            paragraphs.append(Paragraph(id: id, sentenceIDs: id..<(id + 1), page: 0))
        }
        return DocContent(title: "Tall", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                          contentHash: "mac-column-tall")
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
