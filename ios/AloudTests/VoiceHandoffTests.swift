import Combine
import XCTest
@testable import Aloud

/// R5's install switch: the neural engine warms while the system voice keeps
/// reading, and the splice lands on the first sentence not yet on the player
/// node, queued behind the old clips with no flush. Status never leaves
/// .playing. The voice commits quietly as the splice starts playing, and
/// "Now reading in Michael" is shown and announced once. Nothing is persisted.
///
/// All silent: muted controller, stub engines returning silence. A test whose
/// audio engine can't start in the host (status reaches .error before
/// .playing) is skipped, not failed.
@MainActor
final class VoiceHandoffTests: XCTestCase {

    private typealias FakeNeuralEngine = PlaybackTestRig.FakeNeuralEngine
    private static let michael = PlaybackTestRig.michael
    private static let systemID = PlaybackTestRig.voiceA.id

    private var selections: [String] = []
    private var subscriptions: Set<AnyCancellable> = []

    private func makeRig(_ neural: FakeNeuralEngine,
                         sentences: Int = 40,
                         clipDuration: TimeInterval = 0.25) -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration, neural: neural)
        rig.controller.voiceSelections
            .sink { [weak self] in self?.selections.append($0.id) }
            .store(in: &subscriptions)
        return rig
    }

    /// Plays the rig's book from the start, then forgets what was recorded
    /// on the way to .playing.
    private func startPlaying(_ rig: PlaybackTestRig) async throws {
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
    }

    private static func scheduled(_ events: some Sequence<PlaybackController.AudioScheduleEvent>)
        -> [(sentence: Int, voiceID: String)] {
        events.compactMap {
            if case .scheduled(let sentence, let voiceID) = $0 { return (sentence, voiceID) }
            return nil
        }
    }

    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A natural voice whose every clip waits until `failAll()`, then fails,
    /// as does every clip asked of it after: a removed model's engine,
    /// freed while its clip synthesized. Records each text asked.
    private final class HeldNeuralEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = [KokoroVoiceCatalog.defaultVoice]
        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Never>] = []
        private var failing = false
        private var log: [String] = []

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goesOn: Bool = lock.withLock {
                    log.append(text)
                    if failing { return true }
                    held.append(continuation)
                    return false
                }
                if goesOn { continuation.resume() }
            }
            throw TtsError.voiceUnavailable
        }

        var requestedTexts: [String] { lock.withLock { log } }

        func failAll() {
            let parked: [CheckedContinuation<Void, Never>] = lock.withLock {
                failing = true
                let parked = held
                held = []
                return parked
            }
            for continuation in parked { continuation.resume() }
        }
    }

    // MARK: - The splice

    func testInstallSwitchNeverBuffersAndLandsOnASentenceStart() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        try await startPlaying(rig)

        // At the commit: where the playhead was, and what the node had been given.
        var commitSentence: Int?
        var eventsAtCommit: [PlaybackController.AudioScheduleEvent]?
        rig.controller.$voice.dropFirst().sink { [weak rig] _ in
            guard let rig, commitSentence == nil else { return }
            commitSentence = rig.controller.currentSentence
            eventsAtCommit = rig.events
        }.store(in: &subscriptions)

        let switchedAt = rig.controller.currentSentence
        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertFalse(rig.controller.isPreparingVoice, "never 'Preparing voice…'")

        // Warming: the system voice keeps reading.
        await elapse(0.5)
        XCTAssertGreaterThan(rig.controller.currentSentence, switchedAt)
        XCTAssertTrue(Self.scheduled(rig.events).allSatisfy { $0.voiceID == Self.systemID })

        neural.finishWarmUp()
        let switched = await rig.waitUntil { rig.controller.voice == Self.michael }
        XCTAssertTrue(switched, "the voice commits once the splice plays")

        XCTAssertFalse(rig.statuses.contains(.buffering), "the switch never buffers")
        XCTAssertFalse(rig.statuses.contains(.paused))
        let atCommit = try XCTUnwrap(eventsAtCommit)
        XCTAssertFalse(atCommit.contains(.stopped), "nothing was flushed between the handoff and the commit")

        let splice = try XCTUnwrap(commitSentence)
        let queued = Self.scheduled(rig.events)
        let firstMichael = try XCTUnwrap(queued.first { $0.voiceID == Self.michael.id })
        XCTAssertEqual(firstMichael.sentence, splice, "the switch lands on a sentence start")
        XCTAssertTrue(queued.filter { $0.voiceID == Self.systemID }.allSatisfy { $0.sentence < splice },
                      "the old voice never reaches the node at or past the splice")
        XCTAssertTrue(atCommit.contains(.scheduled(sentence: splice, voiceID: Self.michael.id)),
                      "the splice was queued before the old audio ran out")
        XCTAssertEqual(rig.announcements, ["Now reading in Michael"])
        XCTAssertEqual(rig.controller.notice, .nowReadingIn(voiceName: "Michael"))
        XCTAssertEqual(selections, [], "the install switch is never persisted as a pick")
    }

    func testSystemVoiceKeepsSpeakingWhileTheEngineWarms() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        try await startPlaying(rig)

        let switchedAt = rig.controller.currentSentence
        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        await elapse(1)

        XCTAssertGreaterThanOrEqual(rig.controller.currentSentence - switchedAt, 2)
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertTrue(rig.statuses.allSatisfy { $0 == .playing })
        XCTAssertTrue(neural.requests.isEmpty, "nothing is asked of a cold engine")
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        XCTAssertNil(rig.controller.notice)

        neural.finishWarmUp()   // never leave the warm-up parked
    }

    func testWarmUpFailureKeepsTheCurrentVoiceAndNeverBuffers() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        neural.finishWarmUp(failing: true)
        let noticed = await rig.waitUntil(2) { rig.controller.notice == .fellBackToSystem }
        XCTAssertTrue(noticed)

        let failedAt = rig.controller.currentSentence
        let advanced = await rig.waitUntil(3) { rig.controller.currentSentence >= failedAt + 2 }
        XCTAssertTrue(advanced, "the schedule keeps advancing")
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertTrue(Self.scheduled(rig.events).allSatisfy { $0.voiceID == Self.systemID })
        XCTAssertEqual(rig.announcements, ["Natural voice unavailable, using System"])
        XCTAssertEqual(selections, [])
    }

    /// The engine is ready when the old voice has already queued every
    /// sentence left: there is nowhere to splice. Those clips play out, and
    /// the switch and its notice wait for the book to end rather than
    /// naming a voice over the one still reading.
    func testNothingLeftToQueueSwitchesWhenTheBookEnds() async throws {
        let neural = FakeNeuralEngine(warm: true)
        // Three 1 s sentences: the look-ahead (2) queues all of them at once.
        let rig = makeRig(neural, sentences: 3, clipDuration: 1)
        // Not startPlaying(): the instant stub synth can queue all three
        // clips before .playing is observed, and clearing the recordings
        // then would erase the sentence-2 event this waits for. Clear only
        // once everything is queued (the start's .buffering goes with it).
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let allQueued = await rig.waitUntil(2) {
            Self.scheduled(rig.events).contains { $0.sentence == 2 }
        }
        XCTAssertTrue(allQueued)
        rig.clearRecordings()
        XCTAssertEqual(rig.controller.status, .playing, "the System voice is still reading")

        var announced: [(text: String, status: PlayerStatus?)] = []
        rig.controller.announce = { [weak controller = rig.controller] in
            announced.append(($0, controller?.status))
        }
        // The end is heard (full level, app active), so R24's success plays:
        // recorded here, never sent to TransportHaptics.shared.
        var haptics: [TransportHaptic] = []
        rig.controller.emitHaptic = { haptics.append($0) }
        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)

        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "no switch while old clips still play")
        XCTAssertNil(rig.controller.notice)
        XCTAssertTrue(announced.isEmpty)

        let ended = await rig.waitUntil(6) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.controller.voice, Self.michael, "the book's end commits the switch")
        // R24: the switch's notice lands first, then the end is announced.
        XCTAssertEqual(announced.map(\.text), ["Now reading in Michael", ColophonCopy.theEnd])
        XCTAssertEqual(announced.first?.status, .ended, "announced after the System voice finished, never over it")
        XCTAssertTrue(announced.allSatisfy { $0.status == .ended }, "\(announced)")
        XCTAssertEqual(haptics, [.finished])
        XCTAssertTrue(Self.scheduled(rig.events).allSatisfy { $0.voiceID == Self.systemID })
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertEqual(selections, [])

        // Listen again reads in the new voice, with no second notice and no
        // second end.
        rig.controller.play()
        let restarted = await rig.waitUntil { Self.scheduled(rig.events).contains { $0.voiceID == Self.michael.id } }
        XCTAssertTrue(restarted)
        XCTAssertEqual(Self.scheduled(rig.events).first { $0.voiceID == Self.michael.id }?.sentence, 0)
        XCTAssertEqual(announced.count, 2)
        XCTAssertEqual(haptics, [.finished])
        rig.controller.pause()
    }

    // MARK: - Not playing

    func testHandOffWhilePausedSwitchesQuietly() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        rig.loadDefault(at: 5)
        rig.clearRecordings()

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)

        XCTAssertEqual(rig.controller.voice, Self.michael, "nothing is speaking, so it switches at once")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertFalse(rig.controller.isPreparingVoice)
        XCTAssertEqual(rig.controller.notice, .nowReadingIn(voiceName: "Michael"))
        XCTAssertEqual(rig.announcements, ["Now reading in Michael"])

        await elapse(0.3)
        XCTAssertTrue(Self.scheduled(rig.events).isEmpty, "nothing reaches the player")
        XCTAssertTrue(rig.statuses.allSatisfy { $0 == .paused })
        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertEqual(selections, [])
    }

    func testNoBookLoadedSwitchIsSilent() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.voice, Self.michael)

        await elapse(0.3)
        XCTAssertNil(rig.controller.notice)
        XCTAssertEqual(rig.announcements, [])
        XCTAssertEqual(rig.events, [])
        XCTAssertTrue(neural.requests.isEmpty)
        XCTAssertEqual(selections, [])
    }

    // MARK: - Cancelled or cut short

    func testDeliberatePickDuringHandoffCancelsIt() async throws {
        let neural = FakeNeuralEngine()
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        await elapse(0.2)   // the warm-up is parked: the handoff is pending
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        neural.finishWarmUp()

        let spokeB = await rig.waitUntil {
            Self.scheduled(rig.events).contains { $0.voiceID == PlaybackTestRig.voiceB.id }
        }
        XCTAssertTrue(spokeB)
        await elapse(0.5)
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceB, "the pick wins")
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        XCTAssertNil(rig.controller.notice)
        XCTAssertFalse(Self.scheduled(rig.events).contains { $0.voiceID == Self.michael.id })
        XCTAssertEqual(selections, [PlaybackTestRig.voiceB.id])
    }

    /// The System voice standing in during the switch, picked again: the
    /// switch is cancelled, so Michael never takes over at the splice, and
    /// the pick is the listener's choice, so it is stored.
    func testPickingTheSpeakingVoiceDuringHandoffCancelsIt() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        await elapse(1.5)   // well past where the splice was fixed

        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "the pick wins")
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        let queued = Self.scheduled(rig.events)
        XCTAssertFalse(queued.contains { $0.voiceID == Self.michael.id }, "nothing past the splice in Michael")
        XCTAssertTrue(queued.contains { $0.voiceID == PlaybackTestRig.voiceA.id }, "reading went on")
        XCTAssertEqual(selections, [PlaybackTestRig.voiceA.id], "a pick against a pending switch is stored")
    }

    /// The model removed while its install switch is primed (AppModel calls
    /// this): the switch goes with the clips fixed past its splice, the
    /// System voice reads on, and nothing is announced or stored.
    func testCancellingAPrimedHandoffKeepsTheVoiceSpeaking() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        await elapse(0.15)   // the top-up may hand the splice to the node
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "primed, not yet committed")
        let mark = rig.events.count
        rig.controller.cancelVoiceHandoff()
        await elapse(1.5)

        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        XCTAssertNil(rig.controller.notice)
        let after = Self.scheduled(rig.events[mark...])
        XCTAssertFalse(after.isEmpty, "reading went on")
        XCTAssertTrue(after.allSatisfy { $0.voiceID == PlaybackTestRig.voiceA.id }, "no Michael after the cancel: \(after)")
        XCTAssertEqual(selections, [])
        rig.controller.pause(rampsOut: false)
    }

    /// Cancelled with the splice fixed but still ahead of the queue (the
    /// same turn it was primed): only System clips are on the node, so the
    /// sentence reading goes on, never cut off and read again.
    func testCancellingBeforeTheSpliceIsQueuedNeverRestarts() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "primed")
        rig.clearRecordings()
        rig.controller.cancelVoiceHandoff()

        XCTAssertNil(rig.controller.incomingVoice)
        XCTAssertFalse(rig.events.contains(.stopped), "nothing in Michael on the node: no restart")
        await elapse(1)
        XCTAssertFalse(rig.events.contains(.stopped), "the sentence reading is never read again from its start")
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        let queued = Self.scheduled(rig.events)
        XCTAssertFalse(queued.isEmpty, "reading went on")
        XCTAssertTrue(queued.allSatisfy { $0.voiceID == Self.systemID }, "the splice is read in System: \(queued)")
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        XCTAssertEqual(selections, [])
        rig.controller.pause(rampsOut: false)
    }

    /// The splice fell past the end (the System voice had queued every
    /// sentence left): cancelling leaves those clips to play out, with no
    /// restart of the sentence reading, and the end commits nothing.
    func testCancellingASpliceFixedPastTheEndNeverRestarts() async throws {
        let neural = FakeNeuralEngine(warm: true)
        // Three 1 s sentences: the look-ahead queues all of them at once.
        let rig = makeRig(neural, sentences: 3, clipDuration: 1)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let allQueued = await rig.waitUntil(2) {
            Self.scheduled(rig.events).contains { $0.sentence == 2 }
        }
        XCTAssertTrue(allQueued)
        rig.clearRecordings()
        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "fixed past the end")

        rig.controller.cancelVoiceHandoff()

        XCTAssertFalse(rig.events.contains(.stopped), "every clip on the node is System: no restart")
        let ended = await rig.waitUntil(6) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        XCTAssertFalse(rig.events.contains(.stopped))
        XCTAssertTrue(Self.scheduled(rig.events).isEmpty, "no sentence is read again: \(Self.scheduled(rig.events))")
        XCTAssertFalse(rig.statuses.contains(.buffering))
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "the end commits nothing")
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        XCTAssertEqual(selections, [])
    }

    /// Cancelled once a clip in Michael is on the node, past the splice:
    /// the current sentence reloads in System, so that clip never plays
    /// under the System chip.
    func testCancellingAfterTheSpliceIsQueuedRestartsInTheSpeakingVoice() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        let queuedInMichael = await rig.waitUntil(3) {
            Self.scheduled(rig.events).contains { $0.voiceID == Self.michael.id }
        }
        XCTAssertTrue(queuedInMichael)
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "queued, not yet playing")
        let mark = rig.events.count
        rig.controller.cancelVoiceHandoff()

        let stop = try XCTUnwrap(rig.events[mark...].firstIndex(of: .stopped), "the current sentence reloads")
        await elapse(1)
        let after = Self.scheduled(rig.events[(stop + 1)...])
        XCTAssertFalse(after.isEmpty, "reading went on")
        XCTAssertTrue(after.allSatisfy { $0.voiceID == Self.systemID }, "no Michael after the cancel: \(after)")
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        XCTAssertFalse(rig.announcements.contains("Now reading in Michael"))
        XCTAssertEqual(selections, [])
        rig.controller.pause(rampsOut: false)
    }

    /// The model removed while the top-up waits on the splice's clip in
    /// Michael (AppModel cancels the switch, then frees the engine, so the
    /// clip fails): nothing in Michael was on the node, so nothing restarts,
    /// and that failure is no bad sentence. The System voice reads it, with
    /// no skip and no notice.
    func testASwitchDroppedWhileItsClipSynthesizesSkipsNothing() async throws {
        let held = HeldNeuralEngine()
        defer { held.failAll() }   // a failed assertion never leaves a clip parked
        let rig = PlaybackTestRig(sentences: 40, kokoro: FakeNeuralEngine(warm: true),
                                  extraRoutes: [Self.michael.id: held])
        try await startPlaying(rig)
        await elapse(0.1)   // the look-ahead fills: the splice lies past the cue's System warm-ups

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        let asked = await rig.waitUntil(2) { !held.requestedTexts.isEmpty }
        XCTAssertTrue(asked, "the splice is warmed in Michael")
        // The first Michael request is the splice (`cuePrefetch(from: splice)`).
        let splice = try XCTUnwrap(held.requestedTexts.first.flatMap(PlaybackTestRig.sentenceIndex(ofRequest:)))
        // The last System clip before the splice is reading: the top-up now
        // waits on the splice's held clip.
        let reached = await rig.waitUntil(5) { rig.controller.currentSentence >= splice - 1 }
        XCTAssertTrue(reached)
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        let mark = rig.events.count

        rig.controller.cancelVoiceHandoff()   // as AppModel does for a removed model
        XCTAssertFalse(rig.events[mark...].contains(.stopped), "nothing in Michael on the node: no restart")
        held.failAll()   // the freed engine can't load the removed model

        let read = await rig.waitUntil(3) {
            Self.scheduled(rig.events[mark...]).contains { $0.sentence == splice }
        }
        XCTAssertTrue(read, "reading went on past the splice")
        XCTAssertTrue(rig.requestedSentences(rig.engineA).contains(splice),
                      "the System voice reads the splice sentence, never a beat of silence")
        XCTAssertNil(rig.controller.notice, "no skipped-sentence notice")
        XCTAssertFalse(rig.events[mark...].contains(.stopped))
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA)
        rig.controller.pause(rampsOut: false)
    }

    func testSeekAfterPrimingCommitsBeforeRestart() async throws {
        let neural = FakeNeuralEngine(warm: true)
        let rig = makeRig(neural)
        try await startPlaying(rig)

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.voice, PlaybackTestRig.voiceA, "primed, not yet committed")

        rig.controller.seek(to: 20, andPlay: true)
        XCTAssertEqual(rig.controller.voice, Self.michael, "the restart commits the splice first")

        let restarted = await rig.waitUntil {
            guard let stop = rig.events.firstIndex(of: .stopped) else { return false }
            return !Self.scheduled(rig.events[(stop + 1)...]).isEmpty
        }
        XCTAssertTrue(restarted)
        let stop = try XCTUnwrap(rig.events.firstIndex(of: .stopped))
        let first = try XCTUnwrap(Self.scheduled(rig.events[(stop + 1)...]).first)
        XCTAssertEqual(first.sentence, 20)
        XCTAssertEqual(first.voiceID, Self.michael.id, "the restarted schedule speaks the new voice from its first clip")
        XCTAssertEqual(rig.announcements, ["Now reading in Michael"])
        XCTAssertEqual(selections, [])
    }
}
