import XCTest
@testable import Aloud

/// Round 4's Classics and empty-Library fixes, on both apps: the shelf map's
/// compact cell (R4-17), VoiceOver landing on a jumped-to shelf's heading
/// (R4-18) and the empty Library's optical centre (R4-22). The placement
/// math runs everywhere; the source pins skip where the checkout can't be
/// read (`SourceTree`).
final class ClassicsShelfRound4Tests: XCTestCase {

    private static let iosShelf = "Bookshelf/BookshelfView.swift"
    private static let macShelf = "Library/MacClassicsView.swift"
    private static let iosEmpty = "Library/EmptyLibraryView.swift"
    private static let macLibrary = "Library/MacLibraryView.swift"

    // MARK: - R4-22: the optical centre

    /// A block that fits sits `bias` of the slack down: 0.42 of it above,
    /// the rest below, so its middle is above the column's.
    func testABlockThatFitsTakesTheBiasOfTheSlack() {
        XCTAssertEqual(OpticalCenterColumn.offset(blockHeight: 304, in: 724), 176.4, accuracy: 0.001)
        XCTAssertEqual(OpticalCenterColumn.offset(blockHeight: 300, in: 700, bias: 0.5), 200, accuracy: 0.001)
        let column = OpticalCenterColumn(minHeight: 724)
        XCTAssertEqual(column.bias, 0.42, "the default bias")
        let top = OpticalCenterColumn.offset(blockHeight: 304, in: 724, bias: column.bias)
        XCTAssertLessThan(top + 304 / 2, 724 / 2, "the block's middle sits above the column's")
        XCTAssertGreaterThan(top, 0, "but not at the top")
    }

    /// A block as tall as the column, or taller (AX5), starts at its top
    /// and scrolls, as it did centred.
    func testABlockThatOverflowsStartsAtTheTop() {
        XCTAssertEqual(OpticalCenterColumn.offset(blockHeight: 724, in: 724), 0)
        XCTAssertEqual(OpticalCenterColumn.offset(blockHeight: 1400, in: 724), 0)
        XCTAssertEqual(OpticalCenterColumn.offset(blockHeight: 1400, in: 724, bias: 1), 0)
    }

