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

    /// R1-04: below 80pt the rule scales with the cover (40% of its width,
    /// 1.5pt, as thick as a grid cover's), so the hero reads as a small book.
    func testRuleAndCornerFollowTheTextRule() {
        let small = CoverGeometry.ruleSize(forWidth: 64)
        XCTAssertEqual(small.width, 25.6, accuracy: 0.01)
        XCTAssertEqual(small.height, 1.5)
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 44).width, 17.6, accuracy: 0.01)
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 160), CGSize(width: 26, height: 1.5))
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 64), Theme.Radius.sm)
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 160), Theme.Radius.md)
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
