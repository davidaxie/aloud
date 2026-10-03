import XCTest
@testable import Aloud

/// Calm follow's state and decisions (R16), with no text view: when a
/// follow glides or jumps, who stops and resumes following, which way the
/// chip points, and when a placement without motion has settled. The
/// same rules on a real column are ReaderFollowCoordinatorTests.
final class ReaderFollowEngineTests: XCTestCase {

    /// An 800pt viewport at the top of a long text: the band runs from
    /// 144 to 560, and the landing line is at 224.
    private func state(offset: CGFloat = 0, reduceMotion: Bool = false) -> ReaderScrollState {
        ReaderScrollState(contentOffsetY: offset,
                          viewport: CGRect(x: 0, y: offset, width: 390, height: 800),
                          restingRange: 0...10_000, reduceMotion: reduceMotion)
    }

    // MARK: - Moves

    func testAMoveWithinAPointIsNoScroll() {
        XCTAssertEqual(ReaderFollowEngine.move(to: 0.5, in: state(), animated: true, reaim: true), .none)
        XCTAssertEqual(ReaderFollowEngine.move(to: -1, in: state(), animated: false, reaim: false), .none)
    }

    func testAMoveWithinOneViewportGlides() {
        XCTAssertEqual(ReaderFollowEngine.move(to: 600, in: state(), animated: true, reaim: true),
                       .glide(toY: 600))
        XCTAssertEqual(ReaderFollowEngine.move(to: 0, in: state(offset: 800), animated: true, reaim: false),
                       .glide(toY: 0))
    }

    func testALongMoveReduceMotionOrNoAnimationJumps() {
        XCTAssertEqual(ReaderFollowEngine.move(to: 5_000, in: state(), animated: true, reaim: true),
                       .jump(toY: 5_000, reaim: true))
        XCTAssertEqual(ReaderFollowEngine.move(to: 600, in: state(reduceMotion: true), animated: true, reaim: true),
                       .jump(toY: 600, reaim: true))
        XCTAssertEqual(ReaderFollowEngine.move(to: 600, in: state(), animated: false, reaim: false),
                       .jump(toY: 600, reaim: false))
    }

    func testTheLandingPutsTheSentenceTopOnTheLandingLineWithinTheRestingRange() {
        let sentence = CGRect(x: 24, y: 1_000, width: 300, height: 29)
        XCTAssertEqual(ReaderFollowEngine.landingOffset(for: sentence, in: state()), 1_000 - 224, accuracy: 0.001)
        var pinned = state()
        pinned.restingRange = 0...500
        XCTAssertEqual(ReaderFollowEngine.landingOffset(for: sentence, in: pinned), 500)
    }

    // MARK: - Following

    func testTakingOverStopsFollowingAndDropsPendingChecks() {
        var engine = ReaderFollowEngine()
        engine.startPlacementCheck()
        engine.startRevealCheck(7)
        engine.takeOver()
        XCTAssertFalse(engine.isFollowing)
        XCTAssertFalse(engine.pendingPlacement)
        XCTAssertNil(engine.pendingReveal)
        XCTAssertFalse(engine.isCheckingPlacement)
    }

    func testResumingFollowsAndEndsARotorStopsCheck() {
        var engine = ReaderFollowEngine()
        engine.takeOver()
        engine.startRevealCheck(3)
        engine.resume()
        XCTAssertTrue(engine.isFollowing)
        XCTAssertNil(engine.pendingReveal)
    }

    func testAScrollEndingWithTheVoiceInViewFollowsAgainAndOnlyThen() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)
        var engine = ReaderFollowEngine()
        engine.takeOver()
        engine.scrollEnded(voice: CGRect(x: 0, y: 900, width: 300, height: 29), in: viewport)
        XCTAssertFalse(engine.isFollowing, "the voice is below the screen")
        engine.scrollEnded(voice: CGRect(x: 0, y: 790, width: 300, height: 29), in: viewport)
        XCTAssertTrue(engine.isFollowing, "part of it shows")
    }

    func testTheChipPointsAtTheVoiceOnlyWhileNotFollowing() {
        let viewport = CGRect(x: 0, y: 1_000, width: 390, height: 800)
        let above = CGRect(x: 0, y: 100, width: 300, height: 29)
        let below = CGRect(x: 0, y: 2_000, width: 300, height: 29)
        var engine = ReaderFollowEngine()
        XCTAssertNil(engine.chipDirection(voice: below, in: viewport), "no chip while following")
        engine.takeOver()
        XCTAssertEqual(engine.chipDirection(voice: below, in: viewport), .down)
        XCTAssertEqual(engine.chipDirection(voice: above, in: viewport), .up)
        XCTAssertNil(engine.chipDirection(voice: CGRect(x: 0, y: 1_200, width: 300, height: 29), in: viewport))
    }

    func testTheChipIsPublishedOncePerChange() {
        var engine = ReaderFollowEngine()
        XCTAssertFalse(engine.publish(nil), "nothing shown yet")
        XCTAssertTrue(engine.publish(.down))
        XCTAssertFalse(engine.publish(.down))
        XCTAssertEqual(engine.voiceOffscreen, .down)
        XCTAssertTrue(engine.publish(nil))
    }

    func testEveryFollowScrollCounts() {
        var engine = ReaderFollowEngine()
        engine.noteScroll()
        engine.noteScroll()
        XCTAssertEqual(engine.programmaticScrollCount, 2)
    }

    // MARK: - Placement check

    func testAPlacementEndsOnlyOnASteadyHeight() {
        var engine = ReaderFollowEngine()
        engine.startPlacementCheck()
        XCTAssertTrue(engine.isCheckingPlacement)
        XCTAssertEqual(engine.placementPass(.holds, laidOutHeight: 9_000), .confirm, "no height to compare yet")
        XCTAssertEqual(engine.placementPass(.holds, laidOutHeight: 12_000), .confirm, "the text grew")
        XCTAssertEqual(engine.placementPass(.holds, laidOutHeight: 12_000.2), .end)
    }

    func testAnOffPlacementIsCorrectedWhateverTheHeight() {
        var engine = ReaderFollowEngine()
        engine.startPlacementCheck()
        _ = engine.placementPass(.holds, laidOutHeight: 9_000)
        XCTAssertEqual(engine.placementPass(.moveTo(4_321), laidOutHeight: 9_000), .correct(toY: 4_321))
    }

    func testAPlacementCheckIsBoundedAndRestartsFresh() {
        var engine = ReaderFollowEngine()
        engine.startPlacementCheck()
        for pass in 1...ReaderFollowEngine.placementPassLimit {
            XCTAssertFalse(engine.placementPassesSpent, "pass \(pass)")
            _ = engine.placementPass(.moveTo(CGFloat(pass)), laidOutHeight: CGFloat(pass) * 100)
        }
        XCTAssertTrue(engine.placementPassesSpent)
        engine.endPlacementCheck()
        XCTAssertFalse(engine.isCheckingPlacement)

        engine.startRevealCheck(4)
        XCTAssertEqual(engine.pendingReveal, 4)
        XCTAssertFalse(engine.placementPassesSpent)
        XCTAssertNil(engine.placementHeight, "a new check compares nothing from the last one")
    }
}
