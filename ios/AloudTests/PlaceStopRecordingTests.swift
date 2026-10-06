import XCTest
@testable import Aloud

/// "Where you stopped": the controller reports each end of listening through
/// `onPlaceStop` — pause, an unattended stop, a book switch, unload, quit
/// while playing — at the sentence progress was saved at, and hands over a
/// session iOS ended once at the next launch.
///
/// All silent: muted rigs on their own defaults suites. A test whose audio
/// engine can't start in the host is skipped, not failed.
@MainActor
final class PlaceStopRecordingTests: XCTestCase {

    private final class StopLog {
        var stops: [PlaceStop] = []
    }

    /// A rig cued at `sentence`, recording stops, playing.
    private func playingRig(at sentence: Int = 5) async throws -> (PlaybackTestRig, StopLog) {
        let (rig, log) = cuedRig(at: sentence)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        return (rig, log)
    }

    private func cuedRig(at sentence: Int = 5) -> (PlaybackTestRig, StopLog) {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 0.5)
        let log = StopLog()
        rig.controller.onPlaceStop = { [log] in log.stops.append($0) }
        rig.loadDefault(at: sentence)
        return (rig, log)
    }

    func testAPauseReportsOneStopAtTheSavedSentence() async throws {
        let (rig, log) = try await playingRig(at: 5)
        rig.controller.pause(rampsOut: false)

        XCTAssertEqual(log.stops.count, 1)
        let stop = try XCTUnwrap(log.stops.first)
        XCTAssertEqual(stop.documentID, rig.document.id)
        XCTAssertEqual(stop.contentHash, "rig-hash")
        XCTAssertEqual(stop.sentence, rig.controller.currentSentence)
        XCTAssertEqual(stop.sentence, rig.progress.last?.sentence, "the stop is where progress was saved")
        XCTAssertEqual(stop.startSentence, 5, "the session starts where its audio first played")
        XCTAssertGreaterThanOrEqual(stop.listenedSeconds, 0)
        XCTAssertLessThan(stop.listenedSeconds, 60)
        XCTAssertFalse(stop.movedAway)
        XCTAssertEqual(stop.excerpt, rig.content.sentences[stop.sentence].text)

        rig.controller.pause(rampsOut: false)
        XCTAssertEqual(log.stops.count, 1, "pausing while paused reports nothing")
    }

    func testAnUnattendedStopReportsAStop() async throws {
        let (rig, log) = try await playingRig()
        rig.audioSession.onRouteRequiresPause?()
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(log.stops.map(\.documentID), [rig.document.id])
        XCTAssertEqual(log.stops.last?.sentence, rig.progress.last?.sentence)
    }

    /// Opening B while A plays reports A's place, never B's.
    func testSwitchingBooksReportsTheOutgoingBook() async throws {
        let (rig, log) = try await playingRig(at: 8)
        let playedTo = rig.controller.currentSentence
        let other = PlaybackTestRig.makeContent(hash: "other-hash", count: 20)
        let otherDocument = PlaybackTestRig.makeDocument(hash: "other-hash", sentences: 20)

        rig.controller.load(document: otherDocument, content: other)

        XCTAssertEqual(log.stops.count, 1)
        let stop = try XCTUnwrap(log.stops.first)
        XCTAssertEqual(stop.documentID, rig.document.id)
        XCTAssertEqual(stop.contentHash, "rig-hash")
        XCTAssertGreaterThanOrEqual(stop.sentence, playedTo)
        XCTAssertFalse(log.stops.contains { $0.documentID == otherDocument.id })
    }

    func testUnloadWhilePlayingReportsAndWhilePausedDoesNot() async throws {
        let (rig, log) = try await playingRig()
        rig.controller.unload()
        XCTAssertEqual(log.stops.map(\.documentID), [rig.document.id])

        let (paused, pausedLog) = cuedRig()
        paused.controller.unload()
        XCTAssertEqual(pausedLog.stops, [])
    }

    func testQuittingWhilePlayingReportsAndWhilePausedDoesNot() async throws {
        let (rig, log) = try await playingRig()
        rig.controller.applicationWillTerminate()
        XCTAssertEqual(log.stops.map(\.documentID), [rig.document.id])

        let (paused, pausedLog) = cuedRig()
        paused.controller.applicationWillTerminate()
        XCTAssertEqual(pausedLog.stops, [])
    }

    /// A far jump while playing leaves the place the session started from
    /// as the listener's own; a short tap does not.
    func testAFarJumpWhilePlayingMarksTheSessionMovedAway() async throws {
        let (rig, log) = try await playingRig(at: 2)
        rig.controller.jump(to: 30, origin: .chapter)
        rig.controller.pause(rampsOut: false)
        XCTAssertEqual(log.stops.last?.movedAway, true)

        let (near, nearLog) = try await playingRig(at: 2)
        near.controller.jump(to: near.controller.currentSentence + 2, origin: .sentence)
        near.controller.pause(rampsOut: false)
        XCTAssertEqual(nearLog.stops.last?.movedAway, false)
    }

    /// While audio plays the live marker carries the session's start, so a
    /// session iOS ends still has one.
    func testTheLiveMarkerCarriesTheSessionStart() async throws {
        let (rig, _) = try await playingRig(at: 5)
        let advanced = await rig.waitUntil(5) { rig.controller.currentSentence > 5 }
        try XCTSkipUnless(advanced, "playback didn't advance in this host")
        let data = try XCTUnwrap(rig.defaults.data(forKey: PlaybackStopStore.liveSessionKey))
        let live = try JSONDecoder().decode(LiveSession.self, from: data)
        XCTAssertEqual(live.startSentence, 5)
        XCTAssertNotNil(live.startedAt)
        rig.controller.pause(rampsOut: false)
    }

    /// The next launch after iOS ended the app mid-speech: the marker's
    /// place, handed over once.
    func testARecoveredSessionIsHandedOverOnce() {
        let rig = PlaybackTestRig(sentences: 40)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        rig.stopStore.markLive(LiveSession(documentID: rig.document.id, sentenceIndex: 17,
                                           wallClock: started.addingTimeInterval(120),
                                           startedAt: started, startSentence: 9))

        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let relaunched = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlaybackTestRig.FakeAudioOutput(),
                                            anchorStore: rig.anchorStore,
                                            stopStore: rig.stopStore,
                                            outputMuted: true)

        let recovered = relaunched.takeRecoveredPlaceStop()
        XCTAssertEqual(recovered?.documentID, rig.document.id)
        XCTAssertEqual(recovered?.sentence, 17)
        XCTAssertEqual(recovered?.startSentence, 9)
        XCTAssertEqual(recovered?.listenedSeconds ?? 0, 120, accuracy: 0.001)
        XCTAssertNil(recovered?.contentHash, "AppModel fills in the library record's hash")
        XCTAssertNil(relaunched.takeRecoveredPlaceStop(), "once")
    }

    /// The book reopens at the sentence iOS ended the app on, which the
    /// throttled progress write may not have reached, so the reader and the
    /// newest stop agree; and a jump away during that session survives.
    func testARecoveredSessionReopensAtItsSentenceAndKeepsItsJump() {
        let rig = PlaybackTestRig(sentences: 40)
        rig.stopStore.markLive(LiveSession(documentID: rig.document.id, sentenceIndex: 17,
                                           wallClock: Date(), startedAt: Date().addingTimeInterval(-60),
                                           startSentence: 9, movedAway: true))
        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let relaunched = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlaybackTestRig.FakeAudioOutput(),
                                            anchorStore: rig.anchorStore,
                                            stopStore: rig.stopStore,
                                            outputMuted: true)
        XCTAssertEqual(relaunched.takeRecoveredPlaceStop()?.movedAway, true)

        // The library's last write reached sentence 15 of the 17 heard.
        var reopened = rig.document
        reopened.progressSentence = 15
        reopened.progressFraction = 15.0 / 40
        relaunched.load(document: reopened, content: rig.content)
        XCTAssertEqual(relaunched.currentSentence, 17, "the marker's sentence, not the older write")

        // Only once: a later load of the book uses its saved place.
        relaunched.unload()
        reopened.progressSentence = 12
        relaunched.load(document: reopened, content: rig.content)
        XCTAssertEqual(relaunched.currentSentence, 12)
    }
}
