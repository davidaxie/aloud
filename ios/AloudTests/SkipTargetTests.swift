import XCTest
@testable import Aloud

/// R14's one skip unit: the nearest sentence start to 15 s of speech away
/// from the playhead at the current rate, always at least one sentence,
/// clamped; back restarts the current sentence once more than 3 s of it has
/// played.
@MainActor
final class SkipTargetTests: XCTestCase {

    /// Uniform 10-word sentences at 165 wpm unless a test says otherwise:
    /// 15 s is 41.25 words, so the nearest start is 4 sentences away.
    private func target(from current: Int,
                        seconds: TimeInterval,
                        count: Int = 100,
                        wordsPerMinute: Double = 165,
                        words: (Int) -> Int = { _ in 10 }) -> Int {
        PlaybackController.skipTarget(from: current, seconds: seconds, sentenceCount: count,
                                      wordsPerMinute: wordsPerMinute, words: words)
    }

    func testFifteenSecondsEachWay() {
        XCTAssertEqual(target(from: 20, seconds: 15), 24)
        XCTAssertEqual(target(from: 20, seconds: -15), 16)
    }

    func testRateScalesTheDistance() {
        XCTAssertEqual(target(from: 20, seconds: 15, wordsPerMinute: 330), 28)
    }

    func testLongCurrentSentenceStillMovesForwardOne() {
        XCTAssertEqual(target(from: 20, seconds: 15, words: { $0 == 20 ? 500 : 10 }), 21)
    }

    func testAlwaysMovesAtLeastOneSentence() {
        XCTAssertEqual(target(from: 20, seconds: 0.1), 21)
        XCTAssertEqual(target(from: 20, seconds: -0.1), 19)
    }

    func testClampedAtBothEnds() {
        XCTAssertEqual(target(from: 0, seconds: -15), 0)
        XCTAssertEqual(target(from: 99, seconds: 15), 99)
        XCTAssertEqual(target(from: 2, seconds: -15), 0)
        XCTAssertEqual(target(from: 97, seconds: 15), 99)
        XCTAssertEqual(target(from: 250, seconds: 15), 99, "an out-of-range playhead is clamped first")
    }

    func testZeroWordSentencesArePassedOver() {
        // Forward from 0: sentences 1–3 are empty, so 4 sentence starts tie
        // at 20 words and the walk must go on to 40 words at sentence 5.
        XCTAssertEqual(target(from: 0, seconds: 15, words: { (1...3).contains($0) ? 0 : 20 }), 5)
        // Back from 10 over empty 7–9: 40 words lands on sentence 3.
        XCTAssertEqual(target(from: 10, seconds: -15, words: { (7...9).contains($0) ? 0 : 10 }), 3)
    }

    func testEmptyDocument() {
        XCTAssertEqual(target(from: 0, seconds: 15, count: 0), 0)
        XCTAssertEqual(target(from: 5, seconds: -15, count: 0), 0)
    }

    func testZeroSecondsStaysPut() {
        XCTAssertEqual(target(from: 20, seconds: 0), 20)
    }

    // MARK: - R14: measured from the playhead

    /// The PRD fixture at 60 wpm (a word a second): even sentences are 3 s,
    /// odd ones 40 s.
    private func r14(from current: Int, seconds: TimeInterval, elapsed: TimeInterval) -> Int {
        PlaybackController.skipTarget(from: current, seconds: seconds, elapsed: elapsed,
                                      sentenceCount: 20, wordsPerMinute: 60,
                                      words: { $0 % 2 == 0 ? 3 : 40 })
    }

    func testBackEarlyInALongSentenceLandsOnThePreviousStart() {
        XCTAssertEqual(r14(from: 5, seconds: -15, elapsed: 2), 4)
    }

    func testBackLaterInALongSentenceRestartsIt() {
        XCTAssertEqual(r14(from: 5, seconds: -15, elapsed: 10), 5)
    }

