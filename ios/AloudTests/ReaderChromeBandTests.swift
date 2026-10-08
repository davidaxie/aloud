import SwiftUI
import XCTest
@testable import Aloud

/// The shared chrome in the reader's bands (M18, mac-ux §10.4): the chapter
/// line, the natural-voice offer that takes its place, and the Play glyph.
/// On the Mac they read the band; on the iPhone they render as they always
/// have: the type follows Dynamic Type whatever the band, the line stacks
/// only at the accessibility sizes, and the glyph is title2 bold in the bar's
/// 54 pt circle and title3 semibold in the Continue card's 44. Runs on both
/// hosts; pure values, no window.
final class ReaderChromeBandTests: XCTestCase {

    // MARK: - Chapter line

    /// The iPhone's two-line rule holds in every band, and stays the only
    /// one under the accessibility sizes there.
    func testTheLineStacksAtEveryAccessibilitySize() {
        for scale in ChromeScale.allCases {
            for size in DynamicTypeSize.allCases where size.isAccessibilitySize {
                XCTAssertTrue(ReaderMessageLine.stacksPosition(dynamicTypeSize: size, scale: scale), "\(size), \(scale)")
            }
        }
        XCTAssertFalse(ReaderMessageLine.stacksPosition(dynamicTypeSize: .xxxLarge, scale: .standard),
                       "the largest size short of the accessibility ones keeps one line")
    }

    /// Short of the accessibility sizes, only the Mac's Largest band lets
    /// the title wrap; the iPhone's line never wraps by band.
    func testOnlyTheMacsLargestBandWrapsTheLineByItself() {
        let wraps = ChromeScale.allCases.map { ReaderMessageLine.stacksPosition(dynamicTypeSize: .large, scale: $0) }
        #if os(macOS)
        XCTAssertEqual(wraps, [false, false, true])
        #else
        XCTAssertEqual(wraps, [false, false, false])
        #endif
        XCTAssertEqual(ChromeScale.allCases.map { PlatformTypeRamp.wrapsChapterLine(in: $0) }, wraps)
    }

    /// The line's type in each band: the Mac's ramp on the Mac, and on the
    /// iPhone the very fonts it set before the line read the band.
    func testTheLinesTypeFollowsTheBandOnlyOnTheMac() {
        for scale in ChromeScale.allCases {
            #if os(macOS)
            let points = PlatformTypeRamp.points(.subhead, scale: scale)
            XCTAssertEqual(ReaderMessageLine.titleFont(scale), .system(size: points, weight: .semibold), "\(scale)")
            XCTAssertEqual(ReaderMessageLine.detailFont(scale),
                           .system(size: PlatformTypeRamp.points(.footnote, scale: scale)), "\(scale)")
            #else
            XCTAssertEqual(ReaderMessageLine.titleFont(scale), .footnote.weight(.semibold), "\(scale)")
            XCTAssertEqual(ReaderMessageLine.detailFont(scale), .footnote, "\(scale)")
            #endif
            XCTAssertEqual(ReaderMessageLine.titleFont(scale), Theme.font(.subhead, scale: scale), "\(scale)")
            XCTAssertEqual(ReaderMessageLine.detailFont(scale), Theme.font(.footnote, scale: scale), "\(scale)")
        }
        XCTAssertEqual(ReaderMessageLine.titleFont(.standard), Theme.font(.subhead), "the band's default is today's type")
        XCTAssertEqual(ReaderMessageLine.detailFont(.standard), Theme.font(.footnote))
        XCTAssertEqual(EnvironmentValues().chromeScale, .standard, "nothing on the iPhone sets a band")
    }

