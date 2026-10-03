import XCTest
@testable import Aloud

/// R24 in the controller: one "at the end" state (`isAtEnd`), a Finished
/// book reopening there and any other keeping its place (the one Finished
/// rule, with its time slack, and its one exception: an unattended stop (R11)
/// still on record short of a stored 1.0 holds the book at that stop's
/// sentence), Listen again starting over, and the one success haptic plus
/// "The End" announcement for a book heard to its own end, never for Undo, a
/// voice sample or a reopen.
///
/// All silent: the muted PlaybackTestRig over stub engines returning silence;
/// the haptic goes to a recorder (`emitHaptic`), never TransportHaptics. A
/// test whose audio engine can't start in the host is skipped, not failed.
@MainActor
final class BookEndTests: XCTestCase {

    private final class Haptics {
        var played: [TransportHaptic] = []
    }

    private func record(_ rig: PlaybackTestRig) -> Haptics {
        let haptics = Haptics()
        rig.controller.emitHaptic = { haptics.played.append($0) }
        return haptics
    }

    private func theEnds(_ rig: PlaybackTestRig) -> Int {
        rig.announcements.filter { $0 == ColophonCopy.theEnd }.count
    }

    /// The rig's 4-sentence book stored as Finished at its last sentence.
    private func openFinished(_ rig: PlaybackTestRig, fraction: Double = 1.0) {
        let count = rig.content.sentences.count
        let document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: count,
                                                    progressSentence: count - 1, progressFraction: fraction)
        rig.controller.load(document: document, content: rig.content)
    }

    /// Plays the rig's default book from its last sentence to the end.
    private func playToTheEnd(_ rig: PlaybackTestRig) async throws {
        rig.loadDefault(at: rig.content.sentences.count - 1)
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let ended = await rig.waitUntil(8) { rig.controller.status == .ended }
        XCTAssertTrue(ended, "the book reaches its end")
    }

    // MARK: - Reopening a Finished book

    func testAFinishedBookReopensAtItsEnd() {
        let rig = PlaybackTestRig(sentences: 4)
        let haptics = record(rig)
        openFinished(rig)

        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(Array(rig.statuses.suffix(2)), [.paused, .ended],
                       "the outgoing book's stop, then the end")

        rig.controller.startAutoplay()
        XCTAssertEqual(rig.controller.status, .ended, "a Finished book never autoplays")
        XCTAssertEqual(rig.controller.userPlayAction, 0)
        XCTAssertEqual(haptics.played, [], "a reopen is no end heard")
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertTrue(rig.progress.allSatisfy { $0.fraction >= LibraryDocument.finishedThreshold },
                      "\(rig.progress.map(\.fraction))")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A long classic 1,190 sentences into 1,200 (0.9917, past the 0.99
    /// threshold), as a sleep timer leaves it: 594,000 words is 60 hours at
    /// 1×, so the last 10 sentences are half an hour.
    private func longClassicNearItsEnd() -> LibraryDocument {
        var document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 1200,
                                                    progressSentence: 1190, progressFraction: 1190.0 / 1200)
        document.wordCount = 594_000
        return document
    }

    /// Past 0.99 with half an hour left is not Finished: the card reads the
    /// time left, and the book reopens paused at its saved sentence, never
    /// at the colophon. The open writes back exactly the stored sentence and
    /// fraction, so nothing on disk moves until the listener acts. In
    /// progress, it opens speaking from there (R4), as its card promises,
    /// rather than starting over.
    func testALongBookPastTheThresholdWithMinutesLeftIsNotFinished() {
        let rig = PlaybackTestRig(sentences: 1200)
        let haptics = record(rig)
        let document = longClassicNearItsEnd()
        XCTAssertEqual(document.progressFraction, 0.9917, accuracy: 0.0001)
        XCTAssertEqual(document.estimatedSecondsRemaining(rate: 1) ?? 0, 30 * 60, accuracy: 1)
        XCTAssertFalse(document.isFinished)
        XCTAssertFalse(PlaybackController.reopensAtItsEnd(document, stop: nil))
        XCTAssertEqual(document.listeningSubtitle(rate: 1), "30 min left")
        XCTAssertEqual(document.spokenListeningSubtitle(rate: 1), "30 minutes left")

        rig.controller.load(document: document, content: rig.content)

        XCTAssertEqual(rig.controller.currentSentence, 1190, "at its saved sentence, not the last")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertFalse(rig.controller.isAtEnd, "no colophon: half an hour is left")
        let writes = rig.progress.filter { $0.documentID == document.id }
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { $0.sentence == 1190 && $0.fraction == document.progressFraction },
                      "\(writes.map { ($0.sentence, $0.fraction) })")

        rig.controller.startAutoplay()
        XCTAssertTrue(rig.controller.isActive, "in progress, so it autoplays")
        XCTAssertEqual(rig.controller.currentSentence, 1190, "reads on, not Listen again")
        XCTAssertEqual(rig.controller.userPlayAction, 1)
        rig.controller.pause(rampsOut: false)
        XCTAssertEqual(haptics.played, [])
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Fed the record each open leaves behind, the place holds on every
    /// reopen (a cue that moved it would show up on the second).
    func testALongBookPastTheThresholdKeepsItsPlaceOnEveryReopen() {
        let rig = PlaybackTestRig(sentences: 1200)
        let original = longClassicNearItsEnd()
        var stored = original
        for open in 1...3 {
            rig.controller.load(document: stored, content: rig.content)
            XCTAssertEqual(rig.controller.status, .paused, "open \(open)")
            if let saved = rig.progress.last(where: { $0.documentID == stored.id }) {
                stored.progressSentence = saved.sentence
                stored.progressFraction = saved.fraction
            }
            XCTAssertEqual(stored.progressSentence, 1190, "open \(open)")
            XCTAssertEqual(stored.progressFraction, original.progressFraction, "open \(open)")
            XCTAssertFalse(stored.isFinished, "open \(open)")
            rig.controller.unload()
        }
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// An article paused on its last sentence, 0.995 of the way with seconds
    /// left (3,300 words is 20 minutes at 1×), is Finished: its card says
    /// so, and it reopens at the colophon (.ended), never autoplays, and
    /// keeps its stored fraction on every reopen (`finishedCue`), so it
    /// never drifts back to in progress.
    func testAShortBookPastTheThresholdWithSecondsLeftIsFinished() {
        let rig = PlaybackTestRig(sentences: 200)
        let haptics = record(rig)
        var stored = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 200,
                                                  progressSentence: 199, progressFraction: 0.995)
        stored.wordCount = 3_300
        XCTAssertEqual(stored.estimatedSecondsRemaining(rate: 1) ?? -1, 6, accuracy: 0.01)
        XCTAssertTrue(stored.isFinished)
        XCTAssertTrue(PlaybackController.reopensAtItsEnd(stored, stop: nil))
        XCTAssertEqual(stored.listeningSubtitle(rate: 1), "Finished")
        XCTAssertEqual(stored.spokenListeningSubtitle(rate: 1), "finished")

        for open in 1...3 {
            rig.controller.load(document: stored, content: rig.content)
            XCTAssertEqual(rig.controller.status, .ended, "open \(open): at the colophon")
            XCTAssertTrue(rig.controller.isAtEnd, "open \(open)")
            XCTAssertEqual(rig.controller.currentSentence, 199, "open \(open)")
            rig.controller.startAutoplay()
            XCTAssertEqual(rig.controller.status, .ended, "open \(open): a Finished book never autoplays")
            if let saved = rig.progress.last(where: { $0.documentID == stored.id }) {
                stored.progressSentence = saved.sentence
                stored.progressFraction = saved.fraction
            }
            XCTAssertEqual(stored.progressSentence, 199, "open \(open)")
            XCTAssertEqual(stored.progressFraction, 0.995, "open \(open)")
            XCTAssertTrue(stored.isFinished, "open \(open)")
            rig.controller.unload()
        }
        XCTAssertEqual(rig.controller.userPlayAction, 0)
        XCTAssertEqual(haptics.played, [], "a reopen is no end heard")
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// With no word count there is no time to weigh: 0.99 alone is
    /// Finished, and the book reopens at the colophon on its last sentence,
    /// holding its stored fraction rather than (n-1)/n by position.
    func testAnUnmeasuredBookAtTheThresholdIsFinished() {
        let rig = PlaybackTestRig(sentences: 4)
        let document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 4,
                                                    progressSentence: 1, progressFraction: 0.99)
        XCTAssertEqual(document.wordCount, 0)
        XCTAssertNil(document.estimatedSecondsRemaining(rate: 1))
        XCTAssertTrue(document.isFinished)
        XCTAssertEqual(document.listeningSubtitle(rate: 1), "Finished")

        rig.controller.load(document: document, content: rig.content)
        rig.controller.startAutoplay()

        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        let writes = rig.progress.filter { $0.documentID == document.id }
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { $0.fraction == 0.99 }, "\(writes.map(\.fraction))")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A book that really ended stores 1.0, Finished at any length, and
    /// reopens at the end, on the last sentence, wherever its sentence was
    /// saved (Mark as finished on an unmeasured book saves sentence 0).
    func testAnEndedBookReopensOnItsLastSentenceWhereverItWasSaved() {
        let rig = PlaybackTestRig(sentences: 200)
        let document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 200,
                                                    progressSentence: 0, progressFraction: 1.0)
        rig.controller.load(document: document, content: rig.content)

        XCTAssertEqual(rig.controller.currentSentence, 199)
        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertTrue(rig.controller.isAtEnd)
        let writes = rig.progress.filter { $0.documentID == document.id }
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { $0.sentence == 199 && $0.fraction == 1.0 },
                      "\(writes.map { ($0.sentence, $0.fraction) })")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// The reopen at the colophon is the Finished rule, never a second one:
    /// a stored 1.0 always, 0.99 with a minute or less left at 1× (or no
    /// length to weigh), and never below 0.99 however little is left. Its one
    /// exception: with an unattended stop of any reason on record, only a
    /// stored 1.0 opens at the end; anything short of it opens at the stop.
    func testABookReopensAtItsEndExactlyWhenFinishedUnlessAStopHoldsIt() {
        let cases: [(fraction: Double, words: Int, atEnd: Bool)] = [
            (0.98, 0, false), (0.989, 100, false),
            (LibraryDocument.finishedThreshold, 0, true), (0.9999, 0, true),
            (LibraryDocument.finishedThreshold, 3_300, true),
            (1190.0 / 1200, 594_000, false), (LibraryDocument.finishedThreshold, 48_208, false),
            (1.0, 0, true), (1.0, 594_000, true),
        ]
        for (fraction, words, atEnd) in cases {
            var document = PlaybackTestRig.makeDocument(hash: "rig-hash", sentences: 200,
                                                        progressSentence: 199, progressFraction: fraction)
            document.wordCount = words
            XCTAssertEqual(PlaybackController.reopensAtItsEnd(document, stop: nil), atEnd,
                           "progress \(fraction), \(words) words")
            XCTAssertEqual(PlaybackController.reopensAtItsEnd(document, stop: nil), document.isFinished,
                           "one rule: progress \(fraction), \(words) words")
            for reason in StopReason.allCases {
                XCTAssertEqual(PlaybackController.reopensAtItsEnd(document, stop: reason), fraction >= 1,
                               "\(reason) on record: progress \(fraction), \(words) words")
            }
        }
    }

    // MARK: - A stop in a book's last minute (R11)

    /// The next launch: a new controller over the rig's anchor and stop stores.
    private func relaunch(_ rig: PlaybackTestRig) -> PlaybackController {
        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let controller = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlatformAudioOutput.makeMonitor(),
                                            anchorStore: rig.anchorStore,
                                            stopStore: rig.stopStore,
                                            outputMuted: true)
        controller.isAppActive = { true }
        return controller
    }

    /// The rig's 150-sentence article (450 words, under 3 minutes) saved on
    /// its last sentence: 0.9933 with about a second left, so its card reads
    /// Finished.
    private func articleSavedOnItsLastSentence(_ rig: PlaybackTestRig, fraction: Double = 149.0 / 150) -> LibraryDocument {
        var document = rig.document
        document.progressSentence = 149
        document.progressFraction = fraction
        document.wordCount = 450
        return document
    }

    /// iOS closed Aloud while it read the article's last sentence. The
    /// record reads Finished, but the stop's line promises one tap resumes
    /// there, so the book reopens paused at that sentence (not the colophon,
    /// whose Listen again would start it over), never autoplays, and Play
    /// rewinds from it after the rest.
    func testAStopInTheLastMinuteReopensAtItsSentenceAndOneTapResumesThere() {
        let rig = PlaybackTestRig(sentences: 150)
        rig.stopStore.markLive(LiveSession(documentID: rig.document.id, sentenceIndex: 149,
                                           wallClock: Date(timeIntervalSinceNow: -600)))
        let next = relaunch(rig)
        let document = articleSavedOnItsLastSentence(rig)
        XCTAssertTrue(document.isFinished, "the card reads Finished")
        XCTAssertEqual(next.stopReason(for: document.id), .closedByIOS)

        next.load(document: document, content: rig.content)

        XCTAssertEqual(next.status, .paused, "held at the stop, not the colophon")
        XCTAssertFalse(next.isAtEnd)
        XCTAssertEqual(next.currentSentence, 149)
        XCTAssertEqual(next.stopReason(for: document.id), .closedByIOS, "the stop's line still shows")
        XCTAssertFalse(next.opensPlaying(document), "a Finished record never autoplays")
        next.startAutoplay()
        XCTAssertEqual(next.status, .paused)
        XCTAssertEqual(next.userPlayAction, 0)

        next.play()
        XCTAssertTrue(next.isActive)
        XCTAssertEqual(next.currentSentence, 147, "a 10-minute rest backs up 2; never Listen again from 0")
        XCTAssertEqual(next.notice, .backedUp(sentences: 2))
        XCTAssertNil(next.stopped)
        next.pause(rampsOut: false)
        XCTAssertEqual(next.mixerOutputVolume, 0)
    }

    /// Any reason holds the book, a sleep stop left overnight included, but
    /// only short of a stored 1.0: a book that really ended (a natural end,
    /// Mark as finished) opens at the colophon whatever stop is on record.
    func testAStopHoldsOnlyABookShortOfAStoredEnd() {
        let rig = PlaybackTestRig(sentences: 150)
        rig.stopStore.save(PlaybackStop(reason: .sleepTimer, documentID: rig.document.id))

        let held = relaunch(rig)
        held.load(document: articleSavedOnItsLastSentence(rig), content: rig.content)
        XCTAssertEqual(held.status, .paused)
        XCTAssertEqual(held.currentSentence, 149)
        held.play()
        XCTAssertEqual(held.currentSentence, 149, "Play resumes at the stop")
        held.pause(rampsOut: false)

        rig.stopStore.save(PlaybackStop(reason: .sleepTimer, documentID: rig.document.id))
        let ended = relaunch(rig)
        let document = articleSavedOnItsLastSentence(rig, fraction: 1.0)
        XCTAssertEqual(ended.stopReason(for: document.id), .sleepTimer)
        ended.load(document: document, content: rig.content)
        XCTAssertEqual(ended.status, .ended, "a stored 1.0 is at its end")
        XCTAssertTrue(ended.isAtEnd)
        XCTAssertEqual(ended.currentSentence, 149)
        XCTAssertEqual(held.mixerOutputVolume, 0)
        XCTAssertEqual(ended.mixerOutputVolume, 0)
    }

    /// Listen again: Play from the reopened end starts at the top, with no
    /// resume rewind even after a long rest, and leaves the end.
    func testListenAgainStartsFromTheFirstSentence() {
        let rig = PlaybackTestRig(sentences: 4)
        let haptics = record(rig)
        // A rest of two hours on the book's last sentence, as a relaunch
        // finds it on disk.
        rig.anchorStore.save(ResumeAnchor(documentID: rig.document.id, sentenceIndex: 3,
                                          wallClock: Date().addingTimeInterval(-2 * 3600), monotonic: nil))
        var stored = rig.document
        stored.progressSentence = 3
        stored.progressFraction = 1.0
        rig.controller.load(document: stored, content: rig.content)
        XCTAssertEqual(rig.controller.status, .ended)

        rig.controller.play()

        XCTAssertEqual(rig.controller.currentSentence, 0, "from the top")
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.userPlayAction, 1)
        XCTAssertFalse(rig.controller.isAtEnd)
        if case .backedUp = rig.controller.notice {
            XCTFail("no resume rewind from the end")
        }
        XCTAssertEqual(haptics.played, [], "the Play button's own tap plays .play, not the controller")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Back 15 at the end restarts the last sentence (all of it was heard),
    /// paused: the end is left, and the book stays Finished.
    func testSkippingBackFromTheEndLeavesIt() {
        // 20 words: the last sentence is over 3 s, so Back restarts it.
        let rig = PlaybackTestRig(sentences: 4, wordsPerSentence: 20)
        openFinished(rig)

        rig.controller.skip(seconds: -PlaybackController.skipInterval)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertFalse(rig.controller.isAtEnd)
        XCTAssertTrue(rig.progress.allSatisfy { $0.fraction >= LibraryDocument.finishedThreshold },
                      "\(rig.progress.map(\.fraction))")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - A natural end

    func testANaturalEndPlaysOneSuccessAndAnnouncesTheEnd() async throws {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
        let haptics = record(rig)
        try await playToTheEnd(rig)

        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(haptics.played, [.finished])
        XCTAssertEqual(theEnds(rig), 1)
        XCTAssertEqual(rig.progress.last?.fraction, 1.0)

        // Nothing later repeats it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(haptics.played, [.finished])
        XCTAssertEqual(theEnds(rig), 1)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testNoHapticWhileTheAppIsInactive() async throws {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
        let haptics = record(rig)
        rig.appActive = false
        try await playToTheEnd(rig)

        XCTAssertTrue(rig.controller.isAtEnd, "the end is still the end")
        XCTAssertEqual(haptics.played, [])
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Below full level (the sleep timer's End-of-book fade) the end was
    /// not heard as an end: no haptic, no announcement.
    func testNoHapticUnderAFade() async throws {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
        let haptics = record(rig)
        rig.loadDefault(at: 3)
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        rig.controller.rampOutputVolume(to: 0.2, over: 0)
        let ended = await rig.waitUntil(8) { rig.controller.status == .ended }
        XCTAssertTrue(ended)

        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(haptics.played, [])
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    // MARK: - Never twice, never for a sample or Undo

    /// A voice picked at the reopened end speaks the last sentence once and
    /// hands the end back: the colophon never leaves, nothing celebrates.
    func testASampleOverTheEndKeepsTheEndAndPlaysNoHaptic() async throws {
        let rig = PlaybackTestRig(sentences: 4)
        let haptics = record(rig)
        openFinished(rig)
        let mark = rig.statuses.count

        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(rig.controller.isActive, "the sample speaks")
        XCTAssertTrue(rig.controller.isAtEnd)
        var leftTheEnd = false
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let back = await rig.waitUntil(5) {
            if !rig.controller.isAtEnd { leftTheEnd = true }
            return rig.controller.status == .ended
        }
        XCTAssertTrue(back, "the sample returns to the end")
        XCTAssertFalse(leftTheEnd, "isAtEnd holds throughout the sample")
        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(haptics.played, [])
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A pause over that sample hands the end back at once; the sample's
    /// clip may then run out inside the 120 ms ramp, which is no second end.
    func testPausingASampleOverTheEndHandsItBackOnce() async throws {
        let rig = PlaybackTestRig(sentences: 4)
        let haptics = record(rig)
        openFinished(rig)
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let progressMark = rig.progress.count

        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .ended, "back to the end at once")
        let pausedAt = rig.statuses.count
        try? await Task.sleep(nanoseconds: 500_000_000)   // the ramp and the clip's end

        XCTAssertEqual(Array(rig.statuses[pausedAt...]), [], "the end is not entered again")
        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(haptics.played, [])
        XCTAssertEqual(theEnds(rig), 0)
        XCTAssertTrue(rig.progress[progressMark...].allSatisfy { $0.fraction >= LibraryDocument.finishedThreshold })
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// A jump away from a natural end and Undo back: at the end again, and
    /// the success was played once, for the real end.
    func testUndoBackToTheEndPlaysNoSecondHaptic() async throws {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 1)
        let haptics = record(rig)
        try await playToTheEnd(rig)
        XCTAssertEqual(haptics.played, [.finished])

        rig.controller.jump(to: 0, origin: .scrub)
        XCTAssertFalse(rig.controller.isAtEnd)
        XCTAssertNotNil(rig.controller.undoableJump)
        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertTrue(rig.controller.isAtEnd)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(haptics.played, [.finished], "Undo is no second end")
        XCTAssertEqual(theEnds(rig), 1)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }
}
