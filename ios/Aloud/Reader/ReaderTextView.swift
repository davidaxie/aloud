import Combine
import SwiftUI
import UIKit

/// The reading column: a TextKit 2 `UITextView` rendering the whole document as
/// one attributed string, with a sentence-range table for highlighting and
/// tap-to-play (R15).
///
/// Calm follow (R16): while following, the text scrolls only when the spoken
/// sentence leaves the `FollowBand` (18–70% of the visible height), then
/// glides once so it lands at 28%. A user scroll stops following, and nothing
/// re-engages it on a timer: only Play, a jump or Undo, the Follow chip
/// (`followRequest`) or a scroll that ends with the voice in view.
///
/// VoiceOver (R12a): the column is one element browsed by rotor (Chapters or
/// Pages, Paragraphs, Sentences). Its label is the sentence the rotor is on,
/// its value is always nil, and "Play from here" or a double-tap plays that
/// sentence through the same path as a tap. Nothing is built at open.
///
/// The end of the book (R24): at the end, the "· · ·" mark becomes a
/// colophon in one tail edit, fading in through a paper veil, and is then
/// what following and VoiceOver aim at.
///
/// The sentence highlight and the optional word underline are drawn by
/// `ReaderHighlightLayer` (`HighlightLayers`) beneath the text — never as
/// text attributes — so glyph metrics never change and the layout is
/// rock-steady while reading.
struct ReaderTextView: UIViewRepresentable {

    let content: DocContent
    /// Text books (bookshelf classics, .txt imports) group sentences by
    /// chapter, not by physical page: their groups open with a styled
    /// heading and never get "PAGE N" marks. PDFs keep their page marks.
    var isChapterBook = false
    /// Chapter starts for the Chapters (Pages) rotor.
    var navigation: ReaderNavigation? = nil
    let fontSize: CGFloat
    let activeSentence: Int
    /// Token index (into `tokenizeSentence` of the active sentence) of the word
    /// being spoken; -1 = none. Drives the color-only word tint. The
    /// word-highlight pref is folded in at the source (`ReaderScreen` passes
    /// -1 while the pref is off), so this view has a single gate to honor.
    let activeWord: Int
    /// Token index of the word being spoken whatever the Word highlight pref
    /// (`playback.currentWord`); -1 = none. Never drawn: it tells following
    /// where the voice is inside a sentence taller than the band
    /// (`FollowBand.followed`), so the end of a long sentence at a large
    /// text size isn't read under the player bar with the underline off.
    var followWord = -1
    /// Any change resumes following and brings the active sentence into the
    /// band: Play, a jump or Undo, or the Follow chip.
    var followRequest = 0
    /// How far the player bar reaches up this view, its paper under the
    /// home indicator included (`FollowBand.obscuredBottom`): the text runs
    /// under it, so the band is measured above it and recomputed when the
    /// chrome changes height.
    var obscuredBottom: CGFloat = 0
    /// R24: at the end of the book, the colophon that replaces the "· · ·"
    /// end mark; nil everywhere else. Appearing fades in, and a fresh
    /// column (a reopen) builds with it already in place.
    var colophon: ReaderColophon? = nil
    /// Where the voice is while the reader is NOT following and it is off
    /// screen (the Follow chip's arrow); nil otherwise.
    @Binding var voiceOffscreen: ReaderFollowDirection?
    /// True once any text sits under the top bar (content scrolled past its
    /// resting top); drives the hairline that frames the clipped first line.
    @Binding var textUnderTopBar: Bool
    /// A tap, and VoiceOver "Play from here" or double-tap: play from this
    /// sentence.
    let onTapSentence: (Int) -> Void
    var onMagicTap: () -> Void = {}

    func makeUIView(context: Context) -> ReaderUITextView {
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        context.coordinator.install(on: textView)
        return textView
    }

