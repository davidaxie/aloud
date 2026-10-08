import Combine
import XCTest
@testable import Aloud

/// R8: you hear a voice where you pick it. Playing, a pick restarts the
/// current sentence in the new voice. Not playing, it speaks the current
/// sentence once (an audition) and returns to where it was. With no book, it
/// speaks one sample line. Every path uses the one player node, so at most
/// one voice is ever in it, and only a change of voice is persisted.
///
/// All silent: muted controller, stub engines returning silence. A test whose
/// audio engine can't start in the host (status reaches .error before
/// .playing) is skipped, not failed.
@MainActor
final class VoiceAuditionTests: XCTestCase {

    private var selections: [String] = []
    private var subscriptions: Set<AnyCancellable> = []

    private func makeRig(sentences: Int = 4, clipDuration: TimeInterval = 0.25) -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration)
        rig.controller.voiceSelections
            .sink { [weak self] in self?.selections.append($0.id) }
            .store(in: &subscriptions)
        return rig
    }

    private static func voiceID(of event: PlaybackController.AudioScheduleEvent) -> String? {
        if case .scheduled(_, let voiceID) = event { return voiceID }
        return nil
    }

    private static func sentence(of event: PlaybackController.AudioScheduleEvent) -> Int? {
        if case .scheduled(let sentence, _) = event { return sentence }
        return nil
    }

    @MainActor
    private final class LateClipProbe {
        var playhead: TimeInterval?
        var elapsed: TimeInterval?
    }

    /// Silence at once for the sentences before `lateFrom`, and only after
    /// `delay` for the rest: synthesis slower than speech.
    private final class LateEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let lateFrom: Int
        private let delay: TimeInterval
        private let clipDuration: TimeInterval

        init(voices: [TtsVoice], lateFrom: Int, delay: TimeInterval, clipDuration: TimeInterval) {
            self.voices = voices
            self.lateFrom = lateFrom
            self.delay = delay
            self.clipDuration = clipDuration
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            // "Line<i> word…" (PlaybackTestRig.makeContent).
            let index = text.hasPrefix("Line") ? Int(text.dropFirst(4).prefix { $0.isNumber }) : nil
            if let index, index >= lateFrom {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return .silence(duration: clipDuration, sampleRate: 22_050)
        }
    }

    /// Waits for an audition started at status index `mark` to hand back
    /// `status` (it reached .playing first).
    private func waitForAuditionEnd(_ rig: PlaybackTestRig, after mark: Int,
                                    returningTo status: PlayerStatus = .paused) async -> Bool {
        await rig.waitUntil {
            rig.statuses[mark...].contains(.playing) && rig.statuses.last == status
        }
    }

    // MARK: - Paused pick

    func testPausedPickSpeaksCurrentSentenceOnceThenPausesThere() async throws {
        let rig = makeRig()
        rig.loadDefault(at: 1)
        XCTAssertEqual(rig.controller.status, .paused)
        let playActions = rig.controller.userPlayAction

        var sentencesSeen: Set<Int> = []
        rig.controller.$currentSentence.sink { sentencesSeen.insert($0) }.store(in: &subscriptions)
        // What voice B was asked for by the moment the audition hands back the
        // pause: after that, the paused cue warms the next sentence, which is
        // synthesis, not speech.
        var requestsAtPause: [Int]?
        rig.controller.$status.dropFirst().sink { [weak rig] status in
            if status == .paused, requestsAtPause == nil, let rig {
                requestsAtPause = rig.requestedSentences(rig.engineB)
            }
        }.store(in: &subscriptions)

        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let ended = await waitForAuditionEnd(rig, after: mark)
        XCTAssertTrue(ended, "the audition returns to paused")

        let tail = Array(rig.statuses[mark...])
        let buffering = try XCTUnwrap(tail.firstIndex(of: .buffering))
        let playing = try XCTUnwrap(tail.firstIndex(of: .playing))
        XCTAssertLessThan(buffering, playing)
        XCTAssertEqual(tail.last, .paused)
        XCTAssertEqual(sentencesSeen, [1], "the playhead never leaves the auditioned sentence")
        XCTAssertEqual(rig.controller.currentSentence, 1)
        XCTAssertEqual(requestsAtPause, [1], "voice B was asked for sentence 1 only")
        XCTAssertEqual(rig.events.compactMap(Self.sentence(of:)).filter { $0 != 1 && $0 >= 0 }, [],
                       "nothing past the auditioned sentence reached the player")
        XCTAssertEqual(rig.controller.userPlayAction, playActions)
        XCTAssertEqual(selections, ["test:b"])

        // Once: it stays paused.
        let scheduled = rig.events.compactMap(Self.voiceID(of:)).count
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.events.compactMap(Self.voiceID(of:)).count, scheduled)
    }

    // MARK: - Playing pick

    func testPlayingPickRestartsSentenceAndContinues() async throws {
        let rig = makeRig(sentences: 12)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let switchedAt = rig.controller.currentSentence
        let mark = rig.events.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        let movedOn = await rig.waitUntil { rig.controller.currentSentence > switchedAt + 1 }
        XCTAssertTrue(movedOn, "playback continues past the switched sentence")

        let after = Array(rig.events[mark...])
        let stop = try XCTUnwrap(after.firstIndex(of: .stopped))
        let firstB = try XCTUnwrap(after.firstIndex { Self.voiceID(of: $0) == "test:b" })
        XCTAssertLessThan(stop, firstB, "the old voice is flushed before the new one is queued")
        XCTAssertEqual(Self.sentence(of: after[firstB]), switchedAt, "the current sentence restarts")
        XCTAssertFalse(after[stop...].contains { Self.voiceID(of: $0) == "test:a" },
                       "no clip in the old voice is queued after the switch")
        XCTAssertEqual(selections, ["test:b"])
    }

    // MARK: - No book

    func testPickWithNothingLoadedSpeaksSampleLineOnly() async throws {
        let rig = makeRig()
        rig.controller.selectVoice(PlaybackTestRig.voiceB)

        let sample = PlaybackController.AudioScheduleEvent.scheduled(sentence: -1, voiceID: "test:b")
        let spoke = await rig.waitUntil { rig.events.contains(sample) }
        if !spoke, rig.engineB.requestedTexts == [PlaybackController.sampleLine] {
            throw XCTSkip("The audio engine can't start in this test host")
        }
        XCTAssertTrue(spoke)
        XCTAssertEqual(rig.engineB.requestedTexts, [PlaybackController.sampleLine])
        XCTAssertEqual(rig.engineA.requestedTexts, [])
        XCTAssertEqual(rig.events.compactMap(Self.voiceID(of:)).count, 1)
        XCTAssertEqual(rig.events.filter { $0 == sample }.count, 1)
        XCTAssertEqual(Set(rig.statuses), [.idle], "the sample line is not playback")
        XCTAssertEqual(selections, ["test:b"])
    }

    /// Voice B's sample line, held until `release()`: a sample still being
    /// made.
    private final class HeldSampleEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []   // routed by id (`PlaybackTestRig.RoutingEngine`)
        private let lock = NSLock()
        private var held: CheckedContinuation<Void, Never>?
        private var released = false
        private var asked = 0

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goesOn: Bool = lock.withLock {
                    asked += 1
                    if released { return true }
                    held = continuation
                    return false
                }
                if goesOn { continuation.resume() }
            }
            return .silence(duration: 3, sampleRate: 22_050)
        }

        var requests: Int { lock.withLock { asked } }

        func release() {
            let parked: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { held = nil }
                return held
            }
            parked?.resume()
        }
    }

    /// Headphones out during the sample with no book (J003): the line is
    /// cut at once, so it never carries on from the speaker. Nothing is
    /// recorded or announced: no book was stopped.
    func testALostRouteCutsTheSampleWithNoBook() async throws {
        let long = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceB], clipDuration: 3)
        let rig = PlaybackTestRig(extraRoutes: [PlaybackTestRig.voiceB.id: long])
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        let sample = PlaybackController.AudioScheduleEvent.scheduled(sentence: -1, voiceID: "test:b")
        let spoke = await rig.waitUntil { rig.events.contains(sample) }
        if !spoke, long.requestedTexts == [PlaybackController.sampleLine] {
            throw XCTSkip("The audio engine can't start in this test host")
        }
        XCTAssertTrue(spoke)
        let mark = rig.events.count
        let spoken = rig.announcements.count

        rig.audioSession.onRouteRequiresPause?()

        XCTAssertTrue(rig.events[mark...].contains(.stopped), "the sample is dropped at once")
        XCTAssertEqual(rig.controller.status, .idle)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(rig.announcements.count, spoken)
    }

    /// Headphones out while the sample is still being made: it never starts.
    func testALostRouteBeforeTheSampleIsMadeNeverStartsIt() async throws {
        let held = HeldSampleEngine()
        defer { held.release() }   // a failed assertion never leaves the line parked
        let rig = PlaybackTestRig(extraRoutes: [PlaybackTestRig.voiceB.id: held])
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        let asked = await rig.waitUntil { held.requests > 0 }
        XCTAssertTrue(asked, "the sample line is being made")

        rig.audioSession.onRouteRequiresPause?()
        held.release()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(rig.events.contains { Self.sentence(of: $0) == -1 }, "the sample never starts: \(rig.events)")
        XCTAssertEqual(rig.controller.status, .idle)
        XCTAssertFalse(rig.controller.isPreparingVoice)
    }

    /// A headset Pause or Play/Pause during the no-book sample (L028) cuts
    /// the sample, as a route loss does, and never continues the last book.
    func testARemotePauseDuringTheNoBookSampleCutsItAndContinuesNothing() async throws {
        for command in [NowPlayingManager.RemoteTransportCommand.togglePlayPause, .pause] {
            let held = HeldSampleEngine()
            defer { held.release() }   // a failed assertion never leaves the line parked
            let rig = PlaybackTestRig(extraRoutes: [PlaybackTestRig.voiceB.id: held])
            let manager = NowPlayingManager(publish: { _ in }, renderArtwork: { _ in nil })
            manager.observe(playback: rig.controller)
            var continued = 0
            manager.onPlayWithNoBook = { continued += 1 }
            rig.controller.selectVoice(PlaybackTestRig.voiceB)
            let asked = await rig.waitUntil { held.requests > 0 }
            XCTAssertTrue(asked, "the sample line is being made")
            XCTAssertTrue(rig.controller.isSpeakingSample, "\(command)")

            manager.handle(command)

            XCTAssertEqual(continued, 0, "\(command) continued the last book")
            XCTAssertFalse(rig.controller.isSpeakingSample, "\(command) left the sample going")
            held.release()
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(rig.events.contains { Self.sentence(of: $0) == -1 },
                           "\(command): the sample started anyway: \(rig.events)")
            XCTAssertNil(rig.controller.document)
            XCTAssertEqual(rig.controller.status, .idle)
        }
    }

    // MARK: - Re-picking the selected voice

    func testReselectingCurrentVoiceWritesNothing() async throws {
        let rig = makeRig(sentences: 12, clipDuration: 0.5)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        // Playing: nothing happens at all.
        let statusMark = rig.statuses.count
        let eventMark = rig.events.count
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        XCTAssertEqual(rig.statuses.count, statusMark, "no status transition")
        XCTAssertFalse(rig.events[eventMark...].contains(.stopped), "nothing was flushed")
        XCTAssertEqual(selections, [])

        // Paused: the same voice speaks the sentence once more.
        rig.controller.pause()
        let pausedAt = rig.controller.currentSentence
        let mark = rig.statuses.count
        let respeakMark = rig.events.count
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let ended = await waitForAuditionEnd(rig, after: mark)
        XCTAssertTrue(ended)
        XCTAssertTrue(rig.events[respeakMark...].contains(.scheduled(sentence: pausedAt, voiceID: "test:a")))
        XCTAssertEqual(rig.controller.currentSentence, pausedAt)
        XCTAssertEqual(selections, [], "re-picking the selected voice is never persisted")
    }

    // MARK: - One voice in the player

    func testAtMostOneVoiceInPlayerDuringSwitch() async throws {
        let rig = makeRig(sentences: 12, clipDuration: 0.5)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        // While playing: A → B → A.
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        _ = await rig.waitUntil { rig.events.last.flatMap(Self.voiceID(of:)) == "test:b" }
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        _ = await rig.waitUntil { rig.events.last.flatMap(Self.voiceID(of:)) == "test:a" }

        // While paused: A → B → A, each an audition.
        rig.controller.pause()
        var mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        let first = await waitForAuditionEnd(rig, after: mark)
        mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        let second = await waitForAuditionEnd(rig, after: mark)
        XCTAssertTrue(first && second)

        var inPlayer: Set<String> = []
        for event in rig.events {
            switch event {
            case .stopped: inPlayer.removeAll()
            case .scheduled(_, let voiceID): inPlayer.insert(voiceID)
            }
            XCTAssertLessThanOrEqual(inPlayer.count, 1, "two voices queued in the player at once")
        }
        XCTAssertEqual(selections, ["test:b", "test:a", "test:b", "test:a"])
    }

    // MARK: - Transport during an audition

    func testPauseDuringAuditionThenPlayContinues() async throws {
        let rig = makeRig(sentences: 6, clipDuration: 1)
        rig.loadDefault(at: 1)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)

        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .paused)
        rig.controller.play()

        let advanced = await rig.waitUntil(8) { rig.controller.currentSentence > 1 }
        XCTAssertTrue(advanced, "after a pause, Play is ordinary playback past the auditioned sentence")
    }

    func testSeekDuringAuditionBecomesNormalPlayback() async throws {
        let rig = makeRig(sentences: 8, clipDuration: 0.5)
        rig.loadDefault(at: 1)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)

        rig.controller.seek(to: 3, andPlay: true)

        let past = await rig.waitUntil(8) { rig.controller.currentSentence > 3 }
        XCTAssertTrue(past, "the seek ends the audition; playback keeps going past 3")
    }

    /// Paused with voice A's clips still on the node, a pick of a natural
    /// voice that must warm first. Play during the warm-up starts the new
    /// voice from the cue, fading in like any start (R20). It never resumes
    /// voice A for the seconds the warm-up takes, only for the warm-up's
    /// reload to cut the new voice in at full level.
    func testPlayWhileAPickedVoiceWarmsFromAPauseStartsItFadingIn() async throws {
        let neural = PlaybackTestRig.FakeNeuralEngine(warm: false)
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 2, neural: neural)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()
        let paused = await rig.waitUntil(1) { !rig.nodePauseTimes().isEmpty }
        XCTAssertTrue(paused)
        let cue = rig.controller.currentSentence

        rig.controller.selectVoice(PlaybackTestRig.michael)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(rig.controller.isPreparingVoice, "the natural voice warms first")
        XCTAssertEqual(rig.controller.status, .paused, "nothing speaks until it can")
        let eventMark = rig.events.count
        let edgeMark = rig.edges.count

        rig.controller.play()

        XCTAssertFalse(rig.edges[edgeMark...].contains { $0.event == .nodeResumed }, "voice A never resumes")
        XCTAssertEqual(rig.controller.status, .buffering, "a fresh start from the cue")
        let settled = await rig.waitUntil(2) {
            rig.controller.status == .playing && !rig.controller.isRampingVolume
                && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(settled, "the new voice came up to full level")
        neural.finishWarmUp()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let queued = rig.events[eventMark...].filter { Self.voiceID(of: $0) != nil }
        XCTAssertEqual(queued.first, .scheduled(sentence: cue, voiceID: PlaybackTestRig.michael.id),
                       "the first clip after Play is the new voice at the cue")
        XCTAssertFalse(queued.contains { Self.voiceID(of: $0) == PlaybackTestRig.voiceA.id },
                       "voice A is never queued again")
        let levels = rig.volumes(from: edgeMark).map(\.value)
        XCTAssertEqual(levels.first, 0, "starts silent: \(levels)")
        XCTAssertGreaterThanOrEqual(levels.filter { $0 > 0 && $0 < 1 }.count, 2, "ramps up in steps: \(levels)")
        XCTAssertTrue(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 }, "never a jump down: \(levels)")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Restore status and anchor

    func testAuditionFromEndedReturnsToEnded() async throws {
        let rig = makeRig(sentences: 4)
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil { rig.controller.status == .ended }
        XCTAssertTrue(ended)

        var fractions: [Double] = []
        rig.controller.onProgress = { _, _, fraction in fractions.append(fraction) }
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let back = await waitForAuditionEnd(rig, after: mark, returningTo: .ended)

        XCTAssertTrue(back)
        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(fractions.last, 1.0, "the book reads Finished again")
    }

    /// Played to its end (.ended on the last of 4 sentences). Voice B's
    /// sample lasts `sampleSeconds`, so a test can act while it is heard.
    private func endedRig(sampleSeconds: TimeInterval = 3) async throws -> PlaybackTestRig {
        let sample = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceB], clipDuration: sampleSeconds)
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 0.25,
                                  extraRoutes: [PlaybackTestRig.voiceB.id: sample])
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil { rig.controller.status == .ended }
        XCTAssertTrue(ended, "the book played to its end")
        return rig
    }

    /// A Pause over a sample of a Finished book hands back the end, as the
    /// sample's own finish would. The book stays Finished, and Play starts
    /// it over: never the rest of the last sentence warm-resumed, ending
    /// the book again.
    func testPausingAnAuditionOverTheEndKeepsTheBookFinished() async throws {
        let rig = try await endedRig()
        let anchor = rig.controller.resumeAnchor
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let eventMark = rig.events.count
        let edgeMark = rig.edges.count
        let progressMark = rig.progress.count

        rig.controller.pause()

        XCTAssertEqual(rig.controller.status, .ended, "the book is still Finished")
        XCTAssertEqual(rig.controller.currentSentence, 3)
        let dropped = await rig.waitUntil(1) {
            !rig.controller.isRampingVolume && rig.events[eventMark...].contains(.stopped)
        }
        XCTAssertTrue(dropped, "the sample ramps out, then its schedule is dropped")
        let levels = rig.volumes(from: edgeMark).map(\.value)
        XCTAssertGreaterThanOrEqual(levels.count, 3, "a user pause ramps out (R20): \(levels)")
        XCTAssertEqual(levels.last, 0, "\(levels)")
        XCTAssertEqual(rig.nodePauseTimes(from: edgeMark).count, 1, "the node pauses once, after the ramp")
        let lastLevel = try XCTUnwrap(rig.edges.lastIndex { if case .volume = $0.event { return true }; return false })
        let nodePause = try XCTUnwrap(rig.edges.lastIndex { $0.event == .nodePaused })
        XCTAssertGreaterThan(nodePause, lastLevel, "after the final 0")
        XCTAssertFalse(rig.edges[edgeMark...].contains { $0.event == .nodeResumed })
        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(rig.controller.resumeAnchor, anchor, "the rest began at the end, not at the sample")
        XCTAssertTrue(rig.progress[progressMark...].allSatisfy { $0.fraction == 1 }, "still reads Finished")
        let playActions = rig.controller.userPlayAction

        rig.controller.play()

        XCTAssertEqual(rig.controller.currentSentence, 0, "Play from the end starts over")
        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A stop over it (headphones out) is the same return, cut silent at
    /// once, and records nothing: it stopped a sample, not the book.
    func testAStopDuringAnAuditionOverTheEndKeepsTheBookFinished() async throws {
        let rig = try await endedRig()
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let eventMark = rig.events.count
        let edgeMark = rig.edges.count
        let spoken = rig.announcements.count

        rig.audioSession.onRouteRequiresPause?()

        XCTAssertEqual(rig.controller.status, .ended, "the book is still Finished")
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(rig.nodePauseTimes(from: edgeMark).count, 1, "cut at once")
        XCTAssertTrue(rig.events[eventMark...].contains(.stopped), "the sample is dropped at once")
        XCTAssertFalse(rig.controller.isRampingVolume)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0, "cut silent")
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(rig.announcements.count, spoken)

        rig.controller.play()

        XCTAssertEqual(rig.controller.currentSentence, 0, "Play from the end starts over")
        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Not heard yet (still buffering), a Pause or a stop over it hands
    /// back the end too.
    func testPauseOrStopBeforeAnAuditionOverTheEndIsHeardKeepsTheBookFinished() async throws {
        let moves: [(name: String, run: (PlaybackController) -> Void)] = [
            ("a pause", { $0.pause() }),
            ("a stop", { $0.stop(because: .headphonesDisconnected) }),
        ]
        for move in moves {
            let rig = try await endedRig()
            rig.controller.selectVoice(PlaybackTestRig.voiceB)
            XCTAssertEqual(rig.controller.status, .buffering, "\(move.name): the sample isn't heard yet")

            move.run(rig.controller)

            XCTAssertEqual(rig.controller.status, .ended, "\(move.name) keeps the book Finished")
            XCTAssertEqual(rig.controller.currentSentence, 3, move.name)
            XCTAssertNil(rig.controller.stopped, move.name)

            rig.controller.play()

            XCTAssertEqual(rig.controller.currentSentence, 0, "\(move.name): Play from the end starts over")
            rig.controller.pause(rampsOut: false)
        }
    }

    func testAuditionLeavesResumeAnchorUntouched() async throws {
        let rig = makeRig(sentences: 12)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.pause()
        let before = try XCTUnwrap(rig.controller.resumeAnchor, "the pause anchors the rest")
        let storedBefore = rig.anchorStore.load()

        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let ended = await waitForAuditionEnd(rig, after: mark)
        XCTAssertTrue(ended)

        XCTAssertEqual(rig.controller.resumeAnchor, before)
        XCTAssertEqual(rig.anchorStore.load()?.documentID, storedBefore?.documentID)
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, storedBefore?.sentenceIndex)
        XCTAssertEqual(rig.anchorStore.load()?.wallClock, storedBefore?.wallClock)
    }

    // MARK: - An audition is a sample over a pause, never playback

    /// The live-session marker, read without taking it.
    private func liveSession(_ rig: PlaybackTestRig) -> LiveSession? {
        rig.defaults.data(forKey: PlaybackStopStore.liveSessionKey)
            .flatMap { try? JSONDecoder().decode(LiveSession.self, from: $0) }
    }

    /// Paused at `sentence` by a headphone loss (a recorded stop), then a
    /// voice pick: the audition is speaking (`.buffering` at once, so no audio
    /// engine is needed) and the stop is still recorded.
    private func auditioningAfterAStop(sentences: Int = 40, at sentence: Int = 10) -> PlaybackTestRig {
        let rig = makeRig(sentences: sentences)
        rig.loadDefault(at: sentence)
        rig.controller.play()
        rig.controller.stop(because: .headphonesDisconnected)
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the audition speaks")
        XCTAssertEqual(rig.controller.stopped?.reason, .headphonesDisconnected, "a voice sample isn't Play")
        XCTAssertNil(liveSession(rig), "an audition is not a session")
        return rig
    }

    func testATapDuringAnAuditionIsAPlayThatClearsTheStop() {
        let rig = auditioningAfterAStop()
        let playActions = rig.controller.userPlayAction

        rig.controller.jump(to: 12, origin: .sentence)

        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.currentSentence, 12)
        XCTAssertNil(rig.controller.stopped, "the book plays on, so the stop is over")
        XCTAssertNil(rig.stopStore.load(), "and no relaunch brings it back")
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1, "a start from the listener's pause")
        XCTAssertEqual(liveSession(rig)?.sentenceIndex, 12)
    }

    /// The sample hasn't been heard yet (still buffering): Play is an
    /// ordinary start from the cue, and the stop is over.
    func testPlayBeforeAnAuditionIsHeardStartsTheBookAndClearsTheStop() {
        let rig = auditioningAfterAStop()
        let playActions = rig.controller.userPlayAction

        rig.controller.play()

        XCTAssertTrue(rig.controller.isListenerPlaying, "the book, not a sample, is playing")
        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1)
        XCTAssertEqual(liveSession(rig)?.sentenceIndex, 10)
    }

    /// Like any start, the first clip comes up over the resume fade (R20),
    /// never at full level out of the pause's silence.
    func testPlayBeforeAnAuditionIsHeardFadesIn() async throws {
        let rig = makeRig(sentences: 8, clipDuration: 1)
        rig.loadDefault(at: 1)
        let mark = rig.statuses.count
        let edgeMark = rig.edges.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertEqual(rig.controller.status, .buffering, "the sample isn't heard yet")

        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let settled = await rig.waitUntil(1) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(settled)

        // (The graph's first connection re-asserts the level before it.)
        let levels = rig.volumes(from: edgeMark).map(\.value)
        let silent = try XCTUnwrap(levels.lastIndex(of: 0), "starts silent: \(levels)")
        let fade = Array(levels[silent...])
        XCTAssertGreaterThanOrEqual(fade.count, 3, "ramps up in steps: \(levels)")
        XCTAssertEqual(fade.last, 1)
        XCTAssertTrue(zip(fade, fade.dropFirst()).allSatisfy { $0 <= $1 }, "\(fade)")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Heard already: the sample carries on as the book, with no flush, and
    /// the look-ahead the audition held back is filled.
    func testPlayDuringAnAuditionReadsOnPastTheAuditionedSentence() async throws {
        let rig = makeRig(sentences: 8, clipDuration: 0.5)
        rig.loadDefault(at: 1)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let eventMark = rig.events.count

        rig.controller.play()

        let past = await rig.waitUntil(8) { rig.controller.currentSentence > 2 }
        XCTAssertTrue(past, "the look-ahead the audition held back is filled")
        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertFalse(rig.events[eventMark...].contains(.stopped), "no restart: the sample goes on as the book")
    }

    /// From the end, Play starts the book over (as it does with no sample
    /// speaking), never reads out the rest of the last sentence and ends.
    func testPlayDuringAnAuditionFromTheEndStartsOver() async throws {
        let rig = makeRig(sentences: 4, clipDuration: 0.25)
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the sample speaks over the end")
        let playActions = rig.controller.userPlayAction

        rig.controller.play()

        XCTAssertEqual(rig.controller.currentSentence, 0, "Play from the end restarts")
        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1)
        XCTAssertEqual(liveSession(rig)?.sentenceIndex, 0)
        let readOn = await rig.waitUntil(5) { rig.controller.currentSentence > 0 }
        XCTAssertTrue(readOn, "and reads on from the start")
    }

    /// A long break before the sample still rewinds on Play, exactly as it
    /// would have a moment later, once the sample had ended.
    func testPlayDuringAnAuditionAfterALongBreakRewindsLikeAnyResume() {
        let rig = makeRig(sentences: 40)
        rig.loadDefault(at: 10)
        rig.controller.play()
        rig.controller.pause()
        // Ten minutes of rest: two sentences back.
        rig.controller.resumeAnchor = ResumeAnchor(documentID: rig.document.id, sentenceIndex: 10,
                                                   wallClock: Date().addingTimeInterval(-600),
                                                   monotonic: MonotonicClock.now - 600)
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the sample speaks")
        let playActions = rig.controller.userPlayAction

        rig.controller.play()

        XCTAssertEqual(rig.controller.currentSentence, 8)
        XCTAssertEqual(rig.controller.notice, .backedUp(sentences: 2))
        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertNil(rig.controller.resumeAnchor, "the rewind applies once")
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1)
    }

    /// Opening the book whose sample is speaking over its pause plays on
    /// (R4), the same as opening it once the sample has ended.
    func testOpeningTheBookDuringAnAuditionPlaysOn() {
        let rig = makeRig(sentences: 12)
        rig.loadDefault(at: 2)
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the sample speaks")
        XCTAssertTrue(rig.controller.opensPlaying(rig.document), "a sample isn't the book speaking")
        let playActions = rig.controller.userPlayAction

        rig.controller.startAutoplay()

        XCTAssertTrue(rig.controller.isListenerPlaying)
        XCTAssertEqual(rig.controller.currentSentence, 2)
        XCTAssertEqual(rig.controller.userPlayAction, playActions + 1)
    }

    /// The audition held its look-ahead back, so after Play the next clip
    /// can land after the sample has ended, with the node playing silence.
    /// That clip starts at the playhead, not where the sample ended: read
    /// from the sample's end, a Back 15 s right after it would see more
    /// than 3 s heard (R14), the sleep timer would aim short (R19) and the
    /// word tint would run ahead.
    func testALateClipAfterAnAuditionStartsAtThePlayhead() async throws {
        let late = LateEngine(voices: [PlaybackTestRig.voiceB], lateFrom: 2, delay: 1.5, clipDuration: 0.5)
        let rig = PlaybackTestRig(sentences: 6, clipDuration: 0.5,
                                  extraRoutes: [PlaybackTestRig.voiceB.id: late])
        rig.loadDefault(at: 1)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)

        // The playhead as sentence 2 is handed to the node, and what a skip
        // would read right after.
        let probe = LateClipProbe()
        let record = rig.controller.onAudioScheduleEvent
        rig.controller.onAudioScheduleEvent = { [weak controller = rig.controller] event in
            record?(event)
            guard case .scheduled(2, _) = event, probe.playhead == nil, let controller else { return }
            probe.playhead = controller.playerMediaSeconds ?? -1
            Task { @MainActor [weak controller] in probe.elapsed = controller?.currentSentenceElapsed }
        }

        rig.controller.play()
        let queued = await rig.waitUntil(5) { probe.elapsed != nil }
        XCTAssertTrue(queued, "sentence 2 reached the node")
        let playhead = try XCTUnwrap(probe.playhead)
        if playhead < 0 { throw XCTSkip("The player node reports no playhead in this test host") }
        XCTAssertGreaterThan(playhead, 1, "the queue ran dry: sentence 1 ended at 0.5 s")

        let clip = try XCTUnwrap(rig.controller.wordTiming.clip(for: 2))
        XCTAssertGreaterThanOrEqual(clip.start, playhead - 0.001, "the clip can't start behind the playhead")
        let elapsed = try XCTUnwrap(probe.elapsed)
        XCTAssertLessThan(elapsed, 0.4, "just queued, almost none of it has been heard")
    }

    /// The timeline rule on its own (no audio engine): a clip queued after
    /// the playhead ran past the end of the queue starts at the playhead, and
    /// later clips line up behind it; a playhead still inside the queue
    /// changes nothing.
    func testAClipQueuedAfterTheQueueRanDryStartsAtThePlayhead() {
        let timing = WordKaraokeState()
        timing.appendScheduled(sentence: 1, duration: 0.5, windows: [])
        timing.appendScheduled(sentence: 2, duration: 0.5, windows: [], playhead: 1.6)   // dry since 0.5
        timing.appendScheduled(sentence: 3, duration: 0.5, windows: [], playhead: 1.7)   // ahead again

        XCTAssertEqual(timing.clip(for: 1)?.start, 0)
        XCTAssertEqual(timing.clip(for: 2)?.start ?? -1, 1.6, accuracy: 1e-9)
        XCTAssertEqual(timing.clip(for: 3)?.start ?? -1, 2.1, accuracy: 1e-9)
    }

    func testPicksAndSkipsDuringAnAuditionKeepTheListenersPause() {
        typealias Move = (name: String, landsOn: Int, run: (PlaybackController) -> Void)
        let moves: [Move] = [
            ("a Contents row", 20, { $0.jump(to: 20, origin: .chapter) }),
            ("a search result", 20, { $0.jump(to: 20, origin: .searchResult) }),
            ("a scrub release", 20, { $0.jump(to: 20, origin: .scrub) }),
            // 3-word sentences at 165 wpm: 15 s is 41.25 words, 14 sentences.
            ("the skip button", 24, { $0.skip(seconds: PlaybackController.skipInterval) }),
            ("a lock-screen skip", 24, { _ = NowPlayingManager.perform(.skipForward, on: $0) }),
            ("a seek", 20, { $0.seek(to: 20, andPlay: false) }),
        ]
        for move in moves {
            let rig = auditioningAfterAStop()
            let playActions = rig.controller.userPlayAction

            move.run(rig.controller)

            XCTAssertEqual(rig.controller.status, .paused, "\(move.name) keeps the pause the sample was over")
            XCTAssertEqual(rig.controller.currentSentence, move.landsOn, move.name)
            XCTAssertEqual(rig.controller.stopped?.reason, .headphonesDisconnected, "\(move.name) isn't Play")
            XCTAssertNil(liveSession(rig), move.name)
            XCTAssertEqual(rig.controller.userPlayAction, playActions, move.name)
        }
    }

    func testUndoingAJumpMadeDuringAnAuditionReturnsToThePause() {
        let rig = auditioningAfterAStop()

        rig.controller.jump(to: 20, origin: .sentence)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.undoableJump?.fromStatus, .paused, "the listener was paused, not playing")

        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 10)
    }
}
