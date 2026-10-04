import XCTest
@testable import Aloud

/// R20's audio edges and the volume primitive R19 shares: a user pause
/// publishes `.paused` at once and ramps out over 120 ms before the node
/// pauses; a resume ramps back in; autoplay fades in over 300 ms; unattended
/// stops cut at once; a sleep fade survives a restart.
///
/// Observed through the `onAudioEdge` seam (requested levels, before the
/// mute) while the mixer itself stays at 0 in every test: the controllers
/// are muted. A test whose audio engine can't start in the host is skipped.
@MainActor
final class AudioEdgeTests: XCTestCase {

    // MARK: - Pure

    func testRampLevelIsLinearAndClamped() {
        XCTAssertEqual(VolumeRamp.level(from: 1, to: 0, progress: 0), 1)
        XCTAssertEqual(VolumeRamp.level(from: 1, to: 0, progress: 0.25), 0.75, accuracy: 1e-6)
        XCTAssertEqual(VolumeRamp.level(from: 0, to: 1, progress: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VolumeRamp.level(from: 0.3, to: 1, progress: 1), 1, "the end is exact")
        XCTAssertEqual(VolumeRamp.level(from: 1, to: 0, progress: -1), 1)
        XCTAssertEqual(VolumeRamp.level(from: 1, to: 0, progress: 2), 0)
    }

    func testStepInterval() {
        XCTAssertEqual(VolumeRamp.stepInterval(for: 0.12), 0.01)
        XCTAssertEqual(VolumeRamp.stepInterval(for: 1), 0.01)
        XCTAssertEqual(VolumeRamp.stepInterval(for: 1.5), 0.05)
        XCTAssertEqual(VolumeRamp.stepInterval(for: 15), 0.05)
    }

    func testEdgeDurations() {
        XCTAssertEqual(AudioEdge.pauseRamp, 0.12)
        XCTAssertEqual(AudioEdge.resumeRamp, 0.12)
        XCTAssertEqual(AudioEdge.autoplayFadeIn, 0.3)
    }

    // MARK: - Harness

    /// Playing, with the start's own fade-in finished (level 1, no ramp).
    private func playingAtFullLevel(sentences: Int = 40,
                                    clipDuration: TimeInterval = 2) async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let settled = await rig.waitUntil(2) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(settled, "the start's fade-in finished")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
        return rig
    }

