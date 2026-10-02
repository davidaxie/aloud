import XCTest
@testable import Aloud

/// R19's controller mechanics, which the sleep timer drives: a scheduled stop
/// caps the queue and lands at a sentence end, cued at the next sentence;
/// the queued sentence ends give the timer its landing choices; and "Back 5
/// min" rewinds about 5 minutes of words and plays.
///
/// Scaled down (quarter-second sentences) and silent: muted rigs on their
/// own defaults suites. A test whose audio engine can't start is skipped.
@MainActor
final class SleepStopMechanicsTests: XCTestCase {

    private func scheduledSentences(_ rig: PlaybackTestRig) -> [Int] {
        rig.events.compactMap {
            if case .scheduled(let sentence, _) = $0 { return sentence }
            return nil
        }
    }

    private func playingRig(sentences: Int = 12,
                            clipDuration: TimeInterval = 0.25) async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: sentences, clipDuration: clipDuration)
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        return rig
    }

    // MARK: - The scheduled stop

    func testAScheduledStopCapsTheQueueAndStopsCuedAfterIt() async throws {
        let rig = try await playingRig()
        rig.controller.scheduleStop(afterSentence: 3)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 3)

        let stopped = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(stopped)
        XCTAssertFalse(scheduledSentences(rig).contains(4), "the queue never passed the landing")
        XCTAssertEqual(rig.controller.currentSentence, 4, "cued at the next sentence")
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0, "silent, so Play ramps in")
        XCTAssertEqual(rig.controller.resumeAnchor?.sentenceIndex, 4)
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, 4)
        XCTAssertNil(rig.controller.scheduledStopSentence)
        XCTAssertEqual(rig.announcements, ["Paused by sleep timer"])
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testRaisingTheCapResumesTheTopUp() async throws {
        let rig = try await playingRig()
        rig.controller.scheduleStop(afterSentence: 2)
        let atOne = await rig.waitUntil(2) { rig.controller.currentSentence >= 1 }
        XCTAssertTrue(atOne)
        XCTAssertFalse(scheduledSentences(rig).contains(3), "held at the cap")

        rig.controller.scheduleStop(afterSentence: 5)
        let resumed = await rig.waitUntil(2) { self.scheduledSentences(rig).contains(3) }
        XCTAssertTrue(resumed)

        let stopped = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(stopped)
        XCTAssertEqual(rig.controller.currentSentence, 6)
        XCTAssertFalse(scheduledSentences(rig).contains(6))
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
    }

    func testCancellingTheCapResumesTheTopUp() async throws {
        let rig = try await playingRig()
        rig.controller.scheduleStop(afterSentence: 2)
        let atOne = await rig.waitUntil(2) { rig.controller.currentSentence >= 1 }
        XCTAssertTrue(atOne)

        rig.controller.cancelScheduledStop()
        XCTAssertNil(rig.controller.scheduledStopSentence)
        let pastIt = await rig.waitUntil(3) { rig.controller.currentSentence >= 4 }
        XCTAssertTrue(pastIt)
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertNil(rig.controller.stopped)
    }

    func testAMovePastTheLandingClearsIt() {
        let rig = PlaybackTestRig()
        rig.loadDefault()

        rig.controller.scheduleStop(afterSentence: 3)
        rig.controller.seek(to: 2, andPlay: false)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 3, "still ahead")
        rig.controller.seek(to: 5, andPlay: false)
        XCTAssertNil(rig.controller.scheduledStopSentence, "left behind")

        rig.controller.scheduleStop(afterSentence: 8)
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "other", sentences: 8),
                            content: PlaybackTestRig.makeContent(hash: "other", count: 8))
        XCTAssertNil(rig.controller.scheduledStopSentence, "another book")

        rig.controller.scheduleStop(afterSentence: 4)
        rig.controller.unload()
        XCTAssertNil(rig.controller.scheduledStopSentence)
    }

    /// The timer hears its stop land from `sleepStopSerial` alone: one bump
    /// per sleep stop, the landing's or the deadline's, and none for a pause,
    /// another reason's stop, a sleep stop over a pause, or a voice sample
    /// handed back over a sleep stop.
    func testOnlyASleepStopBumpsTheSleepStopSerial() async throws {
        let rig = try await playingRig(sentences: 40)
        rig.controller.pause()
        XCTAssertEqual(rig.controller.sleepStopSerial, 0, "the listener's pause")

        rig.controller.play()
        rig.controller.stop(because: .headphonesDisconnected)
        XCTAssertEqual(rig.controller.stopped?.reason, .headphonesDisconnected)
        XCTAssertEqual(rig.controller.sleepStopSerial, 0, "another reason")

        rig.controller.play()
        rig.controller.scheduleStop(afterSentence: rig.controller.currentSentence + 1)
        let landed = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(landed)
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.controller.sleepStopSerial, 1, "the landing, once")

        rig.controller.stop(because: .sleepTimer)
        XCTAssertEqual(rig.controller.sleepStopSerial, 1, "nothing to stop over a pause")

        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let back = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(back, "the sample hands the pause back")
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.controller.sleepStopSerial, 1, "a sample over the stop records nothing")

        rig.controller.play()
        rig.controller.stop(because: .sleepTimer)
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.controller.sleepStopSerial, 2, "the deadline's stop, once")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Queued ends

    func testQueuedSentenceEndsAreSortedFutureEndsWhilePlaying() async throws {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 0.5)
        rig.loadDefault()
        XCTAssertEqual(rig.controller.queuedSentenceEnds(), [])
        XCTAssertNil(rig.controller.secondsUntilEnd(ofSentence: 0))

        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let queued = await rig.waitUntil(2) { rig.controller.queuedSentenceEnds().count >= 2 }
        XCTAssertTrue(queued)

        let current = rig.controller.currentSentence
        let ends = rig.controller.queuedSentenceEnds()
        XCTAssertEqual(ends.first?.sentence, current)
        XCTAssertEqual(ends.map(\.sentence), ends.map(\.sentence).sorted())
        XCTAssertTrue(ends.allSatisfy { $0.sentence >= current })
        XCTAssertTrue(ends.allSatisfy { $0.secondsFromNow >= 0 })
        XCTAssertTrue(zip(ends, ends.dropFirst()).allSatisfy { $0.secondsFromNow < $1.secondsFromNow })
        XCTAssertLessThanOrEqual(ends.last?.secondsFromNow ?? 0, 0.5 * 3 + 0.1, "at most the look-ahead")

        let first = try XCTUnwrap(ends.first)
        let until = try XCTUnwrap(rig.controller.secondsUntilEnd(ofSentence: first.sentence))
        XCTAssertEqual(until, first.secondsFromNow, accuracy: 0.1)
        XCTAssertNil(rig.controller.secondsUntilEnd(ofSentence: 11), "not queued yet")

        rig.controller.pause()
        XCTAssertEqual(rig.controller.queuedSentenceEnds(), [], "only while playing")
        XCTAssertNil(rig.controller.secondsUntilEnd(ofSentence: first.sentence))
    }

    // MARK: - Back 5 min

    func testBackFiveMinutesRewindsAboutFiveMinutesAndPlays() {
        for rate in [1.0, 1.5] {
            let rig = PlaybackTestRig(sentences: 300, wordsPerSentence: 11)
            rig.controller.rate = rate
            rig.loadDefault(at: 200)
            rig.controller.play()
            rig.controller.stop(because: .sleepTimer)
            XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)

            rig.controller.backFiveMinutes()

            let target = rig.controller.currentSentence
            let minutes = Double((200 - target) * 11) / (LibraryDocument.spokenWordsPerMinute * rate)
            XCTAssertTrue((4.5...5.5).contains(minutes), "\(rate)×: \(minutes) min earlier")
            XCTAssertTrue(rig.controller.isActive, "\(rate)×: it plays")
            XCTAssertNil(rig.controller.stopped, "\(rate)×: Play clears the stop")
            XCTAssertNil(rig.stopStore.load())
            XCTAssertNil(rig.controller.resumeAnchor, "\(rate)×: rewinds never stack")
            rig.controller.pause()
        }
    }

    func testTheSleepRewindIsFiveMinutes() {
        XCTAssertEqual(PlaybackController.sleepRewindSeconds, 300)
    }
}