    func updateUIView(_ textView: ReaderUITextView, context: Context) {
        let coordinator = context.coordinator
        let obscuredBottomChanged = coordinator.parent.obscuredBottom != obscuredBottom
        coordinator.parent = self

        if coordinator.builtHash == content.contentHash, coordinator.builtFontSize != fontSize {
            // A text-size step keeps the reader's place: the voice while
            // following, else the passage at the top of the screen.
            // Following is left as it was (mirrors the Mac's changeTextSize).
            // The checks below then pick up anything else this update moved.
            coordinator.reflowKeepingPlace(fontSize: fontSize)
        } else if coordinator.builtHash != content.contentHash {
            coordinator.rebuild(content: content, fontSize: fontSize)
            // A fresh column starts on the voice.
            coordinator.lastFollowRequest = followRequest
            coordinator.isFollowing = true
            coordinator.setActiveSentence(activeSentence, scroll: false)
            // Re-apply the word tint from CURRENT state — while paused no
            // word tick arrives to restore it (mirrors rebuildForTraitChange).
            coordinator.setActiveWord(activeWord)
            // The placement aims at the spoken word in a tall sentence.
            coordinator.setSpokenWord(followWord, follows: false)
            Task { @MainActor in coordinator.placeActiveSentence() }
            return
        }

        // Before the follow request: Listen again clears the colophon, so
        // following then aims at sentence 0, not at the end mark.
        if coordinator.shownColophon != colophon {
            coordinator.setColophon(colophon, animated: true)
        }

        if coordinator.lastFollowRequest != followRequest {
            coordinator.lastFollowRequest = followRequest
            coordinator.setActiveSentence(activeSentence, scroll: false)
            coordinator.resumeFollowing()
        } else if coordinator.activeSentence != activeSentence {
            coordinator.setActiveSentence(activeSentence, scroll: true)
        }

        if coordinator.activeWordToken != activeWord {
            coordinator.setActiveWord(activeWord)
        }
        if coordinator.spokenWordToken != followWord {
            coordinator.setSpokenWord(followWord, follows: true)
        }

        if obscuredBottomChanged {
            coordinator.followIfNeeded(animated: true)
            coordinator.updateFollowChip()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        weak var textView: ReaderUITextView?

        private(set) var builtHash = ""
        private(set) var builtFontSize: CGFloat = 0
        /// The traits the built string was set and colored for. A trait
        /// change that leaves them as built rebuilds nothing; a Bold Text
        /// flip reflows every line.
        private(set) var builtLook: TraitLook?
        /// Whole-column builds, the costliest thing the reader makes (a
        /// trait flip must not pay for one it doesn't need). Test seam.
        private(set) var columnBuilds = 0
        private(set) var activeSentence = -1

        private var sentenceRanges: [NSRange] = []

        // End of the book (R24)
        /// The colophon the text shows in place of "· · ·"; nil = the mark.
        private(set) var shownColophon: ReaderColophon?
        /// The end mark's characters (the dots or the colophon), always the
        /// tail of the text, after the last sentence.
        private(set) var endMarkRange = NSRange(location: 0, length: 0)
        /// The paper-coloured cover the colophon fades in from, alive for
        /// `Theme.Motion.colophon` after it appears on screen.
        private(set) var colophonVeil: UIView?

        /// Content height of the last layout pass; a jump means TextKit
        /// swapped estimated line heights wholesale under a still offset.
        private var lastContentHeight: CGFloat = 0
        /// The band's height at the last layout pass (bounds, insets and the
        /// player bar); a change re-checks the band.
        private var lastViewportHeight: CGFloat = 0

        // Calm follow (R16)
        /// The follow state and its decisions, with the cached active-sentence
        /// rect and the placement checks; this coordinator measures and moves
        /// the UITextView for it.
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
        /// The one in-flight glide; touches stop it where it is.
        private var glide: UIViewPropertyAnimator?
        /// Set when a touch lands: a tap that began on moving text only
        /// stops it (R15).
        private var touchBeganWhileScrolling = false
        /// Between a flick's release and the end of its deceleration; a
        /// touch can stop the deceleration without a callback.
        private var deceleratingAfterDrag = false
        /// Every follow scroll, for the R16 budget.
        var programmaticScrollCount: Int { follow.programmaticScrollCount }
        /// The last direction published to `voiceOffscreen` (kept by the
        /// engine, not read back from the binding).
        var voiceOffscreen: ReaderFollowDirection? { follow.voiceOffscreen }
        /// Test seam.
        var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
        /// Test seam: whether a flick is still coasting. A view outside a
        /// window never decelerates.
        var isCoasting: (UIScrollView) -> Bool = { $0.isDecelerating }
        /// Test seam: whether the app is in the background, where iOS flips
        /// light/dark only to snapshot it for the app switcher.
        var isInBackground: @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }
        /// Hears the app become active, to catch a look change the
        /// background skipped (`rebuildForTraitChange`).
        private var activation: AnyCancellable?

        // VoiceOver (R12a)
        /// The sentence the rotor is on; nil = the playhead's. Cleared on
        /// focus loss and after playing.
        private(set) var accessibilitySentence: Int?

        #if DEBUG
        private let publishesProbe = UITestHooks.isUITestLaunch
        #endif

        // Word underline (drawn by ReaderHighlightLayer, never in textStorage)
        private(set) var activeWordToken = -1
        private var activeWordRange: NSRange?
        // The spoken word following tracks (`followWord`), underlined or not
        private(set) var spokenWordToken = -1
        private var spokenWordRange: NSRange?
        /// Where the last spoken word of a tall sentence sat, so a tick
        /// follows only when the voice moves on to a new line
        /// (`FollowBand.wordTickFollows`). Cleared with the sentence.
        private var lastSpokenWordRect: CGRect?
        /// Absolute token NSRanges per sentence (nil for whitespace tokens),
        /// derived lazily from the same tokenizer the playback side uses so
        /// token indices always agree. Small; cleared when it grows.
        private var wordRangeCache: [Int: [NSRange?]] = [:]

        init(parent: ReaderTextView) {
            self.parent = parent
        }

        // MARK: Setup

        /// Everything the view needs before its first update. Builds nothing
        /// from the content: no string, no rotor items, no per-sentence
        /// elements, so a 60,000-sentence book opens as fast as a short one.
        func install(on textView: ReaderUITextView) {
            textView.isEditable = false
            textView.isSelectable = false
            textView.backgroundColor = .clear
            textView.showsHorizontalScrollIndicator = false
            textView.contentInsetAdjustmentBehavior = .automatic
            textView.textContainer.lineFragmentPadding = 0
            textView.adjustsFontForContentSizeCategory = false
            textView.accessibilityIdentifier = "reader.text"
            textView.delegate = self

            let tap = UITapGestureRecognizer(target: self, action: #selector(Coordinator.handleTap(_:)))
            tap.delegate = self
            textView.addGestureRecognizer(tap)

            self.textView = textView
            textView.onTraitChange = { [weak self] in self?.rebuildForTraitChange() }
            textView.onLayout = { [weak self] in self?.handleLayout() }
            activation = NotificationCenter.default
                .publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.appBecameActive() } }

            textView.accessibilityHint = ReaderRotor.textHint
            textView.accessibilityUserInputLabels = ["Text"]
            textView.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: ReaderRotor.playFromHere) { [weak self] _ in
                    self?.playFromHere() ?? false
                },
            ]
            textView.accessibilitySentenceText = { [weak self] in self?.spokenSentence }
            textView.accessibilityHintText = { [weak self] in self?.colophonHint }
            // Over the colophon double-tap does nothing, and says it was
            // handled: a false would have VoiceOver fall back to a tap at
            // the column's center, which plays whatever sentence is drawn
            // there. The Play from here action still reports false.
            textView.onActivate = { [weak self] in
                guard let self else { return false }
                if self.readsColophon { return true }
                return self.playFromHere()
            }
            textView.onMagicTap = { [weak self] in
                guard let self else { return false }
                self.parent.onMagicTap()
                return true
            }
            textView.onAccessibilityFocusLost = { [weak self] in self?.accessibilitySentence = nil }
            textView.onAccessibilityScroll = { [weak self] in self?.userTookOverScroll() }
            textView.onAccessibilityScrollIgnored = { [weak self] in self?.userScrollEnded() }

            #if DEBUG
            if publishesProbe { ReaderFollowProbe.shared.reset() }
            #endif
        }

        // MARK: Building

        func rebuild(content: DocContent, fontSize: CGFloat) {
            guard let textView else { return }
            cancelGlide()
            let built = Self.makeAttributedString(content: content, fontSize: fontSize,
                                                  isChapterBook: parent.isChapterBook,
                                                  colophon: parent.colophon,
                                                  traits: textView.traitCollection)
            textView.attributedText = built.string
            sentenceRanges = built.sentenceRanges
            // A fresh column, a reopen included, shows the colophon in place:
            // only an end reached on screen fades in (`setColophon`).
            shownColophon = parent.colophon
            endMarkRange = built.endMarkRange
            removeColophonVeil()
            builtHash = content.contentHash
            builtFontSize = fontSize
            builtLook = TraitLook(textView.traitCollection)
            columnBuilds += 1
            textView.highlightLayer.clearSentence()
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
            // Rotor items are searched on demand; only the list is set here.
            textView.accessibilityCustomRotors = ReaderRotor.available(content: content,
                                                                       navigation: parent.navigation)
                .map(makeRotor)
            if let rotorSentence = accessibilitySentence, !content.sentences.indices.contains(rotorSentence) {
                accessibilitySentence = nil
            }
        }

        /// Times the column took a new look in place, with no rebuild
        /// (`recolor`); for tests.
        private(set) var columnRecolors = 0

        /// Light/dark and Increase Contrast only recolor: the text's colors
        /// resolve as they draw and each rule carries every look
        /// (`ReaderInk.live(traits:)`), so the column redraws with no edit.
        /// TextKit keeps its layout, and nothing is laid out again from the
        /// top of the book, a long main-thread stall deep in one (the Mac's
        /// G012). Bold Text swaps the serif's face and reflows the whole
        /// book: that one rebuilds, keeping the reader's place
        /// (`reflowKeepingPlace`).
        ///
        /// Only a look the column wasn't set for changes anything, and never
        /// in the background: there iOS flips light/dark and back just to
        /// take the app switcher's snapshots. A real change made meanwhile
        /// is caught when the app is active again (`appBecameActive`).
        func rebuildForTraitChange() {
            guard builtHash == parent.content.contentHash, let textView else { return }
            let look = TraitLook(textView.traitCollection)
            guard look != builtLook, !isInBackground() else { return }
            guard look.boldText != builtLook?.boldText else {
                recolor(for: look)
                return
            }
            reflowKeepingPlace(fontSize: parent.fontSize)
        }

        /// Takes `look` in place: each rule swaps to its variant for the
        /// new traits (no storage edit), the page redraws, and the layers
        /// colored once (the highlight, the underline, a colophon's veil)
        /// take the new colors.
        private func recolor(for look: TraitLook) {
            guard let textView else { return }
            builtLook = look
            columnRecolors += 1
            let traits = textView.traitCollection
            let storage = textView.textStorage
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let asset = attachment.image?.imageAsset else { return }
                attachment.image = asset.image(with: traits)
            }
            Self.redraw(textView)
            renderSentenceHighlight(animated: false)
            renderWordUnderline(animated: false)
            colophonVeil?.backgroundColor = UIColor(Theme.bg).resolvedColor(with: traits)
        }

        /// `view` and every view in it: TextKit 2 draws its fragments in
        /// views of its own.
        private static func redraw(_ view: UIView) {
            view.setNeedsDisplay()
            view.subviews.forEach(redraw)
        }

        /// Rebuilds for a change that reflows the book (a text-size step,
        /// Bold Text) and keeps the reader's place: the voice while
        /// following (the spoken word in a tall sentence), else the passage
        /// at the top of the screen, laid out for real first (`putBack`).
        /// Following is left as it was, so a reader who scrolled away to
        /// another passage is never thrown back to the voice.
        func reflowKeepingPlace(fontSize: CGFloat) {
            guard let textView else { return }
            let following = isFollowing
            let active = activeSentence
            let oldSize = builtFontSize
            let offset = textView.contentOffset
            // The offset into the anchor's line scales with the text.
            let anchor = following ? nil : viewportAnchor().map {
                (character: $0.character, below: oldSize > 0 ? $0.below * fontSize / oldSize : $0.below)
            }
            rebuild(content: parent.content, fontSize: fontSize)
            if !following {
                follow.pendingPlacement = false   // the passage is put back instead
                putBack(anchor, else: offset)
            }
            setActiveSentence(active, scroll: false)
            setActiveWord(parent.activeWord)
            setSpokenWord(parent.followWord, follows: false)
            if following {
                // Back on the voice, placed once the new string has settled.
                Task { @MainActor [weak self] in self?.placeActiveSentence() }
            }
        }

        /// The app is active again: rebuilds for a look that changed while
        /// it was in the background, else nothing.
        func appBecameActive() {
            rebuildForTraitChange()
        }

        /// The character at the top of the viewport and how far below its
        /// line's top the viewport starts, on the layout as it stands.
        private func viewportAnchor() -> (character: Int, below: CGFloat)? {
            guard let textView, let viewport = viewport(),
                  let character = characterOffset(at: CGPoint(x: textView.textContainerInset.left + 1,
                                                              y: viewport.minY + 1)),
                  let rect = boundingRect(for: NSRange(location: character, length: 1)) else { return nil }
            return (character, viewport.minY - rect.minY)
        }

        /// Puts `anchor` back at the top of the viewport after a rebuild.
        /// The rebuild dropped the layout above it, and TextKit 2 would
        /// frame the raw offset on estimated heights, thousands of points
        /// off deep in a book: the anchor is laid out for real first.
        private func putBack(_ anchor: (character: Int, below: CGFloat)?, else offset: CGPoint) {
            guard let textView else { return }
            let range = anchor.map { NSRange(location: $0.character, length: 1) }
            if let range, range.upperBound <= textView.textStorage.length { ensureLayout(through: range) }
            guard let anchor, let range, let rect = boundingRect(for: range) else {
                textView.setContentOffset(offset, animated: false)
                return
            }
            let y = max(rect.minY + anchor.below - textView.adjustedContentInset.top, restingOffsets().lowerBound)
            textView.setContentOffset(CGPoint(x: offset.x, y: y), animated: false)
        }

        // MARK: End of the book (R24)

        /// Swaps the end mark for `colophon` (or back to "· · ·") in ONE tail
        /// edit of the text storage: every sentence range stays valid and
        /// nothing above the mark re-lays out. Never through the TextKit 1
        /// `layoutManager`, which would drop the view out of TextKit 2.
        /// While following, the colophon is brought into the band like the
        /// voice. Appearing with `animated` fades in through a paper veil
        /// (opacity only, so Reduce Motion keeps it), framed AFTER that
        /// follow scroll: a jump makes UIKit lay out the lines it lands on,
        /// and real heights replace the estimates above the end mark, so a
        /// veil framed before it would sit off the colophon until the next
        /// layout pass reframed it.
        func setColophon(_ colophon: ReaderColophon?, animated: Bool) {
            guard colophon != shownColophon, let textView else { return }
            let storage = textView.textStorage
            // Only once a column is built: the mark is always its tail.
            guard endMarkRange.length > 0, NSMaxRange(endMarkRange) == storage.length else { return }
            let appearing = shownColophon == nil && colophon != nil
            let mark = Self.makeEndMark(colophon: colophon, fontSize: builtFontSize,
                                        traits: textView.traitCollection)
            storage.replaceCharacters(in: endMarkRange, with: mark)
            endMarkRange = NSRange(location: endMarkRange.location, length: mark.length)
            shownColophon = colophon
            follow.cachedActiveRect = nil   // the follow target moved (`followRange`)
            removeColophonVeil()
            if colophon != nil, isFollowing { followIfNeeded(animated: true) }
            if appearing, animated { fadeInColophon() }
            updateFollowChip()
        }

        /// Covers the new colophon with the page's own paper and fades the
        /// cover out, so the colophon fades in without moving.
        private func fadeInColophon() {
            guard let textView, let rect = boundingRect(for: endMarkRange) else { return }
            let veil = UIView(frame: CGRect(x: 0, y: rect.minY, width: textView.bounds.width, height: rect.height))
            veil.backgroundColor = UIColor(Theme.bg).resolvedColor(with: textView.traitCollection)
            veil.isUserInteractionEnabled = false
            veil.isAccessibilityElement = false
            veil.accessibilityElementsHidden = true
            textView.addSubview(veil)
            colophonVeil = veil
            UIView.animate(withDuration: Theme.Motion.colophon, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                veil.alpha = 0
            } completion: { [weak self, weak veil] _ in
                guard let veil else { return }
                veil.removeFromSuperview()
                if self?.colophonVeil === veil { self?.colophonVeil = nil }
            }
        }

        private func removeColophonVeil() {
            colophonVeil?.removeFromSuperview()
            colophonVeil = nil
        }

        /// Layout moved the text under a fade in flight: keep the cover on
        /// the colophon.
        private func reframeColophonVeil() {
            guard let veil = colophonVeil, let textView,
                  let rect = boundingRect(for: endMarkRange) else { return }
            let frame = CGRect(x: 0, y: rect.minY, width: textView.bounds.width, height: rect.height)
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
            renderSentenceHighlight(animated: changed)

            if scroll && isFollowing { followIfNeeded(animated: true) }
            updateFollowChip()
        }

        /// Draws the active sentence in the highlight layer beneath the text.
        /// Never touches `textStorage`: the text never re-lays out as the
        /// highlight moves.
        private func renderSentenceHighlight(animated: Bool) {
            guard let textView else { return }
            guard sentenceRanges.indices.contains(activeSentence) else {
                textView.highlightLayer.clearSentence()
                return
            }
            let traits = textView.traitCollection
            textView.highlightLayer.showSentence(
                segments(for: sentenceRanges[activeSentence]),
                fill: UIColor(Theme.highlightBg).resolvedColor(with: traits),
                mark: UIColor(Theme.accent).resolvedColor(with: traits),
                gutterX: textView.textContainerInset.left,
                animated: animated)
        }

        /// Word layer: an accent underline under the spoken word, drawn in
        /// the highlight layer. Glyph metrics never change. With `follows`,
        /// the underlined word is also the spoken word following tracks
        /// (`setSpokenWord`), as when Word highlight is on.
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

        /// The spoken word (`followWord`), drawn or not. Through a sentence
        /// taller than the band, following keeps it on screen
        /// (`FollowBand.followed`), and a tick that `follows` re-checks the
        /// band only when the voice has moved on to a new line
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
                  let sentence = activeSentenceRect(), let viewport = viewport(),
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

        /// The spoken word's laid-out rect in content coordinates, cached
        /// with the sentence's (`cachedWordRect`) so the per-frame chip
        /// check never measures; nil without one.
        func spokenWordRect() -> CGRect? {
            if let cached = follow.cachedWordRect { return cached }
            guard let range = spokenWordRange else { return nil }
            let union = segments(for: range).reduce(CGRect.null) { $0.union($1.frame) }
            guard !union.isNull else { return nil }
            follow.cachedWordRect = union
            return union
        }

        /// The underlined word's laid-out rect in content coordinates, like
        /// `viewport()`; nil without one.
        func activeWordRect() -> CGRect? {
            guard let range = activeWordRange else { return nil }
            let union = segments(for: range).reduce(CGRect.null) { $0.union($1.frame) }
            return union.isNull ? nil : union
        }

        private func renderWordUnderline(animated: Bool) {
            guard let textView else { return }
            guard let range = activeWordRange else {
                textView.highlightLayer.clearWord()
                return
            }
            textView.highlightLayer.showWord(
                segments(for: range),
                color: UIColor(Theme.accentStrong).resolvedColor(with: textView.traitCollection),
                animated: animated)
        }

        /// Geometry changed under the highlight (relayout, rotation, estimated
        /// heights resolving): redraw in place, no crossfade.
        private func refreshHighlightGeometry() {
            renderSentenceHighlight(animated: false)
            renderWordUnderline(animated: false)
        }

        /// Laid-out line pieces of `range` in content coordinates.
        private func segments(for range: NSRange) -> [HighlightLayers.Segment] {
            column?.segments(for: range) ?? []
        }

        /// Absolute NSRanges of sentence `id`'s tokens (nil = whitespace),
        /// from the same tokenizer the playback side uses, cached per
        /// sentence (`ReaderColumnLayout.wordRanges`).
        private func wordRanges(for id: Int) -> [NSRange?]? {
            ReaderColumnLayout.wordRanges(for: id, sentenceRanges: sentenceRanges,
                                          sentences: parent.content.sentences, cache: &wordRangeCache)
        }

        // MARK: Calm follow (R16)

        /// The visible content rect the band is measured in: under the top
        /// inset and above whichever is taller, the bottom inset or the
        /// player bar the text runs beneath.
        func viewport() -> CGRect? {
            guard let textView else { return nil }
            let inset = textView.adjustedContentInset
            let bottom = max(inset.bottom, parent.obscuredBottom)
            return CGRect(x: 0, y: textView.contentOffset.y + inset.top,
                          width: textView.bounds.width,
                          height: max(textView.bounds.height - inset.top - bottom, 0))
        }

        /// While following: a sentence that has left the band glides (or,
        /// under Reduce Motion and past one viewport, jumps) to the landing
        /// line. Never moves under a finger.
        func followIfNeeded(animated: Bool) {
            guard isFollowing, let textView, !textView.isTracking, !textView.isDragging,
                  let sentence = activeSentenceRect(), let viewport = viewport() else { return }
            let rect = followedRect(sentence: sentence, in: viewport)
            guard !FollowBand.contains(rect, in: viewport),
                  let target = rect == sentence ? landingTarget() : landingOffset(for: rect) else { return }
            // Nothing within a point: pinned at an end of the text.
            switch ReaderFollowEngine.move(to: target, in: scrollState(viewport: viewport),
                                           animated: animated, reaim: false) {
            case .none: return
            case .glide(let y): scroll(toY: y, animated: true)
            case .jump(let y, _): scroll(toY: y, animated: false)
            }
        }

        /// `FollowBand.followed` for the active sentence: the spoken word is
        /// measured only for a sentence taller than the band. What every
        /// follow decision judges: the band, a resume, a placement, a
        /// scroll's end and the Follow chip.
        private func followedRect(sentence: CGRect, in viewport: CGRect) -> CGRect {
            guard shownColophon == nil, FollowBand.isTall(sentence, in: viewport) else { return sentence }
            return FollowBand.followed(sentence: sentence, word: spokenWordRect(), in: viewport)
        }

        /// Play, a jump, Undo or the Follow chip: follow again and bring the
        /// active sentence into the band (in a tall one, the spoken word:
        /// `followedRect`). A sentence already in the band stays put.
        func resumeFollowing() {
            follow.resume()   // the voice owns the scroll again
            defer { updateFollowChip() }
            guard let textView, !textView.isTracking, !textView.isDragging else { return }
            // Following takes the scroll back from a flick still coasting.
            stopDeceleration()
            guard let viewport = viewport(), var rect = measureActiveSentenceRect() else { return }
            // On screen, the sentence is measured where it's drawn: a tapped
            // line, a rotor stop. Laying the book out from its start would
            // move it under a still offset, from TextKit's estimate to its
            // real y (after a scroll-indicator drag into text not laid out
            // yet), and a line the reader saw in the band would jump. Off
            // screen, a deep jump must land on CONFIRMED geometry, not on
            // estimated heights of everything above it.
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

        /// Puts the active sentence on the landing line without motion (a
        /// fresh column, a reflow), then verifies on every layout pass.
        func placeActiveSentence() {
            guard isFollowing, let textView, !textView.isTracking, !textView.isDragging else { return }
            follow.pendingReveal = nil
            ensureLayoutThroughActiveSentence()
            follow.startPlacementCheck()
            if let target = landingTarget(), abs(target - textView.contentOffset.y) > 1 {
                jump(toY: target) { self.landingTarget() }
            }
            updateFollowChip()
        }

        /// The contentOffset.y that puts the active sentence (or the shown
        /// colophon, `followRange`) on the landing line under CURRENT
        /// geometry, or in a tall sentence the spoken word once following
        /// tracks it (`followedRect`), so a resume or a reflow mid-sentence
        /// never parks that word under the player bar; nil while its layout
        /// can't resolve. Refreshes the cached sentence and word rects.
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

        /// The scroll view as the follow decisions see it, with the band
        /// measured in `viewport`.
        private func scrollState(viewport: CGRect) -> ReaderScrollState {
            ReaderScrollState(contentOffsetY: textView?.contentOffset.y ?? 0, viewport: viewport,
                              restingRange: restingOffsets(), reduceMotion: reduceMotion())
        }

        /// Every contentOffset.y the text can rest at: from its top under
        /// the top inset to its end above the bottom inset.
        private func restingOffsets() -> ClosedRange<CGFloat> {
            guard let textView else { return 0...0 }
            let inset = textView.adjustedContentInset
            let lowest = -inset.top
            let highest = max(laidOutHeight() + inset.bottom - textView.bounds.height, lowest)
            return lowest...highest
        }

        /// The text's height as TextKit has laid it out. `contentSize`
        /// trails it: UIKit refreshes that in the text canvas's layout pass,
        /// which runs after this view's own. A deep jump's layout pass grows
        /// the text by thousands of points (real line heights replacing
        /// estimates), so a landing clamped to `contentSize` stopped far
        /// short of the sentence, and the next pass took that for placed.
        /// TextKit's own figure catches up as soon as the offset moves (see
        /// `jump(toY:reaim:)`).
        private func laidOutHeight() -> CGFloat {
            guard let textView else { return 0 }
            return column?.laidOutHeight(bottomInset: textView.textContainerInset.bottom)
                ?? textView.contentSize.height
        }

        /// A placement without motion: one counted scroll. Moving the offset
        /// is what makes UIKit lay out the lines newly on screen, and only
        /// then does TextKit refresh the laid-out height that an
        /// ensureLayout pass grew. A landing the old height clamped short is
        /// re-aimed at once, as a correction of the same scroll.
        private func jump(toY y: CGFloat, reaim: () -> CGFloat?) {
            guard let textView else { return }
            scroll(toY: y, animated: false)
            if let settled = reaim(), abs(settled - textView.contentOffset.y) > 1 {
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: settled), animated: false)
            }
        }

        /// Every follow, placement and reveal goes through here, so the R16
        /// budget counts them all.
        private func scroll(toY y: CGFloat, animated: Bool) {
            guard let textView else { return }
            follow.noteScroll()
            #if DEBUG
            if publishesProbe { ReaderFollowProbe.shared.noteScroll() }
            #endif
            stopDeceleration()
            if animated {
                startGlide(toY: y)
            } else {
                stopGlideInPlace()
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
            }
        }

        /// One 0.45 s glide on the (0.4, 0, 0.2, 1) curve. It stays
        /// interruptible: a touch or a drag stops it where it is.
        private func startGlide(toY y: CGFloat) {
            guard let textView else { return }
            stopGlideInPlace()
            let animator = UIViewPropertyAnimator(duration: FollowBand.glideDuration,
                                                  timingParameters: FollowBand.timingParameters())
            animator.isUserInteractionEnabled = true
            animator.addAnimations {
                textView.contentOffset = CGPoint(x: textView.contentOffset.x, y: y)
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, let animator, self.glide === animator else { return }
                self.glide = nil
                self.updateFollowChip()
            }
            glide = animator
            animator.startAnimation()
        }

        /// Stops a glide where the text is on screen right now. Stopping the
        /// animator alone would snap to its end (the model value).
        private func stopGlideInPlace() {
            guard let animator = glide else { return }
            glide = nil
            let onScreen = textView?.layer.presentation()?.bounds.origin
            if animator.state == .active { animator.stopAnimation(true) }
            if let textView, let onScreen {
                textView.setContentOffset(onScreen, animated: false)
            }
        }

        /// A rebuild replaces the text under a glide: drop it without
        /// pinning an offset that no longer means anything.
        private func cancelGlide() {
            if let glide, glide.state == .active { glide.stopAnimation(true) }
            glide = nil
        }

        /// Whether a follow glide is moving the text right now.
        var isGliding: Bool { glide?.isRunning == true }

        /// Stops a flick's coast where it is. Left running, it keeps writing
        /// the offset under a glide (the voice ends wherever the flick does),
        /// and a jump can halt it without the end callback, so the stale flag
        /// would swallow the next still tap as "stopping a scroll" (R15).
        private func stopDeceleration() {
            guard let textView else { return }
            let coasting = isCoasting(textView)
            deceleratingAfterDrag = false
            guard coasting else { return }
            // Stopped mid-bounce, UIKit skips its spring back into range, so
            // stop at the nearest end: never bare paper past the text.
            let range = restingOffsets()
            let y = min(max(textView.contentOffset.y, range.lowerBound), range.upperBound)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
        }

        /// A drag, a scroll-to-top or a VoiceOver scroll: stop following.
        func userTookOverScroll() {
            stopGlideInPlace()
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

        /// Runs on every scroll frame, so it must never force TextKit layout:
        /// the sentence and word rects come from the cache (measured at most
        /// once per sentence, word or relayout) and the rest is bounds
        /// arithmetic.
        func updateFollowChip() {
            guard let textView else { return }
            var direction: ReaderFollowDirection?
            if let rect = activeSentenceRect(), let viewport = viewport() {
                direction = follow.chipDirection(voice: followedRect(sentence: rect, in: viewport), in: viewport)
                #if DEBUG
                if publishesProbe {
                    let onScreen = rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
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

        /// After a (re)build, a reflow or a jump without motion, keep
        /// re-placing on each layout pass until the active sentence's
        /// geometry truly resolves (see `pendingPlacement`).
        ///
        /// The same pass watches content height: a jump means TextKit
        /// swapped estimated line heights wholesale (accessibility snapshot,
        /// deep layout resolving), which moves the content under a still
        /// offset without any scroll callback. While following, that
        /// re-checks the band; either way the cached sentence rect is stale.
        func handleLayout() {
            guard let textView else { return }
            let height = textView.contentSize.height
            if height != lastContentHeight {
                follow.cachedActiveRect = nil
                refreshHighlightGeometry()
                if isFollowing, !follow.pendingPlacement, lastContentHeight > 0 {
                    followIfNeeded(animated: false)
                }
                lastContentHeight = height
            }

            let viewportHeight = viewport()?.height ?? 0
            if viewportHeight != lastViewportHeight {
                let resized = lastViewportHeight > 0
                lastViewportHeight = viewportHeight
                if resized, isFollowing, !follow.pendingPlacement {
                    followIfNeeded(animated: !reduceMotion())
                }
            }

            reframeColophonVeil()
            verifyPlacement()
        }

        /// Ends a placement or rotor-stop check and shows the chip it held.
        private func endPlacementCheck() {
            follow.endPlacementCheck()
            updateFollowChip()
        }

        /// One layout pass's check of a placement (`pendingPlacement`) or a
        /// rotor stop (`pendingReveal`) put in place without motion. A pass
        /// that finds it off re-places it. A pass that finds it in place
        /// ends the check only once the text's laid-out height has held
        /// since the pass before: this view lays out BEFORE UIKit lays out
        /// the lines newly on screen and refreshes `contentSize`, which can
        /// still move a landing, so it asks for another pass. Ends after
        /// `placementPassLimit` passes in any case.
        private func verifyPlacement() {
            guard follow.isCheckingPlacement,
                  let textView, glide == nil,
                  !textView.isTracking, !textView.isDragging,
                  textView.bounds.height > 0 else { return }
            let check = checkPlacement()
            if case .unresolved = check { return }   // no layout to measure yet
            // Steady: the laid-out height held since the pass before.
            switch follow.placementPass(check, laidOutHeight: laidOutHeight()) {
            case .correct(let settled):
                // A correction of a placement already counted, so no `scroll`.
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: settled), animated: false)
                // An offset set inside layoutSubviews doesn't mark the view
                // for layout: ask for the pass that confirms the correction
                // (still bounded by placementPassLimit).
                textView.setNeedsLayout()
            case .end:
                endPlacementCheck()
                return
            case .confirm:
                textView.setNeedsLayout()   // confirm on the next pass
            }
            if follow.placementPassesSpent { endPlacementCheck() }
        }

        /// Measures the pending placement on the layout as it stands; when
        /// it's off, confirms the layout up to it and says where it goes.
        private func checkPlacement() -> ReaderFollowEngine.PlacementCheck {
            guard let textView else { return .unresolved }
            let settled: CGFloat?
            if let id = follow.pendingReveal {
                guard sentenceRanges.indices.contains(id), revealOffset(for: id) != nil else { return .holds }
                ensureLayout(through: sentenceRanges[id])
                settled = revealOffset(for: id)
            } else {
                guard let target = landingTarget() else { return .unresolved }
                guard abs(target - textView.contentOffset.y) > 1 else { return .holds }
                ensureLayoutThroughActiveSentence()
                guard let confirmed = landingTarget() else { return .unresolved }
                settled = confirmed
            }
            guard let settled, abs(settled - textView.contentOffset.y) > 1 else { return .holds }
            return .moveTo(settled)
        }

        // MARK: Scroll view delegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userTookOverScroll()
            deceleratingAfterDrag = false
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            deceleratingAfterDrag = decelerate
            if !decelerate { userScrollEnded() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            deceleratingAfterDrag = false
            userScrollEnded()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            userTookOverScroll()
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            userScrollEnded()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            userScrollEnded()
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            if isFollowing { followIfNeeded(animated: true) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Programmatic scrolls move content under the bar too.
            updateTextUnderTopBar(scrollView)
            updateFollowChip()
        }

        /// Bounds arithmetic only — safe on every scroll frame. The first
        /// text line rests `textContainerInset.top` below the bar, so the
        /// rule appears only once content has scrolled past that gap.
        private func updateTextUnderTopBar(_ scrollView: UIScrollView) {
            let restingTop = -scrollView.adjustedContentInset.top
            let inset = (scrollView as? UITextView)?.textContainerInset.top ?? 0
            let under = scrollView.contentOffset.y > restingTop + inset
            if under != parent.textUnderTopBar {
                let binding = parent.$textUnderTopBar
                Task { @MainActor in binding.wrappedValue = under }
            }
        }

        // MARK: Tap → sentence (R15)

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            touchLanded()
            return true
        }

        /// A finger is down on the text, before any tap or drag resolves.
        func touchLanded() {
            let gliding = isGliding
            touchBeganWhileScrolling = (textView.map(isCoasting) ?? false) || deceleratingAfterDrag || gliding
            if gliding {
                // Stopping a glide is the reader taking the scroll: it may
                // stop short with the voice still off screen, so following
                // survives only if the voice is in view; else the chip shows.
                userTookOverScroll()
                userScrollEnded()
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView else { return }
            tapEnded(at: gesture.location(in: textView))
        }

        /// The tap recognizer fired for the touch that `touchLanded` saw.
        func tapEnded(at point: CGPoint) {
            let wasScrolling = touchBeganWhileScrolling
            touchBeganWhileScrolling = false
            handleTap(at: point, isDecelerating: wasScrolling)
        }

        /// A tap plays from the tapped sentence in any state, unless it
        /// landed on moving text: then it only stopped the scroll.
        func handleTap(at point: CGPoint, isDecelerating: Bool) {
            if isDecelerating {
                deceleratingAfterDrag = false
                userScrollEnded()
                return
            }
            guard let offset = characterOffset(at: point),
                  let id = ReaderColumnLayout.sentence(containing: offset, in: sentenceRanges) else { return }
            parent.onTapSentence(id)
        }

        // MARK: VoiceOver (R12a)

        /// True while the colophon is what VoiceOver reads (R12, R24): it
        /// shows and the rotor isn't on a sentence. A rotor step brings the
        /// sentence behaviour back.
        private var readsColophon: Bool { shownColophon != nil && accessibilitySentence == nil }

        /// The column's label: the colophon as one label at the end, else the
        /// rotor's sentence, else the playhead's.
        var spokenSentence: String? {
            if readsColophon, let shownColophon { return shownColophon.spokenText }
            let id = accessibilitySentence ?? activeSentence
            let sentences = parent.content.sentences
            return sentences.indices.contains(id) ? sentences[id].text : nil
        }

        /// "Play from here" and double-tap: the rotor's sentence (else the
        /// playhead's), through the tap path.
        @discardableResult
        func playFromHere() -> Bool {
            // The colophon is no sentence: nothing to play from (Play reads
            // Listen again).
            guard !readsColophon else { return false }
            let id = accessibilitySentence ?? activeSentence
            guard parent.content.sentences.indices.contains(id) else { return false }
            accessibilitySentence = nil
            parent.onTapSentence(id)
            return true
        }

        /// The column's hint over the colophon: none, since double-tap does
        /// nothing there. nil elsewhere keeps "Plays from this sentence".
        var colophonHint: String? { readsColophon ? "" : nil }

        private func makeRotor(_ rotor: ReaderRotor) -> UIAccessibilityCustomRotor {
            UIAccessibilityCustomRotor(name: rotor.name(listing: parent.navigation,
                                                        isChapterBook: parent.isChapterBook)) {
                [weak self] predicate in
                self?.rotorStep(rotor, forward: predicate.searchDirection == .next)
            }
        }

        /// One rotor flick: a binary search for the next item start, shown
        /// on screen and handed to VoiceOver as a text range of the column.
        private func rotorStep(_ rotor: ReaderRotor, forward: Bool) -> UIAccessibilityCustomRotorItemResult? {
            guard let textView,
                  let target = ReaderRotor.target(rotor, from: accessibilitySentence, anchor: rotorAnchor(),
                                                  forward: forward, content: parent.content,
                                                  navigation: parent.navigation) else { return nil }
            accessibilitySentence = target
            reveal(sentence: target)
            return UIAccessibilityCustomRotorItemResult(targetElement: textView,
                                                        targetRange: textRange(forSentence: target))
        }

        /// Where the first rotor step starts: the playhead while it is on
        /// screen, else the first sentence at the top of the screen.
        private func rotorAnchor() -> Int {
            guard let viewport = viewport() else { return max(activeSentence, 0) }
            if let rect = activeSentenceRect(), FollowBand.direction(of: rect, in: viewport) == nil {
                return activeSentence
            }
            // The top line may sit in a paragraph gap; look a little lower.
            return column?.sentence(nearTopOf: viewport, lineStep: builtFontSize, in: sentenceRanges)
                ?? max(activeSentence, 0)
        }

        /// Brings a rotor stop into the band without motion, and stops
        /// following, so the column doesn't scroll away while browsing. A
        /// far chapter is placed like a deep jump: measured on real layout,
        /// then checked on each layout pass until it holds.
        private func reveal(sentence id: Int) {
            userTookOverScroll()
            // A stop already in the band is where it's drawn: skip the whole-
            // book layout pass, which costs ~20 ms deep in Pepys per flick.
            guard revealOffset(for: id) != nil else { return }
            ensureLayout(through: sentenceRanges[id])
            if let target = revealOffset(for: id) {
                jump(toY: target) { self.revealOffset(for: id) }
                follow.startRevealCheck(id)
            }
            updateFollowChip()
        }

        /// The offset that puts rotor stop `id` on the landing line; nil
        /// while it sits in the band, or the text can't scroll that far.
        private func revealOffset(for id: Int) -> CGFloat? {
            guard let textView, sentenceRanges.indices.contains(id),
                  let rect = boundingRect(for: sentenceRanges[id]), let viewport = viewport(),
                  !FollowBand.contains(rect, in: viewport),
                  let target = landingOffset(for: rect),
                  abs(target - textView.contentOffset.y) > 1 else { return nil }
            return target
        }

        /// Sentence `id` as a text range, in UTF-16 offsets from the start.
        private func textRange(forSentence id: Int) -> UITextRange? {
            guard let textView, sentenceRanges.indices.contains(id) else { return nil }
            let range = sentenceRanges[id]
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length) else { return nil }
            return textView.textRange(from: start, to: end)
        }

        // MARK: TextKit 2 geometry

        /// The column's TextKit 2 geometry (`ReaderColumnLayout`) under the
        /// text container inset as it stands.
        private var column: ReaderColumnLayout? {
            guard let textView, let layoutManager = textView.textLayoutManager else { return nil }
            let inset = textView.textContainerInset
            return ReaderColumnLayout(textLayoutManager: layoutManager,
                                      origin: CGPoint(x: inset.left, y: inset.top))
        }

        private func characterOffset(at point: CGPoint) -> Int? {
            column?.characterOffset(at: point)
        }

        /// Cached bounding rect of the follow target, the active sentence or
        /// the shown colophon (see `cachedActiveRect` and `followRange`),
        /// in content coordinates like `viewport()`.
        func activeSentenceRect() -> CGRect? {
            if let cached = follow.cachedActiveRect { return cached }
            guard let range = followRange, let rect = boundingRect(for: range) else { return nil }
            follow.cachedActiveRect = rect
            return rect
        }

        /// What following and placement aim at: the colophon while it shows
        /// (so a reopen lands its top on the landing line and a natural end
        /// brings it into the band), else the active sentence. The sentence
        /// highlight always stays on `activeSentence`.
        private var followRange: NSRange? {
            if shownColophon != nil, endMarkRange.length > 0 { return endMarkRange }
            return sentenceRanges.indices.contains(activeSentence) ? sentenceRanges[activeSentence] : nil
        }

        /// The active sentence's rect measured again from the layout as it
        /// stands now, refreshing the cache. Deliberate moves and tests
        /// only, never per frame.
        func measureActiveSentenceRect() -> CGRect? {
            follow.cachedActiveRect = nil
            return activeSentenceRect()
        }

        /// `ensureLayout(through:)` for the active sentence, redrawing its
        /// highlight if that moved it. Deliberate moves and placement
        /// retries only, never per scroll frame.
        private func ensureLayoutThroughActiveSentence() {
            guard let range = followRange else { return }
            let drawnAt = measureActiveSentenceRect()
            ensureLayout(through: range)
            // Redraw only a highlight left at the estimate, so an unmoved
            // one keeps its crossfade.
            if measureActiveSentenceRect() != drawnAt { refreshHighlightGeometry() }
        }

        /// One-shot layout from the document start into the paragraph after
        /// `range`'s, so `range` sits on its real frame, not on estimated
        /// heights of everything above it (`ReaderColumnLayout`: the pass
        /// reaches one fragment past it).
        private func ensureLayout(through range: NSRange) {
            column?.ensureLayout(through: range)
        }

        private func boundingRect(for range: NSRange) -> CGRect? {
            column?.boundingRect(for: range)
        }

        // MARK: Attributed string

        /// The whole column, built by `ReaderColumnText` for `traits`, in
        /// ink that takes a light/dark or contrast change without a rebuild
        /// (`ReaderInk.live(traits:)`).
        static func makeAttributedString(content: DocContent, fontSize: CGFloat,
                                         isChapterBook: Bool = false,
                                         colophon: ReaderColophon? = nil,
                                         traits: UITraitCollection = .current)
            -> (string: NSAttributedString, sentenceRanges: [NSRange], endMarkRange: NSRange) {
            ReaderColumnText.makeAttributedString(content: content, fontSize: fontSize,
                                                  isChapterBook: isChapterBook, colophon: colophon,
                                                  bold: traits.legibilityWeight == .bold,
                                                  ink: .live(traits: traits))
        }

        /// The end of the text (`ReaderColumnText.makeEndMark`), in the same ink.
        static func makeEndMark(colophon: ReaderColophon?, fontSize: CGFloat,
                                traits: UITraitCollection) -> NSAttributedString {
            ReaderColumnText.makeEndMark(colophon: colophon, fontSize: fontSize,
                                         bold: traits.legibilityWeight == .bold,
                                         ink: .live(traits: traits))
        }
    }
}

