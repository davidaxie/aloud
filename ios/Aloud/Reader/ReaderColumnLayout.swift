#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The reading column's TextKit 2 geometry, shared by the iPhone and Mac
/// columns: one `NSTextLayoutManager` and where its text container's origin
/// sits in the host's content coordinates (the text container inset's
/// top-left). A host makes one per measurement, so the origin is always the
/// inset as it stands. Every rect it returns is in content coordinates.
///
/// It reads the text only through `textContentManager`, never through the
/// TextKit 1 `layoutManager`: on UIKit and AppKit alike, that call silently
/// drops the view out of TextKit 2.
struct ReaderColumnLayout {

    let textLayoutManager: NSTextLayoutManager
    let origin: CGPoint

    // MARK: Points and ranges

    /// The UTF-16 offset of the character at `point`, or nil off the text.
    func characterOffset(at point: CGPoint) -> Int? {
        guard let contentManager = textLayoutManager.textContentManager else { return nil }
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = textLayoutManager.textLayoutFragment(for: containerPoint) else { return nil }

        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: containerPoint.x - frame.minX, y: containerPoint.y - frame.minY)
        let fragmentStart = contentManager.offset(
            from: textLayoutManager.documentRange.location, to: fragment.rangeInElement.location)
        guard fragmentStart != NSNotFound, fragmentStart >= 0 else { return nil }

        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds
            guard local.y <= bounds.maxY || line === fragment.textLineFragments.last else { continue }
            // characterIndex(for:) takes LINE-local coordinates; lines can
            // start right of the fragment origin (first-line indents,
            // centered headings), so offset by the line's own origin.
            let index = line.characterIndex(for: CGPoint(x: local.x - bounds.minX,
                                                         y: local.y - bounds.minY))
            // A point TextKit can't place answers NSNotFound (Int.max): no
            // character, and never an offset, which adding would overflow.
            guard index >= 0, index != NSNotFound else { return nil }
            let (offset, overflowed) = fragmentStart.addingReportingOverflow(index)
            return overflowed ? nil : offset
        }
        return nil
    }

    /// `range` as a TextKit 2 range; nil past the end of the text.
    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let contentManager = textLayoutManager.textContentManager,
              let start = contentManager.location(textLayoutManager.documentRange.location,
                                                  offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The union of `range`'s laid-out line pieces; nil while it has no
    /// height.
    func boundingRect(for range: NSRange) -> CGRect? {
        guard let textRange = textRange(for: range) else { return nil }

        textLayoutManager.ensureLayout(for: textRange)
        var union = CGRect.null
        textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
            _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull, union.height > 0 else { return nil }
        return union.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Laid-out line pieces of `range`, for the highlight.
    func segments(for range: NSRange) -> [HighlightLayers.Segment] {
        guard let textRange = textRange(for: range) else { return [] }
        textLayoutManager.ensureLayout(for: textRange)
        var result: [HighlightLayers.Segment] = []
        textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
            _, frame, baseline, _ in
            result.append(.init(frame: frame.offsetBy(dx: origin.x, dy: origin.y),
                                baseline: baseline))
            return true
        }
        return result
    }

    /// The laid-out lines whose middles fall inside `rect` (content
    /// coordinates), top to bottom: each line's UTF-16 range in the text and
    /// its typographic frame. Starts at the fragment at the top of `rect`
    /// and stops below it, so a screen deep in a long book lays out only
    /// that screen's paragraphs (VoiceOver's lines, P045).
    func lines(in rect: CGRect) -> [(range: NSRange, frame: CGRect)] {
        guard let contentManager = textLayoutManager.textContentManager, rect.height > 0 else { return [] }
        let top = rect.minY - origin.y
        let bottom = rect.maxY - origin.y
        // The top may sit in a paragraph gap: look a little lower.
        var start: NSTextLayoutFragment?
        var probe = max(top, 0)
        while start == nil, probe < bottom {
            start = textLayoutManager.textLayoutFragment(for: CGPoint(x: 1, y: probe))
            probe += 4
        }
        guard let start else { return [] }
        let documentStart = textLayoutManager.documentRange.location
        var result: [(range: NSRange, frame: CGRect)] = []
        textLayoutManager.enumerateTextLayoutFragments(from: start.rangeInElement.location,
                                                       options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY < bottom else { return false }
            let fragmentStart = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard fragmentStart != NSNotFound, fragmentStart >= 0 else { return true }
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                guard bounds.midY >= top, bounds.midY <= bottom else { continue }
                let local = line.characterRange
                guard local.location != NSNotFound, local.length > 0 else { continue }
                result.append((NSRange(location: fragmentStart + local.location, length: local.length),
                               bounds.offsetBy(dx: origin.x, dy: origin.y)))
            }
            return true
        }
        return result
    }

    // MARK: Layout

    /// One-shot layout from the document start into the paragraph after
    /// `range`'s, so `range` sits on its real frame, not on estimated
    /// heights of everything above it. Drawing a highlight lays a far
    /// sentence out on its own at an ESTIMATED y, and an ensureLayout
    /// pass never re-places the last fragment it reaches when that one
    /// is already placed, so the pass must reach one fragment past it.
    func ensureLayout(through range: NSRange) {
        guard let contentManager = textLayoutManager.textContentManager,
              let text = (contentManager as? NSTextContentStorage)?.textStorage?.mutableString else { return }
        guard NSMaxRange(range) <= text.length else { return }
        // Paragraphs are TextKit 2's layout fragments.
        let next = NSMaxRange(text.paragraphRange(for: range))
        let start = textLayoutManager.documentRange.location
        guard let end = contentManager.location(start, offsetBy: min(next + 1, text.length)),
              let textRange = NSTextRange(location: start, end: end) else { return }
        textLayoutManager.ensureLayout(for: textRange)
    }

    /// The text's height as TextKit has laid it out, with the container's
    /// top inset and `bottomInset`; nil before any layout, when the host
    /// falls back on its own content size.
    func laidOutHeight(bottomInset: CGFloat) -> CGFloat? {
        let usage = textLayoutManager.usageBoundsForTextContainer
        guard usage.maxY > 0 else { return nil }
        return (usage.maxY + origin.y + bottomInset).rounded(.up)
    }

    // MARK: Sentences

    /// The sentence holding `offset`; nil between sentences.
    static func sentence(containing offset: Int, in sentenceRanges: [NSRange]) -> Int? {
        guard let id = sentence(atOrAfter: offset, in: sentenceRanges),
              sentenceRanges[id].location <= offset else { return nil }
        return id
    }

    /// The first sentence that ends after `offset`: the one holding it,
    /// or the next one when `offset` falls between sentences (a
    /// paragraph break, a page mark).
    static func sentence(atOrAfter offset: Int, in sentenceRanges: [NSRange]) -> Int? {
        var low = 0, high = sentenceRanges.count
        while low < high {
            let mid = (low + high) / 2
            let range = sentenceRanges[mid]
            if range.location + range.length <= offset { low = mid + 1 } else { high = mid }
        }
        return low < sentenceRanges.count ? low : nil
    }

    /// The sentence at the top of `viewport`, for the rotor's first step
    /// off screen. The top line may sit in a paragraph gap; look a little
    /// lower, one `lineStep` at a time.
    func sentence(nearTopOf viewport: CGRect, lineStep: CGFloat, in sentenceRanges: [NSRange]) -> Int? {
        for step in 0..<4 {
            let point = CGPoint(x: origin.x, y: viewport.minY + CGFloat(step) * lineStep)
            if let offset = characterOffset(at: point),
               let id = Self.sentence(atOrAfter: offset, in: sentenceRanges) {
                return id
            }
        }
        return nil
    }

    /// Absolute NSRanges of sentence `id`'s tokens (nil = whitespace),
    /// computed once per sentence from the same tokenizer offsets the
    /// playback side uses (concatenation is byte-identical, so walking
    /// UTF-16 lengths from the sentence range's location is exact). The
    /// host keeps `cache`: small, cleared when it grows.
    static func wordRanges(for id: Int, sentenceRanges: [NSRange], sentences: [Sentence],
                           cache: inout [Int: [NSRange?]]) -> [NSRange?]? {
        if let cached = cache[id] { return cached }
        guard sentenceRanges.indices.contains(id),
              sentences.indices.contains(id) else { return nil }

        let sentenceRange = sentenceRanges[id]
        let tokens = SentenceSegmenter.tokenizeSentence(sentences[id].text)
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

        if cache.count > 16 { cache.removeAll() }
        cache[id] = ranges
        return ranges
    }
}
