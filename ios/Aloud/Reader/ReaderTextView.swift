import SwiftUI
import UIKit

/// The reading column: a TextKit 2 `UITextView` rendering the whole document as
/// one attributed string, with a sentence-range table for highlighting, tap-to-seek,
/// and smooth auto-scroll that keeps the active sentence centered.
///
/// The optional word tint is color-only (see `ReaderWordHighlightStyle`):
/// it can never change glyph metrics, so the layout is rock-steady while reading.
struct ReaderTextView: UIViewRepresentable {

    let content: DocContent
    let fontSize: CGFloat
    let activeSentence: Int
    /// Token index (into `tokenizeSentence` of the active sentence) of the word
    /// being spoken; -1 = none. Drives the color-only word tint.
    let activeWord: Int
    /// Pref gate for the word tint (off by default: calm sentence pill only).
    /// The tint is color-only — same font object, zero layout impact.
    let wordHighlight: Bool
    let autoScroll: Bool
    /// True while audio is playing or buffering; drives the 6 s idle
    /// re-engage of auto-follow after a manual scroll.
    let isPlaying: Bool
    /// Increment to force-center the active sentence (the "Return to playhead" chip).
    let returnToPlayheadTrigger: Int
    @Binding var scrolledAway: Bool
    let onTapSentence: (Int) -> Void

