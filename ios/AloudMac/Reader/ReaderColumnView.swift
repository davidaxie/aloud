import AppKit
import SwiftUI

/// The book page (M14, M15, contracts §6): a TextKit 2 `NSTextView` in an
/// `NSScrollView`, rendering the whole document as one attributed string
/// (`ReaderColumnText`) with a sentence-range table for highlighting and
/// click-to-play (R15). It ports the iPhone's `ReaderTextView` onto the same
/// shared core: `ReaderColumnLayout` measures, `HighlightLayers` draws the
/// highlight beneath the text, and `ReaderFollowEngine` decides calm follow.
///
/// Calm follow (R16): while following, the page scrolls only when the
/// spoken sentence leaves the `FollowBand` (18–70% of the visible height),
/// then glides once (0.45 s, `NSAnimationContext`) so it lands at 28%, or
/// jumps under Reduce Motion. Any user scroll stops following: a gesture or
/// the scroller (live-scroll notifications), a wheel without phases, the
/// scroll keys or VoiceOver (the clip view's bounds moving under no scroll
/// of ours). Nothing re-engages it on a timer: only Play, a jump or Undo,
/// Follow the voice (`followRequest`), or a scroll that ends with the voice
/// in view.
///
/// The interface the reader screen uses (wave 2.2):
/// - `content`, `isChapterBook`, `navigation` and `fontSize`
///   (`ReaderTextSize.points(forStep:)`): a change of content or size
///   rebuilds the column.
/// - `activeSentence` (`playback.currentSentence`) moves the highlight, and
///   `activeWord` (`playback.currentWord`, or -1 while Word highlight is off:
///   the preference is gated once, at the source) moves the underline.
/// - `followWord` (`playback.currentWord` whatever the pref): never drawn,
///   it is where following finds the voice in a sentence taller than the
///   band.
/// - `followRequest` (`followRequest(for:followVoiceCount:)`): any change
///   follows the voice again. Follow the voice (the chip, ⌘J) bumps its
///   count; Play, a jump and Undo bump the controller's serials.
/// - `obscuredBottom`: chrome drawn over the page's bottom edge, which the
///   band stays above.
/// - `colophon` (R24): at `.ended` the end mark becomes it, fading in.
/// - `focusRequest`: any change puts the keyboard on the text (Contents
///   closing, M11). A book opening puts it there too, unless a field is
///   being typed in.
/// - Out: `voiceOffscreen`, the Follow chip's arrow while not following;
///   `onPlaySentence`, a click or Play from Here (`playFromSentence(_:on:)`);
///   and `onTextUnderTopBar`, for the toolbar's hairline.
///
/// Re-layout anchoring (M15, the Mac's addition): a window resize (live
/// too), Contents docking or leaving, full screen, or a new text size
/// re-lays the column out around an anchor taken BEFORE the change
/// (`ReaderRelayoutAnchor`). While following, the voice keeps its top at the
/// same fraction of the viewport; otherwise the reader's own place, the
/// text at the top of the viewport, stays there. It is put back as one
/// placement without motion, a move of ours: never a user scroll, never a
/// follow scroll, and it never re-engages following. The page and the text
/// view don't autoresize, so the tile that reports a new size still finds
/// the old layout to measure the anchor on.
///
/// The highlight and underline never touch `textStorage`, so glyph metrics
/// never change and the layout holds still while reading.
struct ReaderColumnView: NSViewRepresentable {

    let content: DocContent
    /// Text books group sentences by chapter (styled openings, no page
    /// marks); PDFs keep their page marks.
    var isChapterBook = false
    /// Chapter starts, for the rotors (wave 2.2).
    var navigation: ReaderNavigation? = nil
    let fontSize: CGFloat
    let activeSentence: Int
    /// Token index of the spoken word in the active sentence; -1 = none.
    let activeWord: Int
    /// Token index of the word being spoken whatever the Word highlight pref
    /// (`playback.currentWord`); -1 = none. Never drawn: it tells following
    /// where the voice is inside a sentence taller than the band
    /// (`FollowBand.followed`), so the end of a long sentence at a large
    /// text size isn't read below the page with the underline off.
    var followWord = -1
    /// Any change resumes following and brings the active sentence into the
    /// band.
    var followRequest = 0
    /// How far chrome reaches up over the page's bottom edge; the band is
    /// measured above it.
    var obscuredBottom: CGFloat = 0
    /// R24: the colophon that replaces the "· · ·" end mark at the end of
    /// the book; nil everywhere else.
    var colophon: ReaderColophon? = nil
    /// Any change puts keyboard focus on the text, a turn later (the
    /// Contents panel closing hands the keyboard back to the page).
    var focusRequest = 0
    /// Where the voice is while the page is NOT following it and it is off
    /// screen (the Follow chip's arrow); nil otherwise.
    @Binding var voiceOffscreen: ReaderFollowDirection?
    /// A click on a sentence, or Play from Here: play from this sentence.
    let onPlaySentence: (Int) -> Void
    /// True once text has scrolled up under the toolbar (past the page's
    /// top inset), false back at the top; reported on a change, a turn
    /// later, so the screen's state never changes inside an update.
    var onTextUnderTopBar: ((Bool) -> Void)? = nil
    /// What a click's play, held for the double-click interval, checks
    /// before it plays: a change since (a Play or pause, a jump or Undo, a
    /// move while paused) was the listener's later word, and drops it.
    /// nil checks nothing.
    var transportStamp: (() -> Int)? = nil

