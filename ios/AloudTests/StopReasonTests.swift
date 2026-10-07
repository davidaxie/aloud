import XCTest
@testable import Aloud

/// R11's honest stops: every stop the listener didn't start records a reason
/// that persists (across launches) until the next Play, is announced once
/// when VoiceOver can hear it, and costs one tap to resume. Every change they
/// didn't ask for is a notice while audio continues.
///
/// All silent: muted rigs on their own defaults suites; route loss and
/// interruptions are driven through the rig's fake output monitor's
/// callbacks, never the global notifications. A test whose audio engine can't start in
/// the host is skipped, not failed.
@MainActor
final class StopReasonTests: XCTestCase {

    // MARK: - Harness

    private func playingRig(sentences: Int = 40,
                            at sentence: Int = 0,
                            clipDuration: TimeInterval = 0.5) async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration)
        rig.loadDefault(at: sentence)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
        return rig
    }

    /// The live-session marker, read without taking it.
    private func liveSession(_ rig: PlaybackTestRig) -> LiveSession? {
        rig.defaults.data(forKey: PlaybackStopStore.liveSessionKey)
            .flatMap { try? JSONDecoder().decode(LiveSession.self, from: $0) }
    }

    /// The next launch: a new controller over the rig's anchor and stop stores.
    private func relaunch(_ rig: PlaybackTestRig) -> PlaybackController {
        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let controller = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlaybackTestRig.FakeAudioOutput(),
                                            anchorStore: rig.anchorStore,
                                            stopStore: rig.stopStore,
                                            outputMuted: true)
        controller.isAppActive = { true }
        return controller
    }

    private func stop(_ reason: StopReason, _ rig: PlaybackTestRig) -> PlaybackStop {
        PlaybackStop(reason: reason, documentID: rig.document.id)
    }

    // MARK: - Headphones

    func testHeadphonesDisconnectedStopsRecordsAndAnnouncesOnce() async throws {
        let rig = try await playingRig()
        let cue = rig.controller.currentSentence

        rig.audioSession.onRouteRequiresPause?()

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, cue)
        XCTAssertEqual(rig.controller.stopped, stop(.headphonesDisconnected, rig))
        XCTAssertEqual(rig.stopStore.load(), stop(.headphonesDisconnected, rig), "persisted")
        XCTAssertEqual(rig.controller.stopReason(for: rig.document.id), .headphonesDisconnected)
        XCTAssertNil(rig.controller.stopReason(for: UUID()), "the reason belongs to its book")
        XCTAssertEqual(rig.announcements, ["Paused, headphones disconnected"])

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.controller.currentSentence, cue, "nothing advances after the cut")
        XCTAssertEqual(rig.announcements.count, 1)

        rig.controller.play()
        XCTAssertTrue(rig.controller.isActive, "one tap resumes")
        XCTAssertEqual(rig.controller.currentSentence, cue)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load(), "the stored copy goes with it")
        XCTAssertEqual(rig.announcements.count, 1)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testRouteLossWhilePausedRecordsNothing() {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 3)

        rig.audioSession.onRouteRequiresPause?()

        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())
        XCTAssertEqual(rig.announcements, [])
        XCTAssertEqual(rig.controller.status, .paused)
    }

    func testAStopFromBufferingCuesAndRecords() {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 4)
        rig.controller.play()
        XCTAssertEqual(rig.controller.status, .buffering)

        rig.controller.stop(because: .headphonesDisconnected)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 4)
        XCTAssertEqual(rig.controller.stopped, stop(.headphonesDisconnected, rig))
        XCTAssertEqual(rig.announcements, ["Paused, headphones disconnected"])
    }

    // MARK: - Interruptions

    func testAnInterruptionThatNeverResumesIsAnnouncedAtItsEnd() async throws {
        let rig = try await playingRig()

        rig.audioSession.onInterruption?(.began)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped, stop(.interrupted, rig))
        XCTAssertEqual(rig.announcements, [], "the audio may still come back")

        rig.audioSession.onInterruption?(.ended(shouldResume: false))
        XCTAssertEqual(rig.announcements, ["Paused by a call or another app"])
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped, stop(.interrupted, rig), "it waits for Play")

        rig.audioSession.onInterruption?(.ended(shouldResume: false))
        XCTAssertEqual(rig.announcements.count, 1, "announced once")
    }

    func testAnInterruptionThatResumesLeavesNoReason() async throws {
        let rig = try await playingRig()

        rig.audioSession.onInterruption?(.began)
        rig.audioSession.onInterruption?(.ended(shouldResume: true))

        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())
        XCTAssertEqual(rig.announcements, [])
        XCTAssertEqual(rig.controller.userPlayAction, 1, "auto-resume is not a user play")
    }

    /// Paused by an interruption whose end hasn't come (another app kept the
    /// audio). `.buffering` is active, so no audio engine is needed.
    private func interruptedRig() -> PlaybackTestRig {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 3)
        rig.controller.play()
        rig.audioSession.onInterruption?(.began)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped, stop(.interrupted, rig))
        return rig
    }

    func testAnInterruptionsEndResumesOnlyThePlaybackItStopped() {
        let untouched = interruptedRig()
        untouched.audioSession.onInterruption?(.ended(shouldResume: true))
        XCTAssertTrue(untouched.controller.isActive, "left alone, its own stop comes back")

        let other = PlaybackTestRig.makeDocument(hash: "other", sentences: 12)
        let otherContent = PlaybackTestRig.makeContent(hash: "other", count: 12)
        let moves: [(name: String, run: (PlaybackTestRig) -> Void)] = [
            ("Play, then pause for the night", { $0.controller.play(); $0.controller.pause() }),
            ("a pause", { $0.controller.pause() }),
            ("a paused seek", { $0.controller.seek(to: 6, andPlay: false) }),
            ("a skip", { $0.controller.skip(seconds: PlaybackController.skipInterval) }),
            ("opening another book", { $0.controller.load(document: other, content: otherContent) }),
            ("headphones unplugged meanwhile", { $0.audioSession.onRouteRequiresPause?() }),
            ("a second interruption that stopped nothing", { $0.audioSession.onInterruption?(.began) }),
        ]
        for move in moves {
            let rig = interruptedRig()
            move.run(rig)

            rig.audioSession.onInterruption?(.ended(shouldResume: true))

            XCTAssertFalse(rig.controller.isActive, "after \(move.name), the end starts nothing")
        }
    }

    /// Undo back to a Finished book is the listener's move too: the book
    /// stays at its end, never restarting from sentence 0 on its own when
    /// the interruption that stopped the jumped-to playback ends.
    func testUndoingBackToTheEndLeavesTheInterruptionNothingToResume() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.1)
        rig.loadDefault(at: 11)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil { rig.controller.status == .ended }
        XCTAssertTrue(ended)

        rig.controller.jump(to: 2, origin: .chapter)   // a Contents pick from the end
        XCTAssertEqual(rig.controller.undoableJump?.fromStatus, .ended)
        rig.controller.play()
        rig.audioSession.onInterruption?(.began)
        XCTAssertEqual(rig.controller.stopped, stop(.interrupted, rig))
        rig.controller.undoJump()
        XCTAssertEqual(rig.controller.status, .ended)

        rig.audioSession.onInterruption?(.ended(shouldResume: true))

        XCTAssertEqual(rig.controller.status, .ended, "the end starts nothing")
        XCTAssertEqual(rig.controller.currentSentence, 11)
    }

    // MARK: - Announcements

    func testTheAnnouncementWaitsForTheForeground() async throws {
        let rig = try await playingRig()
        rig.appActive = false

        rig.audioSession.onRouteRequiresPause?()
        XCTAssertEqual(rig.announcements, [], "VoiceOver can't hear it in the background")
        XCTAssertEqual(rig.controller.stopped, stop(.headphonesDisconnected, rig))

        rig.appActive = true
        rig.controller.sceneDidBecomeActive()
        XCTAssertEqual(rig.announcements, ["Paused, headphones disconnected"])

        rig.controller.sceneDidBecomeActive()
        XCTAssertEqual(rig.announcements.count, 1)
    }

    func testADiscardedStopIsNeverAnnounced() async throws {
        let rig = try await playingRig()
        rig.appActive = false
        rig.audioSession.onRouteRequiresPause?()

        rig.controller.discardStop(for: UUID())
        XCTAssertNotNil(rig.controller.stopped, "another book's discard leaves it")

        rig.controller.discardStop(for: rig.document.id)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())

        rig.appActive = true
        rig.controller.sceneDidBecomeActive()
        XCTAssertEqual(rig.announcements, [])
    }

    func testUnloadingTheBookDiscardsItsStop() {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 2)
        rig.controller.play()
        rig.controller.stop(because: .sleepTimer)
        XCTAssertNotNil(rig.controller.stopped)

        rig.controller.unload()
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())
    }

    // MARK: - Errors and notices

    func testAPlaybackErrorRecordsAndAnnounces() async {
        let rig = PlaybackTestRig(sentences: 12, failing: { _ in true })
        rig.loadDefault()
        rig.controller.play()

        let errored = await rig.waitUntil(5) { rig.controller.status == .error }
        XCTAssertTrue(errored)
        XCTAssertEqual(rig.controller.stopped, stop(.playbackError, rig))
        XCTAssertEqual(rig.stopStore.load(), stop(.playbackError, rig))
        #if os(iOS)
        let spoken = "Playback stopped, tap to try again"
        #else
        let spoken = "Playback stopped"
        #endif
        XCTAssertEqual(rig.announcements.filter { $0 == spoken }.count, 1)
    }

    /// A voice that fails every sentence while `isOn`: HonestStopsUITest's
    /// `synthesis` fault, switched by hand.
    private final class FaultSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isOn: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
        }
    }

    /// A voice that stops reading mid-book fails its look-ahead first, each
    /// sentence skipped as one bad one, and errors on the third. They were
    /// never bad: the stop hands them back and waits on the first sentence
    /// not heard, and Try again reads it, never a beat of silence past it
    /// (the UI test saw "Resumed at 6, stopped at 4" while they stayed
    /// skipped).
    func testTryAgainAfterASynthesisFailureReadsOnFromTheSentenceNotHeard() async throws {
        let fault = FaultSwitch()
        let rig = PlaybackTestRig(sentences: 40, failing: { _ in fault.isOn })
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let underway = await rig.waitUntil(5) { rig.controller.currentSentence >= 2 }
        XCTAssertTrue(underway, "the look-ahead is full before the voice fails")

        fault.isOn = true
        let errored = await rig.waitUntil(10) { rig.controller.status == .error }
        XCTAssertTrue(errored)
        XCTAssertEqual(rig.controller.stopped, stop(.playbackError, rig))
        XCTAssertEqual(rig.controller.skippedSentences, [], "the voice failed, not the sentences")
        let stoppedAt = rig.controller.currentSentence
        let read = rig.engineA.requestedTexts
        XCTAssertTrue((0..<stoppedAt).allSatisfy { index in read.contains { $0.hasPrefix("Line\(index) ") } },
                      "every sentence before the stop was read")
        // The stop waits on the first sentence not heard. The look-ahead
        // the voice read before it failed (deep on a Mac) is still to come:
        // Try again reads it from the clip cache, then asks for the rest.

        fault.isOn = false
        let mark = rig.statuses.count
        let eventMark = rig.events.count
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, stoppedAt, "one tap, at the same sentence")
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let scheduled = { () -> [Int] in
            rig.events[eventMark...].compactMap {
                if case .scheduled(let sentence, _) = $0 { return sentence }
                return nil
            }
        }
        let reading = await rig.waitUntil(5) { !scheduled().isEmpty }
        XCTAssertTrue(reading)
        XCTAssertEqual(scheduled().first, stoppedAt,
                       "Try again reads sentence \(stoppedAt) first, never a beat past it")
        XCTAssertEqual(rig.controller.skippedSentences, [])
    }

    func testASkippedSentenceIsANoticeWhileStillPlaying() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.25, failing: { $0.hasPrefix("Line3 ") })
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let noticed = await rig.waitUntil(5) { rig.controller.notice == .skippedSentence }
        XCTAssertTrue(noticed)
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.skippedSentences, [3])
        XCTAssertEqual(rig.announcements, ["Skipped a sentence the voice couldn't read"])
        XCTAssertNil(rig.controller.stopped, "a notice is not a stop")
    }

    /// A sentence one voice couldn't read is that voice's failure: picked
    /// instead, another voice reads it from any way back to it (Back, a
    /// chapter pick), not only from a tap on that sentence.
    func testAnotherVoiceReadsASentenceTheFirstSkipped() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.25, failing: { $0.hasPrefix("Line3 ") })
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let skipped = await rig.waitUntil(5) { rig.controller.skippedSentences == [3] }
        XCTAssertTrue(skipped)
        rig.controller.pause()

        rig.controller.voice = PlaybackTestRig.voiceB
        XCTAssertEqual(rig.controller.skippedSentences, [], "Bravo never failed on it")

        rig.controller.seek(to: 1, andPlay: true)   // lands before it, as Back would
        let read = await rig.waitUntil(5) { rig.requestedSentences(rig.engineB).contains(3) }
        XCTAssertTrue(read, "Bravo reads sentence 3 on its way past: \(rig.requestedSentences(rig.engineB))")
        rig.controller.pause()
    }

    /// The same for a switch that lands at a sentence boundary (R5's
    /// install switch, heat's): the voice it replaces takes its skips along.
    func testASkipGoesWithTheVoiceASwitchReplaces() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.25, failing: { $0.hasPrefix("Line3 ") })
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let skipped = await rig.waitUntil(5) { rig.controller.skippedSentences == [3] }
        XCTAssertTrue(skipped)

        rig.controller.switchVoiceAtSentenceBoundary(to: PlaybackTestRig.voiceB)
        let landed = await rig.waitUntil(5) { rig.controller.voice == PlaybackTestRig.voiceB }
        XCTAssertTrue(landed)
        XCTAssertEqual(rig.controller.skippedSentences, [], "Bravo never failed on it")
        rig.controller.pause()
    }

    /// Refuses one sentence as a full prefetch lane does
    /// (`SynthesisSchedulerError.backlogFull`), `times` times, then reads it.
    private final class RefusingEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let base: any TtsEngine
        private let prefix: String
        private let lock = NSLock()
        private var left: Int
        private var count = 0

        init(base: any TtsEngine, refusing prefix: String, times: Int) {
            self.voices = base.voices
            self.base = base
            self.prefix = prefix
            self.left = times
        }

        var refusals: Int { lock.withLock { count } }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await synthesize(text, voice: voice, speed: 1.0)
        }

        func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
            let refuses = lock.withLock { () -> Bool in
                guard text.hasPrefix(prefix), left > 0 else { return false }
                left -= 1
                count += 1
                return true
            }
            if refuses { throw SynthesisSchedulerError.backlogFull }
            return try await base.synthesize(text, voice: voice, speed: speed)
        }
    }

    /// F016: a full prefetch lane is "not now". The refused sentence is
    /// asked for again and read, never skipped with a notice, and three
    /// refusals in a row are no failing voice.
    func testAFullPrefetchLaneNeverSkipsASentence() async throws {
        let base = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA], clipDuration: 0.25)
        let refusing = RefusingEngine(base: base, refusing: "Line3 ", times: 3)
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.25,
                                  extraRoutes: [PlaybackTestRig.voiceA.id: refusing])
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let past = await rig.waitUntil(10) { rig.controller.currentSentence >= 5 }
        XCTAssertTrue(past, "reading went on past the refused sentence")
        XCTAssertEqual(refusing.refusals, 3)
        XCTAssertTrue(base.requestedTexts.contains { $0.hasPrefix("Line3 ") }, "sentence 3 was read after all")
        XCTAssertEqual(rig.controller.skippedSentences, [])
        XCTAssertNotEqual(rig.controller.notice, .skippedSentence)
        XCTAssertEqual(rig.announcements, [], "nothing to say: nothing was skipped")
        XCTAssertNil(rig.controller.stopped)
    }

    func testARepeatedNoticeIsAnnouncedOnce() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.25,
                                  failing: { $0.hasPrefix("Line3 ") || $0.hasPrefix("Line5 ") })
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let both = await rig.waitUntil(5) { rig.controller.skippedSentences == [3, 5] }
        XCTAssertTrue(both)
        XCTAssertEqual(rig.controller.notice, .skippedSentence)
        XCTAssertEqual(rig.announcements, ["Skipped a sentence the voice couldn't read"],
                       "the notice already showing only restarts its clock")
    }

    // MARK: - Auditions

    func testAnAuditionNeverClearsAStop() async throws {
        let rig = try await playingRig(sentences: 12, clipDuration: 0.25)
        rig.audioSession.onRouteRequiresPause?()
        XCTAssertNotNil(rig.controller.stopped)

        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(rig.controller.stopped, stop(.headphonesDisconnected, rig), "a voice sample isn't Play")

        let back = await rig.waitUntil {
            rig.statuses[mark...].contains(.playing) && rig.statuses.last == .paused
        }
        XCTAssertTrue(back)
        XCTAssertEqual(rig.controller.stopped, stop(.headphonesDisconnected, rig))
        XCTAssertEqual(rig.stopStore.load(), stop(.headphonesDisconnected, rig))
    }

    func testAStopDuringAnAuditionRecordsNothing() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 1)
        rig.loadDefault(at: 2)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)

        rig.audioSession.onRouteRequiresPause?()

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(rig.announcements, [])
    }

    // MARK: - Across launches

    func testAStopSurvivesARelaunchAndClearsOnPlay() async throws {
        let rig = try await playingRig()
        rig.audioSession.onRouteRequiresPause?()

        let next = relaunch(rig)
        XCTAssertEqual(next.stopped, stop(.headphonesDisconnected, rig))
        XCTAssertEqual(next.stopReason(for: rig.document.id), .headphonesDisconnected)

        next.load(document: rig.document, content: rig.content)
        next.play()
        XCTAssertTrue(next.isActive)
        XCTAssertNil(next.stopped)
        XCTAssertNil(rig.stopStore.load())
        next.pause(rampsOut: false)
    }

    func testTheLiveMarkerFollowsActivePlayback() {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 3)
        XCTAssertNil(liveSession(rig))

        rig.controller.play()   // buffering: playback is intended
        XCTAssertEqual(liveSession(rig)?.documentID, rig.document.id)
        XCTAssertEqual(liveSession(rig)?.sentenceIndex, 3)

        rig.controller.seek(to: 6, andPlay: true)
        XCTAssertEqual(liveSession(rig)?.sentenceIndex, 6, "the marker follows the playhead")

        rig.controller.pause()
        XCTAssertNil(liveSession(rig), "an orderly stop clears it")

        rig.controller.play()
        XCTAssertNotNil(liveSession(rig))
        rig.controller.resumeAnchor = nil
        rig.anchorStore.clear()

        rig.controller.applicationWillTerminate()
        XCTAssertNil(liveSession(rig), "so does an orderly exit")
        XCTAssertEqual(rig.anchorStore.load()?.documentID, rig.document.id, "and the rest is anchored")
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, 6)
    }

    func testClosedByIOSIsReportedOnTheNextLaunch() {
        let rig = PlaybackTestRig()
        rig.stopStore.markLive(LiveSession(documentID: rig.document.id, sentenceIndex: 7,
                                           wallClock: Date(timeIntervalSinceNow: -600)))

        let next = relaunch(rig)
        var spoken: [String] = []
        next.announce = { spoken.append($0) }

        XCTAssertEqual(next.stopped, stop(.closedByIOS, rig))
        XCTAssertEqual(rig.stopStore.load(), stop(.closedByIOS, rig))
        XCTAssertNil(liveSession(rig), "the marker is reported once")
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, 7, "the rest starts where it was speaking")
        XCTAssertNil(rig.anchorStore.load()?.monotonic)
        XCTAssertEqual(spoken, [])

        next.sceneDidBecomeActive()
        #if os(iOS)
        XCTAssertEqual(spoken, ["Stopped when iOS closed Aloud"])
        #else
        XCTAssertEqual(spoken, ["Stopped when Aloud quit unexpectedly"])
        #endif
        next.sceneDidBecomeActive()
        XCTAssertEqual(spoken.count, 1)

        var document = rig.document
        document.progressSentence = 7
        next.load(document: document, content: rig.content)
        next.play()
        XCTAssertEqual(next.currentSentence, 5, "a 10-minute rest backs up 2")
        XCTAssertEqual(next.notice, .backedUp(sentences: 2))
        XCTAssertNil(next.stopped)
        next.pause(rampsOut: false)
    }
}
