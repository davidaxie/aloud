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
