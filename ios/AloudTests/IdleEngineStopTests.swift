import Foundation
import XCTest
@testable import Aloud

/// A fake clock for M19's idle engine stop: it records each wait the
/// controller arms and fires the ones that come due as the test moves time
/// on, so no test waits 30 real seconds.
@MainActor
final class IdleStopClock {

    private struct Wait {
        let deadline: TimeInterval
        let item: DispatchWorkItem
        let fire: @MainActor @Sendable () -> Void
    }

    private(set) var now: TimeInterval = 0
    /// Every delay the controller asked for, cancelled or not.
    private(set) var requestedDelays: [TimeInterval] = []
    private var waits: [Wait] = []

    /// Becomes `controller`'s idle clock. Its delay stays its own.
    func drive(_ controller: PlaybackController) {
        controller.scheduleIdleEngineStop = { [unowned self] delay, fire in
            let item = DispatchWorkItem {}
            waits.append(Wait(deadline: now + delay, item: item, fire: fire))
            requestedDelays.append(delay)
            return item
        }
    }

    /// Waits armed and neither cancelled nor fired.
    var pendingCount: Int { waits.filter { !$0.item.isCancelled }.count }

    /// Moves time on by `seconds`, firing every live wait that comes due.
    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = waits.filter { $0.deadline <= now }
        waits.removeAll { $0.deadline <= now }
        for wait in due where !wait.item.isCancelled { wait.fire() }
    }
}

/// M19's idle stop as each platform tunes it: the Mac stops its engine 30 s
/// after playback stops; the iPhone never arms the wait, so its engine runs
/// exactly as it always has. Silent: the rig's muted controller, and the
/// wait on a fake clock.
@MainActor
final class IdleEngineStopTests: XCTestCase {

    func testTheDelayIsTunedPerPlatform() {
        #if os(iOS)
        XCTAssertNil(PlatformTuning.idleEngineStopDelay, "the iPhone keeps its engine running")
        #elseif os(macOS)
        XCTAssertEqual(PlatformTuning.idleEngineStopDelay, 30)
        #endif
        XCTAssertEqual(PlaybackTestRig().controller.idleEngineStopDelay, PlatformTuning.idleEngineStopDelay)
    }

    /// With the platform's own tuning, a pause arms the wait only on a Mac.
    func testAPauseArmsTheWaitOnlyWhereThePlatformStopsItsEngine() async throws {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()

        #if os(iOS)
        XCTAssertEqual(clock.requestedDelays, [], "an iPhone never arms it")
        clock.advance(by: 3_600)
        XCTAssertTrue(rig.controller.isEngineRunning, "and its engine runs on")
        #elseif os(macOS)
        XCTAssertEqual(clock.requestedDelays.last, 30)
        XCTAssertEqual(clock.pendingCount, 1)
        #endif
    }
}