    func makeNSView(context: Context) -> ReaderScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: ReaderScrollView, context: Context) {
        context.coordinator.update(to: self)
    }

    static func dismantleNSView(_ scrollView: ReaderScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// The longest a single click holds its play for a second click
    /// (L022): a double-click speed slowed for motor reasons would hold
    /// every click for seconds.
    static let clickPlayHoldLimit: TimeInterval = 0.5

    /// How long a single click waits for a second before it plays: the
    /// system's double-click interval, at most `clickPlayHoldLimit`.
    static func clickPlayHold(doubleClickInterval: TimeInterval) -> TimeInterval {
        min(doubleClickInterval, clickPlayHoldLimit)
    }

    /// R15: a click plays from the clicked sentence in any state, through
    /// the same jump the iPhone's tap makes (a far one offers Undo jump).
    @MainActor
    static func playFromSentence(_ id: Int, on playback: PlaybackController) {
        playback.jump(to: id, origin: .sentence)
    }

    /// The follow request the screen passes: a user Play, every jump and
    /// Undo, and each Follow the voice (`followVoiceCount`).
    @MainActor
    static func followRequest(for playback: PlaybackController, followVoiceCount: Int) -> Int {
        playback.userPlayAction &+ playback.jumpSerial &+ followVoiceCount
    }

    /// The stamp the screen passes (`transportStamp`): every user Play,
    /// jump and Undo, playing starting or stopping, and, while paused, a
    /// move of the cue. Playing moves on by itself, so its place is left
    /// out.
    @MainActor
    static func transportStamp(of playback: PlaybackController) -> Int {
        var stamp = Hasher()
        stamp.combine(playback.userPlayAction)
        stamp.combine(playback.jumpSerial)
        let playing = playback.isListenerPlaying
        stamp.combine(playing)
        if !playing { stamp.combine(playback.currentSentence) }
        return stamp.finalize()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: ReaderColumnView
        private(set) weak var scrollView: ReaderScrollView?
        private(set) weak var page: ReaderPageView?
        var textView: ReaderNSTextView? { page?.textView }

        private(set) var builtHash = ""
        private(set) var builtFontSize: CGFloat = 0
        /// The look (light or dark, Increase Contrast) the colors were
        /// resolved for; a change rebuilds them.
        private var builtLook: NSAppearance.Name?
        private(set) var activeSentence = -1
        private(set) var sentenceRanges: [NSRange] = []

        // End of the book (R24)
        /// The colophon the text shows in place of "· · ·"; nil = the mark.
        private(set) var shownColophon: ReaderColophon?
        /// The end mark's characters, always the tail of the text.
        private(set) var endMarkRange = NSRange(location: 0, length: 0)
        /// The paper-colored cover the colophon fades in from.
        private(set) var colophonVeil: ReaderVeilView?

        /// The text's height at the last layout pass; a change means TextKit
        /// swapped estimated line heights under a still offset.
        private var lastContentHeight: CGFloat = 0
        /// The band's height at the last layout pass; a change re-checks it.
        private var lastViewportHeight: CGFloat = 0

        // Calm follow (R16)
        private var follow = ReaderFollowEngine()
        /// Off from the moment the user scrolls; never back on by itself.
        var isFollowing: Bool {
            get { follow.isFollowing }
            set { follow.isFollowing = newValue }
        }
        var lastFollowRequest: Int {
            get { follow.lastFollowRequest }
            set { follow.lastFollowRequest = newValue }
        }
        /// Where the one glide asked for (set off or about to be) is going;
        /// nil when none. A click or a user scroll stops it where it is.
        private(set) var glideTarget: CGFloat?
        /// Tells a finished glide from one stopped and replaced since.
        private var glideSerial = 0
        /// The glide asked for and not yet set off: it starts one turn of
        /// the main queue after the request, never inside the sentence
        /// update (SwiftUI's pass) that asked for it. A newer request or a
        /// stop cancels it.
        private var pendingGlide: DispatchWorkItem?
        /// The text's height changed under a glide: the glide's end checks
        /// the band once, as that layout pass would have.
        private var followCheckAfterGlide = false
        /// Whether a follow glide is moving the page, or sets off on the
        /// next turn.
        var isGliding: Bool { glideTarget != nil }
        /// Every glide set off, of `programmaticScrollCount`'s scrolls
        /// (Reduce Motion makes none); one replaced before its turn never
        /// sets off.
        private(set) var glideCount = 0
        /// Whether a placement or rotor stop is still being checked on the
        /// layout passes (tests).
        var isCheckingPlacement: Bool { follow.isCheckingPlacement }
        /// Set when a click lands: a click that began on moving text only
        /// stops it (R15).
        private var clickBeganWhileScrolling = false
        /// Set when a Force Click or Look Up comes during the click: it
        /// looked a word up, so it never plays (J022).
        private var clickLookedUp = false
        /// A single click's play, held for the double-click interval: the
        /// next click landing in time (a double- or triple-click selecting
        /// a word or a paragraph) cancels it, as does any other key or click
        /// in the app (`clickPlayMonitor`) or a change of playback
        /// (`transportStamp`).
        private var pendingClickPlay: DispatchWorkItem?
        /// While a click's play is held: a key (Space, ⌘Z, an arrow) or a
        /// click anywhere else (the bar's Pause) drops it.
        private var clickPlayMonitor: Any?
        /// A single click's sentence, highlighted as the button comes up
        /// while its play is held, so the click shows at once (L022). Kept
        /// once the play runs, until the jump moves the voice there; the
        /// hold giving way puts the highlight back on the voice.
        private var clickCue: (sentence: Int, hash: String)?
        /// Moves of our own in progress (offsets, rebuilds): the clip view's
        /// bounds moving then is not the reader scrolling.
        private var programmaticMoves = 0
        /// Between a gesture's (or the scroller's) start and the end of its
        /// momentum.
        private var inLiveScroll = false
        /// A finger on the trackpad or the scroller holds the page: a live
        /// scroll short of its momentum. Momentum alone never keeps the
        /// page from the voice: following stops it, as on the iPhone. The
        /// mouse button held down on the text holds it too (a drag
        /// selection AppKit is tracking ends where the pointer is), as a
        /// finger resting on the iPhone's page does, until it comes up.
        private var userHoldsScroll: Bool {
            (inLiveScroll && scrollView?.inMomentum != true) || textView?.isMouseHeld == true
        }
        /// A follow the held mouse button kept back, run as it comes up.
        private var followKeptBack = false
        /// The clip view's bounds and the page's height when last seen, to
        /// tell a scroll from a resize or a reflow.
        private var lastClipBounds = CGRect.zero
        private var lastPageHeight: CGFloat = 0
        /// The end of a scroll no gesture announced: a quiet moment after it.
        private var discreteScrollEnd: DispatchWorkItem?
        static let discreteScrollSettle: TimeInterval = 0.25
        /// A layout pass asked for, to confirm a placement.
        private var layoutPassRequested = false
        /// What `onTextUnderTopBar` was last told.
        private var reportedTextUnderTopBar = false
        /// Inside `handleLayout`: the frame it may grow calls back in.
        private var isHandlingLayout = false
        /// The text storage is being replaced or its tail swapped: a layout
        /// pass then would measure the new text with the old ranges.
        private var isEditingText = false
        /// Every follow scroll, for the R16 budget.
        var programmaticScrollCount: Int { follow.programmaticScrollCount }
        /// The last direction published to `voiceOffscreen`.
        var voiceOffscreen: ReaderFollowDirection? { follow.voiceOffscreen }
        /// Test seam.
        var reduceMotion: () -> Bool = { PlatformAccessibility.reduceMotion }
        /// Test seam: whether momentum is still moving the page, or stopped
        /// it a moment ago (the touch of the click that lands on it).
        var isCoasting: (ReaderScrollView) -> Bool = { $0.isCoastingOrJustStopped }
        /// Test seam: how long a single click waits for a second before it
        /// plays.
        var clickPlayDelay: () -> TimeInterval = {
            ReaderColumnView.clickPlayHold(doubleClickInterval: NSEvent.doubleClickInterval)
        }
        /// A single click is waiting out the double-click interval (tests).
        var isClickPlayPending: Bool { pendingClickPlay != nil }
        /// The sentence the highlight is drawn on: a held click's cue
        /// (`clickCue`) in the text it landed on, else the voice's.
        var highlightedSentence: Int {
            if let clickCue, clickCue.hash == builtHash { return clickCue.sentence }
            return activeSentence
        }
        /// Keys and clicks elsewhere are watched for, while a click waits
        /// (tests).
        var isWatchingForOtherInput: Bool { clickPlayMonitor != nil }

        #if DEBUG
        private let publishesProbe = UITestHooks.isUITestLaunch
        #endif

        // Word underline (drawn by HighlightLayers, never in textStorage)
        private(set) var activeWordToken = -1
        private var activeWordRange: NSRange?
        // The spoken word following tracks (`followWord`), underlined or not
        private(set) var spokenWordToken = -1
        private var spokenWordRange: NSRange?
        /// Where the last spoken word of a tall sentence sat, so a tick
        /// follows only when the voice moves on to a new line
        /// (`FollowBand.wordTickFollows`). Cleared with the sentence.
        private var lastSpokenWordRect: CGRect?
        /// Absolute token ranges per sentence (`ReaderColumnLayout.wordRanges`).
        private var wordRangeCache: [Int: [NSRange?]] = [:]

        // Re-layout anchoring (M15, Mac)
        /// The clip view's size and offset as the page was last laid out
        /// and placed: a tile at another size is a re-layout, measured
        /// against these.
        private(set) var placedViewSize = CGSize.zero
        private var placedOffset: CGFloat = 0
        /// The anchor a re-layout puts back, held while TextKit settles
        /// (and through a live resize, so its frames never drift); nil when
        /// none is pending.
        private(set) var relayoutAnchor: ReaderRelayoutAnchor?
        /// Layout passes the anchor's check may still take, and the text's
        /// laid-out height at its last pass.
        private var anchorPassesLeft = 0
        private var anchorHeight: CGFloat?
        /// Whether the anchor was last put back on confirmed layout (the
        /// text laid out through it), not on TextKit's estimates.
        private var anchorConfirmed = false
        /// A re-layout's new geometry going in, before its anchor is armed:
        /// a layout pass then (the text view taking its new width) would
        /// measure the band at the new size on the old offset, and follow.
        private var isRelayingOut = false

        /// The last `focusRequest` acted on.
        private var lastFocusRequest: Int

        init(parent: ReaderColumnView) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        // MARK: Setup

        /// The scroll view, its page and the text view, wired. Builds
        /// nothing from the content: the first update does.
        func makeScrollView() -> ReaderScrollView {
            let textView = ReaderNSTextView(usingTextLayoutManager: true)
            Self.configure(textView)
            let page = ReaderPageView(textView: textView)
            let scrollView = ReaderScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            // The page sits under the toolbar's safe area already; no
            // automatic inset moves the offsets the band is measured in.
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.documentView = page
            // Sized by `updateGeometry` alone, on the tile: autoresized, the
            // text would re-lay out before the anchor is measured.
            page.autoresizingMask = []
            self.scrollView = scrollView
            self.page = page

            textView.onClickLanded = { [weak self] in self?.clickLanded() }
            textView.onClickEnded = { [weak self] point, clicks, selectionMade in
                self?.clickEnded(at: point, clickCount: clicks, selectionMade: selectionMade)
            }
            textView.onMouseReleased = { [weak self] in self?.mouseReleased() }
            textView.onLookUpGesture = { [weak self] in self?.lookUpGestureArrived() }
            textView.sentenceAtPoint = { [weak self] point in self?.sentence(at: point) }
            textView.characterOffsetAtPoint = { [weak self] point in self?.column?.characterOffset(at: point) }
            textView.baselineOrigin = { [weak self] range in
                self?.segments(for: range).first.map { CGPoint(x: $0.frame.minX, y: $0.frame.minY + $0.baseline) }
            }
            textView.onPlayFromHere = { [weak self] id in self?.parent.onPlaySentence(id) }
            textView.onCommand = { [weak self] selector in self?.keyScroll(selector) ?? false }
            textView.onAppearanceChange = { [weak self] in self?.rebuildForAppearanceChange() }
            textView.onLayout = { [weak self] in self?.handleLayout() }
            textView.onFrameChange = { [weak self] in self?.textFrameChanged() }
            page.laidOutTextHeight = { [weak self] in self?.laidOutTextHeight() }
            scrollView.onTile = { [weak self] in self?.tiled() }
            scrollView.onPhaselessWheel = { [weak self] in self?.userScrolledDiscretely() }
            // Rotors, Play from here, the label and the bounded value (M18).
            installAccessibility()

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(liveScrollWillStart(_:)),
                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveScrollDidEnd(_:)),
                               name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            // Any window's: the page's window is known only once it is in one.
            center.addObserver(self, selector: #selector(windowLiveResizeDidEnd(_:)),
                               name: NSWindow.didEndLiveResizeNotification, object: nil)

            #if DEBUG
            if publishesProbe { ReaderFollowProbe.shared.reset() }
            #endif
            updateGeometry()
            return scrollView
        }

        /// Read-only, selectable, and none of NSTextView's editing, checking,
        /// finding or rich-text machinery: no find bar (⌘F is Contents
        /// search), no font panel or ruler, no spelling, substitutions or
        /// Writing Tools.
        static func configure(_ textView: ReaderNSTextView) {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isFieldEditor = false
            textView.drawsBackground = false
            textView.usesFindBar = false
            textView.isIncrementalSearchingEnabled = false
            textView.usesFontPanel = false
            textView.usesRuler = false
            textView.isRulerVisible = false
            textView.usesInspectorBar = false
            textView.importsGraphics = false
            textView.allowsImageEditing = false
            textView.allowsUndo = false
            textView.allowsDocumentBackgroundColorChange = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.displaysLinkToolTips = false
            if #available(macOS 15.0, *) {
                textView.writingToolsBehavior = .none
            }
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            // The width is `updateGeometry`'s (see `makeScrollView`).
            textView.autoresizingMask = []
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.setAccessibilityIdentifier("reader.text")
        }

        /// Observers go with the view; a glide or a pending scroll end
        /// must not outlive it.
        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            discreteScrollEnd?.cancel()
            discreteScrollEnd = nil
            cancelClickPlay()
            stopGlideInPlace()
            endAnchor()
        }

        // MARK: Updates

        func update(to newParent: ReaderColumnView) {
            let obscuredBottomChanged = parent.obscuredBottom != newParent.obscuredBottom
            parent = newParent
            guard textView != nil else { return }

            if lastFocusRequest != newParent.focusRequest {
                lastFocusRequest = newParent.focusRequest
                focusText()
            }

            if !builtHash.isEmpty, builtHash == newParent.content.contentHash,
               builtFontSize != newParent.fontSize {
                // A text size: the same column re-laid out around its anchor.
                changeTextSize(to: newParent)
            } else if builtHash != newParent.content.contentHash || builtFontSize != newParent.fontSize {
                let opening = builtHash.isEmpty
                rebuild(content: newParent.content, fontSize: newParent.fontSize)
                // A book opening: the scroll keys work at once, with no
                // click (which plays) to give the page the keyboard.
                if opening, !builtHash.isEmpty { focusText(sparingAField: true) }
                // A fresh column starts on the voice.
                lastFollowRequest = newParent.followRequest
                isFollowing = true
                setActiveSentence(newParent.activeSentence, scroll: false)
                setActiveWord(newParent.activeWord)
                // The placement aims at the spoken word in a tall sentence.
                setSpokenWord(newParent.followWord, follows: false)
                // Placed once the view has its size and insets.
                Task { @MainActor [weak self] in self?.placeActiveSentence() }
                return
            }

            // Before the follow request: Listen again clears the colophon,
            // so following then aims at sentence 0, not at the end mark.
            if shownColophon != newParent.colophon {
                setColophon(newParent.colophon, animated: true)
            }

            if lastFollowRequest != newParent.followRequest {
                lastFollowRequest = newParent.followRequest
                setActiveSentence(newParent.activeSentence, scroll: false)
                resumeFollowing()
            } else if activeSentence != newParent.activeSentence {
                setActiveSentence(newParent.activeSentence, scroll: true)
            }

            if activeWordToken != newParent.activeWord {
                setActiveWord(newParent.activeWord)
            }
            if spokenWordToken != newParent.followWord {
                setSpokenWord(newParent.followWord, follows: true)
            }

            if obscuredBottomChanged {
                followIfNeeded(animated: true)
                updateFollowChip()
            }
        }

        // MARK: Building

        func rebuild(content: DocContent, fontSize: CGFloat) {
            guard let textView, let storage = textView.textStorage else { return }
            stopGlideInPlace()
            endAnchor()
            let appearance = textView.effectiveAppearance
            let built = ReaderColumnText.makeAttributedString(content: content, fontSize: fontSize,
                                                              isChapterBook: parent.isChapterBook,
                                                              colophon: parent.colophon,
                                                              bold: PlatformLegibility.isBold(appearance),
                                                              ink: .live())
            // No layout pass is handled until the ranges and state below
            // match the new text.
            isEditingText = true
            defer { isEditingText = false }
            movingProgrammatically {
                storage.setAttributedString(built.string)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            sentenceRanges = built.sentenceRanges
            // A fresh column, a reopen included, shows the colophon in
            // place: only an end reached on screen fades in, and the
            // highlight is already out under it (R1-19).
            shownColophon = parent.colophon
            page?.highlight.setSentenceHidden(parent.colophon != nil)
            endMarkRange = built.endMarkRange
            removeColophonVeil()
            builtHash = content.contentHash
            builtFontSize = fontSize
            builtLook = Self.look(of: appearance)
            page?.highlight.clearSentence()
            activeSentence = -1
            wordRangeCache = [:]
            activeWordRange = nil
            activeWordToken = -1
            spokenWordRange = nil
            spokenWordToken = -1
            lastSpokenWordRect = nil
            follow.cachedActiveRect = nil
            follow.startPlacementCheck()
            follow.pendingReveal = nil
            // The measure is in ems of the text size.
            updateGeometry()
        }

        /// Light/dark and Increase Contrast only recolor (the Mac has no
        /// Bold Text), and the text's colors resolve as they draw
        /// (`ReaderInk.live`): the page redraws, with no edit. TextKit keeps
        /// its layout, so the passage on screen, the reader's selection and
        /// VoiceOver's cursor stay put, and nothing is laid out again from
        /// the top of the book, a long stall deep in one. The layers
        /// colored once (the highlight, the underline, a colophon's veil)
        /// take the new look.
        func rebuildForAppearanceChange() {
            guard let textView, !builtHash.isEmpty, builtHash == parent.content.contentHash else { return }
            let look = Self.look(of: textView.effectiveAppearance)
            guard look != builtLook else { return }
            builtLook = look
            Self.redraw(textView)
            renderSentenceHighlight(animated: false)
            renderWordUnderline(animated: false)
            colophonVeil?.layer?.backgroundColor = textView.effectiveAppearance.resolvedCGColor(Theme.bg)
        }

        /// `view` and every view in it: TextKit 2 draws its fragments in
        /// views of its own.
        private static func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }

        /// Which of the four looks a theme token tells apart `appearance` is.
        private static func look(of appearance: NSAppearance) -> NSAppearance.Name? {
            appearance.bestMatch(from: PlatformColor.lookNames)
        }

        // MARK: Geometry

        /// The column centered at its measure, the page as wide as the clip
        /// view, and 0.45 × the visible height of paper under the end. Runs
        /// on every tile (a resize) and after a rebuild.
        func updateGeometry() {
            guard let scrollView, let page, let textView else { return }
            let visible = scrollView.contentView.bounds.size
            let fontSize = builtFontSize > 0 ? builtFontSize : parent.fontSize
            let inset = NSSize(width: ReaderColumnMetrics.sideInset(forWidth: visible.width, fontSize: fontSize),
                               height: ReaderColumnMetrics.topInset)
            // The paper first: a reflow the new width starts measures the
            // resting range with it.
            page.bottomInset = ReaderColumnMetrics.bottomInset(forVisibleHeight: visible.height)
            page.minimumHeight = visible.height
            if textView.textContainerInset != inset {
                textView.textContainerInset = inset
            }
            if page.frame.width != visible.width {
                page.setFrameSize(NSSize(width: visible.width, height: page.frame.height))
            }
            if textView.frame.width != visible.width || textView.frame.origin != .zero {
                textView.frame = NSRect(x: 0, y: 0, width: visible.width, height: textView.frame.height)
            }
            // The container tracks the text view's width, and is set here
            // too: a new inset alone (a text size) doesn't move the frame.
            let columnWidth = max(visible.width - 2 * inset.width, 0)
            if let container = textView.textContainer, container.size.width != columnWidth {
                container.size = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
            }
            syncPageHeight()
        }

        /// The page follows the text, and TextKit's own figure for it when
        /// the text view's frame trails a deep layout pass (it only grows the
        /// frame here; the text view settles it). A clip view clamped by a
        /// shorter page reports that as a move of the page, never the
        /// reader's.
        private func syncPageHeight() {
            guard let page, let textView else { return }
            // A point and a half of slack: TextKit and the text view may
            // round the same figure apart.
            if let laidOut = laidOutTextHeight(), laidOut > textView.frame.height + 1.5 {
                textView.setFrameSize(NSSize(width: textView.frame.width, height: laidOut))
            }
            page.syncHeight()
            lastPageHeight = page.frame.height
        }

        /// A tile: at a new size (the window, Contents, full screen) the
        /// anchor is measured on the layout as it was, before the new
        /// geometry re-lays the column out, then put back.
        private func tiled() {
            guard let scrollView else { return }
            let size = scrollView.contentView.bounds.size
            let relaid = !builtHash.isEmpty && placedViewSize != .zero && size != placedViewSize
            // A tile in a burst (a live resize, full screen's animation)
            // keeps the anchor the burst began with: its frames never drift.
            let held = relayoutAnchor
            var anchor = held
            if relaid {
                if anchor == nil { anchor = captureAnchor(offset: placedOffset, viewSize: placedViewSize) }
                stopGlideInPlace()
                follow.cachedActiveRect = nil
            }
            // The pass at the end of the tile is the anchor's to place.
            isRelayingOut = relaid
            updateGeometry()
            isRelayingOut = false
            if relaid, let anchor { arm(anchor, confirming: held == nil) }
            placedViewSize = size
            placedOffset = contentOffsetY
            handleLayout()
        }

        private func textFrameChanged() {
            syncPageHeight()
            handleLayout()
        }

        // MARK: Re-layout anchoring (M15, Mac)

        /// A new text size: the anchor is measured on the old size, the
        /// column rebuilt (the same characters, so the same ranges), and the
        /// anchor put back. Following is left as it was: neither ended nor
        /// re-engaged, and the follow request is untouched.
        private func changeTextSize(to newParent: ReaderColumnView) {
            let anchor = relayoutAnchor ?? viewport().flatMap { captureAnchor(offset: $0.minY, viewSize: viewSize) }
            // The same text at a new size: VoiceOver's cursor stays put.
            let rebuildPage = { self.rebuild(content: newParent.content, fontSize: newParent.fontSize) }
            if let access = textView?.readerAccessibility {
                access.keepingCursor(through: rebuildPage)
            } else {
                rebuildPage()
            }
            // The anchor places this column, not the landing line.
            follow.endPlacementCheck()
            setActiveSentence(newParent.activeSentence, scroll: false)
            setActiveWord(newParent.activeWord)
            setSpokenWord(newParent.followWord, follows: false)
            if let anchor { arm(anchor, confirming: true) }
            placedViewSize = viewSize
            placedOffset = contentOffsetY
        }

        private var viewSize: CGSize {
            scrollView?.contentView.bounds.size ?? .zero
        }

        /// The anchor for the page as it stands in a clip view `viewSize`
        /// tall at `offset`: the voice while following, else the reader's
        /// place. Measured on the current layout; nil without one.
        func captureAnchor(offset: CGFloat, viewSize: CGSize) -> ReaderRelayoutAnchor? {
            let viewport = CGRect(x: 0, y: offset, width: viewSize.width,
                                  height: max(viewSize.height - parent.obscuredBottom, 0))
            guard viewport.height > 0 else { return nil }
            if isFollowing {
                guard let range = followRange, let rect = activeSentenceRect() else { return nil }
                // In a sentence taller than the band, the spoken word once
                // following tracks it (`followedRect`): the sentence's top
                // would take the landing line and leave the word below the
                // page.
                if let word = spokenWordRange, let wordRect = spokenWordRect(),
                   followedRect(sentence: rect, in: viewport) == wordRect {
                    return .voice(range: word, rect: wordRect, in: viewport, isGliding: isGliding)
                }
                return .voice(range: range, rect: rect, in: viewport, isGliding: isGliding)
            }
            return readingAnchor(in: viewport)
        }

        /// The first line visible in `viewport`, by the character at its
        /// start. The top may sit in a paragraph gap: look a little lower,
        /// one line at a time.
        private func readingAnchor(in viewport: CGRect) -> ReaderRelayoutAnchor? {
            guard let column, let textView, let length = textView.textStorage?.length, length > 0 else { return nil }
            let origin = textView.textContainerOrigin
            let line = ReaderPageStyle(fontSize: builtFontSize > 0 ? builtFontSize : parent.fontSize).lineHeight
            let top = max(viewport.minY, origin.y)
            for step in 0..<4 {
                let point = CGPoint(x: origin.x + 1, y: top + 1 + CGFloat(step) * line)
                guard let location = column.characterOffset(at: point), location < length else { continue }
                let range = NSRange(location: location, length: 1)
                guard let rect = boundingRect(for: range) else { continue }
                return .reading(range: range, lineTop: rect.minY, viewportTop: viewport.minY)
            }
            return nil
        }

        /// Puts `anchor` back now, and checks it on the layout passes that
        /// follow. The follow placement check gives way: the anchor places
        /// the page. `confirming` lays the text out through the anchor
        /// first: a deep pass, so a burst's later frames and a live resize
        /// place on the layout as it stands, and the check (or the live
        /// resize's end) confirms it once.
        private func arm(_ anchor: ReaderRelayoutAnchor, confirming: Bool) {
            relayoutAnchor = anchor
            anchorPassesLeft = ReaderFollowEngine.placementPassLimit
            anchorHeight = nil
            follow.endPlacementCheck()
            let confirmed = confirming && scrollView?.inLiveResize != true
            anchorConfirmed = confirmed
            restore(anchor, confirmed: confirmed)
        }

        /// One placement without motion: a move of ours, so never a user
        /// scroll, and never a follow scroll (not counted for R16). With
        /// `confirmed`, the text through the anchor is laid out first, so it
        /// lands on real heights, not estimates.
        private func restore(_ anchor: ReaderRelayoutAnchor, confirmed: Bool) {
            guard let viewport = viewport(), viewport.height > 0 else { return }
            if confirmed { column?.ensureLayout(through: anchor.range) }
            guard let rect = boundingRect(for: anchor.range) else { return }
            let y = anchor.offset(forTop: rect.minY, viewportHeight: viewport.height,
                                  restingRange: anchorRestingRange())
            if abs(y - contentOffsetY) > 0.5 { setOffset(y) }
            follow.cachedActiveRect = nil
            refreshHighlightGeometry()
            updateFollowChip()
        }

        /// Where an anchor may rest: `restingOffsets()`, but never short of
        /// the page as it stands. TextKit's figure for re-laid-out text
        /// trails until its layout reaches the end, and would clamp the
        /// anchor short; the checks that follow clamp it on settled heights.
        private func anchorRestingRange() -> ClosedRange<CGFloat> {
            let range = restingOffsets()
            guard let scrollView, let page else { return range }
            let pageEnd = page.frame.height - scrollView.contentView.bounds.height
            return range.lowerBound...max(range.upperBound, pageEnd)
        }

        /// One layout pass's check of the anchor: TextKit settling estimated
        /// heights moves the text under a still offset, so put it back. Held
        /// through a live resize; then, once in place on a steady height (or
        /// after `placementPassLimit` passes), confirmed on laid-out text if
        /// it was placed on estimates, and over.
        private func verifyAnchor() {
            guard let anchor = relayoutAnchor, let scrollView else { return }
            guard glideTarget == nil, !userHoldsScroll else { return endAnchor() }
            let height = laidOutHeight()
            let steady = anchorHeight.map { abs($0 - height) < 0.5 } ?? false
            anchorHeight = height
            let before = contentOffsetY
            restore(anchor, confirmed: false)
            guard !scrollView.inLiveResize else { return }
            anchorPassesLeft -= 1
            if (abs(contentOffsetY - before) <= 0.5 && steady) || anchorPassesLeft <= 0 {
                if anchorConfirmed { return endAnchor() }
                // Placed on estimates: once on laid-out text, then checked.
                confirmAnchor(anchor)
            } else {
                requestLayoutPass()
            }
        }

        /// The anchor put back on confirmed layout, with a fresh check.
        private func confirmAnchor(_ anchor: ReaderRelayoutAnchor) {
            anchorPassesLeft = ReaderFollowEngine.placementPassLimit
            anchorHeight = nil
            anchorConfirmed = true
            restore(anchor, confirmed: true)
            requestLayoutPass()
        }

        private func endAnchor() {
            relayoutAnchor = nil
            anchorHeight = nil
            anchorPassesLeft = 0
            anchorConfirmed = false
        }

        /// A live resize is over: put the anchor back on confirmed layout,
        /// then check it until it holds.
        @objc func windowLiveResizeDidEnd(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === scrollView?.window,
                  let anchor = relayoutAnchor else { return }
            confirmAnchor(anchor)
            placedOffset = contentOffsetY
        }

        /// Puts keyboard focus on the text, a turn later: after SwiftUI has
        /// taken the closed Contents panel, and its focus, out of the window.
        /// `sparingAField` (a book opening) leaves a field being typed in
        /// alone: ⌘F's Contents search, opened before the text loaded.
        func focusText(sparingAField: Bool = false) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView, let window = textView.window,
                          window.firstResponder !== textView else { return }
                    if sparingAField, let editor = window.firstResponder as? NSTextView,
                       editor.isFieldEditor { return }
                    // Taking focus never scrolls the page; were AppKit to,
                    // it would be a move of ours.
                    self.movingProgrammatically { _ = window.makeFirstResponder(textView) }
                }
            }
        }

        // MARK: End of the book (R24)

        /// Swaps the end mark for `colophon` (or back to "· · ·") in ONE tail
        /// edit of the text storage: every sentence range stays valid and
        /// nothing above the mark re-lays out. While following, the colophon
        /// is brought into the band like the voice; appearing with
        /// `animated`, it fades in through a paper veil (opacity only, so
        /// Reduce Motion keeps it), framed after that follow scroll.
        func setColophon(_ colophon: ReaderColophon?, animated: Bool) {
            guard colophon != shownColophon, let textView, let storage = textView.textStorage else { return }
            guard endMarkRange.length > 0, NSMaxRange(endMarkRange) == storage.length else { return }
            let appearing = shownColophon == nil && colophon != nil
            let appearance = textView.effectiveAppearance
            let mark = ReaderColumnText.makeEndMark(colophon: colophon, fontSize: builtFontSize,
                                                    bold: PlatformLegibility.isBold(appearance),
                                                    ink: .live())
            isEditingText = true
            movingProgrammatically {
                storage.replaceCharacters(in: endMarkRange, with: mark)
            }
            endMarkRange = NSRange(location: endMarkRange.location, length: mark.length)
            isEditingText = false
            shownColophon = colophon
            follow.cachedActiveRect = nil   // the follow target moved (`followRange`)
            removeColophonVeil()
            // R1-19: the highlight fades out under the colophon (opacity
            // only, so Reduce Motion keeps it), and is back at once, before
            // the next highlight draws, when it clears.
            page?.highlight.setSentenceHidden(colophon != nil,
                                              fadeDuration: appearing && animated ? Theme.Motion.colophon : nil)
            if colophon != nil, isFollowing { followIfNeeded(animated: true) }
            if appearing, animated { fadeInColophon() }
            updateFollowChip()
        }

        /// Covers the new colophon with the page's own paper and fades the
        /// cover out over `Theme.Motion.colophon`.
        private func fadeInColophon() {
            guard let page, let textView, let rect = boundingRect(for: endMarkRange) else { return }
            let veil = ReaderVeilView(frame: CGRect(x: 0, y: rect.minY, width: page.bounds.width, height: rect.height))
            veil.wantsLayer = true
            veil.layer?.backgroundColor = textView.effectiveAppearance.resolvedCGColor(Theme.bg)
            page.addSubview(veil, positioned: .above, relativeTo: textView)
            colophonVeil = veil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.colophon
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                veil.animator().alphaValue = 0
            } completionHandler: { [weak self, weak veil] in
                MainActor.assumeIsolated {
                    guard let veil else { return }
                    veil.removeFromSuperview()
                    if self?.colophonVeil === veil { self?.colophonVeil = nil }
                }
            }
        }

        private func removeColophonVeil() {
            colophonVeil?.removeFromSuperview()
            colophonVeil = nil
        }

        /// Layout moved the text under a fade in flight: keep the cover on
        /// the colophon.
        private func reframeColophonVeil() {
            guard let veil = colophonVeil, let page, let rect = boundingRect(for: endMarkRange) else { return }
            let frame = CGRect(x: 0, y: rect.minY, width: page.bounds.width, height: rect.height)
            if veil.frame != frame { veil.frame = frame }
        }

        // MARK: Highlighting

        func setActiveSentence(_ id: Int, scroll: Bool) {
            guard textView != nil else { return }
            let changed = id != activeSentence
            if changed {
                setActiveWord(-1)   // never carry a word underline across sentences
                setSpokenWord(-1, follows: false)
                lastSpokenWordRect = nil
                follow.cachedActiveRect = nil
            }
            activeSentence = id
            // The voice takes the highlight back from a click's cue, once
            // the click's play is no longer held.
            if pendingClickPlay == nil { clickCue = nil }
            renderSentenceHighlight(animated: changed)
            if scroll && isFollowing { followIfNeeded(animated: true) }
            updateFollowChip()
        }

        /// Draws the active sentence (or a held click's, `highlightedSentence`)
        /// in the highlight layer beneath the text. Never touches
        /// `textStorage`.
        private func renderSentenceHighlight(animated: Bool) {
            guard let page, let textView else { return }
            let shown = highlightedSentence
            guard sentenceRanges.indices.contains(shown) else {
                page.highlight.clearSentence()
                return
            }
            let appearance = textView.effectiveAppearance
            let heading = headingFontSize(at: sentenceRanges[shown])
            let containerWidth = textView.textContainer?.size.width ?? 0
            page.highlight.showSentence(glyphSegments(for: shown),
                                        fill: appearance.resolvedCGColor(Theme.highlightBg),
                                        mark: appearance.resolvedCGColor(Theme.accent),
                                        gutterX: textView.textContainerOrigin.x,
                                        style: heading == nil ? .body : .heading, em: heading ?? 0,
                                        trailingEdge: containerWidth > 0
                                            ? textView.textContainerOrigin.x + containerWidth : nil,
                                        animated: animated, reduceMotion: reduceMotion())
        }

        /// R1-17: a centred sentence is a chapter heading (the only centred
        /// ones): its font's size, else nil.
        private func headingFontSize(at range: NSRange) -> CGFloat? {
            guard let storage = textView?.textStorage, range.location < storage.length,
                  let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle, style.alignment == .center else { return nil }
            return (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize
                ?? builtFontSize
        }

        /// R1-18: sentence `id`'s word frames, so each highlighted row ends at
        /// its last glyph, not at a trailing space; its lines if it has none.
        private func glyphSegments(for id: Int) -> [HighlightLayers.Segment] {
            let words = (wordRanges(for: id) ?? []).compactMap { $0 }.flatMap { segments(for: $0) }
            return words.isEmpty ? segments(for: sentenceRanges[id]) : words
        }

        /// The sentence fill's and margin mark's opacity (R1-19); for tests.
        var highlightOpacity: (sentence: Float, mark: Float)? {
            page.map { ($0.highlight.sentenceOpacity, $0.highlight.markOpacity) }
        }

        /// Word layer: an accent underline under the spoken word. With
        /// `follows`, the underlined word is also the spoken word following
        /// tracks (`setSpokenWord`), as when Word highlight is on.
        func setActiveWord(_ token: Int, follows: Bool = false) {
            guard textView != nil else { return }
            if follows { setSpokenWord(token, follows: true) }
            let newRange = wordRange(token)
            activeWordToken = token
            guard newRange != activeWordRange else { return }
            let slide = activeWordRange != nil
            activeWordRange = newRange
            renderWordUnderline(animated: slide)
        }

        /// The spoken word (`followWord`), drawn or not, as on the iPhone.
        /// Through a sentence taller than the band, following keeps it on
        /// the page (`FollowBand.followed`), and a tick that `follows`
        /// re-checks the band only when the voice has moved on to a new line
        /// (`FollowBand.wordTickFollows`): never on a sentence that fits,
        /// and never within the line a user scroll left in view.
        func setSpokenWord(_ token: Int, follows: Bool) {
            guard textView != nil else { return }
            let newRange = wordRange(token)
            spokenWordToken = token
            guard newRange != spokenWordRange else { return }
            spokenWordRange = newRange
            follow.cachedWordRect = nil
            // Measured only in a tall sentence; whitespace keeps the last line.
            guard newRange != nil, shownColophon == nil,
                  let sentence = activeSentenceRect(), let viewport = viewport(), viewport.height > 0,
                  FollowBand.isTall(sentence, in: viewport), let word = spokenWordRect() else { return }
            let previous = lastSpokenWordRect
            lastSpokenWordRect = word
            if follows, isFollowing,
               FollowBand.wordTickFollows(sentence: sentence, word: word, previousWord: previous, in: viewport) {
                followIfNeeded(animated: true)
            }
        }

        /// Token `token` of the active sentence; nil for none and for
        /// whitespace tokens.
        private func wordRange(_ token: Int) -> NSRange? {
            guard token >= 0, let ranges = wordRanges(for: activeSentence),
                  ranges.indices.contains(token) else { return nil }
            return ranges[token]
        }

        /// The spoken word's laid-out rect in the page's coordinates, cached
        /// with the sentence's (`cachedWordRect`) so the per-frame chip
        /// check never measures; nil without one.
        func spokenWordRect() -> CGRect? {
            if let cached = follow.cachedWordRect { return cached }
            guard let range = spokenWordRange, let rect = boundingRect(for: range) else { return nil }
            follow.cachedWordRect = rect
            return rect
        }

        /// The underlined word's laid-out rect in the page's coordinates,
        /// like `viewport()`; nil without one.
        func activeWordRect() -> CGRect? {
            activeWordRange.flatMap { boundingRect(for: $0) }
        }

        private func renderWordUnderline(animated: Bool) {
            guard let page, let textView else { return }
            guard let range = activeWordRange else {
                page.highlight.clearWord()
                return
            }
            page.highlight.showWord(segments(for: range),
                                    color: textView.effectiveAppearance.resolvedCGColor(Theme.accentStrong),
                                    fill: textView.effectiveAppearance.resolvedCGColor(Theme.wordHighlightBg),
                                    animated: animated, reduceMotion: reduceMotion())
        }

        /// Geometry changed under the highlight (a reflow, estimates
        /// resolving): redraw in place, no crossfade.
        private func refreshHighlightGeometry() {
            renderSentenceHighlight(animated: false)
            renderWordUnderline(animated: false)
        }

        private func segments(for range: NSRange) -> [HighlightLayers.Segment] {
            column?.segments(for: range) ?? []
        }

        private func wordRanges(for id: Int) -> [NSRange?]? {
            ReaderColumnLayout.wordRanges(for: id, sentenceRanges: sentenceRanges,
                                          sentences: parent.content.sentences, cache: &wordRangeCache)
        }

        // MARK: Calm follow (R16)

        /// The visible content rect the band is measured in: the clip view,
        /// above any chrome drawn over the page's bottom edge.
        func viewport() -> CGRect? {
            guard let scrollView else { return nil }
            let bounds = scrollView.contentView.bounds
            return CGRect(x: 0, y: bounds.minY, width: bounds.width,
                          height: max(bounds.height - parent.obscuredBottom, 0))
        }

        private var contentOffsetY: CGFloat {
            scrollView?.contentView.bounds.origin.y ?? 0
        }

        /// While following: a sentence that has left the band glides (or,
        /// under Reduce Motion and past one viewport, jumps) to the landing
        /// line. Never moves under a gesture.
        func followIfNeeded(animated: Bool) {
            if isFollowing { noteFollowKeptBack() }
            guard isFollowing, !userHoldsScroll,
                  let sentence = activeSentenceRect(), let viewport = viewport(), viewport.height > 0 else { return }
            let rect = followedRect(sentence: sentence, in: viewport)
            guard !FollowBand.contains(rect, in: viewport),
                  let target = rect == sentence ? landingTarget() : landingOffset(for: rect) else { return }
            switch ReaderFollowEngine.move(to: target, in: scrollState(viewport: viewport),
                                           animated: animated, reaim: false) {
            case .none: return
            case .glide(let y): scroll(toY: y, animated: true)
            case .jump(let y, _): scroll(toY: y, animated: false)
            }
        }

        /// `FollowBand.followed` for the active sentence, as on the iPhone:
        /// the spoken word is measured only for a sentence taller than the
        /// band, whose end would otherwise be read below the page. What
        /// every follow decision judges: the band, a resume, a placement, a
        /// scroll's end and the Follow chip.
        private func followedRect(sentence: CGRect, in viewport: CGRect) -> CGRect {
            guard shownColophon == nil, FollowBand.isTall(sentence, in: viewport) else { return sentence }
            return FollowBand.followed(sentence: sentence, word: spokenWordRect(), in: viewport)
        }

        /// Play, a jump, Undo or Follow the voice: follow again and bring
        /// the active sentence into the band (in a tall one, the spoken
        /// word: `followedRect`). A sentence already in the band stays put.
        func resumeFollowing() {
            follow.resume()   // the voice owns the scroll again
            defer { updateFollowChip() }
            noteFollowKeptBack()
            guard !userHoldsScroll else { return }
            // Following takes the scroll back from a coast.
            stopCoasting()
            guard let viewport = viewport(), viewport.height > 0,
                  var rect = measureActiveSentenceRect() else { return }
            // Off screen, a deep jump must land on CONFIRMED geometry, not on
            // estimated heights of everything above it; on screen, the
            // sentence is measured where it is drawn.
            if FollowBand.direction(of: rect, in: viewport) != nil {
                ensureLayoutThroughActiveSentence()
                guard let confirmed = activeSentenceRect() else { return }
                rect = confirmed
            }
            let voice = followedRect(sentence: rect, in: viewport)
            guard !FollowBand.contains(voice, in: viewport),
                  let target = landingOffset(for: voice) else { return }
            switch ReaderFollowEngine.move(to: target, in: scrollState(viewport: viewport),
                                           animated: true, reaim: true) {
            case .none:
                return
            case .glide(let y):
                scroll(toY: y, animated: true)
            case .jump(let y, _):
                jump(toY: y) { self.landingTarget() }
                // A jump keeps verifying while estimated heights resolve.
                follow.startPlacementCheck()
            }
        }

        /// Follow the voice, as the chip and ⌘J ask through `followRequest`.
        func followTheVoice() {
            resumeFollowing()
        }

        /// Puts the active sentence on the landing line without motion (a
        /// fresh column), then verifies on every layout pass.
        func placeActiveSentence() {
            if isFollowing { noteFollowKeptBack() }
            guard isFollowing, !userHoldsScroll, let viewport = viewport(), viewport.height > 0 else { return }
            follow.pendingReveal = nil
            ensureLayoutThroughActiveSentence()
            follow.startPlacementCheck()
            if let target = landingTarget(), abs(target - contentOffsetY) > 1 {
                jump(toY: target) { self.landingTarget() }
            }
            updateFollowChip()
        }

        /// The offset that puts the active sentence (or the shown colophon)
        /// on the landing line under CURRENT geometry, or in a tall sentence
        /// the spoken word once following tracks it (`followedRect`), so a
        /// resume or a placement mid-sentence never parks that word below
        /// the page; nil while its layout can't resolve. Refreshes the
        /// cached sentence and word rects.
        private func landingTarget() -> CGFloat? {
            guard let range = followRange, let rect = boundingRect(for: range) else { return nil }
            follow.cachedActiveRect = rect
            guard let viewport = viewport() else { return nil }
            return landingOffset(for: followedRect(sentence: rect, in: viewport))
        }

        private func landingOffset(for rect: CGRect) -> CGFloat? {
            guard let viewport = viewport() else { return nil }
            return ReaderFollowEngine.landingOffset(for: rect, in: scrollState(viewport: viewport))
        }

        private func scrollState(viewport: CGRect) -> ReaderScrollState {
            ReaderScrollState(contentOffsetY: contentOffsetY, viewport: viewport,
                              restingRange: restingOffsets(), reduceMotion: reduceMotion())
        }

        /// Every offset the page can rest at: from its top to its end, the
        /// paper under the text included. While the colophon shows, its end
        /// is measured from the colophon itself too (R3-01, the iPhone's
        /// rule): TextKit's usage bounds trail a deep layout on a long book,
        /// and a range clamped short of the colophon left it below the page.
        /// No band is noted for the colophon here: its placement measures
        /// the band as it stands each time.
        private func restingOffsets() -> ClosedRange<CGFloat> {
            guard let scrollView, let page else { return 0...0 }
            var end = laidOutHeight()
            if shownColophon != nil, let colophon = follow.cachedActiveRect, let textView {
                end = max(end, colophon.maxY + textView.textContainerInset.height)
            }
            let highest = end + page.bottomInset - scrollView.contentView.bounds.height
            return 0...max(highest, 0)
        }

        /// Every resting offset (`restingOffsets`); for tests.
        var restingRange: ClosedRange<CGFloat> { restingOffsets() }

        /// TextKit's own figure for the text's height (the text view's frame
        /// trails it after a deep layout pass); nil before any layout.
        private func laidOutTextHeight() -> CGFloat? {
            guard let textView else { return nil }
            return column?.laidOutHeight(bottomInset: textView.textContainerInset.height)
        }

        private func laidOutHeight() -> CGFloat {
            laidOutTextHeight() ?? textView?.frame.height ?? 0
        }

        /// A placement without motion: one counted scroll. A landing the old
        /// height clamped short is re-aimed at once, as a correction of the
        /// same scroll.
        private func jump(toY y: CGFloat, reaim: () -> CGFloat?) {
            scroll(toY: y, animated: false)
            if let settled = reaim(), abs(settled - contentOffsetY) > 1 {
                setOffset(settled)
            }
        }

        /// Every follow, placement and reveal goes through here, so the R16
        /// budget counts them all.
        private func scroll(toY y: CGFloat, animated: Bool) {
            follow.noteScroll()
            // The page moves on purpose: the anchor's hold is over.
            endAnchor()
            #if DEBUG
            if publishesProbe { ReaderFollowProbe.shared.noteScroll() }
            #endif
            stopCoasting()
            if animated {
                startGlide(toY: y)
            } else {
                stopGlideInPlace()
                setOffset(y)
            }
        }

        /// Moves the page to `y` at once, as a move of ours.
        private func setOffset(_ y: CGFloat) {
            guard let scrollView, let page else { return }
            let clip = scrollView.contentView
            page.ensureRoom(forOffset: y, visibleHeight: clip.bounds.height)
            movingProgrammatically {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
            lastPageHeight = page.frame.height
        }

        /// One 0.45 s glide on the (0.4, 0, 0.2, 1) curve, set off one turn
        /// of the main queue later: the sentence update that asks for it is
        /// SwiftUI's pass, and the animation group is no work for it. A
        /// newer request before then replaces it; a click or a user scroll
        /// stops it, set off or not.
        private func startGlide(toY y: CGFloat) {
            guard scrollView != nil, page != nil else { return }
            stopGlideInPlace()
            glideSerial &+= 1
            let serial = glideSerial
            glideTarget = y
            let start = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.glideSerial == serial, self.glideTarget != nil else { return }
                    self.pendingGlide = nil
                    self.setOffGlide(toY: y, serial: serial)
                }
            }
            pendingGlide = start
            DispatchQueue.main.async(execute: start)
        }

        /// The glide `startGlide` asked for, on its turn.
        private func setOffGlide(toY y: CGFloat, serial: Int) {
            guard let scrollView, let page else {
                glideTarget = nil
                return
            }
            let clip = scrollView.contentView
            page.ensureRoom(forOffset: y, visibleHeight: clip.bounds.height)
            lastPageHeight = page.frame.height
            glideCount += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FollowBand.glideDuration
                context.timingFunction = FollowBand.mediaTimingFunction()
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.glideSerial == serial, self.glideTarget != nil else { return }
                    self.glideLanded()
                }
            }
        }

        /// The glide reached its target. When the text's height changed
        /// under it, the band is checked once now, as that layout pass
        /// would have (`handleLayout`).
        private func glideLanded() {
            glideTarget = nil
            if let scrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if followCheckAfterGlide {
                followCheckAfterGlide = false
                if isFollowing, !follow.pendingPlacement, relayoutAnchor == nil {
                    followIfNeeded(animated: false)
                }
            }
            updateFollowChip()
        }

        /// Stops a glide where the page is on screen right now; one not set
        /// off yet never moves.
        private func stopGlideInPlace() {
            guard glideTarget != nil else { return }
            glideTarget = nil
            glideSerial &+= 1
            // Whatever moves the page next measures the text as it is now.
            followCheckAfterGlide = false
            if let pending = pendingGlide {
                pending.cancel()
                pendingGlide = nil
                return
            }
            guard let scrollView else { return }
            let clip = scrollView.contentView
            let here = clip.bounds.origin
            movingProgrammatically {
                // A zero-length animation of the same key replaces the glide.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    clip.animator().setBoundsOrigin(here)
                }
                clip.setBoundsOrigin(here)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        /// Stops a coast where it is: left running, it keeps moving the page
        /// under a glide, and a click on it must only stop it.
        private func stopCoasting() {
            guard let scrollView, isCoasting(scrollView) || scrollView.inMomentum else { return }
            scrollView.stopCoasting()
        }

        private func movingProgrammatically(_ move: () -> Void) {
            programmaticMoves += 1
            defer { programmaticMoves -= 1 }
            move()
        }

        /// A gesture, the scroller, a key or VoiceOver: stop following.
        func userTookOverScroll() {
            stopGlideInPlace()
            endAnchor()
            follow.takeOver()   // and drops pending checks: don't fight the user
            updateFollowChip()
        }

        /// A user scroll came to rest: following resumes only when the voice
        /// is in view (in a tall sentence, the spoken word once following
        /// tracks it, not merely some line of the sentence).
        func userScrollEnded() {
            if let rect = activeSentenceRect(), let viewport = viewport() {
                follow.scrollEnded(voice: followedRect(sentence: rect, in: viewport), in: viewport)
            }
            updateFollowChip()
        }

        /// A scroll no gesture announced (a wheel without phases, a scroller
        /// click, the keys, VoiceOver): it takes over at once and ends after
        /// a quiet moment.
        func userScrolledDiscretely() {
            userTookOverScroll()
            discreteScrollEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.discreteScrollEnd = nil
                    self.userScrollEnded()
                }
            }
            discreteScrollEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.discreteScrollSettle, execute: end)
        }

        /// Runs on every scroll frame, so it never forces TextKit layout:
        /// the sentence and word rects come from the cache (measured at most
        /// once per sentence, word or relayout) and the rest is bounds
        /// arithmetic.
        func updateFollowChip() {
            var direction: ReaderFollowDirection?
            if let rect = activeSentenceRect(), let viewport = viewport() {
                direction = follow.chipDirection(voice: followedRect(sentence: rect, in: viewport), in: viewport)
                #if DEBUG
                if publishesProbe {
                    let onScreen = rect.offsetBy(dx: 0, dy: -contentOffsetY)
                    if ReaderFollowProbe.shared.activeRect != onScreen {
                        ReaderFollowProbe.shared.activeRect = onScreen
                    }
                    let line = Int(rect.minY / ReaderPageStyle(fontSize: parent.fontSize).lineHeight)
                    if ReaderFollowProbe.shared.activeLine != line {
                        ReaderFollowProbe.shared.activeLine = line
                    }
                }
                #endif
            }
            guard follow.publish(direction) else { return }
            let binding = parent.$voiceOffscreen
            Task { @MainActor in binding.wrappedValue = direction }
        }

        /// One layout pass: a change of the text's height means TextKit
        /// swapped estimated line heights under a still offset (while
        /// following, that re-checks the band, or under a glide, the
        /// glide's end does; the cached rect is stale either way), and a
        /// change of the visible height re-checks the
        /// band. Then a pending placement is verified.
        func handleLayout() {
            guard let textView, !isHandlingLayout, !isEditingText, !isRelayingOut else { return }
            isHandlingLayout = true
            defer { isHandlingLayout = false }
            let height = textView.frame.height
            // A re-layout's anchor places the page while it holds.
            let anchored = relayoutAnchor != nil
            if height != lastContentHeight {
                follow.cachedActiveRect = nil
                refreshHighlightGeometry()
                if isFollowing, glideTarget == nil, !follow.pendingPlacement, !anchored, lastContentHeight > 0 {
                    followIfNeeded(animated: false)
                } else if isFollowing, glideTarget != nil {
                    // A jump now would snap the page out of its glide: the
                    // glide's end checks the band instead.
                    followCheckAfterGlide = true
                }
                lastContentHeight = height
            }

            let viewportHeight = viewport()?.height ?? 0
            if viewportHeight != lastViewportHeight {
                let resized = lastViewportHeight > 0
                lastViewportHeight = viewportHeight
                if resized, isFollowing, !follow.pendingPlacement, !anchored {
                    followIfNeeded(animated: !reduceMotion())
                }
            }

            reframeColophonVeil()
            verifyPlacement()
            verifyAnchor()
        }

        /// Ends a placement or rotor-stop check and shows the chip it held.
        private func endPlacementCheck() {
            follow.endPlacementCheck()
            updateFollowChip()
        }

        /// One layout pass's check of a placement put in place without
        /// motion (`ReaderFollowEngine.placementPass`): re-placed when off,
        /// ended once in place on a steady height, and ended after
        /// `placementPassLimit` passes in any case.
        private func verifyPlacement() {
            guard follow.isCheckingPlacement, glideTarget == nil, !userHoldsScroll,
                  let scrollView, scrollView.contentView.bounds.height > 0 else { return }
            let check = checkPlacement()
            if case .unresolved = check { return }   // no layout to measure yet
            switch follow.placementPass(check, laidOutHeight: laidOutHeight()) {
            case .correct(let settled):
                // A correction of a placement already counted, so no `scroll`.
                setOffset(settled)
                requestLayoutPass()
            case .end:
                endPlacementCheck()
                return
            case .confirm:
                requestLayoutPass()
            }
            if follow.placementPassesSpent { endPlacementCheck() }
        }

        /// Measures the pending placement on the layout as it stands; when
        /// it is off, confirms the layout up to it and says where it goes.
        private func checkPlacement() -> ReaderFollowEngine.PlacementCheck {
            let settled: CGFloat?
            if let id = follow.pendingReveal {
                guard sentenceRanges.indices.contains(id), revealOffset(for: id) != nil else { return .holds }
                column?.ensureLayout(through: sentenceRanges[id])
                settled = revealOffset(for: id)
            } else {
                guard let target = landingTarget() else { return .unresolved }
                guard abs(target - contentOffsetY) > 1 else { return .holds }
                ensureLayoutThroughActiveSentence()
                guard let confirmed = landingTarget() else { return .unresolved }
                settled = confirmed
            }
            guard let settled, abs(settled - contentOffsetY) > 1 else { return .holds }
            return .moveTo(settled)
        }

        /// The offset that puts sentence `id` on the landing line; nil while
        /// it sits in the band, or the page can't scroll that far.
        private func revealOffset(for id: Int) -> CGFloat? {
            guard sentenceRanges.indices.contains(id),
                  let rect = boundingRect(for: sentenceRanges[id]), let viewport = viewport(),
                  !FollowBand.contains(rect, in: viewport),
                  let target = landingOffset(for: rect),
                  abs(target - contentOffsetY) > 1 else { return nil }
            return target
        }

        /// Asks AppKit for the next layout pass, which verifies the
        /// placement again (never from inside the pass now running).
        private func requestLayoutPass() {
            guard !layoutPassRequested else { return }
            layoutPassRequested = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.layoutPassRequested = false
                    self.textView?.needsLayout = true
                }
            }
        }

        // MARK: Scrolling, as the reader does it

        @objc func liveScrollWillStart(_ notification: Notification) {
            inLiveScroll = true
            discreteScrollEnd?.cancel()
            discreteScrollEnd = nil
            userTookOverScroll()
        }

        @objc func liveScrollDidEnd(_ notification: Notification) {
            inLiveScroll = false
            scrollView?.liveScrollEnded()
            userScrollEnded()
        }

        /// Every move of the page. One that no gesture announced, made by
        /// none of ours, that is neither a resize (the size, the page's
        /// height, or AppKit keeping the clip view on the page as the
        /// window resizes) nor TextKit settling the text under a still
        /// reader, is the reader scrolling.
        @objc func clipBoundsDidChange(_ notification: Notification) {
            guard let scrollView, let page else { return }
            let bounds = scrollView.contentView.bounds
            let pageHeight = page.frame.height
            defer {
                lastClipBounds = bounds
                lastPageHeight = pageHeight
                // Not mid-resize: the tile measures the anchor at the old offset.
                if bounds.size == placedViewSize { placedOffset = bounds.minY }
            }
            updateFollowChip()
            updateTextUnderTopBar(offset: bounds.minY)
            guard bounds.origin.y != lastClipBounds.origin.y,
                  bounds.size == lastClipBounds.size,
                  pageHeight == lastPageHeight,
                  programmaticMoves == 0, glideTarget == nil, !inLiveScroll,
                  !scrollView.isResizing, !scrollView.inLiveResize,
                  textView?.isLayingOut != true else { return }
            userScrolledDiscretely()
        }

        /// Bounds arithmetic only, safe on every scroll frame: the first line
        /// rests `topInset` below the toolbar, so text is under it only once
        /// the page has scrolled past that gap.
        private func updateTextUnderTopBar(offset: CGFloat) {
            let under = offset > ReaderColumnMetrics.topInset
            guard under != reportedTextUnderTopBar else { return }
            reportedTextUnderTopBar = under
            guard let report = parent.onTextUnderTopBar else { return }
            Task { @MainActor in report(under) }
        }

        /// The scroll keys (↑ ↓, Page Up and Down, Home and End, ⌘↑ ⌘↓): the
        /// page moves as the reader asked, which takes over the scroll.
        func keyScroll(_ selector: Selector) -> Bool {
            guard let step = KeyScroll(selector), let scrollView else { return false }
            let bounds = scrollView.contentView.bounds
            let line = ReaderPageStyle(fontSize: builtFontSize > 0 ? builtFontSize : parent.fontSize).lineHeight
            let pageStep = max(bounds.height - 2 * line, line)
            let range = restingOffsets()
            var y = bounds.origin.y
            switch step {
            case .lineUp: y -= line
            case .lineDown: y += line
            case .pageUp: y -= pageStep
            case .pageDown: y += pageStep
            case .top: y = range.lowerBound
            case .end: y = range.upperBound
            }
            y = min(max(y, range.lowerBound), range.upperBound)
            stopGlideInPlace()
            if abs(y - bounds.origin.y) > 0.5 { setOffset(y) }
            userScrolledDiscretely()
            return true
        }

        enum KeyScroll {
            case lineUp, lineDown, pageUp, pageDown, top, end

            init?(_ selector: Selector) {
                switch selector {
                case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.scrollLineUp(_:)):
                    self = .lineUp
                case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.scrollLineDown(_:)):
                    self = .lineDown
                case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                    self = .pageUp
                case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                    self = .pageDown
                case #selector(NSResponder.moveToBeginningOfDocument(_:)),
                     #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                    self = .top
                case #selector(NSResponder.moveToEndOfDocument(_:)),
                     #selector(NSResponder.scrollToEndOfDocument(_:)):
                    self = .end
                default:
                    return nil
                }
            }
        }

        // MARK: Click → sentence (R15)

        /// The mouse is down on the page, before AppKit tracks a click or a
        /// drag.
        func clickLanded() {
            // The second click of a double-click: the first one's play is off.
            cancelClickPlay()
            clickLookedUp = false
            let gliding = isGliding
            let coasting = scrollView.map(isCoasting) ?? false
            clickBeganWhileScrolling = coasting || gliding
            // A click on moving text stops it there.
            stopCoasting()
            if gliding {
                // Stopping a glide is the reader taking the scroll: following
                // survives only if the voice is in view; else the chip shows.
                userTookOverScroll()
                userScrollEnded()
            }
        }

        /// The button is up: a voice that left the band while it held the
        /// page is followed now. A click that only stopped a glide keeps
        /// the page where it stopped.
        func mouseReleased() {
            guard followKeptBack else { return }
            followKeptBack = false
            followIfNeeded(animated: true)
        }

        /// Notes a follow the held mouse button keeps back.
        private func noteFollowKeptBack() {
            if textView?.isMouseHeld == true { followKeptBack = true }
        }

        /// The click AppKit tracked has ended: one click, with no selection
        /// made, plays from its sentence, unless a second click follows.
        func clickEnded(at point: CGPoint, clickCount: Int, selectionMade: Bool) {
            let wasScrolling = clickBeganWhileScrolling
            clickBeganWhileScrolling = false
            let lookedUp = clickLookedUp
            clickLookedUp = false
            guard clickCount == 1, !selectionMade, !lookedUp else { return }
            handleClick(at: point, isDecelerating: wasScrolling)
        }

        /// A Force Click or Look Up's gesture (J022): the definition is for
        /// reading, so neither the click under way nor one already held
        /// plays. A Force Click ends as a plain click with nothing
        /// selected, and its pressure and Look Up events reach no monitor.
        func lookUpGestureArrived() {
            clickLookedUp = true
            cancelClickPlay()
        }

        /// A click plays from the clicked sentence in any state, unless it
        /// landed on moving text: then it only stopped the scroll. The play
        /// waits out the double-click interval (capped, `clickPlayHold`):
        /// AppKit ends a double-click's first click as a plain one, and a
        /// double- or triple-click selects (for Copy or Look Up), never
        /// plays. The clicked sentence is highlighted at once meanwhile.
        func handleClick(at point: CGPoint, isDecelerating: Bool) {
            if isDecelerating {
                userScrollEnded()
                return
            }
            guard let id = sentence(at: point) else { return }
            cancelClickPlay()
            let hash = builtHash
            let stamp = parent.transportStamp?()
            let play = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The cue stays until the jump moves the voice there.
                    self.cancelClickPlay(keepingCue: true)
                    // The same text the click landed on, and a pause, a
                    // jump or an Undo since then stands: the held click
                    // never overrides it.
                    guard self.builtHash == hash, self.parent.transportStamp?() == stamp else {
                        self.dropClickCue()
                        return
                    }
                    self.parent.onPlaySentence(id)
                }
            }
            pendingClickPlay = play
            clickCue = (id, hash)
            renderSentenceHighlight(animated: true)
            clickPlayMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.otherInputArrived() }
                return event
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + clickPlayDelay(), execute: play)
        }

        /// A key or a click while a click's play is held: whatever it does
        /// (Space, Undo Jump, a skip, the bar's Pause, a second click on the
        /// page) comes after the click, so the click no longer plays.
        func otherInputArrived() {
            cancelClickPlay()
        }

        private func cancelClickPlay(keepingCue: Bool = false) {
            pendingClickPlay?.cancel()
            pendingClickPlay = nil
            if let clickPlayMonitor { NSEvent.removeMonitor(clickPlayMonitor) }
            clickPlayMonitor = nil
            if !keepingCue { dropClickCue() }
        }

        /// A held click gave way: the highlight is the voice's again.
        private func dropClickCue() {
            guard clickCue != nil else { return }
            clickCue = nil
            renderSentenceHighlight(animated: false)
        }

        /// The sentence under `point` (page coordinates); nil between
        /// sentences or off the text.
        func sentence(at point: CGPoint) -> Int? {
            guard let offset = column?.characterOffset(at: point) else { return nil }
            return ReaderColumnLayout.sentence(containing: offset, in: sentenceRanges)
        }

        // MARK: TextKit 2 geometry

        /// The column's TextKit 2 geometry under the text container origin
        /// as it stands. Never the TextKit 1 layout object.
        private var column: ReaderColumnLayout? {
            guard let textView, let manager = textView.textLayoutManager else { return nil }
            let origin = textView.textContainerOrigin
            return ReaderColumnLayout(textLayoutManager: manager, origin: CGPoint(x: origin.x, y: origin.y))
        }

        /// Sentence `id`'s laid-out rect in page coordinates (tests).
        func rect(forSentence id: Int) -> CGRect? {
            guard sentenceRanges.indices.contains(id) else { return nil }
            return boundingRect(for: sentenceRanges[id])
        }

        /// Cached rect of the follow target (the active sentence or the shown
        /// colophon), in page coordinates like `viewport()`.
        func activeSentenceRect() -> CGRect? {
            if let cached = follow.cachedActiveRect { return cached }
            guard let range = followRange, let rect = boundingRect(for: range) else { return nil }
            follow.cachedActiveRect = rect
            return rect
        }

        /// What following and placement aim at: the colophon while it shows,
        /// else the active sentence.
        private var followRange: NSRange? {
            if shownColophon != nil, endMarkRange.length > 0 { return endMarkRange }
            return sentenceRanges.indices.contains(activeSentence) ? sentenceRanges[activeSentence] : nil
        }

        /// The active sentence's rect measured again, refreshing the cache.
        /// Deliberate moves and tests only, never per frame.
        func measureActiveSentenceRect() -> CGRect? {
            follow.cachedActiveRect = nil
            return activeSentenceRect()
        }

        /// `ensureLayout(through:)` for the follow target, redrawing its
        /// highlight if that moved it.
        private func ensureLayoutThroughActiveSentence() {
            guard let range = followRange else { return }
            let drawnAt = measureActiveSentenceRect()
            column?.ensureLayout(through: range)
            if measureActiveSentenceRect() != drawnAt { refreshHighlightGeometry() }
        }

        private func boundingRect(for range: NSRange) -> CGRect? {
            column?.boundingRect(for: range)
        }
    }
}