// MARK: - UITextView subclass

/// Centers the measure (~640 pt max) inside at least the reader gutter,
/// keeps a deep bottom inset so the last lines can reach the landing line,
/// reports trait changes for dynamic-color rebuilds, and routes VoiceOver to
/// the coordinator (R12a).
final class ReaderUITextView: UITextView {
    /// Follow-along highlight, kept behind the text's own rendering views.
    /// `lazy` on purpose: this view is made through UIKit's
    /// `init(usingTextLayoutManager:)` factory, which bypasses Swift's
    /// stored-property initializers — a plain `let` would be a null pointer.
    private(set) lazy var highlightLayer = ReaderHighlightLayer()
    var onTraitChange: (@MainActor () -> Void)?
    /// Fired after every layout pass; the coordinator uses it to finish a
    /// placement once insets/bounds have actually settled.
    var onLayout: (@MainActor () -> Void)?

    // VoiceOver: the whole column is one element.
    /// The label: the sentence the rotor is on, never the whole book.
    var accessibilitySentenceText: (@MainActor () -> String?)?
    /// Double-tap: plays the rotor's sentence.
    var onActivate: (@MainActor () -> Bool)?
    var onMagicTap: (@MainActor () -> Bool)?
    var onAccessibilityFocusLost: (@MainActor () -> Void)?
    var onAccessibilityScroll: (@MainActor () -> Void)?
    /// A VoiceOver scroll that moved nothing (at an end of the text, or
    /// sideways): it ends at once.
    var onAccessibilityScrollIgnored: (@MainActor () -> Void)?

