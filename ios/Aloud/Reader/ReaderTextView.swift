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
/// `ReaderHighlightLayer` beneath the text — never as text attributes — so
/// glyph metrics never change and the layout is rock-steady while reading.
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

        if coordinator.builtHash != content.contentHash || coordinator.builtFontSize != fontSize {
            coordinator.rebuild(content: content, fontSize: fontSize)
            // A fresh column starts on the voice.
            coordinator.lastFollowRequest = followRequest
            coordinator.isFollowing = true
            coordinator.setActiveSentence(activeSentence, scroll: false)
            // Re-apply the word tint from CURRENT state — while paused no
            // word tick arrives to restore it (mirrors rebuildForTraitChange).
            coordinator.setActiveWord(activeWord)
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
        /// Whether the built string uses the Bold Text face; a flip reflows
        /// every line, so a trait rebuild can't keep the raw offset.
        private var builtBoldText = false
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

        /// Cached bounding rect of the active sentence, so the per-frame
        /// `updateFollowChip` never forces TextKit layout. Invalidated on
        /// sentence change, rebuild, and content-size change.
        private var cachedActiveRect: CGRect?
        /// Content height of the last layout pass; a jump means TextKit
        /// swapped estimated line heights wholesale under a still offset.
        private var lastContentHeight: CGFloat = 0
        /// The band's height at the last layout pass (bounds, insets and the
        /// player bar); a change re-checks the band.
        private var lastViewportHeight: CGFloat = 0

        // Calm follow (R16)
        /// Off from the moment the user scrolls; never back on by itself.
        var isFollowing = true
        var lastFollowRequest = 0
        /// The one in-flight glide; touches stop it where it is.
        private var glide: UIViewPropertyAnimator?
        /// Set when a touch lands: a tap that began on moving text only
        /// stops it (R15).
        private var touchBeganWhileScrolling = false
        /// Between a flick's release and the end of its deceleration; a
        /// touch can stop the deceleration without a callback.
        private var deceleratingAfterDrag = false
        /// Every follow scroll, for the R16 budget.
        private(set) var programmaticScrollCount = 0
        /// The last direction published to `voiceOffscreen`. Kept here, not
        /// read back from the binding, whose writes land a turn later.
        private(set) var voiceOffscreen: ReaderFollowDirection?
        /// Test seam.
        var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
        /// Test seam: whether a flick is still coasting. A view outside a
        /// window never decelerates.
        var isCoasting: (UIScrollView) -> Bool = { $0.isDecelerating }
        /// After a placement without motion, keep re-placing on every layout
        /// pass until the geometry resolves: insets and bounds settle a few
        /// passes after `attributedText` is set, and a deep target's
        /// estimated line heights shift once it is really laid out. Checked
        /// by `verifyPlacement`; cleared when the user scrolls.
        private var pendingPlacement = false
        /// Layout passes the current placement check may still take, and
        /// the text's laid-out height at its last pass (see
        /// `verifyPlacement`).
        private var placementPassesLeft = 0
        private var placementHeight: CGFloat?
        private static let placementPassLimit = 12

        // VoiceOver (R12a)
        /// The sentence the rotor is on; nil = the playhead's. Cleared on
        /// focus loss and after playing.
        private(set) var accessibilitySentence: Int?
        /// A rotor stop placed without motion, checked on each layout pass
        /// like `pendingPlacement` until it holds in the band. Cleared by a
        /// user scroll, following, or a rebuild.
        private var pendingReveal: Int?

        #if DEBUG
        private let publishesProbe = UITestHooks.isUITestLaunch
        #endif

        // Word underline (drawn by ReaderHighlightLayer, never in textStorage)
        private(set) var activeWordToken = -1
        private var activeWordRange: NSRange?
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

            textView.accessibilityHint = ReaderRotor.textHint
            textView.accessibilityUserInputLabels = ["Text"]
            textView.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: ReaderRotor.playFromHere) { [weak self] _ in
                    self?.playFromHere() ?? false
                },
            ]
            textView.accessibilitySentenceText = { [weak self] in self?.spokenSentence }
            textView.accessibilityHintText = { [weak self] in self?.colophonHint }
            textView.onActivate = { [weak self] in self?.playFromHere() ?? false }
            textView.onMagicTap = { [weak self] in
                guard let self else { return false }
                self.parent.onMagicTap()
                return true
            }
            textView.onAccessibilityFocusLost = { [weak self] in self?.accessibilitySentence = nil }
            textView.onAccessibilityScroll = { [weak self] in self?.userTookOverScroll() }

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
            builtBoldText = textView.traitCollection.legibilityWeight == .bold
            textView.highlightLayer.clearSentence()
            activeSentence = -1
            wordRangeCache = [:]
            activeWordRange = nil
            activeWordToken = -1
            cachedActiveRect = nil
            startPlacementCheck()
            pendingReveal = nil
            // Rotor items are searched on demand; only the list is set here.
            textView.accessibilityCustomRotors = ReaderRotor.available(content: content,
                                                                       navigation: parent.navigation)
                .map(makeRotor)
            if let rotorSentence = accessibilitySentence, !content.sentences.indices.contains(rotorSentence) {
                accessibilitySentence = nil
            }
        }

        /// Dynamic colors resolve at attribute-set time in some paths; rebuilding on
        /// light/dark flips keeps the column and highlight correct.
        func rebuildForTraitChange() {
            guard builtHash == parent.content.contentHash, let textView else { return }
            let active = activeSentence
            let offset = textView.contentOffset
            let wasBoldText = builtBoldText
            rebuild(content: parent.content, fontSize: parent.fontSize)
            // Light/dark and Increase Contrast only recolor (metrics are
            // identical), so the raw offset still frames the same passage.
            // Bold Text swaps the serif's face and reflows the whole book:
            // the old offset would land a paused reader on another passage.
            let reflowed = builtBoldText != wasBoldText
            if !reflowed {
                pendingPlacement = false   // trait flip preserves the offset instead
            }
            setActiveSentence(active, scroll: false)
            setActiveWord(parent.activeWord)
            if reflowed {
                // Back on the voice, placed once the new string has settled
                // (mirrors the size-change rebuild).
                isFollowing = true
                Task { @MainActor [weak self] in self?.placeActiveSentence() }
            } else {
                textView.setContentOffset(offset, animated: false)
            }
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
            cachedActiveRect = nil   // the follow target moved (`followRange`)
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
                cachedActiveRect = nil
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
        /// the highlight layer. Glyph metrics never change.
        func setActiveWord(_ token: Int) {
            guard textView != nil else { return }
            var newRange: NSRange?
            if token >= 0,
               let ranges = wordRanges(for: activeSentence),
               ranges.indices.contains(token) {
                newRange = ranges[token]   // nil for whitespace tokens
            }
            activeWordToken = token
            guard newRange != activeWordRange else { return }
            let slide = activeWordRange != nil
            activeWordRange = newRange
            renderWordUnderline(animated: slide)
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
        private func segments(for range: NSRange) -> [ReaderHighlightLayer.Segment] {
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let start = contentManager.location(layoutManager.documentRange.location,
                                                      offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return [] }
            layoutManager.ensureLayout(for: textRange)
            let inset = textView.textContainerInset
            var result: [ReaderHighlightLayer.Segment] = []
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
                _, frame, baseline, _ in
                result.append(.init(frame: frame.offsetBy(dx: inset.left, dy: inset.top),
                                    baseline: baseline))
                return true
            }
            return result
        }

        /// Absolute NSRanges of sentence `id`'s tokens (nil = whitespace),
        /// computed once per sentence from the same tokenizer offsets the
        /// playback side uses (concatenation is byte-identical, so walking
        /// UTF-16 lengths from the sentence range's location is exact).
        private func wordRanges(for id: Int) -> [NSRange?]? {
            if let cached = wordRangeCache[id] { return cached }
            guard sentenceRanges.indices.contains(id),
                  parent.content.sentences.indices.contains(id) else { return nil }

            let sentenceRange = sentenceRanges[id]
            let tokens = SentenceSegmenter.tokenizeSentence(parent.content.sentences[id].text)
            var ranges: [NSRange?] = []
            ranges.reserveCapacity(tokens.count)
            var location = sentenceRange.location
            for token in tokens {
                let length = token.text.utf16.count
                ranges.append(token.weight > 0 ? NSRange(location: location, length: length) : nil)
                location += length
            }
            // Paranoia: a mismatch means offsets are unsafe to apply.
            guard location == sentenceRange.location + sentenceRange.length else { return nil }

            if wordRangeCache.count > 16 { wordRangeCache.removeAll() }
            wordRangeCache[id] = ranges
            return ranges
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
                  let rect = activeSentenceRect(), let viewport = viewport(),
                  !FollowBand.contains(rect, in: viewport),
                  let target = landingTarget() else { return }
            let distance = target - textView.contentOffset.y
            guard abs(distance) > 1 else { return }   // pinned at an end of the text
            scroll(toY: target, animated: animated && FollowBand.glides(
                distance: distance, viewportHeight: viewport.height, reduceMotion: reduceMotion()))
        }

        /// Play, a jump, Undo or the Follow chip: follow again and bring the
        /// active sentence into the band. A sentence already in the band
        /// stays put.
        func resumeFollowing() {
            isFollowing = true
            pendingReveal = nil   // the voice owns the scroll again
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
            guard !FollowBand.contains(rect, in: viewport),
                  let target = landingOffset(for: rect) else { return }
            let distance = target - textView.contentOffset.y
            guard abs(distance) > 1 else { return }
            if FollowBand.glides(distance: distance, viewportHeight: viewport.height,
                                 reduceMotion: reduceMotion()) {
                scroll(toY: target, animated: true)
            } else {
                jump(toY: target) { self.landingTarget() }
                // A jump keeps verifying while estimated heights resolve.
                startPlacementCheck()
            }
        }

        /// Puts the active sentence on the landing line without motion (a
        /// fresh column, a reflow), then verifies on every layout pass.
        func placeActiveSentence() {
            guard isFollowing, let textView, !textView.isTracking, !textView.isDragging else { return }
            pendingReveal = nil
            ensureLayoutThroughActiveSentence()
            startPlacementCheck()
            if let target = landingTarget(), abs(target - textView.contentOffset.y) > 1 {
                jump(toY: target) { self.landingTarget() }
            }
            updateFollowChip()
        }

        /// The contentOffset.y that puts the active sentence (or the shown
        /// colophon, `followRange`) on the landing line under CURRENT
        /// geometry; nil while its layout can't resolve. Refreshes the
        /// cached sentence rect.
        private func landingTarget() -> CGFloat? {
            guard let range = followRange, let rect = boundingRect(for: range) else { return nil }
            cachedActiveRect = rect
            return landingOffset(for: rect)
        }

        private func landingOffset(for rect: CGRect) -> CGFloat? {
            guard let textView, let viewport = viewport() else { return nil }
            return FollowBand.landingContentOffsetY(sentenceMinY: rect.minY, viewport: viewport,
                                                    contentOffsetY: textView.contentOffset.y,
                                                    range: restingOffsets())
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
            guard let usage = textView.textLayoutManager?.usageBoundsForTextContainer,
                  usage.maxY > 0 else { return textView.contentSize.height }
            let inset = textView.textContainerInset
            return (usage.maxY + inset.top + inset.bottom).rounded(.up)
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
            programmaticScrollCount += 1
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
            isFollowing = false
            pendingPlacement = false   // don't fight the user
            pendingReveal = nil
            updateFollowChip()
        }

        /// A user scroll came to rest: following resumes only when the voice
        /// is in view.
        func userScrollEnded() {
            if let rect = activeSentenceRect(), let viewport = viewport(),
               FollowBand.direction(of: rect, in: viewport) == nil {
                isFollowing = true
            }
            updateFollowChip()
        }

        /// Runs on every scroll frame, so it must never force TextKit layout:
        /// the sentence rect comes from the cache (measured at most once per
        /// sentence/relayout) and the rest is bounds arithmetic.
        func updateFollowChip() {
            guard let textView else { return }
            var direction: ReaderFollowDirection?
            if let rect = activeSentenceRect(), let viewport = viewport() {
                if !isFollowing { direction = FollowBand.direction(of: rect, in: viewport) }
                #if DEBUG
                if publishesProbe {
                    let onScreen = rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
                    if ReaderFollowProbe.shared.activeRect != onScreen {
                        ReaderFollowProbe.shared.activeRect = onScreen
                    }
                }
                #endif
            }
            guard direction != voiceOffscreen else { return }
            voiceOffscreen = direction
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
                cachedActiveRect = nil
                refreshHighlightGeometry()
                if isFollowing, !pendingPlacement, lastContentHeight > 0 {
                    followIfNeeded(animated: false)
                }
                lastContentHeight = height
            }

            let viewportHeight = viewport()?.height ?? 0
            if viewportHeight != lastViewportHeight {
                let resized = lastViewportHeight > 0
                lastViewportHeight = viewportHeight
                if resized, isFollowing, !pendingPlacement {
                    followIfNeeded(animated: !reduceMotion())
                }
            }

            reframeColophonVeil()
            verifyPlacement()
        }

        /// Arms the layout-pass check of a placement without motion.
        private func startPlacementCheck() {
            pendingPlacement = true
            placementPassesLeft = Self.placementPassLimit
            placementHeight = nil
        }

        /// Arms the same check for a rotor stop placed without motion.
        private func startRevealCheck(_ id: Int) {
            pendingReveal = id
            placementPassesLeft = Self.placementPassLimit
            placementHeight = nil
        }

        private func endPlacementCheck() {
            pendingPlacement = false
            pendingReveal = nil
            updateFollowChip()
        }

        private enum PlacementCheck {
            case holds, unresolved, moveTo(CGFloat)
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
            guard pendingPlacement || pendingReveal != nil,
                  let textView, glide == nil,
                  !textView.isTracking, !textView.isDragging,
                  textView.bounds.height > 0 else { return }
            let check = checkPlacement()
            if case .unresolved = check { return }   // no layout to measure yet
            let height = laidOutHeight()
            let steady = placementHeight.map { abs($0 - height) < 0.5 } ?? false
            placementHeight = height
            placementPassesLeft -= 1
            switch check {
            case .moveTo(let settled):
                // A correction of a placement already counted, so no `scroll`.
                textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: settled), animated: false)
                // An offset set inside layoutSubviews doesn't mark the view
                // for layout: ask for the pass that confirms the correction
                // (still bounded by placementPassLimit).
                textView.setNeedsLayout()
            case .holds where steady:
                endPlacementCheck()
                return
            case .holds, .unresolved:
                textView.setNeedsLayout()   // confirm on the next pass
            }
            if placementPassesLeft <= 0 { endPlacementCheck() }
        }

        /// Measures the pending placement on the layout as it stands; when
        /// it's off, confirms the layout up to it and says where it goes.
        private func checkPlacement() -> PlacementCheck {
            guard let textView else { return .unresolved }
            let settled: CGFloat?
            if let id = pendingReveal {
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
                  let id = sentence(containing: offset) else { return }
            parent.onTapSentence(id)
        }

        private func sentence(containing offset: Int) -> Int? {
            guard let id = sentence(atOrAfter: offset), sentenceRanges[id].location <= offset else { return nil }
            return id
        }

        /// The first sentence that ends after `offset`: the one holding it,
        /// or the next one when `offset` falls between sentences (a
        /// paragraph break, a page mark).
        private func sentence(atOrAfter offset: Int) -> Int? {
            var low = 0, high = sentenceRanges.count
            while low < high {
                let mid = (low + high) / 2
                let range = sentenceRanges[mid]
                if range.location + range.length <= offset { low = mid + 1 } else { high = mid }
            }
            return low < sentenceRanges.count ? low : nil
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
            UIAccessibilityCustomRotor(name: rotor.name(for: parent.isChapterBook ? .text : .pdf)) {
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
            guard let textView, let viewport = viewport() else { return max(activeSentence, 0) }
            if let rect = activeSentenceRect(), FollowBand.direction(of: rect, in: viewport) == nil {
                return activeSentence
            }
            // The top line may sit in a paragraph gap; look a little lower.
            for step in 0..<4 {
                let point = CGPoint(x: textView.textContainerInset.left,
                                    y: viewport.minY + CGFloat(step) * builtFontSize)
                if let offset = characterOffset(at: point), let id = sentence(atOrAfter: offset) {
                    return id
                }
            }
            return max(activeSentence, 0)
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
                startRevealCheck(id)
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

        private func characterOffset(at point: CGPoint) -> Int? {
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return nil }
            let inset = textView.textContainerInset
            let containerPoint = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            guard let fragment = layoutManager.textLayoutFragment(for: containerPoint) else { return nil }

            let frame = fragment.layoutFragmentFrame
            let local = CGPoint(x: containerPoint.x - frame.minX, y: containerPoint.y - frame.minY)
            let fragmentStart = contentManager.offset(
                from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)

            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                guard local.y <= bounds.maxY || line === fragment.textLineFragments.last else { continue }
                // characterIndex(for:) takes LINE-local coordinates; lines can
                // start right of the fragment origin (first-line indents,
                // centered headings), so offset by the line's own origin.
                let index = line.characterIndex(for: CGPoint(x: local.x - bounds.minX,
                                                             y: local.y - bounds.minY))
                guard index >= 0 else { return nil }
                return fragmentStart + index
            }
            return nil
        }

        /// Cached bounding rect of the follow target, the active sentence or
        /// the shown colophon (see `cachedActiveRect` and `followRange`),
        /// in content coordinates like `viewport()`.
        func activeSentenceRect() -> CGRect? {
            if let cachedActiveRect { return cachedActiveRect }
            guard let range = followRange, let rect = boundingRect(for: range) else { return nil }
            cachedActiveRect = rect
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
            cachedActiveRect = nil
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
        /// heights of everything above it. Drawing a highlight lays a far
        /// sentence out on its own at an ESTIMATED y, and an ensureLayout
        /// pass never re-places the last fragment it reaches when that one
        /// is already placed, so the pass must reach one fragment past it.
        private func ensureLayout(through range: NSRange) {
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager else { return }
            let text = textView.textStorage.mutableString
            guard NSMaxRange(range) <= text.length else { return }
            // Paragraphs are TextKit 2's layout fragments.
            let next = NSMaxRange(text.paragraphRange(for: range))
            let start = layoutManager.documentRange.location
            guard let end = contentManager.location(start, offsetBy: min(next + 1, text.length)),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layoutManager.ensureLayout(for: textRange)
        }

        private func boundingRect(for range: NSRange) -> CGRect? {
            guard let textView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager,
                  let start = contentManager.location(layoutManager.documentRange.location,
                                                      offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return nil }

            layoutManager.ensureLayout(for: textRange)
            var union = CGRect.null
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
                _, frame, _, _ in
                union = union.union(frame)
                return true
            }
            guard !union.isNull, union.height > 0 else { return nil }
            return union.offsetBy(dx: textView.textContainerInset.left,
                                  dy: textView.textContainerInset.top)
        }

        // MARK: Attributed string

        /// The whole column. The end mark (`makeEndMark`) comes last, so
        /// `endMarkRange` is the tail and swapping it never moves a sentence.
        static func makeAttributedString(content: DocContent, fontSize: CGFloat,
                                         isChapterBook: Bool = false,
                                         colophon: ReaderColophon? = nil,
                                         traits: UITraitCollection = .current)
            -> (string: NSAttributedString, sentenceRanges: [NSRange], endMarkRange: NSRange) {

            let page = ReaderPageStyle(fontSize: fontSize)
            // Bold Text: body and headings take the serif's bold face.
            let bold = traits.legibilityWeight == .bold
            let bodyFont = ReaderPageStyle.serif(size: fontSize, bold: bold)

            func bodyStyle(indent: Bool) -> NSParagraphStyle {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = page.lineHeight
                style.maximumLineHeight = page.lineHeight
                style.paragraphSpacing = page.paragraphGap
                style.firstLineHeadIndent = indent ? page.firstLineIndent : 0
                style.hyphenationFactor = ReaderPageStyle.hyphenationFactor
                return style
            }
            func bodyAttributes(indent: Bool) -> [NSAttributedString.Key: Any] {
                [.font: bodyFont, .foregroundColor: UIColor(Theme.text),
                 .paragraphStyle: bodyStyle(indent: indent)]
            }

            // The page numeral sits 8pt under its hairline: no space before
            // (the rule paragraph already carries the gap from the text).
            let numeralStyle = NSMutableParagraphStyle()
            numeralStyle.alignment = .center
            numeralStyle.paragraphSpacingBefore = 0
            numeralStyle.paragraphSpacing = (fontSize * 1.6).rounded()
            var numeralAttributes = markAttributes(fontSize: fontSize)
            numeralAttributes[.paragraphStyle] = numeralStyle

            // Chapter opening: space above, a centered small-caps heading
            // (still a speakable, tappable, highlightable sentence), a short
            // accent rule, space, then an unindented first paragraph whose
            // first words are in small caps.
            func headingAttributes(isFirst: Bool) -> [NSAttributedString.Key: Any] {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.paragraphSpacingBefore = isFirst ? 0 : page.openingSpaceAbove
                style.paragraphSpacing = page.headingToRule
                style.hyphenationFactor = 0
                return [.font: ReaderPageStyle.smallCapsSerif(size: page.headingSize, bold: bold),
                        .foregroundColor: UIColor(Theme.text),
                        .kern: ReaderPageStyle.headingKern,
                        .paragraphStyle: style]
            }

            // Which paragraphs open a chapter: text books only, the first
            // paragraph of a chapter group that reads as a heading, and only
            // when the book is genuinely chaptered (see ReaderPageStyle).
            var openings = Set<Int>()
            if isChapterBook {
                var candidates: [Int] = []
                var previousPage: Int?
                for (index, paragraph) in content.paragraphs.enumerated() {
                    defer { previousPage = paragraph.page }
                    guard paragraph.page != previousPage else { continue }
                    let lines = paragraph.sentenceIDs
                        .filter { content.sentences.indices.contains($0) }
                        .map { content.sentences[$0].text }
                    // Also as lines: the extractor recognizes two-line headings
                    // ("I" over a title line), which a space-joined string
                    // hides.
                    if TextExtractor.isChapterHeading(lines.joined(separator: " "))
                        || (lines.count > 1 && TextExtractor.isChapterHeading(lines.joined(separator: "\n"))) {
                        candidates.append(index)
                    }
                }
                openings = ReaderPageStyle.openingParagraphs(candidates: candidates)
            }

            // Page indices may arrive 0- or 1-based; display starts at 1 either
            // way — the shared rule every page-naming surface uses. Text books
            // group by chapter, so they never get page marks.
            let pageOffset = content.pageOffset
            let showPageMarks = !isChapterBook && content.pageCount > 1

            let result = NSMutableAttributedString()
            var ranges = [NSRange](repeating: NSRange(location: 0, length: 0),
                                   count: content.sentences.count)
            var lastPage: Int?
            var afterOpening = false

            for (index, paragraph) in content.paragraphs.enumerated() {
                if showPageMarks, let last = lastPage, paragraph.page != last {
                    // PDF page boundary: a short hairline over the page numeral.
                    result.append(ruleParagraph(size: ReaderPageStyle.pageRuleSize,
                                                color: UIColor(Theme.lineStrong),
                                                spacingBefore: (fontSize * 1.2).rounded(),
                                                spacingAfter: Theme.Space.xs,
                                                traits: traits))
                    result.append(NSAttributedString(
                        string: "\(paragraph.page + pageOffset)\n", attributes: numeralAttributes))
                }
                let isFirstParagraph = lastPage == nil
                lastPage = paragraph.page

                let sentenceIDs = paragraph.sentenceIDs.filter { content.sentences.indices.contains($0) }
                let isOpening = openings.contains(index)
                // Book convention: no indent on a book's first paragraph or
                // the first paragraph after a chapter opening.
                let attributes = isOpening
                    ? headingAttributes(isFirst: isFirstParagraph)
                    : bodyAttributes(indent: !(isFirstParagraph || afterOpening))
                let paragraphStart = result.length

                var first = true
                for sentenceID in sentenceIDs {
                    let sentence = content.sentences[sentenceID]
                    if !first {
                        result.append(NSAttributedString(string: " ", attributes: attributes))
                    }
                    first = false
                    let location = result.length
                    // Display-only typesetting; UTF-16 length is preserved, so
                    // this range (and the word-tint offsets walked from the
                    // source text) stay exact.
                    result.append(NSAttributedString(
                        string: ReaderTypography.typeset(sentence.text), attributes: attributes))
                    ranges[sentence.id] = NSRange(location: location,
                                                  length: result.length - location)
                }
                result.append(NSAttributedString(string: "\n", attributes: attributes))

                if isOpening {
                    result.append(ruleParagraph(size: ReaderPageStyle.ruleSize,
                                                color: UIColor(Theme.accent),
                                                spacingBefore: 0,
                                                spacingAfter: page.ruleToText,
                                                traits: traits))
                } else if afterOpening, let firstID = sentenceIDs.first {
                    // Opening words in small caps: font only, never length.
                    let length = ReaderPageStyle.utf16LengthOfFirstWords(
                        content.sentences[firstID].text, count: ReaderPageStyle.openingSmallCapsWords)
                    result.addAttribute(.font, value: ReaderPageStyle.smallCapsSerif(size: fontSize, bold: bold),
                                        range: NSRange(location: paragraphStart, length: length))
                }
                afterOpening = isOpening
            }

            let endMark = makeEndMark(colophon: colophon, fontSize: fontSize, traits: traits)
            let endMarkRange = NSRange(location: result.length, length: endMark.length)
            result.append(endMark)
            return (result, ranges, endMarkRange)
        }

        /// The end of the text. nil: the "· · ·" mark. A colophon (R24),
        /// every paragraph centered and unhyphenated, honoring Bold Text: an
        /// accent rule, the heading (`ColophonCopy.theEnd`) in the serif's
        /// italic, the title in small caps, the author and the listening
        /// time, both muted. None of it is a sentence, so it is never
        /// spoken, tapped or highlighted.
        static func makeEndMark(colophon: ReaderColophon?, fontSize: CGFloat,
                                traits: UITraitCollection) -> NSAttributedString {
            guard let colophon else {
                return NSAttributedString(string: "· · ·", attributes: markAttributes(fontSize: fontSize))
            }
            let page = ReaderPageStyle(fontSize: fontSize)
            let bold = traits.legibilityWeight == .bold
            func centered(spacingAfter: CGFloat) -> NSParagraphStyle {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.paragraphSpacing = spacingAfter
                style.hyphenationFactor = 0
                return style
            }
            let mark = NSMutableAttributedString()
            // The chapter opening's rule and spacing, so the end reads as the
            // book's own typography.
            mark.append(ruleParagraph(size: ReaderPageStyle.ruleSize, color: UIColor(Theme.accent),
                                      spacingBefore: page.openingSpaceAbove,
                                      spacingAfter: page.headingToRule, traits: traits))
            mark.append(NSAttributedString(string: ColophonCopy.theEnd + "\n", attributes: [
                .font: ReaderPageStyle.italicSerif(size: page.headingSize, bold: bold),
                .foregroundColor: UIColor(Theme.text),
                .paragraphStyle: centered(spacingAfter: page.headingToRule),
            ]))
            // Display-only typesetting, like the sentences' (curly quotes).
            mark.append(NSAttributedString(string: ReaderTypography.typeset(colophon.title) + "\n", attributes: [
                .font: ReaderPageStyle.smallCapsSerif(size: fontSize, bold: bold),
                .foregroundColor: UIColor(Theme.text),
                .kern: ReaderPageStyle.headingKern,
                .paragraphStyle: centered(spacingAfter: page.paragraphGap),
            ]))
            if let author = colophon.author {
                mark.append(NSAttributedString(string: author + "\n", attributes: [
                    .font: ReaderPageStyle.serif(size: fontSize, bold: bold),
                    .foregroundColor: UIColor(Theme.textMuted),
                    .paragraphStyle: centered(spacingAfter: page.paragraphGap),
                ]))
            }
            mark.append(NSAttributedString(string: colophon.listeningLine, attributes: [
                .font: ReaderPageStyle.serif(size: page.colophonDetailSize, bold: bold),
                .foregroundColor: UIColor(Theme.textMuted),
                .paragraphStyle: centered(spacingAfter: 0),
            ]))
            return mark
        }

        /// The "· · ·" end mark's and the PDF page numerals' look.
        private static func markAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            let markStyle = NSMutableParagraphStyle()
            markStyle.alignment = .center
            markStyle.paragraphSpacingBefore = (fontSize * 1.2).rounded()
            markStyle.paragraphSpacing = (fontSize * 1.6).rounded()
            return [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor(Theme.textMuted),
                .kern: 1.2,
                .paragraphStyle: markStyle,
            ]
        }

        /// A centered rule image on a paragraph of its own: chapter openings
        /// and the colophon (accent), PDF page marks (hairline).
        private static func ruleParagraph(size: CGSize, color: UIColor, spacingBefore: CGFloat,
                                          spacingAfter: CGFloat, traits: UITraitCollection) -> NSAttributedString {
            let attachment = NSTextAttachment()
            attachment.image = ReaderPageStyle.ruleImage(size: size, color: color, traits: traits)
            attachment.bounds = CGRect(origin: .zero, size: size)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.minimumLineHeight = max(size.height, 4)
            style.maximumLineHeight = max(size.height, 4)
            let rule = NSMutableAttributedString(attachment: attachment)
            rule.append(NSAttributedString(string: "\n"))
            rule.addAttribute(.paragraphStyle, value: style,
                              range: NSRange(location: 0, length: rule.length))
            return rule
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

    /// A three-finger scroll is the user taking over, like a drag.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onAccessibilityScroll?()
        return super.accessibilityScroll(direction)
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