    func makeUIView(context: Context) -> ReaderUITextView {
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.showsHorizontalScrollIndicator = false
        textView.contentInsetAdjustmentBehavior = .automatic
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.accessibilityIdentifier = "reader.text"
        textView.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        textView.onTraitChange = { [weak coordinator = context.coordinator] in
            coordinator?.rebuildForTraitChange()
        }
        textView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.handleLayout()
        }
        return textView
    }

    func updateUIView(_ textView: ReaderUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.builtHash != content.contentHash || coordinator.builtFontSize != fontSize {
            coordinator.rebuild(content: content, fontSize: fontSize)
            coordinator.setActiveSentence(activeSentence, scroll: false)
            Task { @MainActor in coordinator.scrollToActiveSentence(force: true, animated: false) }
            return
        }

        if coordinator.activeSentence != activeSentence {
            coordinator.setActiveSentence(activeSentence, scroll: autoScroll)
        }

        let desiredWord = wordHighlight ? activeWord : -1
        if coordinator.activeWordToken != desiredWord {
            coordinator.setActiveWord(desiredWord)
        }

        if coordinator.lastReturnTrigger != returnToPlayheadTrigger {
            coordinator.lastReturnTrigger = returnToPlayheadTrigger
            coordinator.scrollToActiveSentence(force: true, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderTextView
        weak var textView: ReaderUITextView?

        private(set) var builtHash = ""
        private(set) var builtFontSize: CGFloat = 0
        private(set) var activeSentence = -1
        var lastReturnTrigger = 0

        private var sentenceRanges: [NSRange] = []
        private var highlightedRange: NSRange?
        private var suppressAutoScrollUntil: Date = .distantPast
        private var isProgrammaticScroll = false
        /// After a (re)build the active sentence must land centered even though
        /// insets/bounds may not have settled yet; retried on every layout pass
        /// until the geometry resolves (fixes off-screen restore mid-book).
        private var pendingInitialCenter = false
        /// Re-engages auto-follow 6 s after the user's last drag while playing.
        private var idleReturnTask: Task<Void, Never>?

        // Word tint (color-only)
        private(set) var activeWordToken = -1
        private var activeWordRange: NSRange?
        /// Absolute token NSRanges per sentence (nil for whitespace tokens),
        /// derived lazily from the same tokenizer the playback side uses so
        /// token indices always agree. Small; cleared when it grows.
        private var wordRangeCache: [Int: [NSRange?]] = [:]

        init(parent: ReaderTextView) {
            self.parent = parent
        }

        // MARK: Building

        func rebuild(content: DocContent, fontSize: CGFloat) {
            guard let textView else { return }
            let built = Self.makeAttributedString(content: content, fontSize: fontSize)
            textView.attributedText = built.string
            sentenceRanges = built.sentenceRanges
            builtHash = content.contentHash
            builtFontSize = fontSize
            highlightedRange = nil
            activeSentence = -1
            wordRangeCache = [:]
            activeWordRange = nil
            activeWordToken = -1
            pendingInitialCenter = true
        }

        /// Dynamic colors resolve at attribute-set time in some paths; rebuilding on
        /// light/dark flips keeps the column and highlight correct.
        func rebuildForTraitChange() {
            guard builtHash == parent.content.contentHash, let textView else { return }
            let active = activeSentence
            let offset = textView.contentOffset
            rebuild(content: parent.content, fontSize: parent.fontSize)
            pendingInitialCenter = false   // trait flip preserves the offset instead
            setActiveSentence(active, scroll: false)
            setActiveWord(parent.wordHighlight ? parent.activeWord : -1)
            textView.setContentOffset(offset, animated: false)
        }

        // MARK: Highlighting

        func setActiveSentence(_ id: Int, scroll: Bool) {
            guard let textView else { return }
            if id != activeSentence {
                setActiveWord(-1)   // never carry a word highlight across sentences
            }
            activeSentence = id

            if let old = highlightedRange {
                textView.textStorage.removeAttribute(.backgroundColor, range: old)
                highlightedRange = nil
            }
            if sentenceRanges.indices.contains(id) {
                let range = sentenceRanges[id]
                textView.textStorage.addAttribute(
                    .backgroundColor, value: UIColor(Theme.highlightBg), range: range)
                highlightedRange = range
            }

            if scroll { scrollToActiveSentence(force: false, animated: true) }
            updateScrolledAway()
        }

        /// Word layer: a COLOR-ONLY tint over the active word's sub-range of
        /// the active sentence — `.foregroundColor` and nothing else (no font,
        /// weight, kern, or tracking), so glyph metrics never change and the
        /// text never reflows while the word advances. Clearing = re-applying
        /// the body color over the previous word range; the sentence pill
        /// lives in `.backgroundColor` and is untouched.
        func setActiveWord(_ token: Int) {
            guard let textView else { return }
            var newRange: NSRange?
            if token >= 0,
               let ranges = wordRanges(for: activeSentence),
               ranges.indices.contains(token) {
                newRange = ranges[token]   // nil for whitespace tokens
            }
            activeWordToken = token
            guard newRange != activeWordRange else { return }

            activeWordRange = ReaderWordHighlightStyle.apply(
                in: textView.textStorage,
                clearing: activeWordRange,
                applying: newRange,
                enabled: parent.wordHighlight,
                bodyColor: UIColor(Theme.text),
                accentColor: UIColor(Theme.accentStrong))
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

        // MARK: Scrolling

        /// After a rebuild (and after every force-center), keep re-centering
        /// on each layout pass until the active sentence's geometry truly
        /// resolves. Two things move under us: insets/bounds settle a few
        /// passes after `attributedText` is set, and — for a deep restore or
        /// seek — TextKit's estimated line heights shift once the target
        /// region is actually laid out, which would otherwise strand the view
        /// a page off the playhead. Armed until a pass finds us centered;
        /// cancelled the moment the user drags.
        func handleLayout() {
            guard pendingInitialCenter, !isProgrammaticScroll,
                  let textView, textView.bounds.height > 0,
                  let target = centeredTarget() else { return }
            guard abs(target.y - textView.contentOffset.y) > 1 else {
                pendingInitialCenter = false   // geometry settled, centered
                updateScrolledAway()
                return
            }
            scrollToActiveSentence(force: true, animated: false)
        }

        /// Content offset that centers the active sentence under CURRENT
        /// geometry; nil while its layout can't resolve yet.
        private func centeredTarget() -> CGPoint? {
            guard let textView,
                  sentenceRanges.indices.contains(activeSentence),
                  let rect = boundingRect(for: sentenceRanges[activeSentence]) else { return nil }
            let visibleHeight = textView.bounds.height
                - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
            var targetY = rect.midY - textView.adjustedContentInset.top - visibleHeight * 0.42
            let maxY = textView.contentSize.height + textView.adjustedContentInset.bottom
                - textView.bounds.height
            targetY = min(max(targetY, -textView.adjustedContentInset.top),
                          max(maxY, -textView.adjustedContentInset.top))
            return CGPoint(x: 0, y: targetY)
        }

        func scrollToActiveSentence(force: Bool, animated: Bool) {
            guard let textView, let target = centeredTarget() else { return }

            if !force {
                guard Date() >= suppressAutoScrollUntil,
                      !textView.isTracking, !textView.isDragging else { return }
            }

            if force {
                idleReturnTask?.cancel()
                suppressAutoScrollUntil = .distantPast
                // The target may rest on estimated layout (deep jump) —
                // verify and correct on subsequent layout passes.
                pendingInitialCenter = true
            }
            guard abs(target.y - textView.contentOffset.y) > 1 else {
                updateScrolledAway()   // already centered: make sure no chip lingers
                return
            }

            isProgrammaticScroll = true
            if animated && !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    textView.contentOffset = target
                } completion: { [weak self] _ in
                    self?.isProgrammaticScroll = false
                    self?.updateScrolledAway()
                }
            } else {
                textView.setContentOffset(target, animated: false)
                isProgrammaticScroll = false
                updateScrolledAway()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            suppressAutoScrollUntil = .distantFuture
            pendingInitialCenter = false   // the user took over; don't fight them
            idleReturnTask?.cancel()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            suppressAutoScrollUntil = Date().addingTimeInterval(2)
            scheduleIdleReturn()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            suppressAutoScrollUntil = Date().addingTimeInterval(2)
            scheduleIdleReturn()
        }

        /// 6 s after the user's last touch, gently re-engage auto-follow —
        /// but only while audio is playing and auto-scroll is on. The chip
        /// remains for immediate manual return in the meantime.
        private func scheduleIdleReturn() {
            idleReturnTask?.cancel()
            idleReturnTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.parent.isPlaying, self.parent.autoScroll else { return }
                self.scrollToActiveSentence(force: true, animated: true)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll else { return }
            updateScrolledAway()
        }

        private func updateScrolledAway() {
            guard let textView,
                  sentenceRanges.indices.contains(activeSentence),
                  let rect = boundingRect(for: sentenceRanges[activeSentence]) else { return }
            let visible = CGRect(x: 0, y: textView.contentOffset.y,
                                 width: textView.bounds.width, height: textView.bounds.height)
                .inset(by: textView.adjustedContentInset)
            let away = !visible.insetBy(dx: 0, dy: -24).intersects(rect)
            if away != parent.scrolledAway {
                let binding = parent.$scrolledAway
                Task { @MainActor in binding.wrappedValue = away }
            }
        }

        // MARK: Tap → sentence

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView,
                  let offset = characterOffset(at: gesture.location(in: textView)),
                  let id = sentence(containing: offset) else { return }
            parent.onTapSentence(id)
        }

        private func sentence(containing offset: Int) -> Int? {
            var low = 0, high = sentenceRanges.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let range = sentenceRanges[mid]
                if offset < range.location {
                    high = mid - 1
                } else if offset >= range.location + range.length {
                    low = mid + 1
                } else {
                    return mid
                }
            }
            return nil
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
                let index = line.characterIndex(for: local)
                guard index >= 0 else { return nil }
                return fragmentStart + index
            }
            return nil
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

        private static func makeAttributedString(content: DocContent, fontSize: CGFloat)
            -> (string: NSAttributedString, sentenceRanges: [NSRange]) {

            let bodyFont = UIFont(name: Theme.serifFamilyName, size: fontSize)
                ?? .systemFont(ofSize: fontSize)
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.minimumLineHeight = (fontSize * 1.75).rounded()
            bodyStyle.maximumLineHeight = (fontSize * 1.75).rounded()
            bodyStyle.paragraphSpacing = (fontSize * 0.85).rounded()
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: UIColor(Theme.text),
                .paragraphStyle: bodyStyle,
            ]

            let markStyle = NSMutableParagraphStyle()
            markStyle.alignment = .center
            markStyle.paragraphSpacingBefore = (fontSize * 1.2).rounded()
            markStyle.paragraphSpacing = (fontSize * 1.6).rounded()
            let markAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: UIColor(Theme.textFaint),
                .kern: 1.8,
                .paragraphStyle: markStyle,
            ]

            // Page indices may arrive 0- or 1-based; display starts at 1 either way.
            let pageOffset = (content.sentences.first?.page ?? 1) == 0 ? 1 : 0
            let showPageMarks = content.pageCount > 1

            let result = NSMutableAttributedString()
            var ranges = [NSRange](repeating: NSRange(location: 0, length: 0),
                                   count: content.sentences.count)
            var lastPage: Int?

            for paragraph in content.paragraphs {
                if showPageMarks, let last = lastPage, paragraph.page != last {
                    result.append(NSAttributedString(
                        string: "PAGE \(paragraph.page + pageOffset)\n", attributes: markAttributes))
                }
                lastPage = paragraph.page

                var first = true
                for sentenceID in paragraph.sentenceIDs
                where content.sentences.indices.contains(sentenceID) {
                    let sentence = content.sentences[sentenceID]
                    if !first {
                        result.append(NSAttributedString(string: " ", attributes: bodyAttributes))
                    }
                    first = false
                    let location = result.length
                    result.append(NSAttributedString(string: sentence.text, attributes: bodyAttributes))
                    ranges[sentence.id] = NSRange(location: location,
                                                  length: result.length - location)
                }
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            }

            result.append(NSAttributedString(string: "· · ·", attributes: markAttributes))
            return (result, ranges)
        }
    }
}