    /// The hint where it differs from the stored one: "" over the colophon
    /// (R24), whose double-tap does nothing; nil keeps the stored hint.
    var accessibilityHintText: (@MainActor () -> String?)?

    override var accessibilityLabel: String? {
        get { accessibilitySentenceText?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityHint: String? {
        get { accessibilityHintText?() ?? super.accessibilityHint }
        set { super.accessibilityHint = newValue }
    }

    /// Always nil: a text view's value is its whole text, and no value may
    /// carry a sentence index (R12e).
    override var accessibilityValue: String? {
        get { nil }
        set {}
    }

    /// Same rule for the attributed form, which a text view would otherwise
    /// fill from its whole attributed text.
    override var accessibilityAttributedValue: NSAttributedString? {
        get { nil }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? super.accessibilityActivate()
    }

    override func accessibilityPerformMagicTap() -> Bool {
        onMagicTap?() ?? false
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        onAccessibilityFocusLost?()
    }

    /// A three-finger scroll is the user taking over, like a drag. One that
    /// can't move the text gets no scroll-end callback, so it ends here:
    /// following comes back while the voice is in view, as after a drag.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onAccessibilityScroll?()
        let scrolled = super.accessibilityScroll(direction)
        if !scrolled { onAccessibilityScrollIgnored?() }
        return scrolled
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontal = max(Theme.Space.sheetGutter, (bounds.width - 640) / 2)
        let bottom = UIScreen.main.bounds.height * 0.45
        let inset = UIEdgeInsets(top: Theme.Space.xl, left: horizontal,
                                 bottom: bottom, right: horizontal)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        if highlightLayer.superview !== self {
            insertSubview(highlightLayer, at: 0)
        } else if subviews.first !== highlightLayer {
            sendSubviewToBack(highlightLayer)
        }
        let highlightFrame = CGRect(x: 0, y: 0, width: bounds.width,
                                    height: max(contentSize.height, bounds.height))
        if highlightLayer.frame != highlightFrame {
            highlightLayer.frame = highlightFrame
        }
        onLayout?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Light/dark and Increase Contrast both change resolved colors;
        // Bold Text changes the serif's face.
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast
            || previousTraitCollection?.legibilityWeight != traitCollection.legibilityWeight {
            onTraitChange?()
        }
    }
}

// MARK: - Trait look

/// What the column's string is set and colored for: light/dark, Increase
/// Contrast and Bold Text (which also swaps the serif's face).
struct TraitLook: Equatable {
    let style: UIUserInterfaceStyle
    let contrast: UIAccessibilityContrast
    let boldText: Bool

