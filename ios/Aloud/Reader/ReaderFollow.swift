import Combine
import UIKit

/// Where the voice is relative to the viewport: the Follow chip's arrow.
enum ReaderFollowDirection: Equatable, Sendable {
    case up, down
}

/// Calm follow (R16) as numbers: the text scrolls only when the spoken
/// sentence leaves the comfort band between 18% and 70% of the visible
/// height, then glides once so the sentence top lands at 28%. Pure; every
/// rect is in the text view's CONTENT coordinates.
enum FollowBand {

    static let top: CGFloat = 0.18
    static let bottom: CGFloat = 0.70
    static let landing: CGFloat = 0.28
    static let glideDuration: TimeInterval = 0.45
    static let glideCurve: (CGPoint, CGPoint) = (CGPoint(x: 0.4, y: 0), CGPoint(x: 0.2, y: 1))

    /// Whether the sentence sits in the band. `viewport` is the visible
    /// content rect: bounds offset by contentOffset, inset by the top inset
    /// and the obscured bottom (the player bar). A sentence taller than the
    /// band can never fit, so it counts as inside once its top has reached
    /// the landing line; otherwise every sentence would scroll on every
    /// boundary.
    static func contains(_ sentence: CGRect, in viewport: CGRect) -> Bool {
        let height = viewport.height
        guard sentence.minY >= viewport.minY + top * height - 0.5 else { return false }
        if sentence.height > (bottom - top) * height {
            return sentence.minY <= viewport.minY + landing * height + 1
        }
        return sentence.maxY <= viewport.minY + bottom * height + 0.5
    }

    /// The contentOffset.y that puts `sentenceMinY` on the landing line,
    /// clamped to the scrollable `range`.
    static func landingContentOffsetY(sentenceMinY: CGFloat, viewport: CGRect,
                                      contentOffsetY: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let target = contentOffsetY + sentenceMinY - (viewport.minY + landing * viewport.height)
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// Which way the Follow chip points: nil while any part of the sentence
    /// is visible.
    static func direction(of sentence: CGRect, in viewport: CGRect) -> ReaderFollowDirection? {
        if sentence.maxY <= viewport.minY { return .up }
        if sentence.minY >= viewport.maxY { return .down }
        return nil
    }

    /// Glide only within one viewport; a longer move, and every move under
    /// Reduce Motion, jumps.
    static func glides(distance: CGFloat, viewportHeight: CGFloat, reduceMotion: Bool) -> Bool {
        !reduceMotion && abs(distance) <= viewportHeight
    }

    static func timingParameters() -> UICubicTimingParameters {
        UICubicTimingParameters(controlPoint1: glideCurve.0, controlPoint2: glideCurve.1)
    }

    /// How much of the text view the bottom chrome covers: from the
    /// chrome's top edge down to the text view's bottom edge, both measured
    /// in one coordinate space. The player bar paints its paper under the
    /// home indicator, so its layout height alone leaves that strip out and
    /// the band would run behind the bar. 0 until both edges are measured.
    static func obscuredBottom(textMaxY: CGFloat?, chromeMinY: CGFloat?) -> CGFloat {
        guard let textMaxY, let chromeMinY else { return 0 }
        return max(textMaxY - chromeMinY, 0)
    }
}

#if DEBUG
/// UI-test probe for R16: counts programmatic follow scrolls, holds the
/// active sentence's frame, and the page line its top sits on, published
/// through reader.followScrolls.<n>, reader.activeSentence and
/// reader.activeLine.<n>. R16's budget is per 100 lines read, so a run
/// measures lines as the distance the voice travelled down the column.
@MainActor
final class ReaderFollowProbe: ObservableObject {
    static let shared = ReaderFollowProbe()

    @Published private(set) var scrolls = 0
    @Published var activeRect: CGRect?
    @Published var activeLine: Int?

    func noteScroll() { scrolls += 1 }

    func reset() {
        scrolls = 0
        activeRect = nil
        activeLine = nil
    }
}
#endif
