import AVFoundation
import XCTest
@testable import Aloud

/// S7b: when the engine's output configuration changes under it, the output
/// monitor's decision is all playback does. `.ignore` (the iPhone's) keeps
/// today's path untouched; `.stop` is an honest stop whose next Play
/// schedules afresh; `.follow` restarts from the current sentence's start,
/// with no notice. Each change is posted for the rig's own engine, which the
/// host app's controller never observes.
@MainActor
final class PlaybackConfigurationChangeTests: XCTestCase {

    // MARK: - Harness

    /// Playing two-second clips from sentence 3, recordings cleared.
    private func playingRig(_ decision: RouteDecision) async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 2)
        rig.audioSession.decision = decision
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
        return rig
    }

    /// Posts the change and waits until the controller has asked the monitor
    /// and acted (one main-actor turn does both).
    private func changeOutput(_ rig: PlaybackTestRig,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let asked = rig.audioSession.decisionsAsked
        rig.controller.postEngineConfigurationChange()
        let answered = await rig.waitUntil { rig.audioSession.decisionsAsked > asked }
        XCTAssertTrue(answered, "the controller asks the monitor", file: file, line: line)
        XCTAssertEqual(rig.audioSession.decisionsAsked, asked + 1, "once per change", file: file, line: line)
    }

    private static func isScheduled(_ event: PlaybackController.AudioScheduleEvent) -> Bool {
        if case .scheduled = event { return true }
        return false
    }

    // MARK: - Ignore (the iPhone)

    func testIgnoreKeepsTodaysPath() async throws {
        let rig = try await playingRig(.ignore)
        let bindings = rig.audioSession.bindings
        await changeOutput(rig)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertFalse(rig.events.contains(.stopped), "the schedule is untouched")
        XCTAssertFalse(rig.statuses.contains(.buffering), "no restart")
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.controller.notice)
        XCTAssertEqual(rig.announcements, [])
        XCTAssertEqual(rig.audioSession.bindings, bindings, "nothing rebinds")
    }

    /// Another engine's change is not this controller's business.
    func testAnotherEnginesChangeIsIgnoredUnasked() async throws {
        let rig = PlaybackTestRig()
        rig.audioSession.decision = .stop(.headphonesDisconnected)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.audioSession.decisionsAsked, 0)
    }

    // MARK: - Stop

    func testStopPausesHonestlyAndSchedulesNothingBeforeTheNextPlay() async throws {
        let rig = try await playingRig(.stop(.headphonesDisconnected))
        await changeOutput(rig)
        let cue = rig.controller.currentSentence

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped, PlaybackStop(reason: .headphonesDisconnected, documentID: rig.document.id))
        XCTAssertEqual(rig.announcements, ["Paused, headphones disconnected"])
        let stoppedAt = try XCTUnwrap(rig.events.lastIndex(of: .stopped), "the old output's queue is dropped")
        XCTAssertFalse(rig.events[stoppedAt...].contains(where: Self.isScheduled))

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(rig.events[stoppedAt...].contains(where: Self.isScheduled),
                       "nothing reaches the node before the next Play")
        XCTAssertEqual(rig.controller.currentSentence, cue)

        let mark = rig.statuses.count
        let eventMark = rig.events.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(rig.events[eventMark...].first(where: Self.isScheduled),
                       .scheduled(sentence: cue, voiceID: PlaybackTestRig.voiceA.id),
                       "Play schedules afresh from the stopped sentence")
        XCTAssertNil(rig.controller.stopped, "Play clears the stop")
    }

    // MARK: - Follow

    func testFollowRestartsFromTheSentenceStartWithNoNotice() async throws {
        let rig = try await playingRig(.follow)
        let bindings = rig.audioSession.bindings
        await changeOutput(rig)
        let cue = rig.controller.currentSentence
        let stoppedAt = try XCTUnwrap(rig.events.lastIndex(of: .stopped), "the old schedule is dropped")

        let restarted = await rig.waitUntil {
            rig.controller.status == .playing && rig.events[stoppedAt...].contains(where: Self.isScheduled)
        }
        XCTAssertTrue(restarted)
        XCTAssertEqual(rig.events[stoppedAt...].first(where: Self.isScheduled),
                       .scheduled(sentence: cue, voiceID: PlaybackTestRig.voiceA.id),
                       "rescheduled from the current sentence")
        XCTAssertEqual(rig.controller.wordTiming.clip(for: cue)?.start, 0, "from the sentence's start")
        // A process rendering offline (the muted Mac) has no output to bind.
        XCTAssertEqual(rig.audioSession.bindings, bindings + (rig.controller.rendersOffline ? 0 : 1),
                       "the restart binds the new output")
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.controller.notice)
        XCTAssertEqual(rig.announcements, [], "the listener chose the device: no notice")
    }
}
