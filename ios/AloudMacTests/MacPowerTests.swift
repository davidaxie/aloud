import Combine
import XCTest
@testable import Aloud

/// M19, fast and frugal on battery. The engine stops 30 s after playback
/// stops, so a paused Mac on battery can idle-sleep, and Play starts it
/// again at the same sentence, fading in; Play, a seek, a voice change and
/// the controller's end call the wait off, and nothing that buffers or
/// reads is ever stopped. Low Power Mode skips pre-warm, and memory
/// pressure frees an engine that isn't reading, never one that is.
///
/// Silent: the rig's muted controller renders offline (no output device is
/// ever opened), the idle wait runs on a fake clock, and Kokoro is a fake.
@MainActor
final class MacPowerTests: XCTestCase {

    private typealias Rig = PlaybackTestRig
    private typealias FakeNeuralEngine = PlaybackTestRig.FakeNeuralEngine

    /// A long book of one-second clips, reading at `sentence` on the fake
    /// idle clock with the Mac's own 30 s.
    private func startReading(at sentence: Int = 3) async throws -> (Rig, IdleStopClock) {
        let rig = Rig(sentences: 40, clipDuration: 1)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.loadDefault(at: sentence)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertTrue(rig.controller.isEngineRunning)
        XCTAssertEqual(clock.pendingCount, 0, "nothing waits while it reads")
        return (rig, clock)
    }

    // MARK: - The engine stops 30 s after a pause

    func testTheEngineStopsThirtySecondsAfterAPause() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        let sentence = rig.controller.currentSentence

        clock.advance(by: 29)
        XCTAssertTrue(rig.controller.isEngineRunning, "not before the 30 s are up")
        clock.advance(by: 1)

