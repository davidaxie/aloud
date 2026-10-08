import Combine
import MediaPlayer
import XCTest
@testable import Aloud

/// R23's manager on the muted rig: what it pushes and when, the lock-screen
/// scrub and skips. No manager is configured, and every observed one pushes
/// into a recorder or a dropping sink: no test writes the system's
/// now-playing info or adds a remote-command target (the muted-process
/// tests read it, never write it). Only the pause and remote Play tests
/// play, on the muted mixer.
@MainActor
final class NowPlayingManagerTests: XCTestCase {

    private final class Recorder {
        var pushes: [[String: Any]?] = []
        var renders = 0

        var last: [String: Any]? { pushes.last ?? nil }
    }

    private struct Harness {
        let rig: PlaybackTestRig
        let manager: NowPlayingManager
        let recorder: Recorder
        let documents: PassthroughSubject<[LibraryDocument], Never>
        let document: LibraryDocument
        let navigation: ReaderNavigation
    }

    /// Three chapters of three sentences: sentences 3...5 are chapter 2.
    private static let chapterPages = [0, 0, 0, 1, 1, 1, 2, 2, 2]

    /// A manager observing a rig whose controller has the 3-chapter book
    /// loaded, paused at `sentence`, or reopened at its end when `finished`
    /// (R24: .ended, cued on the last sentence; nothing plays).
    private func makeHarness(at sentence: Int, wordsPerSentence: Int = 4, finished: Bool = false) -> Harness {
        let rig = PlaybackTestRig()
        let recorder = Recorder()
        let manager = NowPlayingManager(
            publish: { recorder.pushes.append($0) },
            renderArtwork: { _ -> MPMediaItemArtwork? in
                recorder.renders += 1
                return nil
            })
        let documents = PassthroughSubject<[LibraryDocument], Never>()
        manager.observe(playback: rig.controller, documents: documents.eraseToAnyPublisher())
        let content = PlaybackTestRig.makeContent(hash: "np-manager", count: 9,
                                                  wordsPerSentence: wordsPerSentence, pages: Self.chapterPages)
        let document = PlaybackTestRig.makeDocument(hash: "np-manager", sentences: 9, progressSentence: sentence,
                                                    progressFraction: finished ? 1 : 0)
        rig.controller.load(document: document, content: content)
        return Harness(rig: rig, manager: manager, recorder: recorder, documents: documents,
                       document: document, navigation: ReaderNavigation(content: content, kind: .text))
    }

    /// Waits until the timeline has been pushed (navigation landed).
    private func waitForTimeline(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        let landed = await harness.rig.waitUntil(2) { self.duration(harness.recorder.last) != nil }
        XCTAssertTrue(landed, "the timeline never landed", file: file, line: line)
    }

    private func album(_ info: [String: Any]?) -> String? { info?[MPMediaItemPropertyAlbumTitle] as? String }
    private func title(_ info: [String: Any]?) -> String? { info?[MPMediaItemPropertyTitle] as? String }
    private func duration(_ info: [String: Any]?) -> Double? { info?[MPMediaItemPropertyPlaybackDuration] as? Double }
    private func elapsed(_ info: [String: Any]?) -> Double? { info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double }
    private func rate(_ info: [String: Any]?) -> Double? { info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double }

    // MARK: - What is pushed

    func testAPausedLoadPushesIdentityThenTheTimeline() async throws {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)

        let first = try XCTUnwrap(harness.recorder.pushes.first ?? nil, "the first push")
        XCTAssertEqual(title(first), harness.document.title)
        XCTAssertEqual(first[MPMediaItemPropertyArtist] as? String, "Aloud", "no author: the fallback")
        XCTAssertNil(album(first), "navigation is still building")
        XCTAssertNil(duration(first))
        XCTAssertNil(elapsed(first))
        XCTAssertEqual(rate(first), 0, "paused")