// MARK: - Re-layout anchoring (M15, Mac)

/// What a re-layout holds still (mac-ux §3.5): a window resize, Contents
/// docking or leaving, full screen, or a new text size. While following,
/// the voice (the follow target) keeps its top at the same fraction of the
/// viewport, the band's own measure; otherwise the reader's place, the line
/// at the top of the viewport, keeps its distance from the viewport's top.
/// Pure: the page measures `range` before and after, and this says where
/// the page then rests.
struct ReaderRelayoutAnchor: Equatable {

    /// The text held in place: the follow target, or the first character
    /// of the reader's top line.
    let range: NSRange
    let placement: Placement

    enum Placement: Equatable {
        /// The text's top at this fraction of the viewport's height.
        case fraction(CGFloat)
        /// The text's top this far below the viewport's top (less than 0
        /// while the line is clipped).
        case points(CGFloat)
    }

    /// While following: the voice at its own fraction of the viewport. A
    /// voice outside the band, or gliding to the landing line, takes the
    /// landing line, where following puts it.
    static func voice(range: NSRange, rect: CGRect, in viewport: CGRect, isGliding: Bool) -> Self {
        guard !isGliding, viewport.height > 0, FollowBand.contains(rect, in: viewport) else {
            return Self(range: range, placement: .fraction(FollowBand.landing))
        }
        return Self(range: range, placement: .fraction((rect.minY - viewport.minY) / viewport.height))
    }

    /// Not following: the reader's top line, whose top is at `lineTop` in a
    /// viewport whose top is at `viewportTop`.
    static func reading(range: NSRange, lineTop: CGFloat, viewportTop: CGFloat) -> Self {
        Self(range: range, placement: .points(lineTop - viewportTop))
    }

    /// The offset that puts the anchor back, its text's top now laid out at
    /// `top` in a viewport `height` tall, clamped to where the page can rest.
    func offset(forTop top: CGFloat, viewportHeight height: CGFloat,
                restingRange: ClosedRange<CGFloat>) -> CGFloat {
        let y: CGFloat
        switch placement {
        case .fraction(let fraction): y = top - fraction * height
        case .points(let points): y = top - points
        }
        return min(max(y, restingRange.lowerBound), restingRange.upperBound)
    }
}
