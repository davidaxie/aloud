import QuartzCore

/// The follow-along highlight, drawn BENEATH the text instead of as text
/// attributes: moving it never edits `textStorage`, so glyph metrics and
/// layout never change while reading (PRD R6).
///
/// Three shapes, all in the text view's content coordinates:
/// - the sentence: one rounded shape built from the sentence's line
///   fragments, continuing across line breaks;
/// - a 2pt margin mark in the left gutter spanning the sentence's lines;
/// - an optional 1.5pt underline under the spoken word.
/// Sentence changes crossfade over 200 ms (instant under Reduce Motion);
/// the word underline slides over 90 ms.
///
/// Shared by both columns: the shapes live under a host `CALayer` (the iOS
/// `ReaderHighlightLayer` view's own layer), colors arrive resolved as
/// `CGColor`, and each change says whether Reduce Motion is on.
final class HighlightLayers {

    /// One laid-out line piece of a text range: its frame and the baseline
    /// offset from the frame's top, in content coordinates.
    struct Segment: Equatable {
        let frame: CGRect
        let baseline: CGFloat
    }

    static let cornerRadius: CGFloat = 5
    /// How far the sentence shape reaches past each line: 3pt either side,
    /// 1pt above and below.
    static let outset = CGSize(width: 3, height: 1)
    static let markWidth: CGFloat = 2
    static let markGap: CGFloat = 10
    static let underlineHeight: CGFloat = 1.5
    static let underlineOffset: CGFloat = 2
    static let crossfade: CFTimeInterval = 0.2
    static let wordSlide: CFTimeInterval = 0.09

    private let host: CALayer
    private var sentenceShape = CAShapeLayer()
    private let markShape = CAShapeLayer()
    private let wordShape = CAShapeLayer()

    /// Adds the three shapes to `host`, sentence lowest.
    init(host: CALayer) {
        self.host = host
        host.addSublayer(sentenceShape)
        host.addSublayer(markShape)
        host.addSublayer(wordShape)
    }

    // MARK: Sentence

    /// Shows `segments` as the active sentence. `animated` crossfades from the
    /// previous shape; geometry-only refreshes (relayout) pass `false`.
    func showSentence(_ segments: [Segment], fill: CGColor, mark: CGColor,
                      gutterX: CGFloat, animated: Bool, reduceMotion: Bool) {
        let path = Self.sentencePath(segments)
        let markPath = Self.markPath(segments, gutterX: gutterX)
        let fade = animated && !reduceMotion

        if fade, sentenceShape.path != nil {
            let old = sentenceShape
            let new = CAShapeLayer()
            new.fillColor = fill
            new.path = path
            new.opacity = 0
            host.insertSublayer(new, above: old)
            sentenceShape = new

            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.crossfade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            new.opacity = 1
            old.opacity = 0
            markShape.path = markPath
            markShape.fillColor = mark
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sentenceShape.fillColor = fill
            sentenceShape.path = path
            sentenceShape.opacity = 1
            markShape.fillColor = mark
            markShape.path = markPath
            CATransaction.commit()
        }
    }

    func clearSentence() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sentenceShape.path = nil
        markShape.path = nil
        wordShape.path = nil
        shownWordPieces = 0
        CATransaction.commit()
    }

    // MARK: Word

    /// Rect count of the underline currently shown; a path animation is
    /// only well-defined between paths with the same element count.
    private var shownWordPieces = 0

    func showWord(_ segments: [Segment], color: CGColor, animated: Bool, reduceMotion: Bool) {
        let path = Self.underlinePath(segments)
        let pieces = segments.filter { $0.frame.width > 0 }.count
        let slide = animated && !reduceMotion
            && wordShape.path != nil && pieces == 1 && shownWordPieces == 1
        shownWordPieces = path == nil ? 0 : pieces
        CATransaction.begin()
        if slide {
            CATransaction.setAnimationDuration(Self.wordSlide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        wordShape.fillColor = color
        wordShape.path = path
        CATransaction.commit()
    }

    func clearWord() {
        shownWordPieces = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wordShape.path = nil
        CATransaction.commit()
    }

    // MARK: Geometry (pure; unit-tested)

    /// Rounded, outset rect per line, unioned into one continuous shape.
    static func sentencePath(_ segments: [Segment]) -> CGPath? {
        let rects = segments.map(\.frame).filter { $0.width > 0 && $0.height > 0 }
        guard !rects.isEmpty else { return nil }
        var shape: CGPath?
        for rect in rects {
            let piece = CGPath(roundedRect: rect.insetBy(dx: -outset.width, dy: -outset.height),
                               cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                               transform: nil)
            shape = shape.map { $0.union(piece) } ?? piece
        }
        return shape
    }

    /// A thin bar in the left gutter from the first line's top to the last
    /// line's bottom.
    static func markPath(_ segments: [Segment], gutterX: CGFloat) -> CGPath? {
        let rects = segments.map(\.frame).filter { $0.height > 0 }
        guard let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { return nil }
        let bar = CGRect(x: gutterX - markGap - markWidth, y: top + 2,
                         width: markWidth, height: max(bottom - top - 4, markWidth))
        return CGPath(roundedRect: bar, cornerWidth: markWidth / 2, cornerHeight: markWidth / 2,
                      transform: nil)
    }

    /// An underline under each piece of the word (a hyphenated word can
    /// span two lines), `underlineOffset` below the baseline.
    static func underlinePath(_ segments: [Segment]) -> CGPath? {
        let pieces = segments.filter { $0.frame.width > 0 }
        guard !pieces.isEmpty else { return nil }
        let path = CGMutablePath()
        for piece in pieces {
            path.addRect(CGRect(x: piece.frame.minX,
                                y: piece.frame.minY + piece.baseline + underlineOffset,
                                width: piece.frame.width, height: underlineHeight))
        }
        return path
    }
}
