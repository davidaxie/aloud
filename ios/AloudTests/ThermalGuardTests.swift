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

    /// What VoiceOver hears, letter for letter on each platform (M12).
    #if os(iOS)
    private static let tooHotSpoken = "Paused, iPhone is too hot"
    private static let coolingSpoken = "Using the System voice while iPhone cools"
    #else
    private static let tooHotSpoken = "Paused, your Mac is too hot"
    private static let coolingSpoken = "Using the System voice while your Mac cools"
    #endif

    private var selections: [String] = []
    private var subscriptions: Set<AnyCancellable> = []

    /// Long sentences, so the look-ahead stays at the few sentences the
    /// cooling switch splices behind without a cut, on every platform
    /// (`PlatformPlaybackTuning.coolingSwitchLandsWithin`); short ones
    /// (`deepQueue`) fill an iPhone's queue to its six.
    private func makeRig(_ neural: FakeNeuralEngine = FakeNeuralEngine(warm: true),
                         deepQueue: Bool = false) -> PlaybackTestRig {
        let shallow = PlatformPlaybackTuning.coolingSwitchLandsWithin != nil
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: deepQueue || !shallow ? 3 : 30, neural: neural)
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

    /// Sentences queued past the one playing.
    private static func ahead(_ rig: PlaybackTestRig) -> Int {
        (scheduled(rig.events).map(\.sentence).max() ?? -1) - rig.controller.currentSentence
    }

    /// The look-ahead reaches the strained count and never passes it: two
    /// sentences on an iPhone, the whole queue on a Mac.
    private func assertLookAheadStaysStrained(_ rig: PlaybackTestRig,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        let expected = PlaybackController.lookAheadCount(
            characterCounts: rig.content.sentences.map(\.text.count), rate: 1,
            seconds: PlatformPlaybackTuning.lookAheadSeconds, range: PlatformPlaybackTuning.lookAheadSentences,
            strainedCap: PlatformPlaybackTuning.lookAheadUnderStrain)
        let reached = await rig.waitUntil(2) { Self.ahead(rig) >= expected }
        XCTAssertTrue(reached, file: file, line: line)
        await elapse(0.1)
        XCTAssertLessThanOrEqual(Self.ahead(rig), expected, "never past the strained count", file: file, line: line)
        if PlatformPlaybackTuning.lookAheadUnderStrain != nil { XCTAssertEqual(expected, 2, file: file, line: line) }
        rig.controller.pause()
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
        XCTAssertEqual(rig.announcements, [Self.coolingSpoken])
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(selections, [], "heat is never persisted as a pick")
    }

    /// P009: an iPhone keeps up to six sentences queued, more than the
    /// cooling switch may wait behind. Heating up with six natural-voice
    /// clips queued drops those past the next sentence boundary there, so
    /// the System voice reads within three sentences, from the one after
    /// the sentence playing, never re-reading it.
    func testWithADeepQueueTheCoolingSwitchLandsWithinThreeSentences() async throws {
        guard let limit = PlatformPlaybackTuning.coolingSwitchLandsWithin else {
            throw XCTSkip("a Mac splices after its whole queue")
        }
        let rig = makeRig(deepQueue: true)
        try await startPlaying(rig)
        let deep = PlatformPlaybackTuning.lookAheadSentences.upperBound
        let filled = await rig.waitUntil(2) {
            (Self.scheduled(rig.events).map(\.sentence).max() ?? -1) - rig.controller.currentSentence >= deep
        }
        XCTAssertTrue(filled, "six natural-voice clips past the one playing")
        let thermal = makeGuard(rig)
        let mark = rig.events.count
        let startedAt = rig.controller.currentSentence

        thermal.thermalStateChanged(.serious)
        let switched = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(switched)
        // Cut short, the switch commits at the boundary, then its clip goes on.
        let systemQueued = await rig.waitUntil(2) {
            Self.scheduled(Array(rig.events[mark...])).contains { $0.voiceID == Self.system.id }
        }
        XCTAssertTrue(systemQueued)
        let queued = Self.scheduled(Array(rig.events[mark...]))
        let firstSystem = try XCTUnwrap(queued.first { $0.voiceID == Self.system.id })
        XCTAssertLessThanOrEqual(firstSystem.sentence - startedAt, limit,
                                 "the System voice reads within \(limit) sentences")
        XCTAssertGreaterThan(firstSystem.sentence, startedAt, "the sentence playing is never read again")
        XCTAssertEqual(rig.controller.notice, .coolingDown)
        XCTAssertEqual(rig.announcements, [Self.coolingSpoken])
        XCTAssertEqual(selections, [], "heat is never persisted as a pick")

        let readOn = await rig.waitUntil(3) { rig.controller.currentSentence > firstSystem.sentence }
        XCTAssertTrue(readOn, "reading goes on in the System voice")
        XCTAssertEqual(rig.controller.status, .playing)
        rig.controller.pause()
    }

    /// P009: the cut is timed from the render side. The marker ahead of
    /// the splice's clip silences it as it renders, before any hop to the
    /// main actor (an output latency after it, the sentence before would
    /// only now report itself heard), and the level stays down until the
    /// natural voice's queue is flushed. The restart in the System voice,
    /// its first clip already warmed, never shows the busy ring.
    func testACutShortSpliceIsSilentFromItsMarkerUntilTheQueueIsFlushed() async throws {
        guard PlatformPlaybackTuning.coolingSwitchLandsWithin != nil else {
            throw XCTSkip("a Mac splices after its whole queue")
        }
        let rig = makeRig(deepQueue: true)
        try await startPlaying(rig)
        let deep = PlatformPlaybackTuning.lookAheadSentences.upperBound
        let filled = await rig.waitUntil(2) { Self.ahead(rig) >= deep }
        try XCTSkipUnless(filled && rig.controller.status == .playing, "the queue never filled")
        let thermal = makeGuard(rig)
        final class Levels {
            var silentAtFlush: Bool?
            var silentAtFirstSystemClip: Bool?
        }
        let levels = Levels()
        let record = rig.controller.onAudioScheduleEvent
        rig.controller.onAudioScheduleEvent = { [weak controller = rig.controller] event in
            switch event {
            case .stopped where levels.silentAtFlush == nil:
                levels.silentAtFlush = controller?.isSilencingCutSplice
            case .scheduled(_, let voiceID) where voiceID == Self.system.id && levels.silentAtFirstSystemClip == nil:
                levels.silentAtFirstSystemClip = controller?.isSilencingCutSplice
            default:
                break
            }
            record?(event)
        }
        let statusMark = rig.statuses.count
        let mark = rig.events.count

        thermal.thermalStateChanged(.serious)
        let systemQueued = await rig.waitUntil(2) {
            Self.scheduled(Array(rig.events[mark...])).contains { $0.voiceID == Self.system.id }
        }
        XCTAssertTrue(systemQueued)
        let firstSystem = try XCTUnwrap(Self.scheduled(Array(rig.events[mark...])).first { $0.voiceID == Self.system.id })
        XCTAssertEqual(rig.controller.cutSpliceSilencedAt, firstSystem.sentence,
                       "the marker ahead of the splice silenced the natural voice's clip there")
        XCTAssertEqual(levels.silentAtFlush, true, "silent from the marker until the natural voice's clips are flushed")
        XCTAssertEqual(levels.silentAtFirstSystemClip, false, "the level is back for the System voice")
        XCTAssertFalse(rig.controller.isSilencingCutSplice)
        XCTAssertFalse(rig.statuses[statusMark...].contains(.buffering), "the switch never shows the busy ring")
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.voice, Self.system)
        rig.controller.pause()
    }

    /// P009: a pause whose 120 ms ramp crosses a cut-short splice drops
    /// the natural voice's queued clips there too, so the Play after it
    /// reads on in the System voice from the splice, never resuming the
    /// natural clips that were left on the node.
    func testAPauseRampOverACutShortSpliceLeavesNoNaturalClipToResume() async throws {
        guard PlatformPlaybackTuning.coolingSwitchLandsWithin != nil else {
            throw XCTSkip("a Mac splices after its whole queue")
        }
        // 50 ms natural clips: once reading runs steadily, the next boundary
        // always falls inside the ramp.
        let rig = makeRig(FakeNeuralEngine(warm: true, clipDuration: 0.05), deepQueue: true)
        try await startPlaying(rig)
        // Steady first, as `AudioEdgeTests` waits before its boundary inside
        // a ramp: a boundary is heard once the device has played the clip,
        // which trails the render by the output's latency (a Bluetooth
        // route's is well over the 50 ms of the first clip). A pause in the
        // first moments of playback can end its 120 ms ramp before the
        // first clip is heard at all, and then no boundary falls inside it.
        let steady = await rig.waitUntil(2) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
                && rig.controller.currentSentence >= 2
        }
        XCTAssertTrue(steady, "the start's fade-in finished and boundaries are heard")
        let deep = PlatformPlaybackTuning.lookAheadSentences.upperBound
        let filled = await rig.waitUntil(2) {
            (Self.scheduled(rig.events).map(\.sentence).max() ?? -1) - rig.controller.currentSentence >= deep
        }
        try XCTSkipUnless(filled && rig.controller.status == .playing, "the queue never filled")
        let thermal = makeGuard(rig)
        let splice = rig.controller.currentSentence + 1

        thermal.thermalStateChanged(.serious)   // fixes the splice at the next boundary, at once
        rig.controller.pause()
        let rampDone = await rig.waitUntil(1) { !rig.controller.isRampingVolume }
        XCTAssertTrue(rampDone)
        XCTAssertGreaterThanOrEqual(rig.controller.currentSentence, splice, "the ramp crossed the splice")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.voice, Self.system)

        rig.controller.play()
        let playing = await rig.waitUntil(2) { rig.controller.status == .playing }
        XCTAssertTrue(playing)
        await elapse(0.1)
        let lastStop = rig.events.lastIndex(of: .stopped).map { $0 + 1 } ?? 0
        let onTheNode = Self.scheduled(Array(rig.events[lastStop...]))
        XCTAssertFalse(onTheNode.contains { $0.voiceID == Self.michael.id && $0.sentence >= splice },
                       "no natural-voice clip at or past the splice plays after the cooling notice")
        XCTAssertTrue(onTheNode.contains { $0.voiceID == Self.system.id }, "the System voice reads on")
        rig.controller.pause()
    }

    /// The look-ahead in the heat: two sentences on an iPhone at
    /// `.serious` heat, the whole queue on a Mac.
    func testStrainShrinksTheLookAheadWhereThePlatformSaysSo() async throws {
        let rig = makeRig(deepQueue: true)
        rig.controller.isHot = { true }
        rig.controller.isUnderStrain = { true }
        try await startPlaying(rig)
        await assertLookAheadStaysStrained(rig)
    }

    /// The closures AppModel installs: the heat (`AppModel.heat`), Low
    /// Power Mode as the test answers it, and the strain built of both
    /// (`AppModel.strain`).
    private func installAppModelsStrain(_ rig: PlaybackTestRig, _ thermal: ThermalGuard, lowPower: Bool) {
        rig.controller.isHot = AppModel.heat(of: thermal)
        rig.controller.isLowPower = { lowPower }
        rig.controller.isUnderStrain = AppModel.strain(of: thermal) { lowPower }
    }

    /// The strain AppModel installs, hot before Play: the look-ahead
    /// shrinks to the strained two where the platform says so.
    func testHeatShrinksTheLookAheadThroughAppModelsStrain() async throws {
        let rig = makeRig(deepQueue: true)
        let thermal = makeGuard(rig)
        installAppModelsStrain(rig, thermal, lowPower: false)
        thermal.thermalStateChanged(.serious)
        try await startPlaying(rig, in: Self.system)
        await assertLookAheadStaysStrained(rig)
        XCTAssertTrue(thermal.isHot, "heat, not Low Power Mode, held it")
    }

    /// R4-34: in Low Power Mode, cool, the queue stays time-based over the
    /// shorter 2...4: short lines fill it to four and no more on an
    /// iPhone (heat alone keeps two); a Mac keeps its whole queue.
    func testLowPowerModeShrinksTheLookAheadThroughAppModelsStrain() async throws {
        let rig = makeRig(deepQueue: true)
        let thermal = makeGuard(rig)
        installAppModelsStrain(rig, thermal, lowPower: true)
        try await startPlaying(rig)
        let range = PlatformPlaybackTuning.lookAheadSentencesUnderLowPower ?? PlatformPlaybackTuning.lookAheadSentences
        let expected = PlaybackController.lookAheadCount(
            characterCounts: rig.content.sentences.map(\.text.count), rate: 1,
            seconds: PlatformPlaybackTuning.lookAheadSeconds, range: range)
        if PlatformPlaybackTuning.lookAheadSentencesUnderLowPower != nil {
            XCTAssertEqual(expected, 4, "short lines reach the top of 2...4")
        }
        let reached = await rig.waitUntil(2) { Self.ahead(rig) >= expected }
        XCTAssertTrue(reached, "\(Self.ahead(rig)) of \(expected)")
        await elapse(0.1)
        XCTAssertLessThanOrEqual(Self.ahead(rig), expected, "never past the Low Power range")
        XCTAssertTrue(rig.controller.isUnderStrain(), "the speculative work still stops")
        XCTAssertFalse(thermal.isHot, "Low Power Mode, not heat, held it")
        rig.controller.pause()
    }

    /// Cool and on full power, the closure leaves an iPhone its whole queue.
    func testNeitherHeatNorLowPowerKeepsTheWholeLookAhead() async throws {
        guard PlatformPlaybackTuning.lookAheadUnderStrain != nil else {
            throw XCTSkip("a Mac keeps its whole queue either way")
        }
        let rig = makeRig(deepQueue: true)
        let thermal = makeGuard(rig)
        installAppModelsStrain(rig, thermal, lowPower: false)
        try await startPlaying(rig)
        let deep = PlatformPlaybackTuning.lookAheadSentences.upperBound
        let filled = await rig.waitUntil(2) { Self.ahead(rig) >= deep }
        XCTAssertTrue(filled, "six sentences past the one playing")
        XCTAssertFalse(thermal.isHot)
        rig.controller.pause()
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
        XCTAssertEqual(rig.announcements, [Self.tooHotSpoken])
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
        XCTAssertEqual(rig.announcements, [Self.tooHotSpoken, Self.coolingSpoken],
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
        XCTAssertEqual(rig.announcements, [Self.tooHotSpoken], "no second cooling switch")
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

    // MARK: - Heating up again before the switch back lands

    /// .serious again while the cool-down's switch back to the natural
    /// voice waits for its splice: heat drops that switch, so no natural
    /// clip is queued and the System voice reads on, the sentence it was
    /// reading never cut off and started again (only System clips were on
    /// the node). The next cool-down tries again.
    func testReheatingBeforeTheSwitchBackLandsKeepsTheSystemVoice() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        let cooled = await rig.waitUntil { rig.controller.voice == Self.system }
        XCTAssertTrue(cooled)

        thermal.thermalStateChanged(.fair)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "the switch back waits for its splice")
        rig.clearRecordings()
        thermal.thermalStateChanged(.serious)   // same turn: the splice hasn't played

        XCTAssertNil(rig.controller.incomingVoice, "heat drops the switch back")
        XCTAssertFalse(rig.events.contains(.stopped), "nothing in Michael was queued: no restart")
        let landed = await rig.waitUntil(1.5) { rig.controller.voice == Self.michael }
        XCTAssertFalse(landed, "the natural voice never takes over while hot")
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertFalse(rig.events.contains(.stopped), "the sentence reading is never read again from its start")
        XCTAssertFalse(rig.statuses.contains(.buffering), "the System voice reads on with no gap")
        let queued = Self.scheduled(rig.events)
        XCTAssertFalse(queued.isEmpty)
        XCTAssertTrue(queued.allSatisfy { $0.voiceID == Self.system.id },
                      "no natural clip plays under the System chip: \(queued)")
        XCTAssertEqual(selections, [], "heat is never persisted as a pick")

        thermal.thermalStateChanged(.nominal)
        let restored = await rig.waitUntil { rig.controller.voice == Self.michael }
        XCTAssertTrue(restored, "the next cool-down brings the natural voice back")
        rig.controller.pause()
    }

    /// .critical while the switch back to a natural voice still loads its
    /// engine: the stop drops the switch, so the load finishes for nothing,
    /// Kokoro never reads while it's hot, and Play reads the System voice.
    func testCriticalWhileTheSwitchBackWarmsDropsIt() async throws {
        let neural = FakeNeuralEngine()   // cold: the switch back loads it
        let rig = makeRig(neural)
        try await startPlaying(rig, in: Self.system)
        let thermal = makeGuard(rig)
        thermal.thermalStateChanged(.serious)
        thermal.holdNaturalVoiceUntilCool()   // the model installed while hot
        thermal.thermalStateChanged(.fair)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "the engine loads behind the System voice")
        rig.clearRecordings()

        thermal.thermalStateChanged(.critical)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped?.reason, .tooHot)
        XCTAssertNil(rig.controller.incomingVoice, "the stop drops the switch back")
        XCTAssertEqual(rig.controller.voice, Self.system)
        XCTAssertEqual(rig.announcements, [Self.tooHotSpoken])
        neural.finishWarmUp()
        await elapse(0.3)
        XCTAssertTrue(neural.requests.isEmpty, "Kokoro never reads while it's hot")

        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        await elapse(1)
        XCTAssertEqual(rig.controller.voice, Self.system, "Play reads the System voice the stop left")
        XCTAssertTrue(Self.scheduled(rig.events).allSatisfy { $0.voiceID == Self.system.id })
        XCTAssertTrue(neural.requests.isEmpty)
        XCTAssertEqual(selections, [])
        rig.controller.pause()
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
        XCTAssertEqual(rig.announcements, [Self.tooHotSpoken], "announced once")
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