    private func isNonIncreasing(_ values: [Float]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 >= $1 }
    }

    private func isNonDecreasing(_ values: [Float]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    // MARK: - Pause and resume

    func testAPausePublishesAtOnceThenRampsOutBeforeTheNodePauses() async throws {
        let rig = try await playingAtFullLevel()
        let mark = rig.edges.count
        let tap = MonotonicClock.now

        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .paused, "published at tap time")
        XCTAssertNotNil(rig.controller.resumeAnchor, "the rest is anchored at tap time")
        XCTAssertTrue(rig.nodePauseTimes(from: mark).isEmpty, "the node plays out the ramp")

        let paused = await rig.waitUntil(1) { !rig.nodePauseTimes(from: mark).isEmpty }
        XCTAssertTrue(paused)

        let steps = rig.volumes(from: mark)
        XCTAssertGreaterThanOrEqual(steps.count, 5)
        XCTAssertGreaterThan(steps.first?.value ?? 0, 0.5, "starts from full level")
        XCTAssertEqual(steps.last?.value, 0)
        XCTAssertTrue(isNonIncreasing(steps.map(\.value)), "\(steps.map(\.value))")
        let span = (steps.last?.time ?? tap) - tap
        XCTAssertGreaterThanOrEqual(span, 0.10, "over 120 ms")
        XCTAssertLessThanOrEqual(span, 0.25, "over 120 ms")

        let nodePauses = rig.nodePauseTimes(from: mark)
        XCTAssertEqual(nodePauses.count, 1)
        let lastVolume = try XCTUnwrap(rig.edges.lastIndex { if case .volume = $0.event { return true }; return false })
        let nodePause = try XCTUnwrap(rig.edges.lastIndex { $0.event == .nodePaused })
        XCTAssertGreaterThan(nodePause, lastVolume, "the node pauses after the final 0")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testAResumeRampsBackIn() async throws {
        let rig = try await playingAtFullLevel()
        rig.controller.pause()
        let paused = await rig.waitUntil(1) { !rig.nodePauseTimes().isEmpty }
        XCTAssertTrue(paused)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0)

        let mark = rig.edges.count
        rig.controller.play()
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.edges[mark].event, .nodeResumed)

        let done = await rig.waitUntil(1) { !rig.controller.isRampingVolume }
        XCTAssertTrue(done)
        let steps = rig.volumes(from: mark)
        XCTAssertGreaterThanOrEqual(steps.count, 5)
        XCTAssertLessThan(steps.first?.value ?? 1, 0.5, "starts from silence")
        XCTAssertEqual(steps.last?.value, 1)
        XCTAssertTrue(isNonDecreasing(steps.map(\.value)))
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testPlayDuringThePauseRampTurnsAround() async throws {
        let rig = try await playingAtFullLevel()
        let sentence = rig.controller.currentSentence
        let edgeMark = rig.edges.count
        let eventMark = rig.events.count

        rig.controller.pause()
        _ = await rig.waitUntil(1) { !rig.volumes(from: edgeMark).isEmpty }
        if !rig.nodePauseTimes(from: edgeMark).isEmpty {
            throw XCTSkip("the main actor was too busy to land inside the 120 ms ramp")
        }
        rig.controller.play()

        XCTAssertEqual(rig.controller.status, .playing)
        let done = await rig.waitUntil(1) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(done)
        XCTAssertTrue(rig.nodePauseTimes(from: edgeMark).isEmpty, "the node never paused")
        XCTAssertFalse(rig.events[eventMark...].contains(.stopped), "nothing was flushed")
        XCTAssertEqual(rig.controller.currentSentence, sentence)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testAutoplayFadesInOver300Milliseconds() async throws {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 2)
        rig.loadDefault()

        rig.controller.startAutoplay()
        try await rig.waitUntilPlayingOrSkip()
        let done = await rig.waitUntil(2) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(done)

        let volumes = rig.volumes()
        let silent = try XCTUnwrap(volumes.lastIndex { $0.value == 0 }, "starts silent")
        let fade = Array(volumes[silent...])
        XCTAssertGreaterThanOrEqual(fade.count - 1, 10)
        XCTAssertEqual(fade.last?.value, 1)
        XCTAssertTrue(isNonDecreasing(fade.map(\.value)))
        let span = (fade.last?.time ?? 0) - (fade.first?.time ?? 0)
        XCTAssertGreaterThanOrEqual(span, 0.28)
        XCTAssertLessThanOrEqual(span, 0.45)
        XCTAssertEqual(rig.controller.userPlayAction, 1)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Unattended stops

    func testRouteLossAndInterruptionCutAtOnce() async throws {
        for cause in ["route", "interruption"] {
            let rig = try await playingAtFullLevel()
            let mark = rig.edges.count

            if cause == "route" {
                rig.audioSession.onRouteRequiresPause?()
            } else {
                rig.audioSession.onInterruption?(.began)
            }

            XCTAssertEqual(rig.nodePauseTimes(from: mark).count, 1, "\(cause): paused at once")
            XCTAssertEqual(rig.controller.requestedOutputVolume, 0, cause)
            XCTAssertFalse(rig.controller.isRampingVolume, cause)

            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(rig.volumes(from: mark).allSatisfy { $0.value == 0 }, "\(cause): no ramp after the cut")
            XCTAssertEqual(rig.nodePauseTimes(from: mark).count, 1, cause)
            XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
        }
    }

    // MARK: - Inside the ramp

    func testABoundaryInsideTheRampAdvancesAndReanchors() async throws {
        let rig = try await playingAtFullLevel(sentences: 200, clipDuration: 0.05)
        let mark = rig.edges.count
        let pausedAt = rig.controller.currentSentence

        rig.controller.pause()
        XCTAssertEqual(rig.controller.resumeAnchor?.sentenceIndex, pausedAt)

        let paused = await rig.waitUntil(1) { !rig.nodePauseTimes(from: mark).isEmpty }
        XCTAssertTrue(paused)
        XCTAssertGreaterThan(rig.controller.currentSentence, pausedAt,
                             "50 ms sentences end inside the 120 ms ramp")
        XCTAssertEqual(rig.controller.resumeAnchor?.sentenceIndex, rig.controller.currentSentence)
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, rig.controller.currentSentence)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testASeekDuringTheRampCancelsIt() async throws {
        let rig = try await playingAtFullLevel()
        let mark = rig.edges.count

        rig.controller.pause()
        XCTAssertTrue(rig.controller.isRampingVolume)
        rig.controller.seek(to: 10, andPlay: false)

        XCTAssertFalse(rig.controller.isRampingVolume)
        XCTAssertEqual(rig.nodePauseTimes(from: mark).count, 1, "a cancelled pause still pauses the node")
        let afterSeek = rig.edges.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rig.volumes(from: afterSeek).isEmpty, "no step after the seek")
        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - A clip that lands after the queue ran dry

    /// Sentences before `lateFrom` at once, `earlyDuration` each; the rest
    /// wait until the test opens the gate, then are `lateDuration` each:
    /// synthesis slower than speech, timed by hand.
    private final class GatedEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let lateFrom: Int
        private let earlyDuration: TimeInterval
        private let lateDuration: TimeInterval
        private let lock = NSLock()
        private var isOpen = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        init(voices: [TtsVoice], lateFrom: Int, earlyDuration: TimeInterval, lateDuration: TimeInterval) {
            self.voices = voices
            self.lateFrom = lateFrom
            self.earlyDuration = earlyDuration
            self.lateDuration = lateDuration
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            // "Line<i> word…" (PlaybackTestRig.makeContent).
            let index = text.hasPrefix("Line") ? Int(text.dropFirst(4).prefix { $0.isNumber }) : nil
            guard let index, index >= lateFrom else {
                return .silence(duration: earlyDuration, sampleRate: 22_050)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waits = lock.withLock { () -> Bool in
                    if isOpen { return false }
                    parked.append(continuation)
                    return true
                }
                if !waits { continuation.resume() }
            }
            return .silence(duration: lateDuration, sampleRate: 22_050)
        }

        /// Lets every parked request through, and every later one at once.
        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                let waiting = parked
                parked = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Whether sentence 2 reached the node.
    @MainActor
    private final class LandingProbe {
        var landed = false
    }

    /// Sentences 0 and 1 (0.5 s each) heard and sentence 2 held at the gate,
    /// so the queue ran dry at 1 s and the node plays silence. Returns once
    /// the playhead is past 1.8 s, with a probe on sentence 2's landing.
    private func playingPastADryQueue() async throws -> (rig: PlaybackTestRig, gate: GatedEngine,
                                                         probe: LandingProbe) {
        let gate = GatedEngine(voices: [PlaybackTestRig.voiceA], lateFrom: 2,
                               earlyDuration: 0.5, lateDuration: 3)
        addTeardownBlock { gate.open() }   // never leave a synthesis parked
        let rig = PlaybackTestRig(sentences: 6, extraRoutes: [PlaybackTestRig.voiceA.id: gate])
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let past = await rig.waitUntil(5) { (rig.controller.playerMediaSeconds ?? 0) >= 1.8 }
        if !past { throw XCTSkip("The player node reports no playhead in this test host") }
        XCTAssertEqual(rig.controller.currentSentence, 2, "sentences 0 and 1 have been heard")
        XCTAssertNil(rig.controller.wordTiming.clip(for: 2), "sentence 2 isn't on the node yet")

        let probe = LandingProbe()
        let record = rig.controller.onAudioScheduleEvent
        rig.controller.onAudioScheduleEvent = { [weak controller = rig.controller] event in
            record?(event)
            guard case .scheduled(2, _) = event, !probe.landed, let controller else { return }
            _ = controller
            probe.landed = true
        }
        return (rig, gate, probe)
    }

    /// A pause while the queue is dry (reading waits on sentence 2, the busy
    /// ring up) is a pause from buffering: the wait is dropped, so sentence
    /// 2 never lands on a timeline that ran on in silence, and Play reads it
    /// from its start, a fresh schedule. The dry stretch is never counted
    /// as heard: Back's 3 s rule (R14) and the sleep landing (R19) read
    /// sentence 2's own time.
    func testAPauseWhileTheQueueIsDryDropsTheWaitAndPlayReadsTheSentenceFromItsStart() async throws {
        let (rig, gate, probe) = try await playingPastADryQueue()
        XCTAssertEqual(rig.controller.status, .buffering, "the voice is silent, waiting on sentence 2")

        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .paused)
        gate.open()
        let landed = await rig.waitUntil(0.6) { probe.landed }
        XCTAssertFalse(landed, "a dropped wait never reaches the node")
        XCTAssertEqual(rig.controller.currentSentence, 2, "Play resumes at the sentence reading waited for")

        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: rig.statuses.count)
        let clip = try XCTUnwrap(rig.controller.wordTiming.clip(for: 2))
        let moved = await rig.waitUntil(2) { (rig.controller.playerMediaSeconds ?? 0) >= clip.start + 0.3 }
        XCTAssertTrue(moved, "the node plays sentence 2")
        XCTAssertEqual(rig.controller.currentSentence, 2)
        XCTAssertLessThan(rig.controller.currentSentenceElapsed, 0.7, "a fraction of sentence 2 heard")
        let toEnd = try XCTUnwrap(rig.controller.secondsUntilEnd(ofSentence: 2))
        XCTAssertGreaterThan(toEnd, 2.3, "most of the 3 s clip is still to come")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// An audition is a hard start: full level before it is heard, no ramp,
    /// even though the pause before it left the level at 0.
    func testAHardStartAfterARampedPauseIsAtFullLevel() async throws {
        let rig = try await playingAtFullLevel(sentences: 12, clipDuration: 0.5)
        rig.controller.pause()
        let paused = await rig.waitUntil(1) { !rig.nodePauseTimes().isEmpty }
        XCTAssertTrue(paused)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0)

        let mark = rig.edges.count
        var edgesAtPlaying: Int?
        let subscription = rig.controller.$status.dropFirst().sink { [weak rig] status in
            if status == .playing, edgesAtPlaying == nil { edgesAtPlaying = rig?.edges.count }
        }
        defer { subscription.cancel() }
        let statusMark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: statusMark)

        let atPlaying = try XCTUnwrap(edgesAtPlaying)
        XCTAssertTrue(rig.edges[mark..<atPlaying].contains { $0.event == .volume(1) },
                      "full level before the audition is heard")
        XCTAssertTrue(rig.volumes(from: mark).allSatisfy { $0.value == 1 }, "no ramp")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - The shared primitive

    func testReplacingARampContinuesFromTheCurrentLevel() async throws {
        let rig = try await playingAtFullLevel()
        var firstFinished: Bool?
        rig.controller.rampOutputVolume(to: 0, over: 1) { firstFinished = $0 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let level = rig.controller.requestedOutputVolume
        XCTAssertLessThan(level, 1)
        XCTAssertGreaterThan(level, 0)

        let mark = rig.edges.count
        var secondFinished: Bool?
        rig.controller.rampOutputVolume(to: 1, over: 0.2) { secondFinished = $0 }
        XCTAssertEqual(firstFinished, false, "the replaced ramp completes with false")

        let done = await rig.waitUntil(1) { secondFinished != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(secondFinished, true)
        let steps = rig.volumes(from: mark).map(\.value)
        XCTAssertGreaterThanOrEqual(steps.first ?? 0, level - 0.001, "continues from where the first left off")
        XCTAssertLessThan(steps.first ?? 1, level + 0.25)
        XCTAssertEqual(steps.last, 1)
        XCTAssertTrue(isNonDecreasing(steps))
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testAZeroLengthRampWritesTheTargetAtOnce() async throws {
        let rig = try await playingAtFullLevel()
        var finished: Bool?
        rig.controller.rampOutputVolume(to: 0.4, over: 0) { finished = $0 }
        XCTAssertEqual(finished, true)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0.4)
        XCTAssertFalse(rig.controller.isRampingVolume)
    }

    /// A seek-and-play while playing is a hard restart: a fade in flight
    /// (the sleep timer's) carries on, and full level never comes back.
    func testARestartDuringALongRampKeepsTheFade() async throws {
        let rig = try await playingAtFullLevel(clipDuration: 0.5)
        var finished: Bool?
        rig.controller.rampOutputVolume(to: 0, over: 1) { finished = $0 }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mark = rig.edges.count
        rig.controller.seek(to: 20, andPlay: true)
        XCTAssertTrue(rig.controller.isRampingVolume, "a restart doesn't end a fade")

        let restarted = await rig.waitUntil(2) {
            rig.controller.status == .playing && rig.controller.currentSentence >= 20
        }
        XCTAssertTrue(restarted)
        let ended = await rig.waitUntil(2) { finished != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(finished, true)
        XCTAssertFalse(rig.volumes(from: mark).contains { $0.value == 1 }, "no jump back to full level")
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A fade (the sleep timer's) belongs to the playback it fades: every way
    /// out of active playback ends it, so it can't ride into the next hard
    /// start. Each move starts from a restart still buffering, the one state
    /// whose exits never ran a pause's ramp to replace it.
    func testLeavingActivePlaybackEndsAFade() {
        let other = PlaybackTestRig.makeDocument(hash: "other", sentences: 12)
        let otherContent = PlaybackTestRig.makeContent(hash: "other", count: 12)
        let moves: [(name: String, run: (PlaybackController) -> Void)] = [
            ("a pause", { $0.pause() }),
            ("opening another book", { $0.load(document: other, content: otherContent) }),
            ("closing the book", { $0.unload() }),
        ]
        for move in moves {
            let rig = PlaybackTestRig()
            rig.loadDefault(at: 2)
            rig.controller.play()
            XCTAssertEqual(rig.controller.status, .buffering, move.name)
            var finished: Bool?
            rig.controller.rampOutputVolume(to: 0, over: 15) { finished = $0 }

            move.run(rig.controller)

            XCTAssertFalse(rig.controller.isActive, move.name)
            XCTAssertFalse(rig.controller.isRampingVolume, "\(move.name) ends the fade")
            XCTAssertEqual(finished, false, "\(move.name): the fade completes as cancelled")
        }
    }

    /// The case that bit: paused while a restart buffered mid-fade, then a
    /// voice pick within the fade's time. The audition is a hard start, heard
    /// at full level, never fading out under the dead timer.
    func testAnAuditionAfterAPauseMidFadeIsHeardAtFullLevel() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 1)
        rig.loadDefault(at: 2)
        rig.controller.play()
        rig.controller.rampOutputVolume(to: 0, over: 3)
        rig.controller.pause()
        XCTAssertFalse(rig.controller.isRampingVolume, "the pause ended the fade")

        let mark = rig.statuses.count
        let edgeMark = rig.edges.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(rig.controller.requestedOutputVolume, 1, "nothing pulls the sample down")
        XCTAssertTrue(rig.volumes(from: edgeMark).allSatisfy { $0.value == 1 }, "\(rig.volumes(from: edgeMark).map(\.value))")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Opening

    func testOpensPlayingMatrix() {
        let suppressed = PlaybackTestRig(autoplaySuppressed: true)
        XCTAssertFalse(suppressed.controller.opensPlaying(suppressed.document), "a UI-test launch")

        let rig = PlaybackTestRig()
        let finished = PlaybackTestRig.makeDocument(hash: "done", sentences: 12,
                                                    progressSentence: 11, progressFraction: 1.0)
        XCTAssertFalse(rig.controller.opensPlaying(finished), "a Finished book opens paused")
        XCTAssertTrue(rig.controller.opensPlaying(rig.document), "an unfinished book")

        rig.loadDefault()
        XCTAssertTrue(rig.controller.opensPlaying(rig.document), "loaded but paused")

        rig.controller.play()
        XCTAssertFalse(rig.controller.opensPlaying(rig.document), "the book already speaking continues")
        let other = PlaybackTestRig.makeDocument(hash: "other", sentences: 8)
        XCTAssertTrue(rig.controller.opensPlaying(other), "another book while one plays")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }
}