    /// Unspecified reads as what dynamic colors resolve it to (light,
    /// normal contrast), so a view that gains a trait environment later is
    /// not a new look.
    init(_ traits: UITraitCollection) {
        style = traits.userInterfaceStyle == .dark ? .dark : .light
        contrast = traits.accessibilityContrast == .high ? .high : .normal
        boldText = traits.legibilityWeight == .bold
    }
}

// MARK: - Colors

extension ReaderInk {
    /// The theme's colors as they draw: each dynamic `UIColor` resolves
    /// for the traits it is drawn under (light or dark, Increase Contrast or
    /// not). Rule images can't resolve as they draw, so each carries all
    /// four looks in its image asset, shown for `traits`; a change of look
    /// swaps every rule for its variant (`Coordinator.recolor`) instead of
    /// setting the whole book again.
    static func live(traits: UITraitCollection) -> ReaderInk {
        var rules: [String: UIImageAsset] = [:]
        return ReaderInk(text: UIColor(Theme.text),
                         textMuted: UIColor(Theme.textMuted),
                         accent: UIColor(Theme.accent),
                         lineStrong: UIColor(Theme.lineStrong),
                         ruleImage: { size, color in
                             // One asset per rule size and color: a book's
                             // chapter openings share theirs.
                             let key = "\(size.width)x\(size.height)-\(ObjectIdentifier(color))"
                             if let asset = rules[key] { return asset.image(with: traits) }
                             let asset = ruleAsset(size: size, color: color, scale: traits.displayScale)
                             rules[key] = asset
                             return asset.image(with: traits)
                         })
    }

    /// A solid rule of `size` in `color`, drawn for each look a theme token
    /// tells apart.
    static func ruleAsset(size: CGSize, color: UIColor, scale: CGFloat) -> UIImageAsset {
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let look = UITraitCollection { traits in
                    traits.userInterfaceStyle = style
                    traits.accessibilityContrast = contrast
                }
                asset.register(PlatformRuleImage.make(size: size, color: color.resolvedColor(with: look),
                                                      scale: scale),
                               with: look)
            }
        }
        return asset
    }
}

// MARK: - Glide timing

extension FollowBand {
    /// The glide's (0.4, 0, 0.2, 1) curve as UIKit timing (`startGlide`).
    static func timingParameters() -> UICubicTimingParameters {
        UICubicTimingParameters(controlPoint1: glideCurve.0, controlPoint2: glideCurve.1)
    }
}