    func testTheRestartThresholdIsStrict() {
        XCTAssertEqual(r14(from: 5, seconds: -15, elapsed: 3.0), 4, "exactly 3 s is not more than 3 s")
        XCTAssertEqual(r14(from: 5, seconds: -15, elapsed: 3.01), 5)
        XCTAssertEqual(PlaybackController.restartThreshold, 3)
        XCTAssertEqual(PlaybackController.skipInterval, 15)
    }

    func testBackWithinThreeSecondsAlwaysMoves() {
        for current in 1..<20 {
            for elapsed in stride(from: 0.0, through: 3.0, by: 0.5) {
                XCTAssertLessThan(r14(from: current, seconds: -15, elapsed: elapsed), current,
                                  "from \(current) at \(elapsed) s")
            }
        }
    }

    func testForwardAlwaysChangesSentence() {
        for elapsed in 0...39 {
            XCTAssertGreaterThan(r14(from: 5, seconds: 15, elapsed: TimeInterval(elapsed)), 5,
                                 "at \(elapsed) s into the 40 s sentence")
        }
    }

    func testBothDirectionsMeasureFromThePlayhead() {
        // 10-word sentences at 165 wpm: 3 s heard is 8.25 words.
        XCTAssertEqual(target(from: 20, seconds: 15), 24)
        XCTAssertEqual(PlaybackController.skipTarget(from: 20, seconds: 15, elapsed: 3, sentenceCount: 100,
                                                     wordsPerMinute: 165, words: { _ in 10 }), 25)
        XCTAssertEqual(target(from: 20, seconds: -15), 16)
        XCTAssertEqual(PlaybackController.skipTarget(from: 20, seconds: -15, elapsed: 3, sentenceCount: 100,
                                                     wordsPerMinute: 165, words: { _ in 10 }), 17)
    }

    func testElapsedIsClamped() {
        XCTAssertEqual(r14(from: 5, seconds: 15, elapsed: 100), r14(from: 5, seconds: 15, elapsed: 40),
                       "never more heard than the sentence holds")
        XCTAssertEqual(r14(from: 5, seconds: -15, elapsed: -5), r14(from: 5, seconds: -15, elapsed: 0))
        XCTAssertEqual(r14(from: 5, seconds: 15, elapsed: -5), r14(from: 5, seconds: 15, elapsed: 0))
    }

    func testTheFirstSentenceRestartsOnlyAfterThreeSeconds() {
        XCTAssertEqual(r14(from: 0, seconds: -15, elapsed: 2), 0, "nowhere earlier to go")
        XCTAssertEqual(r14(from: 0, seconds: -15, elapsed: 5), 0, "its own start")

        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        rig.loadDefault(at: 0)
        rig.controller.frozenSentenceElapsed = 2
        rig.clearRecordings()
        XCTAssertEqual(rig.controller.skip(seconds: -15), 0)
        XCTAssertFalse(rig.events.contains(.stopped), "within 3 s: nothing to do")

        rig.controller.frozenSentenceElapsed = 5
        XCTAssertEqual(rig.controller.skip(seconds: -15), 0)
        XCTAssertTrue(rig.events.contains(.stopped), "past 3 s: re-cued from its start")
    }

    // MARK: - Controller