        let span = harness.navigation.scrubSpan(at: 4)
        let last = harness.recorder.last
        XCTAssertEqual(album(last), harness.navigation.positionLine(at: 4, rate: 1, documentTitle: harness.document.title).title)
        let words = harness.navigation.wordsRemaining(from: span.lowerBound, through: span.upperBound)
        XCTAssertEqual(try XCTUnwrap(duration(last)), Double(words) / 165 * 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(elapsed(last)), harness.navigation.secondsIntoSpan(of: 4, in: span, rate: 1),
                       accuracy: 1e-9)
        XCTAssertEqual(harness.manager.snapshot?.span, span)
        XCTAssertEqual(harness.manager.snapshot?.artist, "Aloud")
    }

    func testAPausedSeekAcrossAChapterPushesTheNewAlbumWithinASecond() async {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)
        let next = harness.navigation.positionLine(at: 6, rate: 1, documentTitle: harness.document.title).title
        XCTAssertNotEqual(album(harness.recorder.last), next)

        let start = MonotonicClock.now
        harness.rig.controller.seek(to: 6, andPlay: false)
        let landed = await harness.rig.waitUntil(1) { self.album(harness.recorder.last) == next }
        XCTAssertTrue(landed, "the album never became \(next)")
        XCTAssertLessThan(MonotonicClock.now - start, 1)
        XCTAssertEqual(harness.rig.controller.status, .paused)
        XCTAssertEqual(harness.manager.snapshot?.span, 6...8)
    }

    /// A pause publishes rate 0 at once and the time then holds still, so
    /// the lock screen stops where the voice did. Plays on the muted mixer.
    func testAPauseReadsRateZeroAndHoldsTheTime() async throws {
        let harness = makeHarness(at: 0, wordsPerSentence: 10)
        await waitForTimeline(harness)
        let mark = harness.rig.statuses.count
        harness.rig.controller.play()
        try await harness.rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(harness.rig.controller.mixerOutputVolume, 0, "muted")
        let playing = await harness.rig.waitUntil(1) { self.rate(harness.recorder.last) == 1 }
        XCTAssertTrue(playing, "never pushed the playing rate")

        let start = MonotonicClock.now
        harness.rig.controller.pause()
        let paused = await harness.rig.waitUntil(1) { self.rate(harness.recorder.last) == 0 }
        let took = MonotonicClock.now - start
        XCTAssertTrue(paused, "never pushed rate 0")
        XCTAssertLessThan(took, 0.1, "rate 0 took \(took) s")

        // Past the 120 ms pause ramp (a sentence boundary inside it may still
        // advance the cue once), then the time must not move.
        try await Task.sleep(nanoseconds: 200_000_000)
        let held = try XCTUnwrap(elapsed(harness.recorder.last))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)), held, accuracy: 0.001)
        XCTAssertEqual(rate(harness.recorder.last), 0)
        XCTAssertEqual(harness.rig.controller.status, .paused)
        XCTAssertEqual(harness.rig.controller.mixerOutputVolume, 0, "muted")
    }

    // MARK: - Scrubbing

    /// A scrub to the middle of chapter 2 lands on the sentence start nearest
    /// it, as a scrub jump: still paused, Undo jump offered, time republished.
    func testAScrubToHalfwayLandsOnASentenceStart() async throws {
        let harness = makeHarness(at: 3)
        await waitForTimeline(harness)
        let span = harness.navigation.scrubSpan(at: 3)
        let duration = try XCTUnwrap(harness.manager.snapshot?.duration)
        let expected = harness.navigation.sentence(atFraction: 0.5, in: span)
        XCTAssertNotEqual(expected, 3, "the fixture must move the cue")

        let landed = harness.manager.changePlaybackPosition(to: duration * 0.5)
        XCTAssertEqual(landed, expected)
        XCTAssertEqual(harness.rig.controller.currentSentence, expected)
        XCTAssertEqual(harness.rig.controller.status, .paused)
        XCTAssertNotNil(harness.rig.controller.undoableJump)
        XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)),
                       harness.navigation.secondsIntoSpan(of: expected, in: span, rate: 1), accuracy: 1e-9)
    }

    /// A scrub into the sentence already cued re-cues its start.
    func testAScrubToTheCurrentSentenceRecuesItsStart() async throws {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)
        let span = harness.navigation.scrubSpan(at: 4)
        let start = harness.navigation.secondsIntoSpan(of: 4, in: span, rate: 1)
        harness.rig.controller.frozenSentenceElapsed = 2

        let landed = harness.manager.changePlaybackPosition(to: start + 0.1)
        XCTAssertEqual(landed, 4)
        XCTAssertNil(harness.rig.controller.frozenSentenceElapsed, "re-cued at the start")
        XCTAssertNil(harness.rig.controller.undoableJump, "no jump to undo")
        XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)), start, accuracy: 1e-9)
    }

    /// At the end of the book (R24) a scrub onto the last sentence, the one
    /// the end is cued on, keeps the end: still .ended, so the colophon and
    /// Listen again stay and Listen again starts from the top instead of
    /// finishing the book (and saying "The End") a second time. The time is
    /// republished at the end, so the lock-screen scrubber snaps back.
    func testAScrubOntoTheLastSentenceAtTheEndKeepsTheEnd() async throws {
        let harness = makeHarness(at: 8, finished: true)
        XCTAssertTrue(harness.rig.controller.isAtEnd, "a reopened Finished book is at its end")
        await waitForTimeline(harness)
        let span = harness.navigation.scrubSpan(at: 8)
        let duration = try XCTUnwrap(harness.manager.snapshot?.duration)
        XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)), duration, accuracy: 1e-9)
        let lastStart = harness.navigation.secondsIntoSpan(of: 8, in: span, rate: 1)

        for position in [duration, lastStart + 0.1] {
            let pushes = harness.recorder.pushes.count
            let landed = harness.manager.changePlaybackPosition(to: position)

            XCTAssertEqual(landed, 8, "scrub to \(position)")
            XCTAssertEqual(harness.rig.controller.status, .ended, "scrub to \(position) left the end")
            XCTAssertTrue(harness.rig.controller.isAtEnd)
            XCTAssertEqual(harness.rig.controller.currentSentence, 8)
            XCTAssertNil(harness.rig.controller.undoableJump, "nothing moved, so nothing to undo")
            XCTAssertGreaterThan(harness.recorder.pushes.count, pushes, "republished")
            XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)), duration, accuracy: 1e-9,
                           "the scrubber snaps back to the end")
            XCTAssertEqual(rate(harness.recorder.last), 0)
        }
    }

    /// A scrub away from the end is a scrub jump from it: Undo jump goes
    /// back to the end itself, never to a paused last sentence.
    func testAScrubAwayFromTheEndOffersUndoBackToIt() async throws {
        let harness = makeHarness(at: 8, finished: true)
        await waitForTimeline(harness)

        let landed = harness.manager.changePlaybackPosition(to: 0)
        XCTAssertEqual(landed, 6, "the last chapter's first sentence")
        XCTAssertEqual(harness.rig.controller.status, .paused)
        XCTAssertFalse(harness.rig.controller.isAtEnd)
        let offer = try XCTUnwrap(harness.rig.controller.undoableJump)
        XCTAssertEqual(offer.fromStatus, .ended)
        XCTAssertEqual(offer.fromSentence, 8)

        harness.rig.controller.undoJump()
        XCTAssertEqual(harness.rig.controller.status, .ended)
        XCTAssertTrue(harness.rig.controller.isAtEnd)
        XCTAssertEqual(harness.rig.controller.currentSentence, 8)
    }

    /// A lock-screen skip back after 5 s heard restarts the sentence, which
    /// no source reports, so the manager republishes it itself.
    func testASkipBackRepublishesTheSentenceStart() async throws {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)
        let span = harness.navigation.scrubSpan(at: 4)
        harness.rig.controller.frozenSentenceElapsed = 5
        let pushes = harness.recorder.pushes.count

        harness.manager.handle(.skipBackward)
        XCTAssertEqual(harness.rig.controller.currentSentence, 4)
        XCTAssertGreaterThan(harness.recorder.pushes.count, pushes, "republished")
        XCTAssertEqual(try XCTUnwrap(elapsed(harness.recorder.last)),
                       harness.navigation.secondsIntoSpan(of: 4, in: span, rate: 1), accuracy: 1e-9)
    }

    func testNoScrubWithoutABookOrATimeline() async {
        // Nothing loaded.
        let idle = PlaybackTestRig()
        let manager = NowPlayingManager(publish: { _ in }, renderArtwork: { _ in nil })
        manager.observe(playback: idle.controller)
        XCTAssertNil(manager.changePlaybackPosition(to: 10))

        // Loaded, before anything is pushed or built.
        let harness = makeHarness(at: 4)
        XCTAssertNil(harness.manager.changePlaybackPosition(to: 1))
        XCTAssertEqual(harness.rig.controller.currentSentence, 4)
    }

    func testUnloadClearsWhatIsPlaying() async {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)
        harness.rig.controller.unload()
        let cleared = await harness.rig.waitUntil(1) {
            harness.recorder.pushes.last.map { $0 == nil } ?? false
        }
        XCTAssertTrue(cleared, "never pushed nil")
        XCTAssertNil(harness.manager.snapshot)
        XCTAssertNil(harness.manager.changePlaybackPosition(to: 1))
    }

    // MARK: - Remote Play

    /// A car sends Play on connect while the book is already playing, in a
    /// sleep timer's fade: nothing happens. The sentence is never cut and
    /// restarted, and the fade carries on (a restart's ramp-in cancelled it
    /// and brought the voice back at full level).
    func testRemotePlayWhilePlayingKeepsTheSentenceAndTheFade() async throws {
        let rig = PlaybackTestRig(clipDuration: 5)
        rig.loadDefault(at: 2)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        _ = await rig.waitUntil(0.3) { false }   // past the 120 ms ramp-in
        rig.controller.rampOutputVolume(to: 0, over: 5)   // what SleepTimer's fade runs
        _ = await rig.waitUntil(0.2) { false }
        let fadeLevel = try XCTUnwrap(rig.volumes().last?.value)
        XCTAssertLessThan(fadeLevel, 1, "the fade is under way")
        let statusMark = rig.statuses.count
        let eventMark = rig.events.count
        let plays = rig.controller.userPlayAction

        XCTAssertNil(NowPlayingManager.perform(.play, on: rig.controller))
        _ = await rig.waitUntil(0.3) { false }

        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.currentSentence, 2, "the sentence carries on")
        XCTAssertEqual(Array(rig.statuses[statusMark...]), [], "never restarted")
        XCTAssertFalse(rig.events[eventMark...].contains(.stopped), "the schedule was never flushed")
        XCTAssertEqual(rig.controller.userPlayAction, plays, "not a Play")
        XCTAssertTrue(rig.controller.isRampingVolume, "the fade is still running")
        XCTAssertLessThan(try XCTUnwrap(rig.volumes().last?.value), fadeLevel, "and still going down")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0, "muted")
    }

    /// Play over a voice sample spoken over the pause is still a Play: the
    /// sample carries on as the book (R8).
    func testRemotePlayOverAVoiceSampleContinuesItAsTheBook() {
        let rig = PlaybackTestRig(clipDuration: 5)
        rig.loadDefault(at: 3)
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the sample is speaking")
        XCTAssertFalse(rig.controller.isListenerPlaying)
        let plays = rig.controller.userPlayAction

        NowPlayingManager.perform(.play, on: rig.controller)

        XCTAssertEqual(rig.controller.userPlayAction, plays + 1, "a Play")
        XCTAssertEqual(rig.controller.currentSentence, 3)
        // A host whose audio engine can't start errors the start; the counter
        // above is the check there.
        guard !rig.statuses.contains(.error) else { return }
        XCTAssertTrue(rig.controller.isListenerPlaying, "the book plays, not a sample")
    }

    /// A book heard to its end stays loaded at its end (R24). A car's Play
    /// on connect, or Play/Pause from AirPods or the lock screen, isn't
    /// Listen again: nothing restarts, and the book keeps its end, its
    /// Finished and its place. Listen again is in the app.
    func testRemotePlayAtTheEndNeverRestartsTheBook() {
        for command in [NowPlayingManager.RemoteTransportCommand.play, .togglePlayPause] {
            let harness = makeHarness(at: 8, finished: true)
            XCTAssertTrue(harness.rig.controller.isAtEnd, "a reopened Finished book is at its end")
            let plays = harness.rig.controller.userPlayAction
            let progressMark = harness.rig.progress.count

            harness.manager.handle(command)

            XCTAssertEqual(harness.rig.controller.status, .ended, "\(command) left the end")
            XCTAssertTrue(harness.rig.controller.isAtEnd)
            XCTAssertEqual(harness.rig.controller.currentSentence, 8, "\(command) restarted the book")
            XCTAssertEqual(harness.rig.controller.userPlayAction, plays, "\(command) was a Play")
            XCTAssertFalse(harness.rig.progress[progressMark...].contains { $0.sentence == 0 },
                           "\(command) saved the start as the place")
        }
    }

    // MARK: - Remote transport with no book loaded

    /// With nothing loaded, the first Play/Pause starts the Continue card's
    /// load (`onPlayWithNoBook`). A Pause, or a second Play/Pause, before it
    /// lands stops it, as a second tap on the card's circle does: the book
    /// never starts speaking after the listener pressed Pause.
    func testAPauseOrASecondPressStopsTheContinueLoad() async {
        for command in [NowPlayingManager.RemoteTransportCommand.pause, .togglePlayPause] {
            let rig = PlaybackTestRig()
            let manager = NowPlayingManager(publish: { _ in }, renderArtwork: { _ in nil })
            manager.observe(playback: rig.controller)
            let continuePlayback = ContinuePlayback()
            manager.continuePlayback = continuePlayback
            var continued = 0
            manager.onPlayWithNoBook = { continued += 1 }
            let book = rig.document, content = rig.content
            // The first press's load, still extracting.
            continuePlayback.toggle(book, playback: rig.controller, loader: {
                try await Task.sleep(nanoseconds: 200_000_000)
                return (book, content)
            })
            XCTAssertEqual(continuePlayback.pendingDocumentID, book.id)

            manager.handle(command)

            XCTAssertNil(continuePlayback.pendingDocumentID, "\(command) left the load running")
            XCTAssertEqual(continued, 0, "\(command) continued the book")
            _ = await rig.waitUntil(0.6) { rig.controller.document != nil }
            XCTAssertNil(rig.controller.document, "the load landed after \(command)")
            XCTAssertFalse(rig.statuses.contains(.playing), "\(command): the book spoke")
        }
    }

    /// Play while that load runs joins it (Continue's own rule): nothing is
    /// stopped. Pause and Play/Pause stop a load only with no book loaded.
    func testRemotePlayJoinsTheContinueLoad() {
        let rig = PlaybackTestRig()
        let manager = NowPlayingManager(publish: { _ in }, renderArtwork: { _ in nil })
        manager.observe(playback: rig.controller)
        let continuePlayback = ContinuePlayback()
        manager.continuePlayback = continuePlayback
        var continued = 0
        manager.onPlayWithNoBook = { continued += 1 }
        let book = rig.document, content = rig.content
        continuePlayback.toggle(book, playback: rig.controller, loader: {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return (book, content)
        })

        manager.handle(.play)

        XCTAssertEqual(continued, 1, "Play continues the book")
        XCTAssertEqual(continuePlayback.pendingDocumentID, book.id, "the load runs on")
        continuePlayback.cancel()

        for command in NowPlayingManager.RemoteTransportCommand.allCases {
            let stops = command == .pause || command == .togglePlayPause
            XCTAssertEqual(NowPlayingManager.stopsLoadWithNoBook(command, hasBook: false, loading: true), stops,
                           "\(command)")
            XCTAssertFalse(NowPlayingManager.stopsLoadWithNoBook(command, hasBook: false, loading: false))
            XCTAssertFalse(NowPlayingManager.stopsLoadWithNoBook(command, hasBook: true, loading: true),
                           "a loaded book takes its own \(command)")
        }
    }

    /// With no book, only Pause and Play/Pause cut a voice sample (L028);
    /// Play still continues the last book, and a loaded book takes its own.
    func testOnlyAPauseCutsTheNoBookSample() {
        for command in NowPlayingManager.RemoteTransportCommand.allCases {
            let cuts = command == .pause || command == .togglePlayPause
            XCTAssertEqual(NowPlayingManager.cutsSampleWithNoBook(command, hasBook: false, speakingSample: true),
                           cuts, "\(command)")
            XCTAssertFalse(NowPlayingManager.cutsSampleWithNoBook(command, hasBook: false, speakingSample: false))
            XCTAssertFalse(NowPlayingManager.cutsSampleWithNoBook(command, hasBook: true, speakingSample: true),
                           "a loaded book takes its own \(command)")
        }
    }

    // MARK: - Library changes

    /// A rename republishes the title and renders the art once more; a
    /// progress change renders nothing.
    func testARenameRepublishesAndRerendersButProgressDoesNot() async throws {
        let harness = makeHarness(at: 4)
        await waitForTimeline(harness)
        let rendered = await harness.rig.waitUntil(1) { harness.recorder.renders == 1 }
        XCTAssertTrue(rendered, "the art was rendered \(harness.recorder.renders) times on load")

        var progressed = harness.document
        progressed.progressSentence = 5
        progressed.progressFraction = 0.6
        harness.documents.send([progressed])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(harness.recorder.renders, 1, "progress renders nothing")

        var renamed = progressed
        renamed.title = "Renamed"
        harness.documents.send([renamed])
        let republished = await harness.rig.waitUntil(1) { self.title(harness.recorder.last) == "Renamed" }
        XCTAssertTrue(republished, "the new title was never pushed")
        let rerendered = await harness.rig.waitUntil(1) { harness.recorder.renders == 2 }
        XCTAssertTrue(rerendered, "the renamed art was never rendered")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(harness.recorder.renders, 2, "exactly once more")
        XCTAssertEqual(harness.manager.snapshot?.title, "Renamed")
    }

    // MARK: - Muted processes (S10)

    /// The iPhone takes the system's Now Playing even in a muted process, as
    /// it always has; only a muted process on a platform that says so stays
    /// off it.
    func testOnlyAMutedProcessOnAQuietPlatformStaysOffTheSystem() {
        let table: [(muted: Bool, publishesWhenMuted: Bool, takes: Bool)] = [
            (false, false, true), (false, true, true), (true, true, true), (true, false, false),
        ]
        for row in table {
            let label = "muted \(row.muted), publishes when muted \(row.publishesWhenMuted)"
            XCTAssertEqual(NowPlayingManager.takesSystemNowPlaying(outputMuted: row.muted,
                                                                   publishesWhenMuted: row.publishesWhenMuted),
                           row.takes, label)
            // Built, never observed: nothing is pushed.
            let manager = NowPlayingManager(renderArtwork: { _ in nil }, outputMuted: row.muted,
                                            publishesWhenMuted: row.publishesWhenMuted)
            XCTAssertEqual(manager.takesSystemNowPlaying, row.takes, label)
        }
        // The defaults read the platform, so this holds on both hosts; the
        // iPhone's `true` is pinned by PlatformSeamTests.
        XCTAssertTrue(UITestHooks.muteAudio, "this hosted run is muted")
        XCTAssertEqual(NowPlayingManager(renderArtwork: { _ in nil }).takesSystemNowPlaying,
                       PlatformNowPlaying.publishesWhenMuted,
                       "the defaults follow the platform: the iPhone still takes the system's Now Playing")
    }

    /// A manager kept off the system pushes into nothing: its snapshot
    /// follows the book, and the system's info never names it.
    func testAManagerKeptOffTheSystemDropsEveryPush() async {
        let rig = PlaybackTestRig()
        let manager = NowPlayingManager(renderArtwork: { _ in nil }, outputMuted: true, publishesWhenMuted: false)
        manager.observe(playback: rig.controller)
        let hash = "np-muted-\(UUID().uuidString)"
        let document = PlaybackTestRig.makeDocument(hash: hash, sentences: 3, progressSentence: 1)
        rig.controller.load(document: document,
                            content: PlaybackTestRig.makeContent(hash: hash, count: 3, wordsPerSentence: 4))
        let refreshed = await rig.waitUntil(2) { manager.snapshot?.duration != nil }
        XCTAssertTrue(refreshed, "the manager never refreshed")
        XCTAssertEqual(manager.snapshot?.title, document.title)
        let published = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        XCTAssertNotEqual(published, document.title, "a muted push reached the system")
    }

    /// The transport state set beside the info (on the Mac; a no-op on the
    /// iPhone) reads the published rate, the same signal the lock screen
    /// reads: stopped with nothing published, playing while the rate moves
    /// (a buffering sentence included, L025: the app's own button reads
    /// Pause then), paused otherwise, the end of the book included.
    func testThePublishedStateFollowsThePublishedRate() {
        XCTAssertEqual(NowPlayingManager.state(for: nil), .stopped)
        let table: [(status: PlayerStatus, state: NowPlayingState)] = [
            (.playing, .playing), (.paused, .paused), (.ended, .paused),
            (.buffering, .playing), (.idle, .paused), (.error, .paused),
        ]
        for row in table {
            let info = NowPlayingSnapshot(title: "T", author: nil, navigation: nil, sentence: 0,
                                          status: row.status, rate: 1.25, sentenceElapsed: 0).nowPlayingInfo
            XCTAssertEqual(NowPlayingManager.state(for: info), row.state, "\(row.status)")
        }
    }
}
