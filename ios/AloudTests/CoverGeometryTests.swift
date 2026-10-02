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

    func testRuleAndCornerFollowTheTextRule() {
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 64), CGSize(width: 14, height: 1))
        XCTAssertEqual(CoverGeometry.ruleSize(forWidth: 160), CGSize(width: 26, height: 1.5))
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 64), Theme.Radius.sm)
        XCTAssertEqual(CoverGeometry.cornerRadius(forWidth: 160), Theme.Radius.md)
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
