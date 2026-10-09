import Combine
import CoreGraphics
import Foundation

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
        if isTall(sentence, in: viewport) {
            return sentence.minY <= viewport.minY + landing * height + 1
        }
        return sentence.maxY <= viewport.minY + bottom * height + 0.5
    }

    /// Whether the sentence is taller than the band, so it can never fit.
    static func isTall(_ sentence: CGRect, in viewport: CGRect) -> Bool {
        sentence.height > (bottom - top) * viewport.height
    }

    /// What following keeps in the band while `word` is spoken. A sentence
    /// taller than the band parks its top on the landing line (`contains`)
    /// for as long as the spoken word still sits above the band's bottom
    /// from there; past that, following tracks the word's line, landing it
    /// on the landing line, so the end of a long sentence at a large text
    /// size is never read under the player bar. The choice depends only on
    /// where the word sits in its sentence, never on the scroll, so a
    /// relayout re-checking the band never pulls the text back up.
    static func followed(sentence: CGRect, word: CGRect?, in viewport: CGRect) -> CGRect {
        guard let word, isTall(sentence, in: viewport) else { return sentence }
        let parkedWordMaxY = landing * viewport.height + (word.maxY - sentence.minY)
        return parkedWordMaxY <= bottom * viewport.height + 0.5 ? sentence : word
    }

    /// Whether a tick of the spoken word re-checks the band: only once
    /// following tracks the word through a sentence taller than the band
    /// (`followed` picks the word), and only when the word has moved on to
    /// a new line since `previousWord`. A sentence that fits follows on
    /// sentence changes alone, so a user scroll that ends with the voice in
    /// view stays where it is until the voice moves on: to its next
    /// sentence, or in a tall one to its next line.
    static func wordTickFollows(sentence: CGRect, word: CGRect, previousWord: CGRect?,
                                in viewport: CGRect) -> Bool {
        guard followed(sentence: sentence, word: word, in: viewport) == word else { return false }
        guard let previousWord else { return true }
        return abs(word.minY - previousWord.minY) > 0.5
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

    /// How much of the text view the bottom chrome covers: from the
    /// chrome's top edge down to the text view's bottom edge, both measured
    /// in one coordinate space. The player bar paints its paper under the
    /// home indicator, so its layout height alone leaves that strip out and
    /// the band would run behind the bar. 0 until both edges are measured.
    static func obscuredBottom(textMaxY: CGFloat?, chromeMinY: CGFloat?) -> CGFloat {
        guard let textMaxY, let chromeMinY else { return 0 }
        return max(textMaxY - chromeMinY, 0)
    }

    /// The same with a sheet resting over the page too: whichever reaches
    /// further up the text. A sheet is hosted apart from the screen, so its
    /// top edge and the text's bottom come in the window's space
    /// (`windowTextMaxY`, `sheetMinY`), the bar's in the screen's own. No
    /// sheet, and the bar alone counts.
    static func obscuredBottom(textMaxY: CGFloat?, chromeMinY: CGFloat?,
                               windowTextMaxY: CGFloat?, sheetMinY: CGFloat?) -> CGFloat {
        max(obscuredBottom(textMaxY: textMaxY, chromeMinY: chromeMinY),
            obscuredBottom(textMaxY: windowTextMaxY, chromeMinY: sheetMinY))
    }

    /// The same, with the chip slot floating over the text above the
    /// chrome: while a chip shows, its reach (`chipReach`) and a small gap
    /// count too, so the spoken line is never read under the chip. With no
    /// chip, the chrome alone. 0, the chip with it, until both edges are
    /// measured (R3-01): a chip counted over an unmeasured bar made a band
    /// that looked measured, and the colophon landed on it under the bar.
    static func obscuredBottom(textMaxY: CGFloat?, chromeMinY: CGFloat?,
                               chipReach: CGFloat, showsChip: Bool) -> CGFloat {
        guard textMaxY != nil, chromeMinY != nil else { return 0 }
        let chrome = obscuredBottom(textMaxY: textMaxY, chromeMinY: chromeMinY)
        guard showsChip, chipReach > 0 else { return chrome }
        return chrome + chipReach + Theme.Space.sm
    }

    /// How far the chip slot reaches above the chrome: the tallest chip it
    /// has shown (`slotHeight`, 0 while empty) and the slot's padding below
    /// it, kept as a running maximum, so chips swapping never makes the
    /// band, and the page with it, jitter (the Mac's `chipReach`).
    static func chipReach(previous: CGFloat, slotHeight: CGFloat) -> CGFloat {
        guard slotHeight > 0 else { return previous }
        return max(previous, (slotHeight + Theme.Space.sm).rounded(.up))
    }

    /// The least a chip stands: its 44pt touch target. The band counts it
    /// from the pass a chip resolves in, before the chip is measured, so the
    /// first placement already keeps the page above the chip (R2-09).
    static let chipMinimumHeight: CGFloat = 44

    /// R3-01: whether the band stands on measured edges: the text's bottom
    /// and the bar's top, with the bar taller than a touch target (a bar
    /// measured mid-layout at no height is not yet the bar).
    static func isMeasured(textMaxY: CGFloat?, chromeMinY: CGFloat?) -> Bool {
        guard let textMaxY, let chromeMinY else { return false }
        return chromeMinY < textMaxY - chipMinimumHeight
    }

    /// `chipReach` with a chip showing and not yet measured: at least the
    /// chip's minimum and the slot's padding; the running maximum as is
    /// while no chip shows.
    static func chipReach(previous: CGFloat, showsChip: Bool) -> CGFloat {
        guard showsChip else { return previous }
        return chipReach(previous: previous, slotHeight: chipMinimumHeight)
    }

    /// R1-19: the contentOffset.y that ends the book on the chip: the
    /// colophon's bottom on the viewport's bottom edge (measured above the
    /// More classics chip, `obscuredBottom(showsChip: true)`), clamped so
    /// the last sentence's top stays below the top chrome. Where the last
    /// sentence and the colophon don't fit together (the accessibility
    /// sizes), the colophon shows in full first: on the chip if it fits the
    /// viewport alone, else its top under the chrome. Clamped to `range`.
    static func colophonLandingOffsetY(colophon: CGRect, lastSentence: CGRect?, viewport: CGRect,
                                       contentOffsetY: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let onTheChip = colophon.maxY - viewport.maxY
        var shift = onTheChip
        if let lastSentence { shift = min(shift, lastSentence.minY - viewport.minY) }
        if shift < onTheChip {
            shift = colophon.height <= viewport.height ? onTheChip : colophon.minY - viewport.minY
        }
        return min(max(contentOffsetY + shift, range.lowerBound), range.upperBound)
    }

    /// Both at once: the bar with the chip floating over it, and a sheet
    /// resting over the page, whichever reaches further up the text.
    static func obscuredBottom(textMaxY: CGFloat?, chromeMinY: CGFloat?,
                               chipReach: CGFloat, showsChip: Bool,
                               windowTextMaxY: CGFloat?, sheetMinY: CGFloat?) -> CGFloat {
        max(obscuredBottom(textMaxY: textMaxY, chromeMinY: chromeMinY, chipReach: chipReach, showsChip: showsChip),
            obscuredBottom(textMaxY: windowTextMaxY, chromeMinY: sheetMinY))
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
    /// R3-01: every input of the colophon's last landing or ended check,
    /// published through reader.colophonAim for the UI test's messages.
    @Published var colophonAim: String?

    func noteScroll() { scrolls += 1 }

    func reset() {
        scrolls = 0
        activeRect = nil
        activeLine = nil
        colophonAim = nil
    }

    /// One line of the colophon's landing inputs, in whole points.
    static func describeColophonAim(stage: String, band: CGFloat, bandMeasured: Bool, colophon: CGRect,
                            viewport: CGRect, resting: ClosedRange<CGFloat>, target: CGFloat?,
                            contentOffsetY: CGFloat, clears: Bool) -> String {
        func n(_ value: CGFloat) -> String { String(Int(value.rounded())) }
        func span(_ rect: CGRect) -> String { "\(n(rect.minY))-\(n(rect.maxY))" }
        return "\(stage): band \(n(band)) measured \(bandMeasured) colophon \(span(colophon)) "
            + "viewport \(span(viewport)) resting \(n(resting.lowerBound))...\(n(resting.upperBound)) "
            + "target \(target.map(n) ?? "none") offset \(n(contentOffsetY)) clears \(clears)"
    }
}
#endif
