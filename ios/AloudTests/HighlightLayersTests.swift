import XCTest
import QuartzCore
@testable import Aloud

/// The follow-along highlight's shared shapes (PRD R6): their geometry, and
/// how a sentence change crossfades unless Reduce Motion is on.
final class HighlightLayersTests: XCTestCase {

    private typealias Segment = HighlightLayers.Segment

    // MARK: - Geometry

    func testSentencePathIsOneShapeAcrossLines() {
        let lines = [
            Segment(frame: CGRect(x: 24, y: 100, width: 300, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 24, y: 129, width: 180, height: 29), baseline: 22),
        ]
        let path = HighlightLayers.sentencePath(lines)
        XCTAssertNotNil(path)
        // Outset 3pt horizontally and 1pt vertically around the union.
        let box = path?.boundingBoxOfPath ?? .null
        XCTAssertEqual(box.minX, 21, accuracy: 0.001)
        XCTAssertEqual(box.minY, 99, accuracy: 0.001)
        XCTAssertEqual(box.width, 306, accuracy: 0.001)
        XCTAssertEqual(box.height, 60, accuracy: 0.001)
        // The gap between lines is filled: the point between the two rows is inside.
        XCTAssertTrue(path?.contains(CGPoint(x: 100, y: 129)) ?? false)
    }

    // MARK: - One traced outline (R1-18)

    private let lineA = Segment(frame: CGRect(x: 24, y: 100, width: 300, height: 29), baseline: 22)

    /// Rows touch and share their left edge: nothing bites into the left
    /// side where one line meets the next.
    func testTheLeftSideHasNoNotchBetweenLines() throws {
        let lines = [lineA, Segment(frame: CGRect(x: 24, y: 129, width: 180, height: 29), baseline: 22)]
        let path = try XCTUnwrap(HighlightLayers.sentencePath(lines))
        let rows = HighlightLayers.bodyRows(lines)
        XCTAssertEqual(rows[0].maxY, rows[1].minY, "rows touch")
        XCTAssertTrue(path.contains(CGPoint(x: rows[0].minX + 0.5, y: rows[0].maxY)), "no notch at the left")
    }

    /// A 60pt step on the right: the inner corner takes the same soft curve
    /// as the outer ones, so the corner's elbow is filled.
    func testAnInnerCornerIsSoftenedNotCut() throws {
        let lines = [lineA, Segment(frame: CGRect(x: 24, y: 129, width: 240, height: 29), baseline: 22)]
        let path = try XCTUnwrap(HighlightLayers.sentencePath(lines))
        let rows = HighlightLayers.bodyRows(lines)
        let elbow = CGPoint(x: rows[1].maxX, y: rows[0].maxY)
        XCTAssertTrue(path.contains(CGPoint(x: elbow.x + 0.5, y: elbow.y + 2.5)), "the inner corner is filled")
        XCTAssertFalse(path.contains(CGPoint(x: elbow.x + 4.5, y: elbow.y + 4.5)), "with a curve, not a block")
    }

    /// Edges within 10pt of each other snap to the outer one: one straight edge.
    func testANearlyEqualRightEdgeIsStraight() throws {
        let lines = [lineA, Segment(frame: CGRect(x: 24, y: 129, width: 296, height: 29), baseline: 22)]
        let path = try XCTUnwrap(HighlightLayers.sentencePath(lines))
        let right = lineA.frame.maxX + HighlightLayers.outset.width
        XCTAssertTrue(path.contains(CGPoint(x: right - 1, y: 145)), "the shorter row reaches the longer one's edge")
        XCTAssertTrue(path.contains(CGPoint(x: right - 1, y: 128)), "no step at the join")
    }

    func testTheRightEdgeNeverPassesTheContainer() throws {
        let wide = [Segment(frame: CGRect(x: 24, y: 100, width: 330, height: 29), baseline: 22)]
        let path = try XCTUnwrap(HighlightLayers.sentencePath(wide, trailingEdge: 340))
        XCTAssertLessThanOrEqual(path.boundingBoxOfPath.maxX, 340 + 3 + 0.001)
    }

