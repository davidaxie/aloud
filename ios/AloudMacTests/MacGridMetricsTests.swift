import SwiftUI
import XCTest
@testable import Aloud

/// The Library grid's column math (M6, mac-ux §3.2): 2 columns in the
/// narrowest window and 5 in the default one, covers 136-168 wide and 2:3 at
/// every width, and arrow keys that walk the grid by its own columns.
@MainActor
final class MacGridMetricsTests: XCTestCase {

    // MARK: Columns

    func testTwoColumnsAtTheMinimumWindow() {
        let metrics = MacGridMetrics(windowWidth: 520)
        XCTAssertEqual(metrics.columns, 2)
        XCTAssertEqual(metrics.coverWidth, 168, accuracy: 0.001, "a narrow window keeps full-size covers")
    }

    func testFiveColumnsAtTheDefaultWindow() {
        let metrics = MacGridMetrics(windowWidth: 1000)
        XCTAssertEqual(metrics.columns, 5)
        XCTAssertTrue(MacGridMetrics.coverWidths.contains(metrics.coverWidth))
    }

    func testTheGutterNarrowsBelow600() {
        XCTAssertEqual(MacGridMetrics.gutter(forWindowWidth: 599), 20)
        XCTAssertEqual(MacGridMetrics.gutter(forWindowWidth: 600), 32)
        XCTAssertEqual(MacGridMetrics.gutter(forWindowWidth: 1000), 32)
    }

    /// Every window from the minimum to a wide external display: covers in
    /// range, cells 24 apart, and a grid that never spills past its gutters
    /// (by more than the plates the view pulls out on purpose).
    func testCoversStayInRangeAndTheGridFitsAtEveryWidth() {
        var previousColumns = 0
        for width in stride(from: CGFloat(520), through: 2560, by: 1) {
            let metrics = MacGridMetrics(windowWidth: width)
            let content = width - 2 * MacGridMetrics.gutter(forWindowWidth: width)
            XCTAssertTrue(MacGridMetrics.coverWidths.contains(metrics.coverWidth),
                          "\(width) pt: cover \(metrics.coverWidth)")
            XCTAssertLessThanOrEqual(metrics.gridWidth, content + 2 * MacGridMetrics.plateOutset + 0.001,
                                     "\(width) pt")
            if width >= 600 {
                XCTAssertGreaterThanOrEqual(metrics.columns, previousColumns, "\(width) pt: wider never loses a column")
            }
            previousColumns = metrics.columns
        }
        XCTAssertEqual(MacGridMetrics.columnSpacing, 24)
    }

    // MARK: Shape

    func testCoverAspectIsTwoThirds() {
        for width: CGFloat in [520, 760, 1000, 1440, 2560] {
            let metrics = MacGridMetrics(windowWidth: width)
            XCTAssertEqual(metrics.coverWidth / metrics.coverHeight, 0.667, accuracy: 0.01, "\(width) pt")
        }
    }

    /// The drawn cover, not just the numbers: the one cover view, offered a
    /// grid column's width and any height, comes out 2:3.
    func testTheDrawnCoverFrameIsTwoThirds() throws {
        for width: CGFloat in [520, 1000] {
            let metrics = MacGridMetrics(windowWidth: width)
            let renderer = ImageRenderer(content: BookCover(title: "Emma", author: "Jane Austen"))
            renderer.proposedSize = ProposedViewSize(width: metrics.coverWidth, height: nil)
            let image = try XCTUnwrap(renderer.nsImage, "\(width) pt")
            XCTAssertEqual(image.size.width, metrics.coverWidth, accuracy: 0.5, "\(width) pt")
            XCTAssertEqual(image.size.width / image.size.height, 0.667, accuracy: 0.01, "\(width) pt")
        }
    }

    // MARK: Arrows

    /// 12 cards in 5 columns: rows of 5, 5 and 2.
    func testArrowsWalkTheGridByItsColumns() {
        let metrics = MacGridMetrics(windowWidth: 1000)
        XCTAssertEqual(metrics.columns, 5)
        let count = 12
        XCTAssertEqual(metrics.neighbor(of: 3, moving: .right, count: count), 4)
        XCTAssertNil(metrics.neighbor(of: 4, moving: .right, count: count), "a row's end stays put")
        XCTAssertNil(metrics.neighbor(of: 5, moving: .left, count: count), "a row's start stays put")
        XCTAssertEqual(metrics.neighbor(of: 6, moving: .left, count: count), 5)
        XCTAssertNil(metrics.neighbor(of: 2, moving: .up, count: count))
        XCTAssertEqual(metrics.neighbor(of: 7, moving: .up, count: count), 2)
        XCTAssertEqual(metrics.neighbor(of: 2, moving: .down, count: count), 7)
        XCTAssertEqual(metrics.neighbor(of: 6, moving: .down, count: count), 11)
        XCTAssertEqual(metrics.neighbor(of: 8, moving: .down, count: count), 11,
                       "over a short last row, down lands on its last card")
        XCTAssertNil(metrics.neighbor(of: 10, moving: .down, count: count))
        XCTAssertNil(metrics.neighbor(of: 11, moving: .right, count: count))
        XCTAssertNil(metrics.neighbor(of: 12, moving: .left, count: count), "an index past the grid")
    }

    /// The Continue card is on the arrows' path: ↑ from the grid's first
    /// row reaches it, ↓ from it lands on the first card, and the grid
    /// still walks by its columns. Without a card, ↑ stays put.
    func testUpFromTheFirstRowReachesTheContinueCard() {
        let metrics = MacGridMetrics(windowWidth: 1000)
        let hero = UUID()
        let grid = (0..<12).map { _ in UUID() }
        func target(_ from: UUID?, _ move: MacGridMetrics.Move, hero: UUID? = hero) -> UUID? {
            MacLibraryView.focusTarget(from: from, moving: move, hero: hero, grid: grid, metrics: metrics)
        }
        XCTAssertEqual(target(grid[2], .up), hero, "↑ from the first row")
        XCTAssertEqual(target(grid[0], .up), hero)
        XCTAssertEqual(target(grid[7], .up), grid[2], "within the grid, by its columns")
        XCTAssertEqual(target(hero, .down), grid[0], "↓ from the card")
        XCTAssertNil(target(hero, .up))
        XCTAssertNil(target(hero, .left))
        XCTAssertNil(target(grid[2], .up, hero: nil), "no card: focus stays")
        XCTAssertNil(target(grid[4], .right), "a row's end stays put")
        XCTAssertNil(target(nil, .down), "nothing focused")
    }
}
