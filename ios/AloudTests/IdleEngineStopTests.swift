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
    ///
    /// The scheduler holds the clock strongly (R3-08): a test that keeps
    /// only the rig (`let (rig, _) = try await startReading()`) still arms
    /// waits through it, as an interruption's pause does, and an unowned
    /// capture read a freed clock there and crashed the host. No cycle: the
    /// controller holds this closure, the closure the clock, the clock its
    /// waits, and each wait's fire closure holds the controller weakly.
    /// Never weak with an early return: an armed wait would vanish unseen.
    func drive(_ controller: PlaybackController) {
        controller.scheduleIdleEngineStop = { delay, fire in
            let item = DispatchWorkItem {}
            self.waits.append(Wait(deadline: self.now + delay, item: item, fire: fire))
            self.requestedDelays.append(delay)
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

    /// R3-08: the controller keeps the clock that drives it, so a test that
    /// holds only the rig still arms its waits on a live clock.
    func testTheControllerKeepsItsIdleClock() {
        let rig = PlaybackTestRig()
        weak var released: IdleStopClock?
        do {
            let clock = IdleStopClock()
            clock.drive(rig.controller)
            released = clock
        }
        XCTAssertNotNil(released, "the idle scheduler holds its clock")
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
    /// iPhone's; offline there is none). Play
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

    /// G004: after a pause (a lock-screen Pause, AirPods, a sleep stop) the
    /// session goes quietly: an app Aloud interrupted (Music) is never told
    /// it may resume, so it can't start by itself a minute later.
    func testAPauseGivesTheSessionBackWithoutWakingAnotherApp() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
        XCTAssertEqual(rig.audioSession.deactivations, rig.controller.rendersOffline ? 0 : 1)
        XCTAssertEqual(rig.audioSession.notifyingDeactivations, 0, "a pause never hands the audio on")
    }

    /// G004: once the book has been heard to its end, listening is over:
    /// the session goes, and an app Aloud interrupted may take the audio
    /// back up. Not under the sleep timer's End-of-book fade: the listener
    /// may be asleep.
    func testTheBooksEndLetsAnInterruptedAppResume() async throws {
        for sleepFade in [false, true] {
            let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
            let clock = IdleStopClock()
            clock.drive(rig.controller)
            rig.loadDefault(at: 3)
            rig.controller.play()
            try await rig.waitUntilPlayingOrSkip()
            if sleepFade { rig.controller.rampOutputVolume(to: 0, over: 0.5) }
            let ended = await rig.waitUntil { rig.controller.status == .ended }
            XCTAssertTrue(ended)
            clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
            XCTAssertFalse(rig.controller.isEngineRunning)
            let notifies = rig.controller.rendersOffline || sleepFade ? 0 : 1
            XCTAssertEqual(rig.audioSession.notifyingDeactivations, notifies,
                           sleepFade ? "under the sleep fade" : "heard to the end")
        }
    }

    /// G007: paused in the background (from the lock screen), the idle
    /// stop frees the natural voice before iOS can suspend the process,
    /// where no memory warning would reach it. A Mac keeps it (macOS never
    /// ends an app for its memory), and so does a paused app on screen.
    func testInTheBackgroundTheIdleStopFreesTheNaturalVoice() async throws {
        for background in [false, true] {
            let neural = PlaybackTestRig.FakeNeuralEngine(warm: true)
            let rig = PlaybackTestRig(sentences: 40, clipDuration: 1, neural: neural)
            let clock = IdleStopClock()
            clock.drive(rig.controller)
            rig.controller.voice = PlaybackTestRig.michael
            rig.loadDefault(at: 3)
            rig.controller.play()
            try await rig.waitUntilPlayingOrSkip()
            rig.appActive = !background
            rig.controller.pause()
            XCTAssertTrue(neural.isWarm)
            clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
            XCTAssertEqual(neural.isWarm, !(background && PlatformTuning.releasesNeuralOnBackground),
                           background ? "in the background" : "on screen")
        }
    }

    /// P011: a pause, lock and unlock comes back to a warm natural voice.
    /// The move to the background (AppModel's) leaves the engine while the
    /// idle audio engine still runs, since iOS can't suspend the app yet,
    /// and the idle stop frees it once the engine stops there.
    func testTheBackgroundLeavesTheVoiceWarmWhileTheIdleEngineRuns() async throws {
        let neural = PlaybackTestRig.FakeNeuralEngine(warm: true)
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1, neural: neural)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.controller.voice = PlaybackTestRig.michael
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()
        try XCTSkipUnless(rig.controller.isAudioEngineRunning, "the host's engine stopped with the pause")

        rig.appActive = false
        rig.controller.releaseNeuralEngineOnBackground()
        XCTAssertTrue(neural.isWarm, "paused with the idle engine running: still warm")

        clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
        XCTAssertFalse(rig.controller.isAudioEngineRunning)
        XCTAssertEqual(neural.isWarm, !PlatformTuning.releasesNeuralOnBackground,
                       "the idle stop frees it in the background where the platform says so")
    }

    /// P011: with the engine already stopped (a long pause on screen), the
    /// move to the background frees the voice at once.
    func testWithTheIdleEngineStoppedTheBackgroundFreesTheVoiceAtOnce() async throws {
        let neural = PlaybackTestRig.FakeNeuralEngine(warm: true)
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1, neural: neural)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.controller.voice = PlaybackTestRig.michael
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()
        clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
        XCTAssertFalse(rig.controller.isAudioEngineRunning)
        XCTAssertTrue(neural.isWarm, "on screen the idle stop keeps it")

        rig.appActive = false
        rig.controller.releaseNeuralEngineOnBackground()
        XCTAssertFalse(neural.isWarm, "nothing keeps the app running now: it goes at once")
    }

    /// P011: paused in the background with the idle engine still running,
    /// the system stopping that engine first (another app's audio
    /// interrupting, an output change that stops) leaves no idle stop to
    /// free the voice before iOS suspends the app, so it goes then.
    func testTheSystemStoppingTheIdleEngineInTheBackgroundFreesTheVoice() async throws {
        for cause in ["interruption", "output change"] {
            let neural = PlaybackTestRig.FakeNeuralEngine(warm: true)
            let rig = PlaybackTestRig(sentences: 40, clipDuration: 1, neural: neural)
            let clock = IdleStopClock()
            clock.drive(rig.controller)
            rig.controller.voice = PlaybackTestRig.michael
            rig.loadDefault(at: 3)
            rig.controller.play()
            try await rig.waitUntilPlayingOrSkip()
            rig.controller.pause()
            try XCTSkipUnless(rig.controller.isAudioEngineRunning, "the host's engine stopped with the pause")

            rig.appActive = false
            rig.controller.releaseNeuralEngineOnBackground()
            XCTAssertTrue(neural.isWarm, "\(cause): paused with the idle engine running, still warm")

            if cause == "interruption" {
                rig.audioSession.onInterruption?(.began)
            } else {
                rig.audioSession.decision = .stop(.headphonesDisconnected)
                rig.controller.outputConfigurationChanged()
            }
            XCTAssertEqual(neural.isWarm, !PlatformTuning.releasesNeuralOnBackground,
                           "\(cause): no idle stop follows, so it goes where the platform frees memory there")
            XCTAssertEqual(rig.controller.status, .paused, cause)
        }
    }

    /// The same stop on screen keeps the voice: the move to the background
    /// frees it then, the engine having stopped.
    func testTheSystemStoppingTheIdleEngineOnScreenKeepsTheVoice() async throws {
        let neural = PlaybackTestRig.FakeNeuralEngine(warm: true)
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 1, neural: neural)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.controller.voice = PlaybackTestRig.michael
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()

        rig.audioSession.onInterruption?(.began)
        XCTAssertTrue(neural.isWarm, "on screen Play comes back to a warm voice")
    }

    /// G023: once the idle stop has given the session back, iOS tells it
    /// nothing about a call. A Play refused by that call is an
    /// interruption, but no end will come to resume it: nothing is
    /// promised, the reason is said at once, and Play after the call reads
    /// on.
    func testAPlayRefusedAfterTheReleasePromisesNoResume() async throws {
        let (rig, clock) = try await startReading()
        try XCTSkipIf(rig.controller.rendersOffline, "offline there is no session to claim")
        rig.controller.pause()
        clock.advance(by: try XCTUnwrap(PlatformTuning.idleEngineStopDelay))
        XCTAssertEqual(rig.audioSession.deactivations, 1)

        rig.audioSession.activationError = AudioOutputHeldElsewhere()
        rig.clearRecordings()
        rig.controller.play()
        let settled = await rig.waitUntil { rig.statuses.contains(.paused) || rig.statuses.contains(.error) }
        XCTAssertTrue(settled)
        XCTAssertEqual(rig.controller.status, .paused, "an interruption, not a failure")
        XCTAssertEqual(rig.controller.stopped, PlaybackStop(reason: .interrupted, documentID: rig.document.id))
        XCTAssertEqual(rig.announcements, [StopReason.interrupted.spokenText], "said now: no end will come")

        // Even a stray end resumes nothing it never promised.
        rig.audioSession.activationError = nil
        rig.audioSession.onInterruption?(.ended(shouldResume: true))
        XCTAssertEqual(rig.controller.status, .paused)

        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
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

    /// R1-40: a cold start claims the session once; a resume inside the
    /// idle window, the engine still running on the session Aloud holds,
    /// claims nothing again.
    func testAResumeInsideTheIdleWindowKeepsTheSession() async throws {
        let (rig, clock) = try await startReading()
        let offline = rig.controller.rendersOffline
        XCTAssertEqual(rig.audioSession.activations, offline ? 0 : 1, "a cold start claims the session once")

        rig.controller.pause()
        XCTAssertEqual(clock.pendingCount, 1, "inside the idle window")
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertTrue(rig.controller.isEngineRunning)
        XCTAssertEqual(rig.audioSession.activations, offline ? 0 : 1, "the resume keeps the session it holds")
    }

    /// R1-40: the iPhone's session category is set once (at init, and again
    /// only after a media-services reset takes it); a claim only activates,
    /// still mapping a call's refusal to `AudioOutputHeldElsewhere`.
    func testTheSessionCategoryIsSetOnceAndAClaimOnlyActivates() throws {
        let path = "Playback/AudioSessionManager.swift"
        let s = try SourceTree.sources(only: [path]).mapValues(SwiftLiterals.code(in:))
        let source = try XCTUnwrap(s[path])
        XCTAssertEqual(source.components(separatedBy: "setCategory(").count - 1, 1, "one place sets the category")
        XCTAssertTrue(source.contains("mediaServicesWereResetNotification"), "a reset sets it again")
        let activate = try XCTUnwrap(source.range(of: "func activate() throws {"))
        let body = source[activate.upperBound...].prefix(320)
        XCTAssertTrue(body.contains("setActive(true)"), String(body))
        XCTAssertFalse(body.contains("setCategory("), String(body))
        XCTAssertTrue(body.contains("throw AudioOutputHeldElsewhere()"), String(body))
    }

    /// R1-40: an interruption takes the session's activation though Aloud
    /// keeps its hold for the end, so Play after it claims the session
    /// again, even with the engine still running.
    func testAResumeAfterAnInterruptionClaimsTheSessionAgain() async throws {
        // The clock is held to the end: the interruption's pause arms the
        // idle wait through it, and its closure holds it unowned.
        let (rig, clock) = try await startReading()
        defer { withExtendedLifetime(clock) {} }
        try XCTSkipIf(rig.controller.rendersOffline, "offline there is no session to claim")
        rig.audioSession.onInterruption?(.began)
        XCTAssertEqual(rig.controller.status, .paused)
        let activations = rig.audioSession.activations

        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(rig.audioSession.activations, activations + 1)
    }
}
