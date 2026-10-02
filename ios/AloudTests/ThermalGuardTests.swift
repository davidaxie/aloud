import Combine
import XCTest
@testable import Aloud

/// R11, heat as playback policy: at .serious a Kokoro voice hands off to the
/// System voice at a sentence start with no gap, cooling down brings the
/// preference back, and .critical stops playback with a reason. Rules act on
/// transitions only, so a Play while still hot is honoured.
///
/// All silent: the frozen rig's muted controller over silent stub engines,
/// Michael on a FakeNeuralEngine that is already warm. A test whose audio
/// engine can't start in the host is skipped, not failed. Thermal states are
/// driven through thermalStateChanged; nothing observes the real one.
@MainActor
final class ThermalGuardTests: XCTestCase {

    private typealias FakeNeuralEngine = PlaybackTestRig.FakeNeuralEngine
    private static let michael = PlaybackTestRig.michael
    private static let system = PlaybackTestRig.voiceA

    private var selections: [String] = []
    private var subscriptions: Set<AnyCancellable> = []

    private func makeRig(_ neural: FakeNeuralEngine = FakeNeuralEngine(warm: true)) -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 40, neural: neural)
        rig.controller.voiceSelections
            .sink { [weak self] in self?.selections.append($0.id) }
            .store(in: &subscriptions)
        return rig
    }

    private func makeGuard(_ rig: PlaybackTestRig,
                           initialState: ProcessInfo.ThermalState = .nominal) -> ThermalGuard {
        let thermal = ThermalGuard(playback: rig.controller, systemVoice: Self.system,
                                   initialState: initialState)
        thermal.preferredVoice = { Self.michael }
        return thermal
    }

    /// Plays the rig's book from the start in `voice` (Michael when nil),
    /// then forgets what was recorded on the way to .playing.
    private func startPlaying(_ rig: PlaybackTestRig, in voice: TtsVoice? = nil) async throws {
        rig.controller.voice = voice ?? Self.michael   // no book yet: nothing restarts
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
    }

    private static func scheduled(_ events: [PlaybackController.AudioScheduleEvent])
        -> [(sentence: Int, voiceID: String)] {
        events.compactMap {
            if case .scheduled(let sentence, let voiceID) = $0 { return (sentence, voiceID) }
            return nil
        }
    }

    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Serious: the System voice while it cools

    func testSeriousSwitchesToSystemGaplesslyAtASentenceStart() async throws {
        let rig = makeRig()
        try await startPlaying(rig)
        let thermal = makeGuard(rig)

        thermal.thermalStateChanged(.serious)
        XCTAssertTrue(thermal.isHot)
        let switched = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(switched, "the System voice takes over once its first clip plays")

        XCTAssertFalse(rig.statuses.contains(.buffering), "the switch never buffers")
        XCTAssertFalse(rig.statuses.contains(.paused))
        XCTAssertFalse(rig.events.contains(.stopped), "nothing was flushed")
        let queued = Self.scheduled(rig.events)
        let firstSystem = try XCTUnwrap(queued.first { $0.voiceID == Self.system.id })
        XCTAssertTrue(queued.filter { $0.voiceID == Self.michael.id }.allSatisfy { $0.sentence < firstSystem.sentence },
                      "the System voice starts on a sentence of its own, after Michael's last")
        XCTAssertEqual(rig.controller.notice, .coolingDown)
        XCTAssertEqual(rig.announcements, ["Using the System voice while iPhone cools"])
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(selections, [], "heat is never persisted as a pick")
    }

    func testCoolingDownRestoresThePreferredVoice() async throws {
        let rig = makeRig()
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        let cooled = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(cooled)
        rig.clearRecordings()

        thermal.thermalStateChanged(.nominal)
        XCTAssertFalse(thermal.isHot)
        let restored = await rig.waitUntil { rig.controller.voice == Self.michael }
        XCTAssertTrue(restored)
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.notice, .nowReadingIn(voiceName: "Michael"))
        XCTAssertEqual(rig.announcements, ["Now reading in Michael"])
        XCTAssertEqual(selections, [])
    }

    /// A natural voice picked mid-play with its engine cold buffers while the
    /// model loads, with nothing queued. Turning .serious in that window
    /// lands the System voice at once, and playback restarts in it at the
    /// same sentence; the warm-up, for a voice no longer wanted, then
    /// reloads nothing.
    func testSeriousDuringAColdNaturalWarmUpRestartsInSystem() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        try await startPlaying(rig, in: Self.system)
        let thermal = makeGuard(rig)

        rig.controller.selectVoice(Self.michael)
        XCTAssertEqual(rig.controller.status, .buffering, "the cold engine loads first")
        XCTAssertTrue(rig.controller.isPreparingVoice)
        let sentence = rig.controller.currentSentence
        let mark = rig.statuses.count
        let eventMark = rig.events.count

        thermal.thermalStateChanged(.serious)
        XCTAssertEqual(rig.controller.voice, Self.system, "nothing queued, so the switch lands at once")
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(rig.controller.status, .playing, "never left buffering with nothing queued")
        XCTAssertFalse(rig.controller.isPreparingVoice)
        let queued = Self.scheduled(Array(rig.events[eventMark...]))
        XCTAssertEqual(queued.first?.sentence, sentence, "restarted where it stood")
        XCTAssertTrue(queued.allSatisfy { $0.voiceID == Self.system.id })
        XCTAssertEqual(rig.controller.notice, .coolingDown)
        XCTAssertEqual(selections, [Self.michael.id], "the pick, never the heat")

        let warmMark = rig.events.count
        neural.finishWarmUp()
        await elapse(0.3)
        XCTAssertEqual(rig.controller.voice, Self.system)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertFalse(rig.events[warmMark...].contains(.stopped), "the stale warm-up restarts nothing")
        XCTAssertTrue(neural.requests.isEmpty, "the natural voice never read")
        rig.controller.pause()
    }

    func testTheSystemVoiceAtSeriousPostsNothing() async throws {
        let rig = makeRig()
        try await startPlaying(rig, in: Self.system)
        let thermal = makeGuard(rig)

        thermal.thermalStateChanged(.serious)
        await elapse(0.5)

        XCTAssertTrue(thermal.isHot)
        XCTAssertEqual(rig.controller.voice, Self.system)
        XCTAssertNil(rig.controller.notice)
        XCTAssertEqual(rig.announcements, [])
        XCTAssertFalse(rig.events.contains(.stopped))
        XCTAssertTrue(rig.statuses.allSatisfy { $0 == .playing })

        // Cooling down with nothing replaced changes nothing either.
        thermal.thermalStateChanged(.nominal)
        await elapse(0.3)
        XCTAssertEqual(rig.controller.voice, Self.system)
        XCTAssertEqual(rig.announcements, [])
    }

    // MARK: - Critical: stop with a reason

    func testCriticalStopsWithTooHotAndFreesTheEngine() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        let cooled = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(cooled)
        rig.clearRecordings()
        let sentence = rig.controller.currentSentence

        thermal.thermalStateChanged(.critical)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped?.reason, .tooHot)
        XCTAssertEqual(rig.controller.stopReason(for: rig.document.id), .tooHot)
        XCTAssertEqual(rig.announcements, ["Paused, iPhone is too hot"])
        XCTAssertEqual(rig.nodePauseTimes().count, 1, "the audio cuts at once, never ramped")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
        XCTAssertEqual(rig.controller.currentSentence, sentence)
        let released = await rig.waitUntil(1) { !neural.isWarm }
        XCTAssertTrue(released, "an idle, stopped engine gives back its memory")
    }

    /// .critical inside the cooling switch's window, before its splice
    /// plays: the stop lands the switch at once, so nothing is left for
    /// Kokoro to read and the engine is freed; Play then reads System
    /// without warming it again.
    func testCriticalBeforeTheCoolingSwitchLandsStillFreesTheEngine() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)

        thermal.thermalStateChanged(.serious)
        XCTAssertEqual(rig.controller.voice, Self.michael, "the switch waits for its splice")
        thermal.thermalStateChanged(.critical)   // same turn: the splice hasn't played

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped?.reason, .tooHot)
        XCTAssertEqual(rig.controller.voice, Self.system, "paused, the pending switch lands at once")
        XCTAssertEqual(rig.announcements, ["Paused, iPhone is too hot",
                                           "Using the System voice while iPhone cools"],
                       "the stop is heard first")
        let released = await rig.waitUntil(1) { !neural.isWarm }
        XCTAssertTrue(released, "no Kokoro work is left, so the engine gives back its memory")
        XCTAssertEqual(selections, [], "heat is never persisted as a pick")

        let warmUps = neural.warmUpCalls
        rig.clearRecordings()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let queued = Self.scheduled(rig.events)
        XCTAssertFalse(queued.isEmpty)
        XCTAssertTrue(queued.allSatisfy { $0.voiceID == Self.system.id }, "Play reads System: \(queued)")
        XCTAssertFalse(neural.isWarm, "Play never warms the natural voice again")
        XCTAssertEqual(neural.warmUpCalls, warmUps)
    }

    /// A natural voice the listener picks while hot is honoured at
    /// .critical: the stop never swaps it for System.
    func testCriticalAfterAPickMadeWhileHotKeepsThePick() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        let cooled = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(cooled)

        rig.controller.selectVoice(Self.michael)
        let resumed = await rig.waitUntil { rig.controller.status == .playing }
        XCTAssertTrue(resumed)
        rig.clearRecordings()

        thermal.thermalStateChanged(.critical)

        XCTAssertEqual(rig.controller.stopped?.reason, .tooHot)
        XCTAssertEqual(rig.controller.voice, Self.michael, "a pick made while hot is never undone")
        XCTAssertEqual(rig.announcements, ["Paused, iPhone is too hot"], "no second cooling switch")
        let released = await rig.waitUntil(1) { !neural.isWarm }
        XCTAssertTrue(released, "stopped, the engine is still freed")
        XCTAssertEqual(selections, [Self.michael.id], "only the listener's pick is persisted")
    }

    func testCriticalWhilePausedDoesNothing() async throws {
        let rig = makeRig()
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        let cooled = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(cooled)
        rig.controller.pause()
        rig.clearRecordings()

        thermal.thermalStateChanged(.critical)
        await elapse(0.3)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped, "a pause the listener made is theirs")
        XCTAssertEqual(rig.announcements, [])
        XCTAssertEqual(rig.statuses, [])
    }

    /// Paused inside the cooling switch's window, the switch to System still
    /// waits for its splice, and it needs nothing from Kokoro: every clip
    /// before the splice is already queued. Backgrounding (or a memory
    /// warning) frees the engine, and Play lands the switch without warming
    /// it again.
    func testPausedInsideTheCoolingWindowTheEngineCanGo() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        rig.controller.pause()   // same turn: the splice hasn't played
        XCTAssertEqual(rig.controller.voice, Self.michael, "the switch still waits for its splice")

        rig.controller.releaseNeuralEngineIfIdle()

        XCTAssertFalse(neural.isWarm, "a switch to System doesn't hold the natural voice's memory")
        let warmUps = neural.warmUpCalls
        rig.controller.play()
        let switched = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(switched, "the switch lands on Play")
        XCTAssertEqual(neural.warmUpCalls, warmUps, "Play never warms the natural voice again")
        XCTAssertEqual(selections, [])
    }

    /// .critical while the listener has paused inside the cooling window:
    /// nothing is stopped or announced (the pause is theirs), but nothing is
    /// reading either, so the engine is freed.
    func testCriticalWhilePausedInsideTheCoolingWindowFreesTheEngine() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        rig.controller.pause()   // same turn: the splice hasn't played
        XCTAssertEqual(rig.controller.voice, Self.michael, "the switch still waits for its splice")
        rig.clearRecordings()

        thermal.thermalStateChanged(.critical)

        XCTAssertFalse(neural.isWarm, "the hot phone gets the engine's memory back")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped, "a pause the listener made is theirs")
        XCTAssertEqual(rig.announcements, [])
    }

    /// A natural voice the install switch is moving to keeps its warm engine
    /// while paused mid-way, so Play doesn't load it again.
    func testPausedMidwayToANaturalVoiceKeepsItsEngine() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig, in: Self.system)
        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        rig.controller.pause()   // same turn: the splice hasn't played
        XCTAssertEqual(rig.controller.voice, Self.system, "the switch still waits for its splice")

        rig.controller.releaseNeuralEngineIfIdle()

        XCTAssertTrue(neural.isWarm, "the queued natural voice still needs it")
    }

    func testPlayWhileStillCriticalIsHonoured() async throws {
        let rig = makeRig()
        try await startPlaying(rig, in: Self.system)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.critical)
        XCTAssertEqual(rig.controller.stopped?.reason, .tooHot)
        let mark = rig.statuses.count

        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        thermal.thermalStateChanged(.critical)   // the same state again: no transition
        await elapse(0.5)

        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertNil(rig.controller.stopped, "Play cleared the reason")
        XCTAssertEqual(rig.announcements, ["Paused, iPhone is too hot"], "announced once")
    }

    // MARK: - Hot before anything plays

    func testALaunchWhileHotStartsQuietlyInSystem() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        rig.controller.voice = Self.michael   // the restored preference; no book yet

        let thermal = makeGuard(rig, initialState: .serious)

        XCTAssertTrue(thermal.isHot)
        XCTAssertEqual(rig.controller.voice, Self.system)
        XCTAssertNil(rig.controller.notice, "nothing to announce before a book is open")
        XCTAssertEqual(rig.announcements, [])

        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertTrue(Self.scheduled(rig.events).allSatisfy { $0.voiceID == Self.system.id })
        XCTAssertTrue(neural.requests.isEmpty, "the natural voice stays idle while hot")
        XCTAssertEqual(selections, [])
    }

    /// AppModel's install path while hot: hold, then switch once it cools.
    func testAModelInstallWhileHotWaitsForTheCoolDown() async throws {
        let rig = makeRig()
        try await startPlaying(rig, in: Self.system)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        XCTAssertTrue(thermal.isHot)

        thermal.holdNaturalVoiceUntilCool()
        await elapse(0.5)
        XCTAssertEqual(rig.controller.voice, Self.system, "no switch while hot")
        XCTAssertEqual(rig.announcements, [])

        thermal.thermalStateChanged(.fair)
        let switched = await rig.waitUntil { rig.controller.voice == Self.michael }
        XCTAssertTrue(switched, "the held switch lands once it cools")
        XCTAssertEqual(rig.announcements, ["Now reading in Michael"])
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertEqual(selections, [])
    }
}
