import XCTest
@testable import Aloud

/// Forward 15 lands about 15 s past the playhead, beyond the look-ahead on
/// prose of short sentences. Once the look-ahead is full, the sentences past
/// it that a press can land on before the next sentence change are warmed
/// in the clip cache (never onto the node), so the press finds its clip
/// made. Natural voice only; never under strain or with a voice handoff
/// pending; nothing made twice.
///
/// Silent: the shared rig (`outputMuted`) over a fake natural voice whose
/// clips are silence. Every expectation is computed from the platform's own
/// tuning, so the same tests hold on the iPhone and the Mac.
@MainActor
final class SkipTargetWarmUpTests: XCTestCase {

    private typealias FakeNeuralEngine = PlaybackTestRig.FakeNeuralEngine
    private static let michael = PlaybackTestRig.michael

    /// About 6 s a sentence at 1x (16 words at 165 a minute).
    private static let sixSecondWords = 16

    // MARK: - Harness

    /// The rig's natural voice, `michael`'s engine, warm (`makeRig`).
    private var neural: FakeNeuralEngine!

    /// A rig of `sentences` sentences of `words` words whose clips, in either
    /// voice, are `clipDuration` long (a long clip holds the playhead still).
    private func makeRig(sentences: Int = 30, words: Int, clipDuration: TimeInterval) -> PlaybackTestRig {
        let engine = FakeNeuralEngine(warm: true, clipDuration: clipDuration)
        neural = engine
        return PlaybackTestRig(sentences: sentences, wordsPerSentence: words, clipDuration: clipDuration,
                               neural: engine)
    }

    private func startPlaying(_ rig: PlaybackTestRig, in voice: TtsVoice = SkipTargetWarmUpTests.michael) async throws {
        rig.controller.voice = voice   // no book yet: nothing restarts
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
    }

    /// The last sentence the node holds with the playhead on `current`
    /// (`PlaybackController.lookAheadHorizon`).
    private static func horizon(_ rig: PlaybackTestRig, from current: Int = 0, strained: Bool = false) -> Int {
        let ahead = rig.content.sentences.dropFirst(current + 1)
            .prefix(PlatformPlaybackTuning.lookAheadSentences.upperBound).map(\.text.count)
        return current + PlaybackController.lookAheadCount(
            characterCounts: Array(ahead), rate: 1,
            seconds: PlatformPlaybackTuning.lookAheadSeconds,
            range: PlatformPlaybackTuning.lookAheadSentences,
            strainedCap: strained ? PlatformPlaybackTuning.lookAheadUnderStrain : nil)
    }

    /// Where Forward 15 lands from `current` with `elapsed` of it heard; the
    /// whole sentence heard is the furthest it lands before the next change.
    private static func landing(_ rig: PlaybackTestRig, from current: Int = 0, wholeSentenceHeard: Bool) -> Int {
        let wordsPerMinute = LibraryDocument.spokenWordsPerMinute
        let elapsed = wholeSentenceHeard
            ? Double(rig.content.sentences[current].wordCount) / wordsPerMinute * 60 : 0
        return PlaybackController.skipTarget(from: current, seconds: PlaybackController.skipInterval,
                                             elapsed: elapsed, sentenceCount: rig.content.sentences.count,
                                             wordsPerMinute: wordsPerMinute,
                                             words: { rig.content.sentences[$0].wordCount })
    }

    private static func isCached(_ sentence: Int, in rig: PlaybackTestRig) -> Bool {
        let key = AudioClipCache.key(voice: michael, skipBrackets: rig.controller.skipBrackets,
                                     contentHash: rig.content.contentHash,
                                     nativeSpeed: NativeSpeed.tier(for: rig.controller.rate, engine: michael.engine),
                                     sentenceID: sentence)
        return rig.cache.clip(forKey: key) != nil
    }

    /// The sentences `neural` was asked for, in order.
    private static func requested(_ neural: FakeNeuralEngine) -> [Int] {
        neural.requests.map(\.text).compactMap(PlaybackTestRig.sentenceIndex(ofRequest:))
    }

    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The landing is warm

    /// 6 s sentences: once the top-up settles, every sentence Forward 15 can
    /// land on before the next sentence change is in the cache, past the
    /// look-ahead included.
    func testWithSixSecondSentencesForward15sLandingIsCached() async throws {
        let rig = makeRig(words: Self.sixSecondWords, clipDuration: 6)
        let horizon = Self.horizon(rig)
        let furthest = Self.landing(rig, wholeSentenceHeard: true)
        XCTAssertGreaterThan(furthest, horizon, "6 s sentences put the landing past the look-ahead")
        XCTAssertLessThanOrEqual(furthest, horizon + PlaybackController.skipWarmUpLimit)

        try await startPlaying(rig)
        let warmed = await rig.waitUntil(3) { (1...furthest).allSatisfy { Self.isCached($0, in: rig) } }
        XCTAssertTrue(warmed, "cached through \(furthest): \(Self.requested(neural))")
        XCTAssertEqual(rig.controller.currentSentence, 0, "the playhead never moved")
        rig.controller.pause()
    }

