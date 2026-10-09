import XCTest
@testable import Aloud

/// How far ahead reading synthesizes, and what it shows when synthesis falls
/// behind anyway. A sentence that ends before the next one's clip is on the
/// node leaves the voice silent: the controller says so with `.buffering`
/// (the busy ring) instead of showing itself reading, and goes back to
/// `.playing` when the clip lands, logging each dry spell for M19.
///
/// Silent: the rig's muted controller over silence-returning engines; the
/// held engine below only delays a reply, it never makes sound.
@MainActor
final class CatchingUpTests: XCTestCase {

    // MARK: - How far ahead

    /// Where a platform has no listening time, a fixed two sentences.
    func testWithoutAListeningTimeItKeepsTwoSentences() {
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: Array(repeating: 100, count: 20),
                                                         rate: 2.95, seconds: nil, range: 2...2), 2)
    }

    /// A Mac keeps about 12 s of listening at the current speed, within
    /// 3...10 sentences: more short lines at a fast speed, fewer long ones.
    func testTheListeningTimeSetsTheCount() {
        let count = { (characters: Int, rate: Double) in
            PlaybackController.lookAheadCount(characterCounts: Array(repeating: characters, count: 30),
                                              rate: rate, seconds: 12, range: 3...10)
        }
        // 100 characters is about 6.0 s at 1x, 2.0 s at 2.95x.
        XCTAssertEqual(count(100, 1), 3, "two lines are 12 s: never fewer than 3")
        XCTAssertEqual(count(100, 2.95), 6, "12 s at 2.95x is six such lines")
        XCTAssertEqual(count(20, 2.95), 10, "short dialogue at 2.95x: capped at 10")
        XCTAssertEqual(count(300, 2.95), 3, "long sentences: three already pass 12 s")
        XCTAssertLessThan(count(100, 1), count(100, 2.95), "a faster speed reaches further")
    }

    /// P009: an iPhone keeps about 10 s of listening within 2...6
    /// sentences, so two short lines of dialogue at 2.5x (under a second of
    /// listening each) no longer run the voice dry.
    func testAnIPhoneKeepsTenSecondsWithinTwoToSix() {
        let count = { (characters: Int, rate: Double) in
            PlaybackController.lookAheadCount(characterCounts: Array(repeating: characters, count: 30),
                                              rate: rate, seconds: 10, range: 2...6)
        }
        // A 20-character line is about 1.9 s at 1x, 0.8 s at 2.5x.
        XCTAssertGreaterThanOrEqual(count(20, 2.5), 4, "dialogue at 2.5x reaches past two lines")
        XCTAssertEqual(count(20, 2.5), 6, "capped at six")
        XCTAssertEqual(count(300, 1), 2, "long sentences at 1x: the floor of two")
        XCTAssertLessThanOrEqual(count(5, 3), 6)
        #if os(iOS)
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadSeconds, 10)
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadSentences, 2...6)
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadUnderStrain, 2, "heat keeps two")
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadSentencesUnderLowPower, 2...4,
                       "Low Power Mode keeps a shorter time-based queue (R4-34)")
        XCTAssertEqual(PlatformPlaybackTuning.coolingSwitchLandsWithin, 3)
        #else
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadSeconds, 12, "the Mac's look-ahead is unchanged")
        XCTAssertEqual(PlatformPlaybackTuning.lookAheadSentences, 3...10)
        XCTAssertNil(PlatformPlaybackTuning.lookAheadUnderStrain)
        XCTAssertNil(PlatformPlaybackTuning.lookAheadSentencesUnderLowPower)
        XCTAssertNil(PlatformPlaybackTuning.coolingSwitchLandsWithin)
        #endif
    }

    /// R4-34: Low Power Mode's 2...4 keeps two short lines of dialogue at
    /// 2.5x from running the voice dry (about 0.8 s each, so four);
    /// long sentences keep the floor of two.
    func testLowPowerModeKeepsAShortTimeBasedQueue() {
        let dialogue = Array(repeating: 20, count: 30)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: dialogue, rate: 2.5, seconds: 10,
                                                         range: 2...4), 4)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: Array(repeating: 300, count: 30),
                                                         rate: 1, seconds: 10, range: 2...4), 2)
        // Heat outranks Low Power Mode: the strained cap, over the whole range.
        let hot = PlaybackController.lookAheadBounds(hot: true, lowPower: true)
        XCTAssertEqual(hot.range, PlatformPlaybackTuning.lookAheadSentences)
        XCTAssertEqual(hot.strainedCap, PlatformPlaybackTuning.lookAheadUnderStrain)
        let lowPower = PlaybackController.lookAheadBounds(hot: false, lowPower: true)
        XCTAssertEqual(lowPower.range,
                       PlatformPlaybackTuning.lookAheadSentencesUnderLowPower ?? PlatformPlaybackTuning.lookAheadSentences)
        XCTAssertNil(lowPower.strainedCap)
        let neither = PlaybackController.lookAheadBounds(hot: false, lowPower: false)
        XCTAssertEqual(neither.range, PlatformPlaybackTuning.lookAheadSentences)
        XCTAssertNil(neither.strainedCap)
    }

    /// Under Low Power Mode or `.serious` heat the platform's cap holds,
    /// however short the lines; no cap leaves the count alone.
    func testStrainCapsTheCount() {
        let dialogue = Array(repeating: 20, count: 30)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: dialogue, rate: 2.5, seconds: 10,
                                                         range: 2...6, strainedCap: 2), 2)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: dialogue, rate: 2.5, seconds: 10,
                                                         range: 2...6, strainedCap: nil), 6)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: dialogue, rate: 2.95, seconds: 12,
                                                         range: 3...10, strainedCap: nil), 10,
                       "a Mac, with no cap, as before")
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: dialogue, rate: 1, seconds: nil,
                                                         range: 2...2, strainedCap: 2), 2)
    }

    /// Near the end of a book the count asks for what's there and no more:
    /// the horizon is clipped to the last sentence by the controller.
    func testNearTheEndItNeverAsksBeyondTheFloor() {
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: [40],
                                                         rate: 2.95, seconds: 12, range: 3...10), 3)
        XCTAssertEqual(PlaybackController.lookAheadCount(characterCounts: [],
                                                         rate: 1, seconds: 12, range: 3...10), 3)
    }

    func testTheEstimateGrowsWithTheSentence() {
        XCTAssertEqual(PlaybackController.estimatedSeconds(characters: 0), 0.94, accuracy: 0.001)
        XCTAssertEqual(PlaybackController.estimatedSeconds(characters: 100), 5.98, accuracy: 0.001)
        XCTAssertEqual(PlaybackController.estimatedSeconds(characters: -5), 0.94, accuracy: 0.001)
    }

    // MARK: - Running dry

    /// Answers every request with a short beat of silence, except the
    /// `holding`-th one (0-based), which waits until `release()`.
    final class HeldEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let holding: Int
        private let lock = NSLock()
        private var requests = 0
        private var texts: [String] = []
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?

        init(voices: [TtsVoice], holding: Int) {
            self.voices = voices
            self.holding = holding
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            let mine = lock.withLock { () -> Int in
                defer { requests += 1 }
                texts.append(text)
                return requests
            }
            if mine == holding {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let go = lock.withLock { () -> Bool in
                        if released { return true }
                        waiting = continuation
                        return false
                    }
                    if go { continuation.resume() }
                }
            }
            return .silence(duration: 0.25, sampleRate: 22_050)
        }

        var isHolding: Bool { lock.withLock { waiting != nil } }
        /// Every text asked for, in the order synthesis began.
        var requestedTexts: [String] { lock.withLock { texts } }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }

    /// Sentence 2's synthesis is held: sentences 0 and 1 play, then reading
    /// waits on 2 with the busy ring up and the highlight on 2, and goes on
    /// when its clip lands. One dry spell is logged, ended by the clip.
    func testARunDrySentenceShowsBufferingAndResumesWhenItsClipLands() async throws {
        let held = HeldEngine(voices: [PlaybackTestRig.voiceA], holding: 2)
        addTeardownBlock { held.release() }   // never leave a synthesis parked
        let rig = PlaybackTestRig(extraRoutes: [PlaybackTestRig.voiceA.id: held])
        let recorder = BudgetSignpostsTests.Recorder()
        rig.controller.budgetSignposts = recorder.signposts
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let dry = await rig.waitUntil(5) { rig.controller.status == .buffering && rig.controller.currentSentence == 2 }
        XCTAssertTrue(dry, "reading waits on sentence 2, got \(rig.controller.status) at \(rig.controller.currentSentence)")
        XCTAssertTrue(held.isHolding)
        XCTAssertEqual(recorder.events.filter { $0.budget == .catchingUp }.count, 1, "the dry spell began")

        held.release()
        let resumed = await rig.waitUntil(5) { rig.controller.status == .playing }
        XCTAssertTrue(resumed, "its clip landed: reading goes on")
        XCTAssertGreaterThanOrEqual(rig.controller.currentSentence, 2)
        let spell = recorder.events.filter { $0.budget == .catchingUp }
        XCTAssertEqual(spell.count, 2, "one dry spell, begun and ended")
        if case .end(let gaveUp) = spell.last?.kind {
            XCTAssertFalse(gaveUp, "ended by the clip, not abandoned")
        } else {
            XCTFail("the dry spell never ended")
        }
        rig.controller.pause(rampsOut: false)
    }

    /// A pause while reading waits ends the dry spell as given up, and the
    /// clip landing afterwards never starts the voice again.
    func testAPauseWhileRunDryIsAPause() async throws {
        let held = HeldEngine(voices: [PlaybackTestRig.voiceA], holding: 2)
        addTeardownBlock { held.release() }
        let rig = PlaybackTestRig(extraRoutes: [PlaybackTestRig.voiceA.id: held])
        let recorder = BudgetSignpostsTests.Recorder()
        rig.controller.budgetSignposts = recorder.signposts
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let dry = await rig.waitUntil(5) { rig.controller.status == .buffering && rig.controller.currentSentence == 2 }
        XCTAssertTrue(dry)

        rig.controller.pause(rampsOut: false)
        XCTAssertEqual(rig.controller.status, .paused)
        held.release()
        let stayed = await rig.waitUntil(0.6) { rig.controller.status == .playing }
        XCTAssertFalse(stayed, "a clip landing after the pause never plays")
        XCTAssertEqual(rig.controller.status, .paused)
        let spell = recorder.events.filter { $0.budget == .catchingUp }
        if case .end(let gaveUp) = spell.last?.kind {
            XCTAssertTrue(gaveUp, "the pause took it over")
        } else {
            XCTFail("the dry spell never ended")
        }
        XCTAssertEqual(rig.controller.currentSentence, 2, "Play resumes at the sentence reading waited for")
    }

    /// Reading that never runs dry never shows buffering after it starts.
    func testReadingThatKeepsUpNeverBuffersAgain() async throws {
        let rig = PlaybackTestRig()
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let mark = rig.statuses.lastIndex(of: .playing) ?? 0
        _ = await rig.waitUntil(1.5) { rig.controller.currentSentence >= 4 }
        XCTAssertGreaterThanOrEqual(rig.controller.currentSentence, 4, "reading moved on")
        XCTAssertFalse(rig.statuses[mark...].contains(.buffering), "kept up: no dry spell, got \(rig.statuses)")
        rig.controller.pause(rampsOut: false)
    }

    // MARK: - Work no one wants

    private static let voice = PlaybackTestRig.voiceA

    /// A scheduler whose first synthesis is parked until `release()`.
    private func parkedScheduler() async throws -> (SynthesisScheduler, HeldEngine) {
        let held = HeldEngine(voices: [Self.voice], holding: 0)
        addTeardownBlock { held.release() }   // never leave a synthesis parked
        let scheduler = SynthesisScheduler(engine: held, cache: AudioClipCache())
        await scheduler.prefetch("Parked.", voice: Self.voice, key: "parked")
        let parked = await poll { held.isHolding }
        try XCTSkipUnless(parked, "the first synthesis never started")
        return (scheduler, held)
    }

    private func poll(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// Rapid skips while playing: each new start gives up its wait for the
    /// last one's sentence. A sentence no one waits for any more leaves the
    /// now lane, so the one landed on is synthesized next, not after every
    /// sentence skipped past.
    func testASentenceNoOneWaitsForLeavesTheNowLane() async throws {
        let (scheduler, held) = try await parkedScheduler()
        var skippedPast: [Task<SynthesizedAudio, Error>] = []
        for index in 1...3 {
            let key = "skipped\(index)"
            skippedPast.append(Task {
                try await scheduler.synthesize("Skipped \(index).", voice: Self.voice, key: key, priority: .now)
            })
            let queued = await poll { await scheduler.queuedKeys.contains(key) }
            XCTAssertTrue(queued)
        }
        for task in skippedPast {
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("a cancelled wait should end in CancellationError")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
        let leftQueued = await scheduler.queuedKeys
        XCTAssertEqual(leftQueued, [], "no one waits for them")

        let landed = Task {
            try await scheduler.synthesize("Landed.", voice: Self.voice, key: "landed", priority: .now)
        }
        let queued = await poll { await scheduler.queuedKeys.contains("landed") }
        XCTAssertTrue(queued)
        held.release()
        _ = try await landed.value
        XCTAssertEqual(held.requestedTexts, ["Parked.", "Landed."])
    }

    /// A warm-up is wanted with no one waiting: a waiter that joined it and
    /// gave up leaves it queued.
    func testAWarmUpStaysWhenAWaiterGivesUp() async throws {
        let (scheduler, held) = try await parkedScheduler()
        await scheduler.prefetch("Warm.", voice: Self.voice, key: "warm")
        let joined = Task {
            try await scheduler.synthesize("Warm.", voice: Self.voice, key: "warm", priority: .prefetch)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        joined.cancel()
        _ = try? await joined.value
        let leftQueued = await scheduler.queuedKeys
        XCTAssertEqual(leftQueued, ["warm"])
        held.release()
    }

    /// Paused skips fill the prefetch lane with warm-ups for places left
    /// behind. Reading's own look-ahead, which waits, goes ahead of them,
    /// and a full lane makes room for it instead of refusing it (a refusal
    /// counted as a synthesis failure: a skipped sentence, or the System
    /// voice).
    func testAWaitedPrefetchDisplacesStaleWarmUps() async throws {
        let (scheduler, held) = try await parkedScheduler()
        for index in 1...8 {
            await scheduler.prefetch("Stale \(index).", voice: Self.voice, key: "stale\(index)")
        }
        let full = await scheduler.queuedKeys
        XCTAssertEqual(full.count, 8)

        let lookAhead = Task {
            try await scheduler.synthesize("Ahead.", voice: Self.voice, key: "ahead", priority: .prefetch)
        }
        let queued = await poll { await scheduler.queuedKeys.first == "ahead" }
        XCTAssertTrue(queued, "the look-ahead goes ahead of the warm-ups")
        let lane = await scheduler.queuedKeys
        XCTAssertEqual(lane.count, 8, "the lane stays bounded")
        XCTAssertFalse(lane.contains("stale1"), "the oldest warm-up made room")

        held.release()
        _ = try await lookAhead.value
        XCTAssertEqual(Array(held.requestedTexts.prefix(2)), ["Parked.", "Ahead."])
    }

    /// A paused seek moves the cue: the warm-ups still queued for where it
    /// was are dropped, so they never hold up Play at the new place.
    func testAPausedSeekDropsTheOldCuesWarmUps() async throws {
        let held = HeldEngine(voices: [PlaybackTestRig.voiceA], holding: 0)
        addTeardownBlock { held.release() }
        let rig = PlaybackTestRig(sentences: 40, extraRoutes: [PlaybackTestRig.voiceA.id: held])
        rig.loadDefault(at: 0)
        let parked = await rig.waitUntil { held.isHolding }
        try XCTSkipUnless(parked, "the cue's warm-up never started")

        rig.controller.seek(to: 10, andPlay: false)
        rig.controller.seek(to: 20, andPlay: false)
        let sentences = { () async -> [Int] in
            await rig.scheduler.queuedKeys.compactMap { key in key.split(separator: "|").last.flatMap { Int($0) } }
        }
        let settled = await poll { await sentences().contains(21) }
        XCTAssertTrue(settled)
        let queued = await sentences()
        XCTAssertEqual(queued, [20, 21], "only the new cue is warmed")
        held.release()
    }

    /// Opening another book paused (a Finished one at its end, or plain)
    /// drops the outgoing book's queued warm-ups, so they never hold up its
    /// first Play (L001); closing the book drops its own.
    func testOpeningOrClosingABookDropsTheOldBooksWarmUps() async throws {
        for finished in [false, true] {
            let held = HeldEngine(voices: [PlaybackTestRig.voiceA], holding: 0)
            addTeardownBlock { held.release() }
            let rig = PlaybackTestRig(sentences: 40, extraRoutes: [PlaybackTestRig.voiceA.id: held])
            rig.loadDefault(at: 10)
            let parked = await rig.waitUntil { held.isHolding }
            try XCTSkipUnless(parked, "the cue's warm-up never started")
            let oldBook = await poll { await rig.scheduler.queuedKeys.contains { $0.hasPrefix("rig-hash") } }
            XCTAssertTrue(oldBook, "the old book's next sentence is queued")

            let hash = "next-book-\(finished)"
            let other = PlaybackTestRig.makeDocument(hash: hash, sentences: 6, progressSentence: finished ? 5 : 2,
                                                     progressFraction: finished ? 1 : 0)
            rig.controller.load(document: other, content: PlaybackTestRig.makeContent(hash: hash, count: 6))
            XCTAssertEqual(rig.controller.isAtEnd, finished)
            let prefix = String(hash.prefix(12))
            let settled = await poll { await rig.scheduler.queuedKeys.filter { $0.hasPrefix(prefix) }.count == 2 }
            XCTAssertTrue(settled, "finished \(finished): the new cue is warmed")
            let queued = await rig.scheduler.queuedKeys
            XCTAssertTrue(queued.allSatisfy { $0.hasPrefix(prefix) }, "finished \(finished): \(queued)")

            rig.controller.unload()
            let dropped = await poll(1) { await rig.scheduler.queuedKeys.isEmpty }
            let left = await rig.scheduler.queuedKeys
            XCTAssertTrue(dropped, "a closed book stops warming: \(left)")
            held.release()
        }
    }
}
