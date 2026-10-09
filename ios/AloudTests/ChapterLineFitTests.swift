#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Aloud

/// R3-16: the chapter line says its time counts to the chapter's end
/// wherever the whole line fits its one 44 pt row, and falls back to the
/// short form where it doesn't, never growing the row and never truncating
/// the time. Hosted at a 375 pt phone's width on the bar's foot; the widths
/// it compares against are measured from the line's own fonts, so no font
/// metric is assumed. iPhone only, as RenderedPixels is (the Mac's bar
/// shares the line, and MacPlayerBarTests measures its rows).
@MainActor
final class ChapterLineFitTests: XCTestCase {

    /// A 375 pt phone.
    private static let width: CGFloat = 375

    private func line(_ position: ReaderPositionLine, _ size: DynamicTypeSize) -> some View {
        ReaderMessageLine(message: nil, position: position, onOpenContents: {}, onRetry: {},
                          onBackFiveMinutes: {}, rowAlignment: .bottom)
            .environment(\.dynamicTypeSize, size)
    }

    private func height(_ position: ReaderPositionLine, _ size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: line(position, size))
            .sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
            .height
    }

    private func idealWidth(_ view: some View, _ size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: view.fixedSize().environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            .width
    }

    /// Where each form of the line would end, and where the Contents glyph
    /// starts, from the line's own fonts at `size`.
    private struct Metrics {
        /// The glyph's leading edge; the text keeps at least `Theme.Space.xs`
        /// clear of it.
        let glyphLeft: CGFloat
        let shortRight: CGFloat
        let qualifiedRight: CGFloat
    }

    private func metrics(_ position: ReaderPositionLine, _ size: DynamicTypeSize) -> Metrics {
        let gutter = Theme.Space.screenGutter
        let title = idealWidth(Text(position.title).font(ReaderMessageLine.titleFont(.standard)), size)
        func detail(_ text: String) -> CGFloat {
            idealWidth(Text("\u{00A0}\u{00B7} " + text).font(ReaderMessageLine.detailFont(.standard)).monospacedDigit(),
                       size)
        }
        let glyph = idealWidth(Image(systemName: "list.bullet").font(Theme.font(.caption, scale: .standard)), size)
        return Metrics(glyphLeft: Self.width - gutter - glyph,
                       shortRight: gutter + title + detail(position.detail),
                       qualifiedRight: gutter + title + detail(position.qualifiedDetail))
    }

    /// The line drawn in its row: the leftmost column with ink, and the
    /// rightmost left of `limit` (the glyph's side).
    private func ink(_ position: ReaderPositionLine, _ size: DynamicTypeSize,
                     before limit: CGFloat) throws -> (left: CGFloat, right: CGFloat) {
        let pixels = try XCTUnwrap(RenderedPixels(line(position, size),
                                                  size: CGSize(width: Self.width, height: ReaderMessageLine.rowHeight),
                                                  scale: 1))
        func inked(_ x: Int) -> Bool { (0..<pixels.height).contains { pixels.rgba(x: x, y: $0).a > 24 } }
        let end = min(Int(limit.rounded(.down)), pixels.width)
        let left = try XCTUnwrap((0..<end).first(where: inked), "the line draws its text")
        let right = try XCTUnwrap((0..<end).reversed().first(where: inked))
        return (CGFloat(left), CGFloat(right + 1))
    }

    /// At the default size the opening chapter's whole line fits: the time
    /// says it counts to the chapter's end, in one 44 pt row.
    func testTheQualifiedLineFitsWhereItHasRoom() throws {
        let position = ReaderPositionLine(kind: .chapter(number: 1, count: 9), title: "Chapter I", minutesLeft: 37)
        let size = DynamicTypeSize.large
        XCTAssertEqual(height(position, size), ReaderMessageLine.rowHeight, accuracy: 0.5, "one 44 pt row")

        let m = metrics(position, size)
        XCTAssertLessThan(m.qualifiedRight, m.glyphLeft - 2 * Theme.Space.xs, "the premise: the whole line has room")
        let drawn = try ink(position, size, before: m.glyphLeft - 2)
        XCTAssertGreaterThan(drawn.right, m.shortRight + 10, "the qualified time, not the short one")
        XCTAssertEqual(drawn.right, m.qualifiedRight, accuracy: 4, "the whole qualified line, untruncated")
    }

    /// A title that leaves room for the short form but not the qualified one
    /// keeps itself whole and drops the qualifier: the short time, never a
    /// truncated title beside the long one.
    func testATitleWithRoomOnlyForTheShortFormKeepsItWhole() throws {
        let size = DynamicTypeSize.large
        let words = "Chapter XXIV. In Which the Travellers, Having Crossed the Frozen Sea, Come at Last to the Northern Shore"
        var found: (position: ReaderPositionLine, metrics: Metrics)?
        for count in 9...words.count {
            let title = String(words.prefix(count))
            guard title.last != " " else { continue }
            let position = ReaderPositionLine(kind: .chapter(number: 24, count: 61), title: title, minutesLeft: 72)
            let m = metrics(position, size)
            // The first title the qualified line can't fit beside, wherever
            // the row's spacing puts its edge.
            if m.qualifiedRight > m.glyphLeft - Theme.Space.xs {
                found = (position, m)
                break
            }
        }
        let (position, m) = try XCTUnwrap(found, "some prefix outgrows the qualified line")
        XCTAssertLessThanOrEqual(m.shortRight, m.glyphLeft - 2 * Theme.Space.xs,
                                 "the premise: the short line still fits '\(position.title)'")
        XCTAssertEqual(height(position, size), ReaderMessageLine.rowHeight, accuracy: 0.5, "one 44 pt row")

        let drawn = try ink(position, size, before: m.glyphLeft - 2)
        XCTAssertEqual(drawn.right, m.shortRight, accuracy: 4, "the short time beside the whole title")
        XCTAssertLessThan(drawn.right, m.qualifiedRight - 20, "not the qualified one")
    }

    /// At xxxLarge a late chapter's line can't fit the qualifier: it falls
    /// back to the short form (the title truncates, the time never does),
    /// stays one 44 pt row, and keeps clear of the Contents glyph, where the
    /// qualified time, which never truncates, would run past it.
    func testALongLineFallsBackToTheShortFormInOneRow() throws {
        let position = ReaderPositionLine(kind: .chapter(number: 24, count: 61), title: "Chapter XXIV",
                                          minutesLeft: 72)
        let size = DynamicTypeSize.xxxLarge
        XCTAssertEqual(height(position, size), ReaderMessageLine.rowHeight, accuracy: 0.5, "still one 44 pt row")

        let m = metrics(position, size)
        XCTAssertGreaterThan(m.qualifiedRight, m.glyphLeft - Theme.Space.xs, "the premise: the qualifier can't fit")
        let drawn = try ink(position, size, before: m.glyphLeft - 2)
        XCTAssertGreaterThanOrEqual(drawn.left, Theme.Space.screenGutter - 1, "the row never overflows its gutter")
        XCTAssertLessThanOrEqual(drawn.right, m.glyphLeft - Theme.Space.xs + 1,
                                 "the text keeps clear of the glyph: the short form")
        XCTAssertLessThanOrEqual(drawn.right, m.shortRight + 1, "no wider than the short line")
    }
}
#endif