        XCTAssertFalse(rig.controller.isEngineRunning, "30 s after the pause it stops")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, sentence, "the place is kept")
        XCTAssertNil(rig.controller.stopped, "nothing the listener is told about")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    /// Play after the idle stop is an ordinary start: buffering (when the
    /// wait can't fire), then the same sentence from its start, fading in
    /// from silence, on an engine started behind the usual fences.
    func testPlayStartsTheEngineAgainAtTheSameSentence() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: 30)
        XCTAssertFalse(rig.controller.isEngineRunning)
        let sentence = rig.controller.currentSentence
        rig.clearRecordings()

        rig.controller.play()
        XCTAssertEqual(rig.controller.status, .buffering)
        XCTAssertEqual(clock.pendingCount, 0, "Play calls the wait off")
        clock.advance(by: 60)   // nothing armed fires while it buffers
        try await rig.waitUntilPlayingOrSkip()

        XCTAssertTrue(rig.controller.isEngineRunning)
        XCTAssertEqual(rig.events.first(where: { $0 != .stopped }),
                       .scheduled(sentence: sentence, voiceID: Rig.voiceA.id))
        let faded = await rig.waitUntil(2) { rig.volumes().last?.value == 1 }
        XCTAssertTrue(faded)
        let levels = rig.volumes().map(\.value)
        XCTAssertEqual(levels.first, 0, "it comes back from silence, never a jump")
        XCTAssertEqual(levels, levels.sorted(), "rising only")
        XCTAssertEqual(rig.controller.realtimeEngineStarts, 0, "muted, it never opened a device")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - What calls the wait off

    func testPlayBeforeTheThirtySecondsCallsItOff() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: 20)
        rig.controller.play()
        XCTAssertEqual(rig.controller.status, .playing, "a warm resume")
        XCTAssertEqual(clock.pendingCount, 0)
        clock.advance(by: 60)
        XCTAssertTrue(rig.controller.isEngineRunning, "never stopped under the reading")

        // The next pause starts its own 30 s.
        rig.controller.pause()
        clock.advance(by: 29)
        XCTAssertTrue(rig.controller.isEngineRunning)
        clock.advance(by: 1)
        XCTAssertFalse(rig.controller.isEngineRunning)
    }

    func testASeekThatPlaysCallsItOff() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: 20)
        rig.controller.seek(to: 10, andPlay: true)
        XCTAssertEqual(clock.pendingCount, 0)
        try await rig.waitUntilPlayingOrSkip()
        clock.advance(by: 60)
        XCTAssertTrue(rig.controller.isEngineRunning)
        // Between two sentences it may be buffering the next: still reading.
        XCTAssertTrue([.playing, .buffering].contains(rig.controller.status), "still reading, got \(rig.controller.status)")
    }

    /// A seek while paused is the listener still there: the 30 s start
    /// again from it, and Play then reads from the sentence it cued.
    func testASeekWhilePausedStartsTheWaitAgain() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: 20)
        rig.controller.seek(to: 10, andPlay: false)
        clock.advance(by: 20)
        XCTAssertTrue(rig.controller.isEngineRunning, "40 s after the pause, 20 after the seek")
        clock.advance(by: 10)
        XCTAssertFalse(rig.controller.isEngineRunning)
        XCTAssertEqual(rig.controller.currentSentence, 10)

        rig.clearRecordings()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(rig.events.first(where: { $0 != .stopped }),
                       .scheduled(sentence: 10, voiceID: Rig.voiceA.id))
    }

    /// A voice picked while paused speaks the sentence once (R8): the wait
    /// is off while it does, and starts again at the pause it returns to.
    func testAVoiceChangeCallsItOffUntilItsSampleEnds() async throws {
        let (rig, clock) = try await startReading()
        rig.controller.pause()
        clock.advance(by: 20)
        rig.clearRecordings()

        rig.controller.selectVoice(Rig.voiceB)
        XCTAssertEqual(clock.pendingCount, 0, "the sample is reading")
        let returned = await rig.waitUntil(5) {
            rig.statuses.contains(.playing) && rig.controller.status == .paused
        }
        XCTAssertTrue(returned, "the sample plays and hands back the pause")
        XCTAssertEqual(clock.pendingCount, 1)
        clock.advance(by: 29)
        XCTAssertTrue(rig.controller.isEngineRunning)
        clock.advance(by: 1)
        XCTAssertFalse(rig.controller.isEngineRunning)
    }

    func testTheControllersEndCallsItOff() async {
        let clock = IdleStopClock()
        var rig: Rig? = Rig()
        clock.drive(rig!.controller)
        rig!.loadDefault()
        XCTAssertEqual(clock.pendingCount, 1, "a cued book waits like a pause")
        weak var controller = rig?.controller
        rig = nil

        let deadline = Date().addingTimeInterval(2)
        while controller != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(controller)
        XCTAssertEqual(clock.pendingCount, 0, "deinit cancels the wait")
    }

    /// The iPhone's tuning (nil) on the Mac host: the wait is never armed.
    func testNoDelayNeverArmsTheWait() async throws {
        let rig = Rig(sentences: 40, clipDuration: 1)
        let clock = IdleStopClock()
        clock.drive(rig.controller)
        rig.controller.idleEngineStopDelay = nil
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()

        XCTAssertEqual(clock.requestedDelays, [])
        clock.advance(by: 3_600)
        XCTAssertTrue(rig.controller.isEngineRunning)
    }

    // MARK: - Pre-warm and memory pressure

    /// The pre-warm's Low Power check on the Mac is the system's own
    /// (`ProcessInfo.isLowPowerModeEnabled`, macOS 12+): with every other
    /// condition met, it warms exactly when this Mac isn't in Low Power Mode.
    func testPrewarmReadsTheMacsLowPowerMode() async {
        let neural = FakeNeuralEngine()
        let rig = Rig(neural: neural)
        rig.controller.voice = Rig.michael
        let card = CurrentValueSubject<Bool, Never>(true)
        let prewarm = NeuralPrewarm(playback: rig.controller,
                                    kokoro: neural,
                                    cardVisible: card.eraseToAnyPublisher(),
                                    isModelInstalled: { true },
                                    sceneActive: true,
                                    notifications: NotificationCenter())
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        _ = await rig.waitUntil(0.5) { neural.warmUpCalls > 0 }

        XCTAssertEqual(neural.warmUpCalls, lowPower ? 0 : 1)
        neural.finishWarmUp()   // never leave a warm-up parked
        withExtendedLifetime(prewarm) {}
    }

    /// Memory pressure (the Mac's relay, posted as the lifecycle's memory
    /// warning) never takes the engine from under the reading; paused, the
    /// engine gives its memory back.
    func testMemoryPressureFreesAnEngineThatIsNotReading() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = Rig(sentences: 40, neural: neural)
        rig.controller.voice = Rig.michael
        let center = NotificationCenter()
        let prewarm = NeuralPrewarm(playback: rig.controller,
                                    kokoro: neural,
                                    cardVisible: Just(false).eraseToAnyPublisher(),
                                    isModelInstalled: { true },
                                    isLowPowerMode: { false },
                                    sceneActive: true,
                                    notifications: center)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        PlatformLifecycle.post(.memoryWarning, to: center)
        let released = await rig.waitUntil(0.5) { !neural.isWarm }
        XCTAssertFalse(released, "a reading engine is never freed")
        XCTAssertTrue(rig.controller.isActive)

        rig.controller.pause()
        PlatformLifecycle.post(.memoryWarning, to: center)
        let freed = await rig.waitUntil(2) { !neural.isWarm }
        XCTAssertTrue(freed, "paused, it gives its memory back")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped)
        withExtendedLifetime(prewarm) {}
    }
}