    func testSkipWhilePausedMovesAndStaysPaused() {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        rig.loadDefault(at: 20)

        rig.controller.skip(seconds: 15)
        XCTAssertEqual(rig.controller.currentSentence, 24)
        XCTAssertEqual(rig.controller.status, .paused)

        rig.controller.skip(seconds: -15)
        XCTAssertEqual(rig.controller.currentSentence, 20)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.userPlayAction, 0)
    }

    func testSkipWhilePlayingKeepsPlaying() {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        rig.loadDefault(at: 20)
        rig.controller.play()
        XCTAssertTrue(rig.controller.isActive)

        rig.controller.skip(seconds: 15)

        XCTAssertEqual(rig.controller.currentSentence, 24)
        XCTAssertTrue(rig.controller.isActive)
    }

    func testSkipAtTheEndDoesNothing() {
        let rig = PlaybackTestRig(sentences: 6)
        rig.loadDefault(at: 5)
        var transitions = 0
        let subscription = rig.controller.$status.dropFirst().sink { _ in transitions += 1 }
        defer { subscription.cancel() }

        rig.controller.skip(seconds: 15)

        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertEqual(transitions, 0)
    }

    /// R1-42: Forward 15 is enabled exactly when a forward skip would move:
    /// the first and a middle sentence, never the last or the end, and
    /// never with no book.
    func testCanSkipForwardIsExactlyWhetherForwardMoves() {
        let rig = PlaybackTestRig(sentences: 6, wordsPerSentence: 10)
        XCTAssertFalse(rig.controller.canSkipForward, "no book")

        rig.loadDefault()
        for sentence in [0, 3, 5] {
            rig.controller.seek(to: sentence, andPlay: false)
            XCTAssertEqual(rig.controller.currentSentence, sentence)
            let predicted = rig.controller.canSkipForward
            rig.controller.skip(seconds: PlaybackController.skipInterval)
            XCTAssertEqual(predicted, rig.controller.currentSentence != sentence,
                           "sentence \(sentence): canSkipForward \(predicted), landed \(rig.controller.currentSentence)")
        }
        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertFalse(rig.controller.canSkipForward, "the last sentence")

        let ended = PlaybackTestRig(sentences: 6, wordsPerSentence: 10)
        var finished = ended.document
        finished.progressSentence = 5
        finished.progressFraction = 1
        ended.controller.load(document: finished, content: ended.content)
        XCTAssertTrue(ended.controller.isAtEnd, "a Finished book opens at its end")
        XCTAssertFalse(ended.controller.canSkipForward, "the end")
        let before = ended.controller.currentSentence
        ended.controller.skip(seconds: PlaybackController.skipInterval)
        XCTAssertEqual(ended.controller.currentSentence, before, "Forward has nowhere to go at the end")
        XCTAssertTrue(ended.controller.isAtEnd, "and leaves the end alone")
    }

    /// R1-42: a disabled glyph draws faint and never presses, whatever
    /// Reduce Motion says; an enabled one keeps its press.
    func testADisabledSkipGlyphIsFaintAndNeverPresses() {
        XCTAssertEqual(ReaderGlyphButtonStyle.tint(isPressed: false, isEnabled: false), Theme.textFaint)
        XCTAssertEqual(ReaderGlyphButtonStyle.tint(isPressed: true, isEnabled: false), Theme.textFaint)
        XCTAssertEqual(ReaderGlyphButtonStyle.tint(isPressed: false, isEnabled: true), Theme.textMuted)
        XCTAssertEqual(ReaderGlyphButtonStyle.tint(isPressed: true, isEnabled: true), Theme.text)
        XCTAssertEqual(ReaderGlyphButtonStyle.scale(isPressed: true, isEnabled: false, reduceMotion: false), 1)
        XCTAssertEqual(ReaderGlyphButtonStyle.scale(isPressed: true, isEnabled: true, reduceMotion: false),
                       ReaderGlyphButtonStyle.pressedScale)
        XCTAssertEqual(ReaderGlyphButtonStyle.scale(isPressed: true, isEnabled: true, reduceMotion: true), 1)
    }

    func testAPausedBackPastThreeSecondsReCuesTheSameSentence() {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        rig.loadDefault(at: 20)
        rig.controller.frozenSentenceElapsed = 10
        rig.clearRecordings()

        let landed = rig.controller.skip(seconds: -PlaybackController.skipInterval)

        XCTAssertEqual(landed, 20)
        XCTAssertEqual(rig.controller.currentSentence, 20)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertTrue(rig.events.contains(.stopped), "re-cued from its start")
        XCTAssertNil(rig.controller.frozenSentenceElapsed)
        XCTAssertEqual(rig.controller.currentSentenceElapsed, 0)
    }

    func testSkipReturnsTheLandedSentence() {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: 10)
        XCTAssertNil(rig.controller.skip(seconds: 15), "no book")

        rig.loadDefault(at: 20)
        XCTAssertEqual(rig.controller.skip(seconds: 15), 24)
        XCTAssertEqual(rig.controller.skip(seconds: -15), 20)
        rig.controller.seek(to: 39, andPlay: false)
        XCTAssertEqual(rig.controller.skip(seconds: 15), 39, "nothing later: stays")
    }

    func testAPauseFreezesTheElapsedTimeAndAResumeThawsIt() async throws {
        let rig = PlaybackTestRig(sentences: 6, clipDuration: 3)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        try? await Task.sleep(nanoseconds: 600_000_000)

        rig.controller.pause()
        let frozen = try XCTUnwrap(rig.controller.frozenSentenceElapsed)
        XCTAssertGreaterThan(frozen, 0.2)
        XCTAssertLessThan(frozen, 2.5)
        XCTAssertEqual(rig.controller.currentSentenceElapsed, frozen)

        rig.controller.play()
        XCTAssertNil(rig.controller.frozenSentenceElapsed)
        rig.controller.pause(rampsOut: false)
    }

    func testBackAtTheEndRestartsTheLastSentencePaused() async throws {
        let rig = PlaybackTestRig(sentences: 4, wordsPerSentence: 10, clipDuration: 0.1)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        XCTAssertGreaterThan(rig.controller.currentSentenceElapsed, 3, "10 words at 165 wpm")

        let landed = rig.controller.skip(seconds: -PlaybackController.skipInterval)

        XCTAssertEqual(landed, 3)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(rig.controller.status, .paused)
    }

    // MARK: - A boundary inside the pause ramp

    func testABoundaryInsideThePauseRampMeasuresBackFromTheSentenceItReached() async throws {
        let rig = PlaybackTestRig(sentences: 200, clipDuration: 0.05)
        rig.loadDefault(at: 60)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let flowing = await rig.waitUntil(2) { rig.controller.currentSentence >= 62 }
        XCTAssertTrue(flowing)
        let mark = rig.edges.count

        rig.controller.pause()
        let pausedAt = rig.controller.currentSentence
        // As if paused 10 s into a long sentence that then ends in the ramp.
        rig.controller.frozenSentenceElapsed = 10

        let advanced = await rig.waitUntil(1) { rig.controller.currentSentence > pausedAt }
        XCTAssertTrue(advanced, "50 ms sentences end inside the 120 ms ramp")
        let nodePaused = await rig.waitUntil(1) { !rig.nodePauseTimes(from: mark).isEmpty }
        XCTAssertTrue(nodePaused)
        let cued = rig.controller.currentSentence

        XCTAssertEqual(rig.controller.currentSentenceElapsed, 0, "none of the new sentence was heard")
        let landed = try XCTUnwrap(rig.controller.skip(seconds: -PlaybackController.skipInterval))
        // 3-word sentences at 165 wpm: 15 s back is about 14 sentences.
        XCTAssertLessThan(landed, pausedAt, "Back walks back; it doesn't re-cue sentence \(cued)")
        XCTAssertEqual(rig.controller.status, .paused)
    }

    func testAtTheEndAFrozenPauseNeverHidesTheLastSentence() async throws {
        let rig = PlaybackTestRig(sentences: 4, wordsPerSentence: 10, clipDuration: 0.1)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        // What a pause leaves behind when the book ends inside its ramp.
        rig.controller.frozenSentenceElapsed = 1

        XCTAssertGreaterThan(rig.controller.currentSentenceElapsed, 3, "the whole last sentence: 10 words")
        XCTAssertEqual(rig.controller.skip(seconds: -PlaybackController.skipInterval), 3,
                       "Back restarts the last sentence")
        XCTAssertEqual(rig.controller.status, .paused)
    }
}
