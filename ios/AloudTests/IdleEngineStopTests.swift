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
/// after playback stops, the iPhone a minute after, and then gives its
/// session back so iOS can suspend a paused Aloud. Silent: the rig's muted
/// controller, and the wait on a fake clock.
@MainActor
final class IdleEngineStopTests: XCTestCase {

    func testTheDelayIsTunedPerPlatform() {
        #if os(iOS)
        XCTAssertEqual(PlatformTuning.idleEngineStopDelay, 60)
        #elseif os(macOS)
        XCTAssertEqual(PlatformTuning.idleEngineStopDelay, 30)
        #endif
        XCTAssertEqual(PlaybackTestRig().controller.idleEngineStopDelay, PlatformTuning.idleEngineStopDelay)
    }

    private static func isScheduled(_ event: PlaybackController.AudioScheduleEvent) -> Bool {
        if case .scheduled = event { return true }
        return false
    }

    /// Reading at sentence 3 on the fake clock, with the platform's delay.
    private func startReading() async throws -> (PlaybackTestRig, IdleStopClock) {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        return (rig, clock)
    }

    /// With the platform's own tuning, a pause arms the wait on both.
    func testAPauseArmsTheWaitOnEveryPlatform() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        XCTAssertEqual(clock.requestedDelays.last, PlatformTuning.idleEngineStopDelay)
        XCTAssertEqual(clock.pendingCount, 1)
    }

    /// The idle stop stops the engine, then gives the session back (an
    /// iPhone's notifyOthersOnDeactivation; offline there is none). Play
    /// claims it again and reads on from the same sentence's start: what
    /// lock-screen Play after a long pause does.
    func testTheIdleStopLetsTheSessionGoAndPlayClaimsItAgain() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        let cue = rig.controller.currentSentence
        let delay = try XCTUnwrap(PlatformTuning.idleEngineStopDelay)
        clock.advance(by: delay)

        XCTAssertFalse(rig.controller.isEngineRunning, "the engine stops")
        let offline = rig.controller.rendersOffline
        XCTAssertEqual(rig.audioSession.deactivations, offline ? 0 : 1, "then the session goes")

        let activations = rig.audioSession.activations
        let mark = rig.statuses.count
        let eventMark = rig.events.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertTrue(rig.controller.isEngineRunning)
        XCTAssertEqual(rig.audioSession.activations, activations + (offline ? 0 : 1), "Play claims the session")
        XCTAssertEqual(rig.events[eventMark...].first(where: Self.isScheduled),
                       .scheduled(sentence: cue, voiceID: PlaybackTestRig.voiceA.id),
                       "from the same sentence's start")
    }

    /// An interruption's pause keeps the session past the idle stop, so the
    /// interruption's end still resumes.
    func testAnInterruptionKeepsTheSessionForItsEnd() async throws {
        let (rig, clock) = try await startReading()
        rig.audioSession.onInterruption?(.began)
        XCTAssertEqual(rig.controller.status, .paused)
        let delay = try XCTUnwrap(PlatformTuning.idleEngineStopDelay)
        clock.advance(by: delay)
        XCTAssertEqual(rig.audioSession.deactivations, 0)

        let mark = rig.statuses.count
        rig.audioSession.onInterruption?(.ended(shouldResume: true))
        try await rig.waitUntilPlayingOrSkip(after: mark)
    }
}