    /// Rows that overlap by under 10pt are two contours, not a sliver joint.
    func testBarelyOverlappingRowsAreSeparateShapes() throws {
        let lines = [Segment(frame: CGRect(x: 250, y: 100, width: 80, height: 29), baseline: 22),
                     Segment(frame: CGRect(x: 24, y: 129, width: 228, height: 29), baseline: 22)]
        let path = try XCTUnwrap(HighlightLayers.sentencePath(lines))
        XCTAssertTrue(path.contains(CGPoint(x: 290, y: 114)))
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 143)))
        XCTAssertEqual(contours(path), 2, "no joint between them")
        let joined = [lineA, Segment(frame: CGRect(x: 24, y: 129, width: 180, height: 29), baseline: 22)]
        XCTAssertEqual(contours(try XCTUnwrap(HighlightLayers.sentencePath(joined))), 1, "one outline")
    }

    private func contours(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { if $0.pointee.type == .moveToPoint { count += 1 } }
        return count
    }

    // MARK: - A heading's pill (R1-17)

    func testANarrowHeadingIsAPillCentredOnItsText() throws {
        let heading = [Segment(frame: CGRect(x: 180, y: 100, width: 20, height: 29), baseline: 22)]
        let box = try XCTUnwrap(HighlightLayers.sentencePath(heading, style: .heading, em: 24)).boundingBoxOfPath
        XCTAssertGreaterThanOrEqual(box.width, 1.5 * box.height - 0.001, "at least 1.5x as wide as tall")
        XCTAssertEqual(box.midX, 190, accuracy: 0.001, "centred on the heading")
        let wide = [Segment(frame: CGRect(x: 100, y: 100, width: 190, height: 29), baseline: 22)]
        let padded = try XCTUnwrap(HighlightLayers.sentencePath(wide, style: .heading, em: 24)).boundingBoxOfPath
        XCTAssertEqual(padded.width, 190 + 24, accuracy: 0.001, "half an em each side")
    }

    func testABodySentenceKeepsItsShape() throws {
        let body = try XCTUnwrap(HighlightLayers.sentencePath([lineA])).boundingBoxOfPath
        let styled = try XCTUnwrap(HighlightLayers.sentencePath([lineA], style: .body)).boundingBoxOfPath
        let expected = lineA.frame.insetBy(dx: -3, dy: -1)
        for box in [body, styled] {
            XCTAssertEqual(box.minX, expected.minX, accuracy: 0.001)
            XCTAssertEqual(box.minY, expected.minY, accuracy: 0.001)
            XCTAssertEqual(box.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(box.height, expected.height, accuracy: 0.001)
        }
    }

    /// R2-14: a bar beside a single serif "I" read as a text cursor. The
    /// heading's mark is the pill's own edge: its box is the pill's, nothing
    /// sits left of the pill, and the pill stays filled inside the edge.
    func testAHeadingsMarkIsItsPillsEdge() throws {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        let heading = [Segment(frame: CGRect(x: 180, y: 100, width: 20, height: 29), baseline: 22)]
        layers.showSentence(heading, fill: ink, mark: ink, gutterX: 24, style: .heading, em: 24,
                            animated: false, reduceMotion: false)
        let pill = try XCTUnwrap(HighlightLayers.headingPills(heading, em: 24).first)
        let markPath = try XCTUnwrap(shapes(in: host)[1].path)
        let mark = markPath.boundingBoxOfPath
        XCTAssertEqual(mark.minX, pill.minX, accuracy: 0.75, "the edge starts at the pill, no bar beside it")
        XCTAssertEqual(mark.maxX, pill.maxX, accuracy: 0.75)
        XCTAssertEqual(mark.minY, pill.minY, accuracy: 0.75)
        XCTAssertEqual(mark.maxY, pill.maxY, accuracy: 0.75)
        XCTAssertGreaterThanOrEqual(mark.minX, pill.minX - 0.001, "nothing left of the pill")
        XCTAssertGreaterThanOrEqual(mark.minY, pill.minY - 0.001, "the edge stays inside the pill")
        XCTAssertLessThanOrEqual(mark.maxY, pill.maxY + 0.001,
                                 "the edge stays inside the pill, clear of the rule under it")
        // A ring, not a filled pill: the pill's middle is outside the edge,
        // a point on its left side is on it.
        XCTAssertFalse(markPath.contains(CGPoint(x: pill.midX, y: pill.midY)))
        XCTAssertTrue(markPath.contains(CGPoint(x: pill.minX + HighlightLayers.headingEdgeWidth / 2,
                                                y: pill.midY)))
        XCTAssertEqual(markPath, HighlightLayers.headingEdgePath(heading, em: 24))
    }

    func testABodySentencesMarkStaysTheGutterBar() throws {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        layers.showSentence(line, fill: ink, mark: ink, gutterX: 24, animated: false, reduceMotion: false)
        let mark = try XCTUnwrap(shapes(in: host)[1].path)
        XCTAssertEqual(mark, HighlightLayers.markPath(line, gutterX: 24))
        XCTAssertEqual(mark.boundingBoxOfPath.maxX, 24 - HighlightLayers.markGap, accuracy: 0.001)
    }

    // MARK: - Under the colophon (R1-19)

    func testTheSentenceFadesUnderTheColophonAndComesBackAtOnce() {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        layers.showSentence(line, fill: ink, mark: ink, gutterX: 24, animated: false, reduceMotion: false)
        layers.setSentenceHidden(true, fadeDuration: 0.4)
        XCTAssertEqual(layers.sentenceOpacity, 0)
        XCTAssertEqual(layers.markOpacity, 0)
        layers.showSentence(next, fill: ink, mark: ink, gutterX: 24, animated: true, reduceMotion: false)
        XCTAssertEqual(layers.sentenceOpacity, 0, "a sentence drawn under the colophon stays out")
        layers.setSentenceHidden(false)
        XCTAssertEqual(layers.sentenceOpacity, 1)
        XCTAssertEqual(layers.markOpacity, 1)
    }

    func testEmptySegmentsDrawNothing() {
        XCTAssertNil(HighlightLayers.sentencePath([]))
        XCTAssertNil(HighlightLayers.markPath([], gutterX: 24))
        XCTAssertNil(HighlightLayers.underlinePath([]))
    }

    func testMarginMarkSitsInTheGutterSpanningTheLines() {
        let lines = [
            Segment(frame: CGRect(x: 40, y: 200, width: 300, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 40, y: 229, width: 300, height: 29), baseline: 22),
        ]
        let box = HighlightLayers.markPath(lines, gutterX: 40)?.boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 40 - 10 - 2, y: 202, width: 2, height: 54))
    }

    func testUnderlineSitsBelowTheBaselineOfEachPiece() {
        let pieces = [
            Segment(frame: CGRect(x: 250, y: 100, width: 60, height: 29), baseline: 22),
            Segment(frame: CGRect(x: 24, y: 129, width: 30, height: 29), baseline: 22),
        ]
        let box = HighlightLayers.underlinePath(pieces)?.boundingBoxOfPath
        // First piece: y = 100 + 22 + 2; second ends at 129 + 22 + 2 + 1.5.
        XCTAssertEqual(box?.minY, 124)
        XCTAssertEqual(box?.maxY, 154.5)
    }

    // MARK: - Shapes

    private let line = [Segment(frame: CGRect(x: 24, y: 100, width: 300, height: 29), baseline: 22)]
    private let next = [Segment(frame: CGRect(x: 24, y: 129, width: 300, height: 29), baseline: 22)]
    private let ink = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    private func shapes(in host: CALayer) -> [CAShapeLayer] {
        (host.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }

    func testTheThreeShapesJoinTheHostSentenceLowest() {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        XCTAssertEqual(shapes(in: host).count, 3)
        layers.showSentence(line, fill: ink, mark: ink, gutterX: 24, animated: false, reduceMotion: false)
        XCTAssertNotNil(shapes(in: host)[0].path, "the sentence sits beneath the mark and the word")
        XCTAssertNotNil(shapes(in: host)[1].path)
        layers.clearSentence()
        XCTAssertTrue(shapes(in: host).allSatisfy { $0.path == nil })
    }

    func testASentenceChangeCrossfadesThroughANewShape() {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        layers.showSentence(line, fill: ink, mark: ink, gutterX: 24, animated: true, reduceMotion: false)
        XCTAssertEqual(shapes(in: host).count, 3, "nothing to fade from")
        layers.showSentence(next, fill: ink, mark: ink, gutterX: 24, animated: true, reduceMotion: false)
        XCTAssertEqual(shapes(in: host).count, 4, "the new shape fades in above the old")
        XCTAssertEqual(shapes(in: host)[1].opacity, 1)
    }

    func testReduceMotionSwapsTheSentenceInPlace() {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        layers.showSentence(line, fill: ink, mark: ink, gutterX: 24, animated: true, reduceMotion: true)
        layers.showSentence(next, fill: ink, mark: ink, gutterX: 24, animated: true, reduceMotion: true)
        XCTAssertEqual(shapes(in: host).count, 3, "no crossfade under Reduce Motion")
        XCTAssertEqual(shapes(in: host)[0].path?.boundingBoxOfPath.minY ?? 0, 128, accuracy: 0.001)
    }

    func testTheWordUnderlineShowsAndClears() {
        let host = CALayer()
        let layers = HighlightLayers(host: host)
        layers.showWord(line, color: ink, animated: false, reduceMotion: false)
        XCTAssertEqual(shapes(in: host)[2].path?.boundingBoxOfPath.minY ?? 0, 124, accuracy: 0.001)
        layers.clearWord()
        XCTAssertNil(shapes(in: host)[2].path)
    }
}