    /// Both empty Libraries set their block with the one layout, in place of
    /// the centring min-height frame, and the layout places by `offset`.
    func testBothEmptyLibrariesUseTheOpticalCentre() throws {
        let s = try SourceTree.sources(only: [Self.iosEmpty])
        let mac = SourceTree.exists(SourceTree.macRoot)
            ? try SourceTree.sources(in: SourceTree.macRoot, only: [Self.macLibrary]) : [:]
        let ios = try XCTUnwrap(s[Self.iosEmpty])
        var files = [("EmptyLibraryView", try Self.body(of: "struct EmptyLibraryView: View {", in: ios))]
        if SourceTree.exists(SourceTree.macRoot) {
            let macText = try XCTUnwrap(mac[Self.macLibrary])
            files.append(("MacEmptyLibrary", try Self.body(of: "private struct MacEmptyLibrary: View {", in: macText)))
        }
        for (name, body) in files {
            XCTAssertTrue(body.contains(".opticalCenter(minHeight: proxy.size.height)"), "\(name): \(body.prefix(1600))")
            XCTAssertFalse(body.contains(".frame(maxWidth: .infinity, minHeight:"), "\(name): no centring frame")
            XCTAssertTrue(body.contains(".padding(.vertical, Theme.Space.xl)"), name)
        }
        let iosBody = try Self.body(of: "struct EmptyLibraryView: View {", in: ios)
        XCTAssertTrue(iosBody.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(iosBody.contains(".shelfScrollEdge(rule: true)"))

        let layout = try Self.body(of: "struct OpticalCenterColumn: Layout {", in: ios)
        XCTAssertTrue(layout.contains("ProposedViewSize(width: proposal.width, height: nil)"), String(layout))
        XCTAssertTrue(layout.contains("max(size.height, minHeight)"), String(layout))
        XCTAssertTrue(layout.contains("Self.offset(blockHeight: size.height, in: bounds.height, bias: bias)"),
                      String(layout))
        XCTAssertFalse(layout.contains("@State"), "stateless: one pass, nothing jumps after the first frame")
        let helper = try Self.body(of: "func opticalCenter(minHeight: CGFloat) -> some View {", in: ios)
        XCTAssertTrue(helper.contains("OpticalCenterColumn(minHeight: minHeight) { self }"), String(helper))
        XCTAssertTrue(helper.contains(".frame(maxWidth: .infinity)"), String(helper))
    }

    // MARK: - R4-18: a jump hands VoiceOver to the shelf's heading

    /// Both apps hold the focus, the heading answers to it, and the jump
    /// sets it in the settle's last turn, after the second scroll, once the
    /// far heading is laid out; never on a timer, and cleared first so a
    /// repeat jump moves it again.
    func testAJumpMovesVoiceOverToTheShelfsHeading() throws {
        let s = try SourceTree.sources(only: [Self.iosShelf])
        let mac = SourceTree.exists(SourceTree.macRoot)
            ? try SourceTree.sources(in: SourceTree.macRoot, only: [Self.macShelf]) : [:]
        var files = [("BookshelfView", try XCTUnwrap(s[Self.iosShelf]), "proxy")]
        if SourceTree.exists(SourceTree.macRoot) {
            files.append(("MacClassicsView", try XCTUnwrap(mac[Self.macShelf]), "scroller"))
        }
        for (name, file, scroller) in files {
            XCTAssertTrue(file.contains("@AccessibilityFocusState private var focusedShelf: BookshelfSection?"), name)

            let header = try Self.body(of: "private func header(_ section: BookshelfSection) -> some View {", in: file)
            let trait = try XCTUnwrap(header.range(of: ".accessibilityAddTraits(.isHeader)"), name)
            let focus = try XCTUnwrap(header.range(of: ".accessibilityFocused($focusedShelf, equals: section)"),
                                      "\(name): \(header)")
            XCTAssertLessThan(trait.lowerBound, focus.lowerBound, "\(name): next to the header trait")
            XCTAssertEqual(file.components(separatedBy: ".accessibilityFocused(").count - 1, 1,
                           "\(name): only the heading takes the focus")

            let jump = try Self.body(of: "private func jump(to section: BookshelfSection, _ \(scroller): ScrollViewProxy) {",
                                     in: file)
            let clear = try XCTUnwrap(jump.range(of: "focusedShelf = nil"), "\(name): \(jump)")
            let settle = try XCTUnwrap(jump.range(of: "let settle = {"), "\(name): \(jump)")
            XCTAssertLessThan(clear.lowerBound, settle.lowerBound, "\(name): cleared before the scrolls")
            let async = try XCTUnwrap(jump.range(of: "DispatchQueue.main.async {", range: settle.upperBound..<jump.endIndex),
                                      "\(name): \(jump)")
            let turn = try Self.body(of: "DispatchQueue.main.async {", in: String(jump[async.lowerBound...]))
            let second = try XCTUnwrap(turn.range(of: "\(scroller).scrollTo(id, anchor: .top)"), "\(name): \(turn)")
            let set = try XCTUnwrap(turn.range(of: "focusedShelf = section"), "\(name): \(turn)")
            XCTAssertLessThan(second.lowerBound, set.lowerBound, "\(name): after the second scroll")
            XCTAssertEqual(jump.components(separatedBy: "focusedShelf = section").count - 1, 1,
                           "\(name): set once, in the settle's last turn")
            for timer in ["asyncAfter", "Timer", "Task.sleep"] {
                XCTAssertFalse(jump.contains(timer), "\(name): never on a timer (\(timer))")
            }
            // Picks stay silent: no announcement and no haptic.
            for noise in ["postAnnouncement", "AccessibilityNotification", "TransportHaptics.emit", "UIAccessibility.post"] {
                XCTAssertFalse(jump.contains(noise), "\(name): \(noise)")
            }
        }
    }

    // MARK: - R4-17: the shelf map's compact cell

    /// The iPhone's jump cell is the title over its count, through the one
    /// layout (no ViewThatFits, no text size gate), keeping its padding,
    /// its 44 pt floor and the gutter.
    func testTheShelfMapCellIsTheTitleOverItsCount() throws {
        let s = try SourceTree.sources(only: [Self.iosShelf])
        let file = try XCTUnwrap(s[Self.iosShelf])
        let map = try Self.body(of: "private func shelfMap(_ proxy: ScrollViewProxy) -> some View {", in: file)
        XCTAssertTrue(map.contains("ShelfMapLayout(spacing: Theme.Space.xs)"), String(map))
        XCTAssertFalse(map.contains("ViewThatFits"), "one set of buttons")
        XCTAssertFalse(map.contains("dynamicTypeSize"), "the layout falls back to rows by itself")
        XCTAssertTrue(map.contains(".padding(.horizontal, Theme.Space.screenGutter - Theme.Space.sm)"), String(map))

        let cell = try Self.body(of: "private func jumpButton(_ jump: ShelfJump, _ proxy: ScrollViewProxy) -> some View {",
                                 in: file)
        Self.assertStackedCell(cell, "BookshelfView")
        XCTAssertTrue(cell.contains(".padding(.horizontal, Theme.Space.sm)"), String(cell))
        XCTAssertTrue(cell.contains(".padding(.vertical, Theme.Space.xxs)"), String(cell))
        XCTAssertTrue(cell.contains("minHeight: 44"), String(cell))
        XCTAssertTrue(cell.contains(".buttonStyle(ShelfRowButtonStyle())"), String(cell))
        XCTAssertTrue(cell.contains(".accessibilityLabel(jump.accessibilityLabel)"), String(cell))
        XCTAssertTrue(cell.contains(".accessibilityHint(ShelfJump.hint)"), String(cell))
        XCTAssertTrue(cell.contains(".accessibilityIdentifier(jump.identifier)"), String(cell))
    }

    /// The Mac's map draws the same cell.
    func testTheMacShelfMapDrawsTheSameCell() throws {
        guard SourceTree.exists(SourceTree.macRoot) else { throw XCTSkip("AloudMac not created yet") }
        let s = try SourceTree.sources(in: SourceTree.macRoot, only: [Self.macShelf])
        let file = try XCTUnwrap(s[Self.macShelf])
        let map = try Self.body(of: "private func shelfMap(_ scroller: ScrollViewProxy) -> some View {", in: file)
        Self.assertStackedCell(map, "MacClassicsView")
    }

    private static func assertStackedCell(_ cell: String, _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let stack = cell.range(of: "VStack(alignment: .leading, spacing: 0) {") else {
            return XCTFail("\(name): the title over its count: \(cell)", file: file, line: line)
        }
        let label = cell[stack.upperBound...]
        let title = label.range(of: "Text(jump.title)\n")
        let titleFont = label.range(of: ".font(Theme.font(.callout).weight(.medium))")
        let titleInk = label.range(of: ".foregroundStyle(Theme.accentStrong)")
        let count = label.range(of: "Text(jump.countText)\n")
        let countFont = label.range(of: ".font(Theme.font(.caption))")
        let countInk = label.range(of: ".foregroundStyle(Theme.textMuted)")
        let order = [title, titleFont, titleInk, count, countFont, countInk]
        XCTAssertFalse(order.contains { $0 == nil }, "\(name): \(String(label.prefix(600)))", file: file, line: line)
        let bounds = order.compactMap { $0?.lowerBound }
        XCTAssertEqual(bounds, bounds.sorted(), "\(name): title, its font and ink, then the count's",
                       file: file, line: line)
        XCTAssertFalse(cell.contains("HStack(alignment: .firstTextBaseline"), "\(name): no longer one line",
                       file: file, line: line)
        XCTAssertFalse(cell.contains(".lineLimit("), "\(name): no line limit", file: file, line: line)
    }

    // MARK: - Source helpers

    private struct MissingSource: Error, CustomStringConvertible {
        let signature: String
        var description: String { "missing \(signature)" }
    }

    /// The text between `signature`'s opening brace and its matching close;
    /// a missing signature fails the test rather than skipping it.
    private static func body(of signature: String, in source: String) throws -> String {
        guard let start = source.range(of: signature) else { throw MissingSource(signature: signature) }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return String(source[start.upperBound...])
    }
}
