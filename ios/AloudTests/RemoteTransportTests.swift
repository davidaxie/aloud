import XCTest
@testable import Aloud

/// R14: the in-app skip buttons, the lock-screen skip commands and headphone
/// next/previous all reach the one skip function, so they land on the same
/// sentence from the same state.
@MainActor
final class RemoteTransportTests: XCTestCase {

    private typealias Command = NowPlayingManager.RemoteTransportCommand

    /// Paused at sentence 20 of 10-word sentences: 15 s is 4 sentences at 1×.
    private func rigAt20(frozen: TimeInterval? = nil) -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        rig.loadDefault(at: 20)
        rig.controller.frozenSentenceElapsed = frozen
        return rig
    }

    func testEverySurfaceLandsOnTheSameTarget() {
        for frozen in [nil, 10] as [TimeInterval?] {
            for forward in [true, false] {
                let inApp = rigAt20(frozen: frozen)
                let lockScreen = rigAt20(frozen: frozen)
                let headphones = rigAt20(frozen: frozen)
                let interval = forward ? PlaybackController.skipInterval : -PlaybackController.skipInterval
                let label = "\(forward ? "forward" : "back"), \(frozen.map { "\($0) s in" } ?? "at a start")"

                let a = inApp.controller.skip(seconds: interval)
                let b = NowPlayingManager.perform(forward ? .skipForward : .skipBackward, on: lockScreen.controller)
                let c = NowPlayingManager.perform(forward ? .nextTrack : .previousTrack, on: headphones.controller)

                XCTAssertNotNil(a, label)
                XCTAssertEqual(b, a, label)
                XCTAssertEqual(c, a, label)
                XCTAssertEqual(lockScreen.controller.currentSentence, inApp.controller.currentSentence, label)
                XCTAssertEqual(headphones.controller.currentSentence, inApp.controller.currentSentence, label)
                for rig in [inApp, lockScreen, headphones] {
                    XCTAssertEqual(rig.controller.status, .paused, "\(label): skips keep play/pause")
                }
                switch (frozen, forward) {
                case (nil, true): XCTAssertEqual(a, 24, label)
                case (nil, false): XCTAssertEqual(a, 16, label)
                case (_, false): XCTAssertEqual(a, 20, "\(label): more than 3 s heard restarts")
                default: break
                }
            }
        }
    }

    func testTransportArmsChangeStatus() {
        let rig = rigAt20()

        XCTAssertNil(NowPlayingManager.perform(.play, on: rig.controller))
        XCTAssertTrue(rig.controller.isActive)

        XCTAssertNil(NowPlayingManager.perform(.pause, on: rig.controller))
        XCTAssertEqual(rig.controller.status, .paused)

        XCTAssertNil(NowPlayingManager.perform(.togglePlayPause, on: rig.controller))
        XCTAssertTrue(rig.controller.isActive)

        NowPlayingManager.perform(.togglePlayPause, on: rig.controller)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 20)
    }

    func testSkipsWithNoBookDoNothing() {
        let rig = PlaybackTestRig()
        XCTAssertNil(NowPlayingManager.perform(.skipForward, on: rig.controller))
        XCTAssertNil(NowPlayingManager.perform(.previousTrack, on: rig.controller))
        XCTAssertEqual(rig.controller.status, .idle)
    }

    func testEveryCommandIsCovered() {
        XCTAssertEqual(Set(Command.allCases),
                       [.play, .pause, .togglePlayPause, .skipForward, .skipBackward, .nextTrack, .previousTrack])
    }
}
