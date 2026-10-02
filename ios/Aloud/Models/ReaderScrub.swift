import CoreGraphics
import Foundation

/// A seek drag in progress (R17). The span is fixed when the drag starts, so
/// the track never rescales under the finger; `target` is the sentence a
/// release would land on.
struct ScrubDrag: Equatable {
    let span: ClosedRange<Int>
    var target: Int

    /// The drag after one frame, from the gesture state before it (nil at
    /// a drag's first frame: SwiftUI resets gesture state when a drag ends
    /// or the system cancels it). Nil unless 8pt sideways; otherwise the
    /// span this drag froze, or `current()` on its first seek frame.
    static func next(after state: ScrubDrag?, translation: CGSize,
                     current: () -> ClosedRange<Int>,
                     target: (ClosedRange<Int>) -> Int) -> ScrubDrag? {
        guard ScrubGesture.isSeek(translation: translation) else { return nil }
        let span = state?.span ?? current()
        return ScrubDrag(span: span, target: target(span))
    }
}

/// The scrub's gesture rules. Only a horizontal drag of at least 8pt seeks,
/// so a plain tap (or a vertical brush on the way to the transport row)
/// never teleports the playhead.
enum ScrubGesture {

    static let minimumDistance: CGFloat = 8

    static func isSeek(translation: CGSize) -> Bool {
        abs(translation.width) >= minimumDistance
    }

    /// The finger's position along the track, 0...1.
    static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }
}

/// The span the preview froze, handed on to the release. onEnded can't
/// read the @GestureState (SwiftUI has reset it), and a release that fell
/// back to the playhead's chapter landed in a chapter the preview never
/// showed whenever the voice crossed into the next one mid-drag.
///
/// The drag's `.updating` copies each frame's gesture state here, in the
/// same call that sets it, so the release can only seek where the preview
/// pointed. It needs no key of its own: that gesture state starts from nil
/// on every drag, cancelled ones included (an alert, Siri, a call), so a new
/// drag's first frame always overwrites what a cancelled one left. Keying by
/// the start point let a later drag from the same x reuse a stale span.
/// A class, so a gesture frame can write it with no state change or redraw.
final class ScrubReleaseSpan {

    /// The span the latest frame froze; nil until the drag is a seek, and
    /// again whenever it drops back under 8pt, as the preview does.
    private(set) var span: ClosedRange<Int>?

    /// After each drag frame, with that frame's gesture state.
    func track(_ drag: ScrubDrag?) {
        span = drag?.span
    }

    /// The span a release seeks in: the frozen one, else `current()`; nil
    /// when the drag is no seek. Forgets the span either way.
    func release(translation: CGSize, current: () -> ClosedRange<Int>) -> ClosedRange<Int>? {
        let frozen = span
        span = nil
        guard ScrubGesture.isSeek(translation: translation) else { return nil }
        return frozen ?? current()
    }
}

/// The text above the thumb while scrubbing: the target's first words and
/// where it falls in the span, "“Well, Prince, so Genoa and Lucca… · 4:05".
/// Never "Sentence N of M": an index means nothing to a listener.
enum ScrubPreview {

    static let wordLimit = 6

    /// The first `wordLimit` words as the reader shows them (curly quotes,
    /// em dashes). A cut sentence ends in "…", with a dangling comma, colon,
    /// semicolon or dash dropped first.
    static func words(of sentence: String) -> String {
        let words = ReaderTypography.typeset(sentence).split(whereSeparator: \.isWhitespace)
        guard words.count > wordLimit else { return words.joined(separator: " ") }
        var head = words.prefix(wordLimit).joined(separator: " ")
        while let last = head.unicodeScalars.last,
              danglingMarks.contains(last) || last.properties.isWhitespace {
            head.unicodeScalars.removeLast()
        }
        return head + "…"
    }

    static func text(sentence: String, seconds: TimeInterval) -> String {
        "\(words(of: sentence)) · \(ListeningEstimate.clock(seconds: seconds))"
    }

    /// The word joiner rides behind a typeset "--" em dash; a spaced dash is
    /// a word of its own, so the space before it goes too.
    private static let danglingMarks: Set<Unicode.Scalar> = [",", ";", ":", "\u{2014}", "\u{2060}"]
}
