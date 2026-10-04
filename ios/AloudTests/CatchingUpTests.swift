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

    /// Where the platform has no listening time, a fixed two sentences
    /// (an iPhone's rule, unchanged).
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
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?

        init(voices: [TtsVoice], holding: Int) {
            self.voices = voices
            self.holding = holding
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            let mine = lock.withLock { () -> Int in
                defer { requests += 1 }
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
}
