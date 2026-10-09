import SwiftUI
import XCTest
@testable import Aloud

/// R22's numbers: one 2:3 cover, no type below 80pt, and lock-screen art
/// whose small variant is textless. Pure arithmetic, no views.
final class CoverGeometryTests: XCTestCase {

    func testEveryCoverIsTwoByThree() {
        XCTAssertEqual(CoverGeometry.aspectRatio, 0.667, accuracy: 0.01)
        XCTAssertEqual(CoverGeometry.height(forWidth: 160), 240)
    }

    func testTheHeroIsATextless64By96() {
        XCTAssertEqual(CoverGeometry.heroSize, CGSize(width: 64, height: 96))
        XCTAssertEqual(CoverGeometry.heroSize.width / CoverGeometry.heroSize.height,
                       CoverGeometry.aspectRatio, accuracy: 0.001)
        XCTAssertFalse(CoverGeometry.showsText(width: CoverGeometry.heroSize.width))
    }

    func testTypeStartsAtEightyPoints() {
        XCTAssertFalse(CoverGeometry.showsText(width: 79.99))
        XCTAssertTrue(CoverGeometry.showsText(width: 80))
        XCTAssertTrue(CoverGeometry.showsText(width: 160))
    }

    /// R1-04, R2-31: below 80pt each of the ornament's two rules scales with
    /// the cover (18% of its width, 1.5pt, as thick as a grid cover's rule);
    /// from 80pt the grid cover's one 26pt rule.
    func testRuleAndCornerFollowTheTextRule() {
        let small = CoverGeometry.ruleSize(forWidth: 64)
        XCTAssertEqual(small.width, 11.52, accuracy: 0.01)
        XCTAssertEqual(small.height, 1.5)
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 44).width, 7.92, accuracy: 0.01)
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 160), CGSize(width: 26, height: 1.5))
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 64), Theme.Radius.sm)
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 160), Theme.Radius.md)
    }

    /// R2-31: the 64pt face is a small clothbound book: a 5pt spine down
    /// its leading edge, and a stamped ornament (two rules either side of a
    /// 4pt diamond) centred a little above the middle, at 42% of the
    /// height. All of it stays clear of the point where
    /// BookCoverRenderingTests' testTheSmallFaceStandsOffTheCard samples
    /// the ground (the centre, four fifths down), and of the cover's edges.
    func testTheSmallFaceIsAClothboundBook() {
        let hero = CoverGeometry.heroSize
        let spine = CoverGeometry.spineWidth(forWidth: hero.width)
        XCTAssertEqual(CoverGeometry.spineFraction, 0.08)
        XCTAssertEqual(spine, 5.12, accuracy: 0.01, "about 5pt at 64")
        XCTAssertEqual(CoverGeometry.ornamentTop, 0.42)
        XCTAssertEqual(CoverGeometry.ornamentRuleFraction, 0.18)
        XCTAssertEqual(CoverGeometry.ornamentDiamondSide, 4)
        XCTAssertGreaterThan(CoverGeometry.spineOpacity, 0.05)
        XCTAssertLessThan(CoverGeometry.spineOpacity, 0.3, "a pale spine, not a stripe")

        let sample = CGPoint(x: hero.width / 2, y: hero.height * 4 / 5)
        XCTAssertGreaterThan(sample.x, spine + 4, "the sample point is clear of the spine")
        let centre = hero.height * CoverGeometry.ornamentTop
        let halfHeight = CoverGeometry.ornamentDiamondSide * 2.0.squareRoot() / 2
        XCTAssertLessThan(centre + halfHeight + 4, sample.y, "the sample point is clear of the ornament")
        XCTAssertGreaterThan(hero.height - CoverGeometry.panelInset, sample.y + 4,
                             "the sample point is inside the panel, off its hairline")
        XCTAssertGreaterThan(CoverGeometry.panelInset, spine, "the panel sits inside the spine's edge")

        // The ornament fits across every small cover, clear of the spine.
        for width: CGFloat in [44, 64, 79] {
            let ornament = CoverGeometry.ornamentWidth(forWidth: width)
            XCTAssertLessThan(ornament, width - 2 * CoverGeometry.spineWidth(forWidth: width) - 4,
                              "\(width)pt: the ornament is \(ornament)pt")
            XCTAssertFalse(CoverGeometry.showsText(width: width))
        }
    }

    /// R1-08: a long press lifts the cover alone: the cell's width at 2:3
    /// from its top, or the hero's fixed cover at the accessibility sizes,
    /// whatever caption hangs below it. The card draws its cover by the
    /// same rule.
    func testTheLiftIsTheCoverAlone() {
        func assertBounds(_ shape: CoverLiftShape, in rect: CGRect, _ expected: CGRect,
                          line: UInt = #line) {
            let bounds = shape.path(in: rect).boundingRect
            for (got, want) in [(bounds.minX, expected.minX), (bounds.minY, expected.minY),
                                (bounds.width, expected.width), (bounds.height, expected.height)] {
                XCTAssertEqual(got, want, accuracy: 0.01, "\(bounds)", line: line)
            }
        }
        assertBounds(CoverLiftShape(fixedSize: nil), in: CGRect(x: 0, y: 0, width: 160, height: 330),
                     CGRect(x: 0, y: 0, width: 160, height: 240))
        assertBounds(CoverLiftShape(fixedSize: CoverGeometry.heroSize), in: CGRect(x: 0, y: 0, width: 335, height: 260),
                     CGRect(origin: .zero, size: CoverGeometry.heroSize))
        XCTAssertFalse(DocumentCardView.usesHeroCover(at: .large))
        XCTAssertFalse(DocumentCardView.usesHeroCover(at: .xxxLarge))
        XCTAssertTrue(DocumentCardView.usesHeroCover(at: .accessibility1))
        XCTAssertTrue(DocumentCardView.usesHeroCover(at: .accessibility5))
    }

    /// R1-03: the author's lines run a little wider than the title's, so on
    /// the narrowest grid cover (the Mac's 136pt) they are 112pt, room for
    /// the Mac eyebrow's 107pt longest word in a long name, where the
    /// title's 104pt face cut it. MacGridMetricsTests measures the type.
    func testTheAuthorLineIsALittleWiderThanTheTitles() {
        XCTAssertLessThan(CoverGeometry.authorInset, Theme.Space.md)
        XCTAssertGreaterThanOrEqual(CoverGeometry.authorInset, Theme.Space.xs, "still clear of the cover's edge")
        XCTAssertEqual(CoverGeometry.authorLineWidth(forWidth: 136), 112)
        XCTAssertEqual(CoverGeometry.authorLineWidth(forWidth: 160), 160 - 2 * CoverGeometry.authorInset)
    }

    func testTheArtworkCoverIsCentredInItsSquare() {
        let rect = CoverGeometry.artworkCoverRect(side: 300)
        XCTAssertEqual(rect, CGRect(x: 70, y: 30, width: 160, height: 240))
        XCTAssertEqual(rect.midX, 150)
        XCTAssertEqual(rect.midY, 150)
    }

    /// Below 150pt the art's cover would be narrower than 80pt, so the small
    /// variant (96pt, a 51pt cover) is the textless one.
    func testTheSmallArtworkIsTextless() {
        XCTAssertEqual(CoverGeometry.artworkCoverRect(side: NowPlayingArtwork.textlessSide).width, 80, accuracy: 0.001)
        XCTAssertFalse(CoverGeometry.showsText(
            width: CoverGeometry.artworkCoverRect(side: NowPlayingArtwork.smallSide).width))
    }
}
