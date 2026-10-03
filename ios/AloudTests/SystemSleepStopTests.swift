import XCTest
@testable import Aloud

/// S11: the machine going to sleep stops playback honestly (`.macSlept`),
/// recorded through PlaybackStopStore like every stop, so it outlives the
/// launch and one Play resumes. The event goes to the rig's own center, never
/// the host app's. An iPhone never posts it; the test does.
@MainActor
final class SystemSleepStopTests: XCTestCase {

    private func playingRig() async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 0.5)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
        return rig
    }

    func testSleepWhilePlayingStopsAsMacSleptAndPersists() async throws {
        let rig = try await playingRig()

        PlatformLifecycle.post(.systemWillSleep, to: rig.lifecycle)

        let stop = PlaybackStop(reason: .macSlept, documentID: rig.document.id)
        XCTAssertEqual(rig.controller.status, .paused, "stopped synchronously, before the machine sleeps")
        XCTAssertEqual(rig.controller.stopped, stop)
        XCTAssertEqual(rig.stopStore.load(), stop)
        XCTAssertEqual(PlaybackStopStore(defaults: rig.defaults).load(), stop, "persisted, not just held")
        XCTAssertNil(rig.defaults.data(forKey: PlaybackStopStore.liveSessionKey),
                     "an orderly stop: the next launch reports no closed-by-iOS")
        XCTAssertEqual(rig.announcements, [StopReason.macSlept.spokenText])

        // The next launch shows the same stop.
        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let next = PlaybackController(engine: engine,
                                      defaultVoice: PlaybackTestRig.voiceA,
                                      scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                      cache: cache,
                                      audioSession: PlaybackTestRig.FakeAudioOutput(),
                                      anchorStore: rig.anchorStore,
                                      stopStore: rig.stopStore,
                                      outputMuted: true,
                                      lifecycle: NotificationCenter())
        XCTAssertEqual(next.stopped, stop)

        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertNil(rig.controller.stopped, "one Play resumes")
        XCTAssertNil(rig.stopStore.load())
    }

    func testSleepWhilePausedRecordsNothing() async throws {
        let rig = try await playingRig()
        rig.controller.pause()
        rig.clearRecordings()

        PlatformLifecycle.post(.systemWillSleep, to: rig.lifecycle)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertNil(rig.stopStore.load())
        XCTAssertEqual(rig.announcements, [])
    }
}