// MARK: - UITextView subclass

/// Centers the measure (~640 pt max), keeps a deep bottom inset so the last
/// lines can center, and reports trait changes for dynamic-color rebuilds.
final class ReaderUITextView: UITextView {
    var onTraitChange: (@MainActor () -> Void)?
    /// Fired after every layout pass; the coordinator uses it to finish the
    /// initial centering once insets/bounds have actually settled.
    var onLayout: (@MainActor () -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontal = max(24, (bounds.width - 640) / 2)
        let bottom = UIScreen.main.bounds.height * 0.45
        let inset = UIEdgeInsets(top: 28, left: horizontal, bottom: bottom, right: horizontal)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        onLayout?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            onTraitChange?()
        }
    }
}

// MARK: - Word tint attributes

/// The single place word-highlight attributes are written. COLOR-ONLY by
/// contract: applies/clears `.foregroundColor` and touches nothing that can
/// change glyph metrics (no font, weight, kern, tracking, or paragraph
/// attributes), so the text never reflows as the spoken word advances.
/// The sentence pill's `.backgroundColor` is never written here.
///
/// Pure `NSMutableAttributedString` logic so unit tests can pin the contract.
enum ReaderWordHighlightStyle {

    /// Clears the tint from `oldRange` (restoring `bodyColor`) and, when
    /// `enabled`, tints `newRange` with `accentColor`. Returns the range now
    /// tinted (nil when disabled or `newRange` is nil) for the caller to
    /// remember as the next `oldRange`.
    @discardableResult
    static func apply(in storage: NSMutableAttributedString,
                      clearing oldRange: NSRange?,
                      applying newRange: NSRange?,
                      enabled: Bool,
                      bodyColor: UIColor,
                      accentColor: UIColor) -> NSRange? {
        let target = enabled ? newRange : nil
        guard target != oldRange else { return target }

        storage.beginEditing()
        if let old = oldRange {
            storage.addAttribute(.foregroundColor, value: bodyColor, range: old)
        }
        if let new = target {
            storage.addAttribute(.foregroundColor, value: accentColor, range: new)
        }
        storage.endEditing()
        return target
    }
}