    /// A press lands on a clip already made: back to playing with no
    /// synthesis for the sentence it landed on.
    func testForward15ReturnsToPlayingWithNoColdSynthesis() async throws {
        // About 3.3 s sentences: a fresh press lands past the look-ahead on
        // every platform.
        let rig = makeRig(words: 9, clipDuration: 6)
        let horizon = Self.horizon(rig)
        let landing = Self.landing(rig, wholeSentenceHeard: false)
        XCTAssertGreaterThan(landing, horizon, "the rig's press lands past the look-ahead")

        try await startPlaying(rig)
        let furthest = Self.landing(rig, wholeSentenceHeard: true)
        let warmed = await rig.waitUntil(3) { (1...furthest).allSatisfy { Self.isCached($0, in: rig) } }
        XCTAssertTrue(warmed)

        let mark = neural.requests.count
        let statusMark = rig.statuses.count
        let landed = try XCTUnwrap(rig.controller.skip(seconds: PlaybackController.skipInterval))
        XCTAssertEqual(landed, landing)
        try await rig.waitUntilPlayingOrSkip(after: statusMark)
        let made = Array(Self.requested(neural).dropFirst(mark))
        XCTAssertFalse(made.contains(landed), "\(landed) was synthesized cold: \(made)")
        rig.controller.pause()
    }

    /// Over a whole book every sentence is synthesized exactly once: a
    /// warm-up is the clip the look-ahead later queues, never a second one.
    func testNothingIsMadeTwiceOverARun() async throws {
        let rig = makeRig(sentences: 16, words: Self.sixSecondWords, clipDuration: 0.25)
        try await startPlaying(rig)
        let ended = await rig.waitUntil(10) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        let made = Self.requested(neural)
        XCTAssertEqual(made.sorted(), Array(0..<16), "each sentence once: \(made)")
    }

    // MARK: - When nothing is warmed

    /// Under strain (Low Power Mode or serious heat) nothing is synthesized
    /// past the look-ahead.
    func testUnderStrainNothingIsWarmedPastTheLookAhead() async throws {
        let rig = makeRig(words: Self.sixSecondWords, clipDuration: 6)
        rig.controller.isUnderStrain = { true }
        let horizon = Self.horizon(rig, strained: true)
        XCTAssertGreaterThan(Self.landing(rig, wholeSentenceHeard: true), horizon,
                             "unstrained, this book would warm past the look-ahead")

        try await startPlaying(rig)
        let full = await rig.waitUntil(3) { Self.requested(neural).contains(horizon) }
        XCTAssertTrue(full)
        await elapse(0.2)
        let made = Self.requested(neural)
        XCTAssertLessThanOrEqual(made.max() ?? -1, horizon, "nothing past the look-ahead: \(made)")
        rig.controller.pause()
    }

    /// With a handoff to the natural voice pending (R5), a top-up warms
    /// nothing past the look-ahead in it: the only clips past the queue are
    /// the two the handoff warms at its splice.
    func testWithAHandoffPendingNothingIsWarmedPastTheLookAhead() async throws {
        // About 1.5 s sentences: the landing lies well past the splice's two.
        let rig = makeRig(words: 4, clipDuration: 6)
        let horizon = Self.horizon(rig)
        XCTAssertGreaterThan(Self.landing(rig, wholeSentenceHeard: true), horizon + 2)

        try await startPlaying(rig, in: PlaybackTestRig.voiceA)
        // On the node, so the splice falls just past it.
        let full = await rig.waitUntil(3) {
            rig.events.contains {
                if case .scheduled(let sentence, _) = $0 { return sentence == horizon }
                return false
            }
        }
        XCTAssertTrue(full, "the System voice's look-ahead is full")
        XCTAssertTrue(rig.requestedSentences(rig.engineA).allSatisfy { $0 <= horizon },
                      "the System voice warms nothing past it")

        rig.controller.switchVoiceAtSentenceBoundary(to: Self.michael)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "pending, behind the queued clips")
        let spliced = await rig.waitUntil(2) { Self.requested(neural).count >= 2 }
        XCTAssertTrue(spliced)
        XCTAssertEqual(Self.requested(neural), [horizon + 1, horizon + 2], "the splice and the one after")

        // A top-up with the playhead still: a sleep stop at the end caps nothing.
        rig.controller.scheduleStop(afterSentence: rig.content.sentences.count - 1)
        await elapse(0.3)
        XCTAssertEqual(rig.controller.incomingVoice, Self.michael, "still pending")
        let made = Self.requested(neural)
        XCTAssertLessThanOrEqual(made.max() ?? -1, horizon + 2, "nothing warmed past the splice: \(made)")
        rig.controller.pause()
    }
}