    /// R1-43: the Contents glyph sits beside the title in both layouts, so
    /// it shows at every text size (it was dropped when the line stacked),
    /// and the inline line sets its first dot with the detail's own spacing.
    /// A source pin: skips where the checkout can't be read (the Mac host).
    func testTheContentsGlyphShowsInBothLayouts() throws {
        let path = "Reader/ReaderMessageLine.swift"
        let s = try SourceTree.sources(only: [path])
        let source = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(source.range(of: "private var positionLine: some View"))
        let end = try XCTUnwrap(source.range(of: "private var contentsGlyph", range: start.upperBound..<source.endIndex))
        let line = source[start.upperBound..<end.lowerBound]
        let stackedStart = try XCTUnwrap(line.range(of: "if Self.stacksPosition("))
        let split = try XCTUnwrap(line.range(of: "} else {", range: stackedStart.upperBound..<line.endIndex))
        let stacked = line[stackedStart.upperBound..<split.lowerBound]
        let inline = line[split.upperBound...]
        XCTAssertTrue(stacked.contains("contentsGlyph"), "the stacked line: " + String(stacked))
        XCTAssertTrue(inline.contains("contentsGlyph"), "the inline line: " + String(inline))
        XCTAssertFalse(source.contains("\"chevron.up\""), "the line opens Contents, not a mini-player")
        XCTAssertTrue(source.contains("Image(systemName: \"list.bullet\")"))
        XCTAssertTrue(inline.contains("\"\\u{00A0}\\u{00B7} \" + position.detail"),
                      "the first dot's gaps match the detail's: " + String(inline))
        XCTAssertTrue(inline.contains("HStack(alignment: .firstTextBaseline, spacing: 0)"),
                      "the title and its detail sit with no gap of their own: " + String(inline))
    }

    /// The offer row and the line's Contents glyph take the band through
    /// `Theme.font`, which leaves the iPhone's styles as they were.
    func testTheBandLeavesTheIPhonesStylesAlone() {
        #if os(iOS)
        for scale in ChromeScale.allCases {
            for style in [Theme.TypeStyle.subhead, .callout, .footnote, .caption] {
                XCTAssertEqual(Theme.font(style, scale: scale), Theme.font(style), "\(style), \(scale)")
            }
        }
        #else
        XCTAssertNotEqual(Theme.font(.callout, scale: .largest), Theme.font(.callout), "the Mac steps it up")
        #endif
    }

    // MARK: - Play glyph

    /// The iPhone's glyph is what it was: title2 bold in the bar's 54 pt
    /// circle, title3 semibold in the Continue card's 44. The Mac sizes it
    /// from the circle instead.
    func testThePlayGlyphIsUnchangedOnTheIPhone() {
        let bar = PlayCircleFace.glyphFont(diameter: Theme.PlayCircle.diameter)
        let card = PlayCircleFace.glyphFont(diameter: Theme.PlayCircle.compactDiameter)
        XCTAssertEqual(Theme.PlayCircle.diameter, 54)
        XCTAssertEqual(Theme.PlayCircle.compactDiameter, 44)
        #if os(iOS)
        XCTAssertEqual(bar, .title2.weight(.bold))
        XCTAssertEqual(card, .title3.weight(.semibold))
        XCTAssertNil(PlatformTypeRamp.playGlyphFont(diameter: Theme.PlayCircle.diameter))
        #else
        XCTAssertEqual(bar, .system(size: 22, weight: .bold), "the iPhone's 22 pt in its 54 pt circle")
        XCTAssertEqual(card, .system(size: 18, weight: .bold))
        #endif
    }

    /// The Mac's rule keeps the iPhone's proportion, and a larger circle
    /// never gets a smaller glyph.
    func testTheGlyphPointsKeepTheIPhonesProportion() {
        XCTAssertEqual(PlatformTypeRamp.playGlyphPoints(diameter: Theme.PlayCircle.diameter), 22)
        let points = ChromeScale.allCases.map { PlatformTypeRamp.playGlyphPoints(diameter: $0.playCircleDiameter) }
        XCTAssertEqual(points, [18, 21, 24])
        for diameter in stride(from: CGFloat(40), through: 72, by: 1) {
            let glyph = PlatformTypeRamp.playGlyphPoints(diameter: diameter)
            XCTAssertEqual(glyph / diameter, 22 / 54, accuracy: 0.5 / diameter, "\(diameter) pt")
            XCTAssertLessThanOrEqual(glyph, PlatformTypeRamp.playGlyphPoints(diameter: diameter + 1), "\(diameter) pt")
        }
    }
}
