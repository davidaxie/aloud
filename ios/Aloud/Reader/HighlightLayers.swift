import QuartzCore

/// The follow-along highlight, drawn BENEATH the text instead of as text
/// attributes: moving it never edits `textStorage`, so glyph metrics and
/// layout never change while reading (PRD R6).
///
/// Three shapes, all in the text view's content coordinates:
/// - the sentence: one traced outline around the sentence's glyphs, line by
///   line, continuing across line breaks with every corner softened alike;
///   a chapter heading (a centred sentence) is a pill instead;
/// - a 2pt margin mark in the left gutter spanning the sentence's lines
///   (a heading instead wears it as a 1.5pt edge inside its pill);
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

    /// How a sentence is drawn: body text as one traced outline, a chapter
    /// heading (the only centred sentences) as a deliberate pill.
    enum SentenceStyle: Equatable {
        case body, heading
    }

    static let cornerRadius: CGFloat = 5
    /// How far the sentence shape reaches past each line: 3pt either side,
    /// 1pt above and below.
    static let outset = CGSize(width: 3, height: 1)
    static let markWidth: CGFloat = 2
    /// The accent edge a heading's pill wears in place of the gutter bar.
    static let headingEdgeWidth: CGFloat = 1.5
    static let markGap: CGFloat = 10
    static let underlineHeight: CGFloat = 1.5
    static let underlineOffset: CGFloat = 2
    static let crossfade: CFTimeInterval = 0.2
    /// Neighbouring rows whose edges differ by less than this share the
    /// outer edge; rows overlapping by less are drawn as separate contours.
    static let snap: CGFloat = 10
    /// A heading's pill reaches this many ems of its font past the text on
    /// each side, and is at least `headingMinAspect` times as wide as tall.
    static let headingPadding: CGFloat = 0.5
    static let headingMinAspect: CGFloat = 1.5
    static let wordSlide: CFTimeInterval = 0.09

    private let host: CALayer
    private var sentenceShape = CAShapeLayer()
    private var markShape = CAShapeLayer()
    private let wordShape = CAShapeLayer()
    /// The style the shown mark was drawn for. A heading's ring and a body
    /// sentence's bar have unlike paths, which Core Animation can't
    /// interpolate: between them the mark crossfades instead of sliding.
    private var markStyle: SentenceStyle?
    /// At the end of the book the sentence and its mark fade out under the
    /// colophon (`setSentenceHidden`); a sentence drawn meanwhile stays out.
    private(set) var isSentenceHidden = false

    /// Adds the three shapes to `host`, sentence lowest.
    init(host: CALayer) {
        self.host = host
        host.addSublayer(sentenceShape)
        host.addSublayer(markShape)
        host.addSublayer(wordShape)
    }

    // MARK: Sentence

    /// Shows `segments` as the active sentence. `animated` crossfades from the
    /// previous shape; geometry-only refreshes (relayout) pass `false`. A
    /// `.heading` is a pill padded by `em` (its font's size) whose mark is
    /// its own edge; `trailingEdge` is the text container's, which a
    /// body row never passes by more than the outset.
    func showSentence(_ segments: [Segment], fill: CGColor, mark: CGColor,
                      gutterX: CGFloat, style: SentenceStyle = .body, em: CGFloat = 0,
                      trailingEdge: CGFloat? = nil, animated: Bool, reduceMotion: Bool) {
        let path = Self.sentencePath(segments, style: style, em: em, trailingEdge: trailingEdge)
        // A heading's non-colour signal is the pill's own accent edge: a bar
        // beside a single serif numeral reads as a text cursor (R2-14).
        let markPath = style == .heading
            ? Self.headingEdgePath(segments, em: em)
            : Self.markPath(segments, gutterX: gutterX)
        let fade = animated && !reduceMotion
        let shown: Float = isSentenceHidden ? 0 : 1
        let restyled = markShape.path != nil && markStyle != nil && markStyle != style
        markStyle = markPath == nil ? nil : style

        if fade, sentenceShape.path != nil {
            let old = sentenceShape
            let new = CAShapeLayer()
            new.fillColor = fill
            new.path = path
            new.opacity = 0
            host.insertSublayer(new, above: old)
            sentenceShape = new
            // A ring to a bar (or back) fades through a new mark, opacity
            // only, as the fill does; a bar to a bar still slides.
            var oldMark: CAShapeLayer?
            if restyled {
                let newMark = CAShapeLayer()
                newMark.fillColor = mark
                newMark.path = markPath
                newMark.opacity = 0
                host.insertSublayer(newMark, above: markShape)
                oldMark = markShape
                markShape = newMark
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.crossfade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setCompletionBlock {
                old.removeFromSuperlayer()
                oldMark?.removeFromSuperlayer()
            }
            new.opacity = shown
            old.opacity = 0
            if let oldMark {
                markShape.opacity = shown
                oldMark.opacity = 0
            } else {
                markShape.path = markPath
                markShape.fillColor = mark
            }
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sentenceShape.fillColor = fill
            sentenceShape.path = path
            sentenceShape.opacity = shown
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
        markStyle = nil
        wordShape.path = nil
        shownWordPieces = 0
        CATransaction.commit()
    }

    /// The colophon appeared (`hidden`, faded over `fadeDuration`, opacity
    /// only so Reduce Motion keeps it) or cleared (back at once, before the
    /// next sentence draws). Hides the drawing only: the active sentence,
    /// what VoiceOver reads and the resting place are unchanged.
    func setSentenceHidden(_ hidden: Bool, fadeDuration: CFTimeInterval? = nil) {
        guard hidden != isSentenceHidden else { return }
        isSentenceHidden = hidden
        CATransaction.begin()
        if hidden, let fadeDuration {
            CATransaction.setAnimationDuration(fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        sentenceShape.opacity = hidden ? 0 : 1
        markShape.opacity = hidden ? 0 : 1
        CATransaction.commit()
    }

    /// The sentence fill's and the margin mark's opacity as set (the model
    /// value, not a fade in flight); for tests.
    var sentenceOpacity: Float { sentenceShape.opacity }
    var markOpacity: Float { markShape.opacity }

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

    /// The sentence's shape. A body sentence is one traced outline around
    /// its rows (`bodyRows`): each row touches the next, near-equal edges
    /// snap to the outer one, and every corner, inner ones included, takes
    /// the same soft curve; rows that barely overlap are separate contours.
    /// A heading is a pill per line (`headingPills`).
    static func sentencePath(_ segments: [Segment], style: SentenceStyle = .body, em: CGFloat = 0,
                             trailingEdge: CGFloat? = nil) -> CGPath? {
        if style == .heading {
            var shape: CGPath?
            for pill in headingPills(segments, em: em) {
                let radius = pill.height / 2
                let piece = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
                shape = shape.map { $0.union(piece) } ?? piece
            }
            return shape
        }
        let rows = bodyRows(segments, trailingEdge: trailingEdge)
        guard !rows.isEmpty else { return nil }
        // Rows that overlap by less than `snap` would join through a sliver:
        // each run of well-overlapping rows is a contour of its own.
        var contours: [[CGRect]] = []
        for row in rows {
            if let previous = contours.last?.last,
               min(previous.maxX, row.maxX) - max(previous.minX, row.minX) >= snap {
                contours[contours.count - 1].append(row)
            } else {
                contours.append([row])
            }
        }
        let path = CGMutablePath()
        for contour in contours { addRoundedPolygon(outline(of: snapped(contour)), to: path) }
        return path
    }

    /// One outset rect per line of `segments` (pieces on one line are
    /// unioned, so the sentence's word frames give each row its glyph
    /// extent, no trailing space), its right edge at most `trailingEdge` +
    /// the outset, each row's bottom on the next row's top.
    static func bodyRows(_ segments: [Segment], trailingEdge: CGFloat? = nil) -> [CGRect] {
        var rows = lines(segments).map { $0.insetBy(dx: -outset.width, dy: -outset.height) }
        if let trailingEdge {
            let limit = trailingEdge + outset.width
            rows = rows.compactMap { row in
                guard row.maxX > limit else { return row }
                guard limit > row.minX else { return nil }
                return CGRect(x: row.minX, y: row.minY, width: limit - row.minX, height: row.height)
            }
        }
        for index in rows.indices.dropLast() where rows[index + 1].minY > rows[index].minY {
            rows[index].size.height = rows[index + 1].minY - rows[index].minY
        }
        return rows
    }

    /// A heading's pill per line: half an em past the text each side, 1pt
    /// above and below, at least `headingMinAspect` times as wide as tall,
    /// widened evenly about the line's middle.
    static func headingPills(_ segments: [Segment], em: CGFloat) -> [CGRect] {
        let padding = max(em * headingPadding, outset.width)
        return lines(segments).map { line in
            var pill = line.insetBy(dx: -padding, dy: -outset.height)
            let minimum = pill.height * headingMinAspect
            if pill.width < minimum { pill = pill.insetBy(dx: (pill.width - minimum) / 2, dy: 0) }
            return pill
        }
    }

    /// `segments`' frames grouped by line, top to bottom: pieces whose
    /// middles share a line are unioned.
    private static func lines(_ segments: [Segment]) -> [CGRect] {
        let frames = segments.map(\.frame).filter { $0.width > 0 && $0.height > 0 }.sorted { $0.minY < $1.minY }
        var lines: [CGRect] = []
        for frame in frames {
            if let last = lines.last, abs(last.midY - frame.midY) < min(last.height, frame.height) / 2 {
                lines[lines.count - 1] = last.union(frame)
            } else {
                lines.append(frame)
            }
        }
        return lines
    }

    /// Neighbouring rows whose left or right edges differ by less than
    /// `snap` both take the outer edge.
    private static func snapped(_ rows: [CGRect]) -> [CGRect] {
        var rows = rows
        for index in rows.indices.dropLast() {
            var upper = rows[index]
            var lower = rows[index + 1]
            if abs(upper.minX - lower.minX) < snap {
                let left = min(upper.minX, lower.minX)
                upper = CGRect(x: left, y: upper.minY, width: upper.maxX - left, height: upper.height)
                lower = CGRect(x: left, y: lower.minY, width: lower.maxX - left, height: lower.height)
            }
            if abs(upper.maxX - lower.maxX) < snap {
                let right = max(upper.maxX, lower.maxX)
                upper.size.width = right - upper.minX
                lower.size.width = right - lower.minX
            }
            rows[index] = upper
            rows[index + 1] = lower
        }
        return rows
    }

    /// The outline of touching rows: across the top, down the right side
    /// and up the left, with no repeated or collinear vertex.
    private static func outline(of rows: [CGRect]) -> [CGPoint] {
        guard let first = rows.first, let last = rows.last else { return [] }
        var points = [CGPoint(x: first.minX, y: first.minY), CGPoint(x: first.maxX, y: first.minY)]
        for index in rows.indices {
            points.append(CGPoint(x: rows[index].maxX, y: rows[index].maxY))
            if index + 1 < rows.count { points.append(CGPoint(x: rows[index + 1].maxX, y: rows[index].maxY)) }
        }
        points.append(CGPoint(x: last.minX, y: last.maxY))
        for index in stride(from: rows.count - 1, to: 0, by: -1) {
            points.append(CGPoint(x: rows[index].minX, y: rows[index].minY))
            points.append(CGPoint(x: rows[index - 1].minX, y: rows[index].minY))
        }
        var vertices: [CGPoint] = []
        for point in points where vertices.last.map({ !same($0, point) }) ?? true {
            vertices.append(point)
        }
        while vertices.count > 1, let tail = vertices.last, same(tail, vertices[0]) {
            vertices.removeLast()
        }
        // A vertex on a straight run is no corner.
        var index = 0
        while vertices.count > 3, index < vertices.count {
            let previous = vertices[(index + vertices.count - 1) % vertices.count]
            let point = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let cross = (point.x - previous.x) * (next.y - point.y) - (point.y - previous.y) * (next.x - point.x)
            if abs(cross) < 0.01 {
                vertices.remove(at: index)
                index = 0
            } else {
                index += 1
            }
        }
        return vertices
    }

    private static func same(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= 0.01 && abs(a.y - b.y) <= 0.01
    }

    /// `points` as a closed contour with every vertex rounded: radius
    /// `cornerRadius`, or half the shorter edge beside it.
    private static func addRoundedPolygon(_ points: [CGPoint], to path: CGMutablePath) {
        let count = points.count
        guard count >= 3 else { return }
        let first = points[0]
        let last = points[count - 1]
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for index in 0..<count {
            let previous = points[(index + count - 1) % count]
            let point = points[index]
            let next = points[(index + 1) % count]
            let shorter = min(hypot(point.x - previous.x, point.y - previous.y),
                              hypot(next.x - point.x, next.y - point.y))
            path.addArc(tangent1End: point, tangent2End: next, radius: min(cornerRadius, shorter / 2))
        }
        path.closeSubpath()
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

    /// A heading's mark: the outline of its pills as a `headingEdgeWidth`
    /// ring, stroked on the pills inset by half that width so the ring lies
    /// inside the fill's outline. The inset pills are unioned first, as the
    /// fill's are, so a wrapped heading's lines (whose pills still overlap)
    /// share one outline and no ring crosses the fill between them. A fill
    /// path, so the mark layer's fade under the colophon and colours work as
    /// they do for the gutter bar.
    static func headingEdgePath(_ segments: [Segment], em: CGFloat) -> CGPath? {
        let inset = headingEdgeWidth / 2
        var outline: CGPath?
        for pill in headingPills(segments, em: em) {
            let edge = pill.insetBy(dx: inset, dy: inset)
            guard edge.width > 0, edge.height > 0 else { continue }
            let radius = edge.height / 2
            let piece = CGPath(roundedRect: edge, cornerWidth: radius, cornerHeight: radius, transform: nil)
            outline = outline.map { $0.union(piece) } ?? piece
        }
        guard let outline, !outline.isEmpty else { return nil }
        return outline.copy(strokingWithWidth: headingEdgeWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
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
