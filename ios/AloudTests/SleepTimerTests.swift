import Combine
import XCTest
@testable import Aloud

/// R19's sleep timer: the menu order and its memory, the titles, the chip,
/// the landing and chapter rules, then the timer driving a controller.
///
/// The integration tests use the frozen silent rig (muted, on its own
/// defaults suite) and a timer on a fresh suite with its clock scaled down:
/// a 15 "minute" timer lasts 3 s and fades over its last second, with
/// quarter-second sentences. Levels are read through the onAudioEdge seam
/// while the mixer stays at 0. A test whose audio engine can't start is
/// skipped.
@MainActor
final class SleepTimerTests: XCTestCase {

    private static let fast = SleepTimer.Timing(secondsPerMinute: 0.2, fade: 1, landingWindow: 0.4, tick: 0.05)
    private static let standard = SleepTimer.standardMinuteChoices

    // MARK: - Menu

    func testMenuOrderPutsTheMostRecentFirstAndOffLast() {
        XCTAssertEqual(SleepTimer.orderedOptions(lastUsed: nil, minuteChoices: Self.standard),
                       [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter, .off])
        XCTAssertEqual(SleepTimer.orderedOptions(lastUsed: .minutes(45), minuteChoices: Self.standard),
                       [.minutes(45), .minutes(15), .minutes(30), .minutes(60), .endOfChapter, .off])
        XCTAssertEqual(SleepTimer.orderedOptions(lastUsed: .endOfChapter, minuteChoices: Self.standard),
                       [.endOfChapter, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .off])
        // A remembered duration this menu doesn't offer (the UI test's 1
        // minute) leaves the order alone.
        XCTAssertEqual(SleepTimer.orderedOptions(lastUsed: .minutes(1), minuteChoices: Self.standard),
                       [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter, .off])
        XCTAssertEqual(SleepTimer.orderedOptions(lastUsed: nil, minuteChoices: [1] + Self.standard).first,
                       .minutes(1))
    }

    func testTheMostRecentPickPersistsAcrossInstances() {
        let defaults = PlaybackTestRig.freshDefaults()
        let first = SleepTimer(defaults: defaults)
        XCTAssertEqual(first.minuteChoices, Self.standard)
        XCTAssertEqual(first.menuOptions.first, .minutes(15))

        first.select(.minutes(45))
        first.select(.off)
        XCTAssertEqual(defaults.string(forKey: SleepTimer.Key.lastOption), "45", "Off is never remembered")
        XCTAssertEqual(SleepTimer(defaults: defaults).menuOptions.first, .minutes(45))

        first.addFifteenMinutes()
        XCTAssertEqual(first.option, .minutes(15))
        XCTAssertEqual(SleepTimer(defaults: defaults).menuOptions.first, .minutes(45), "+15 min is not a pick")

        first.select(.endOfChapter)
        XCTAssertEqual(defaults.string(forKey: SleepTimer.Key.lastOption), "chapter")
        XCTAssertEqual(SleepTimer(defaults: defaults).menuOptions.first, .endOfChapter)
    }

    func testStorageValuesRoundTrip() {
        for option: SleepTimer.Option in [.minutes(15), .minutes(60), .endOfChapter] {
            XCTAssertEqual(option.storageValue.flatMap(SleepTimer.Option.init(storageValue:)), option)
        }
        XCTAssertNil(SleepTimer.Option.off.storageValue)
        XCTAssertNil(SleepTimer.Option(storageValue: "0"))
        XCTAssertNil(SleepTimer.Option(storageValue: "soon"))
    }

    func testTitles() {
        XCTAssertEqual(SleepTimer.Option.off.title(endsAtChapter: true), "Off")
        XCTAssertEqual(SleepTimer.Option.minutes(1).title(endsAtChapter: true), "1 minute")
        XCTAssertEqual(SleepTimer.Option.minutes(15).title(endsAtChapter: true), "15 minutes")
        XCTAssertEqual(SleepTimer.Option.minutes(45).title(endsAtChapter: true), "45 minutes")
        XCTAssertEqual(SleepTimer.Option.minutes(60).title(endsAtChapter: true), "1 hour")
        XCTAssertEqual(SleepTimer.Option.endOfChapter.title(endsAtChapter: true), "End of chapter")
        XCTAssertEqual(SleepTimer.Option.endOfChapter.title(endsAtChapter: false), "End of book")
    }

    func testChipText() async {
        XCTAssertEqual(SleepTimer.Copy.extendChip, "+15 min")
        // R19's VoiceOver action and its hint, worded from the minutes the
        // chip really adds.
        XCTAssertEqual(SleepTimer.Copy.extendSpoken, "Add 15 minutes")
        XCTAssertEqual(SleepTimer.Copy.extendHint, "Keeps playing for 15 more minutes")
        XCTAssertEqual(SleepTimer.extensionMinutes, 15)
        // A fresh hour reads in minutes, never rolled into hours.
        let hour = SleepTimer(defaults: PlaybackTestRig.freshDefaults())
        hour.select(.minutes(60))
        XCTAssertEqual(hour.chipText, "60:00")
        // VoiceOver hears the time left in words, never the m:ss countdown
        // it reads as numbers or a clock time (H051).
        XCTAssertEqual(hour.chipSpokenLabel, "1 hour left, sleep timer")
        // Inside the landing window the clock runs below zero; a negative
        // "minute" puts it there at once, with nothing playing.
        let landing = SleepTimer(timing: SleepTimer.Timing(secondsPerMinute: -0.4),
                                 defaults: PlaybackTestRig.freshDefaults())
        landing.select(.minutes(1))
        XCTAssertLessThan(landing.remaining, 0)
        XCTAssertEqual(landing.chipText, "0:00")
        // A pause there brings the menu back on "0:00": VoiceOver said
        // "1 minute left" beside it (I003).
        XCTAssertEqual(landing.chipSpokenLabel, "No time left, sleep timer")

        // One "minute" of 1694 s, so the countdown reads 28:14.
        let timer = SleepTimer(timing: SleepTimer.Timing(secondsPerMinute: 1694),
                               defaults: PlaybackTestRig.freshDefaults())
        XCTAssertEqual(timer.chipText, "")
        XCTAssertEqual(timer.chipSpokenLabel, "Sleep timer")
        timer.select(.minutes(1))
        XCTAssertEqual(timer.chipText, "28:14")
        XCTAssertEqual(timer.chipSpokenLabel, "29 minutes left, sleep timer", "rounded up, as the countdown is")
        timer.select(.endOfChapter)
        XCTAssertEqual(timer.chipText, "Book end", "no book with chapters")
        XCTAssertEqual(timer.chipSpokenLabel, "Book end, sleep timer")

        let (_, chaptered) = await harness(pages: Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6))
        XCTAssertTrue(chaptered.endsAtChapter)
        chaptered.select(.endOfChapter)
        XCTAssertEqual(chaptered.chipText, "Chapter end")
        chaptered.select(.off)
        XCTAssertEqual(chaptered.chipText, "")
    }

    // MARK: - Landing

    func testTheLandingIsTheNearestSentenceEndInsideTheWindow() {
        let ends = [SentenceEnd(sentence: 4, secondsFromNow: 2.0),
                    SentenceEnd(sentence: 5, secondsFromNow: 4.1),
                    SentenceEnd(sentence: 6, secondsFromNow: 6.3)]
        XCTAssertEqual(SleepTimer.landing(deadline: 5, ends: ends, window: 5), 5)
        XCTAssertNil(SleepTimer.landing(deadline: 5, ends: ends, window: 0.5), "none in the window")
        XCTAssertNil(SleepTimer.landing(deadline: 5, ends: [], window: 5))

        let tie = [SentenceEnd(sentence: 7, secondsFromNow: 4.0), SentenceEnd(sentence: 8, secondsFromNow: 6.0)]
        XCTAssertEqual(SleepTimer.landing(deadline: 5, ends: tie, window: 5), 7, "a tie goes to the earlier end")
        XCTAssertEqual(SleepTimer.landing(deadline: -1, ends: [SentenceEnd(sentence: 3, secondsFromNow: 0.5)],
                                          window: 5), 3, "past the deadline, inside the window")
    }

    // MARK: - Chapter boundary

    func testTheBoundaryIsTheFoldedChaptersLastSentence() {
        // BOOK ONE (heading only) folds into CHAPTER I: sentences 0...3.
        let content = book([["BOOK ONE."], ["CHAPTER I.", "One two three.", "Four five six."],
                            ["CHAPTER II.", "Seven eight.", "Nine ten."]])
        let navigation = ReaderNavigation(content: content, kind: .text)
        XCTAssertTrue(navigation.hasChapterList)
        let count = content.sentences.count
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: navigation, sentenceCount: count, at: 0), 3)
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: navigation, sentenceCount: count, at: 2), 3)
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: navigation, sentenceCount: count, at: 5), 6)
    }

    func testWithoutAChapterListTheBoundaryIsTheLastSentence() {
        let chapterless = PlaybackTestRig.makeContent(hash: "chapterless", count: 9)
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: ReaderNavigation(content: chapterless, kind: .text),
                                                  sentenceCount: 9, at: 2), 8)

        let pdf = PlaybackTestRig.makeContent(hash: "pdf", count: 9, pages: [0, 0, 0, 1, 1, 1, 2, 2, 2])
        let pdfNavigation = ReaderNavigation(content: pdf, kind: .pdf)
        XCTAssertTrue(pdfNavigation.hasChapterList, "page rows, not chapters")
        XCTAssertEqual(SleepTimer.chapterBoundary(navigation: pdfNavigation, sentenceCount: 9, at: 2), 8)
    }

    // MARK: - Minutes

    func testAMinuteTimerFadesAndStopsAtASentenceEnd() async throws {
        let (rig, timer) = await harness(sentences: 60)
        try await playAtFullLevel(rig)
        let mark = rig.edges.count
        let start = MonotonicClock.now
        timer.select(.minutes(15))
        XCTAssertEqual(timer.remaining, 3, accuracy: 1e-9)

        var landed: Int?
        var loud = false
        let stopped = await rig.waitUntil(6) {
            if let sentence = rig.controller.scheduledStopSentence { landed = sentence }
            loud = loud || rig.controller.mixerOutputVolume != 0
            return !rig.controller.isActive
        }
        let elapsed = MonotonicClock.now - start
        XCTAssertTrue(stopped)
        XCTAssertFalse(loud, "the muted mixer stayed at 0 throughout")
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.announcements, [StopReason.sleepTimer.spokenText])
        XCTAssertEqual(elapsed, 3.0, accuracy: 0.7, "the stop lands near the deadline")
        let landing = try XCTUnwrap(landed, "the stop was aimed at a sentence end")
        XCTAssertEqual(rig.controller.currentSentence, landing + 1, "cued after the landing")

        let volumes = rig.volumes(from: mark)
        let fadeStart = try XCTUnwrap(volumes.first { $0.value < 1 }, "the voice faded")
        XCTAssertGreaterThanOrEqual(fadeStart.time - start, 2.0 - 0.15, "the fade is the last second")
        XCTAssertEqual(volumes.last?.value, 0, "silent, so Play ramps in")
        let beforeStop = try XCTUnwrap(volumes.dropLast().last)
        XCTAssertLessThanOrEqual(beforeStop.value, 0.05, "faded out by the sentence end")

        await settle()
        XCTAssertEqual(timer.option, .off)
        XCTAssertFalse(timer.isFading)
        XCTAssertEqual(timer.remaining, 0)
        XCTAssertNil(rig.controller.scheduledStopSentence)
        XCTAssertEqual(rig.controller.sleepStopSerial, 1, "one landing, one sleep stop")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testPlusFifteenDuringTheFadeRestoresTheVoice() async throws {
        let (rig, timer) = await harness(sentences: 80)
        try await playAtFullLevel(rig)
        timer.select(.minutes(15))
        let fading = await rig.waitUntil(4) { timer.isFading && rig.controller.requestedOutputVolume < 1 }
        XCTAssertTrue(fading)

        timer.addFifteenMinutes()
        XCTAssertEqual(timer.option, .minutes(15))
        XCTAssertEqual(timer.remaining, 15 * Self.fast.secondsPerMinute, accuracy: 1e-9)
        XCTAssertFalse(timer.isFading)
        XCTAssertNil(rig.controller.scheduledStopSentence)
        let restored = await rig.waitUntil(0.2) { rig.controller.requestedOutputVolume == 1 }
        XCTAssertTrue(restored, "full volume within 0.2 s")
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertNil(rig.controller.stopped)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)

        timer.select(.off)
        rig.controller.pause()
    }

    func testAPauseFreezesTheCountdownAndDropsTheFade() async throws {
        let (rig, timer) = await harness(sentences: 80)
        try await playAtFullLevel(rig)
        timer.select(.minutes(15))
        let fading = await rig.waitUntil(4) { timer.isFading }
        XCTAssertTrue(fading)

        rig.controller.pause()
        let dropped = await rig.waitUntil(1) { !timer.isFading }
        XCTAssertTrue(dropped)
        XCTAssertNil(rig.controller.scheduledStopSentence, "the landing waits for the audio")
        let frozen = timer.remaining
        await settle(0.4)
        XCTAssertEqual(timer.remaining, frozen, "paused time doesn't burn the timer")
        XCTAssertEqual(timer.option, .minutes(15))
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.stopped, "the listener's pause, not the timer's")
    }

    // MARK: - End of chapter

    func testEndOfChapterFadesAcrossTheLastSentenceAndStopsAfterIt() async throws {
        let (rig, timer) = await harness(pages: Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6),
                                         cue: 3)
        XCTAssertTrue(timer.endsAtChapter)
        var fadeStartedAt: Int?
        let watch = timer.$isFading.sink { fading in
            if fading, fadeStartedAt == nil { fadeStartedAt = rig.controller.currentSentence }
        }
        defer { watch.cancel() }

        timer.select(.endOfChapter)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let stopped = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(stopped)

        XCTAssertEqual(fadeStartedAt, 5, "the fade starts on the chapter's last sentence")
        XCTAssertFalse(scheduledSentences(rig).contains(6), "the next chapter never reached the node")
        XCTAssertEqual(rig.controller.currentSentence, 6)
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 0)
        // The stop anchors the cued sentence, so a later Play starts there.
        XCTAssertEqual(rig.controller.resumeAnchor?.sentenceIndex, 6)
        XCTAssertEqual(rig.anchorStore.load()?.sentenceIndex, 6)

        await settle()
        XCTAssertEqual(timer.option, .off)
        XCTAssertFalse(timer.isFading)
        XCTAssertNil(rig.controller.scheduledStopSentence)
        XCTAssertEqual(rig.controller.sleepStopSerial, 1, "one landing, one sleep stop")
    }

    // MARK: - After a sleep stop (R19, R8)

    /// A timer armed over a sleep stop's pause is the listener's new one:
    /// a voice sample there plays and hands `.paused` back with the old stop
    /// still on record, and neither turns the timer off nor counts it down.
    func testAVoiceSampleOverASleepStopKeepsANewTimer() async throws {
        let (rig, timer) = await harness(sentences: 60)
        try await playAtFullLevel(rig)
        timer.select(.minutes(15))
        let stopped = await rig.waitUntil(6) { !rig.controller.isActive }
        XCTAssertTrue(stopped)
        await settle()
        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer)
        XCTAssertEqual(timer.option, .off, "the landing turned the first timer off")
        let serial = rig.controller.sleepStopSerial

        timer.select(.minutes(30))
        let armed = timer.remaining
        let mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertFalse(rig.controller.isListenerPlaying, "a sample over the pause, not the book")
        let back = await rig.waitUntil(5) { rig.controller.status == .paused }
        XCTAssertTrue(back, "the sample hands the pause back")
        await settle()

        XCTAssertEqual(rig.controller.stopped?.reason, .sleepTimer, "the old stop is still on record")
        XCTAssertEqual(rig.controller.sleepStopSerial, serial, "a sample records no stop")
        XCTAssertEqual(timer.option, .minutes(30), "the new timer stays armed")
        XCTAssertEqual(timer.remaining, armed, "and never counted the sample")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)

        timer.select(.off)
    }

    func testEndOfBookEndsWithTheBook() async throws {
        let (rig, timer) = await harness(sentences: 6, cue: 3)
        XCTAssertFalse(timer.endsAtChapter)
        XCTAssertTrue(timer.menuOptions.map { $0.title(endsAtChapter: timer.endsAtChapter) }.contains("End of book"))
        var fadeStartedAt: Int?
        let watch = timer.$isFading.sink { fading in
            if fading, fadeStartedAt == nil { fadeStartedAt = rig.controller.currentSentence }
        }
        defer { watch.cancel() }

        timer.select(.endOfChapter)
        XCTAssertEqual(timer.chipText, "Book end")
        XCTAssertNil(rig.controller.scheduledStopSentence, "the book's own end is the stop")
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended)

        XCTAssertEqual(fadeStartedAt, 5, "the fade crosses the last sentence")
        XCTAssertNil(rig.controller.stopped, "an ending, not a stop")
        await settle()
        XCTAssertEqual(timer.option, .off)
        XCTAssertFalse(timer.isFading)
    }

    /// R24: a Finished book opens at its end (.paused, then .ended), but
    /// nothing played to that end, so a timer armed while another book
    /// played stays armed, frozen, and counts again on Listen again.
    func testAnArmedTimerSurvivesOpeningAFinishedBook() async throws {
        let (rig, timer) = await harness(sentences: 60)
        try await playAtFullLevel(rig)
        timer.select(.minutes(30))
        let ticking = await rig.waitUntil(1) { timer.remaining < 30 * Self.fast.secondsPerMinute }
        XCTAssertTrue(ticking, "the countdown runs while A plays")

        let finished = PlaybackTestRig.makeDocument(hash: "finished-b", sentences: 40,
                                                    progressSentence: 39, progressFraction: 1.0)
        XCTAssertTrue(finished.isFinished)
        rig.controller.load(document: finished,
                            content: PlaybackTestRig.makeContent(hash: "finished-b", count: 40))
        await settle()
        XCTAssertEqual(rig.controller.status, .ended, "a Finished book opens at its end")
        XCTAssertTrue(timer.isArmed, "opening a Finished book is not the end of listening")
        XCTAssertEqual(timer.option, .minutes(30))
        let frozen = timer.remaining
        XCTAssertGreaterThan(frozen, 0)
        await settle(0.4)
        XCTAssertEqual(timer.remaining, frozen, "the countdown waits while nothing plays")

        // Listen again: the book restarts from its first sentence, and the
        // countdown picks up where it stopped.
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let resumed = await rig.waitUntil(1) { timer.isArmed && timer.remaining < frozen }
        XCTAssertTrue(resumed, "the countdown runs again on Listen again")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)

        timer.select(.off)
        rig.controller.pause()
    }

    /// R24: a voice sample over a reopened Finished book plays (.buffering,
    /// .playing) and hands the end back (.ended), whether it runs out or a
    /// pause cuts it short. Nothing played to the end, so an armed timer
    /// stays armed for Listen again.
    func testAVoiceSampleOverTheEndKeepsAnArmedTimer() async throws {
        let (rig, timer) = await harness(sentences: 6, clipDuration: 1)
        timer.select(.minutes(30))
        openFinishedBook(rig, sentences: 6)
        await settle()
        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(timer.option, .minutes(30))

        var mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        let back = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(back, "the sample hands the end back")
        XCTAssertTrue(rig.controller.isAtEnd)
        await settle()
        XCTAssertEqual(timer.option, .minutes(30), "a sample over the end is not the end")

        mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceA)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertTrue(rig.controller.isActive, "the second sample still speaks")
        rig.controller.pause()
        XCTAssertEqual(rig.controller.status, .ended, "a pause hands the end back at once")
        await settle()
        XCTAssertEqual(timer.option, .minutes(30), "nor is a pause that cuts the sample short")
        XCTAssertGreaterThan(timer.remaining, 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)

        timer.select(.off)
    }

    /// R24: a sentence tap at a reopened Finished book plays from there, and
    /// Undo jump hands the end back (.ended straight from .playing). The
    /// listener never played to the end, so an armed timer stays armed.
    func testUndoBackToTheEndKeepsAnArmedTimer() async throws {
        let (rig, timer) = await harness(sentences: 12, clipDuration: 1)
        timer.select(.minutes(30))
        openFinishedBook(rig, sentences: 12)
        await settle()
        XCTAssertEqual(rig.controller.status, .ended)

        let mark = rig.statuses.count
        rig.controller.jump(to: 0, origin: .sentence)
        XCTAssertNotNil(rig.controller.undoableJump, "a jump from the end offers Undo")
        try await rig.waitUntilPlayingOrSkip(after: mark)
        await settle()
        XCTAssertTrue(rig.controller.isListenerPlaying, "the tap plays from sentence 0")

        rig.controller.undoJump()
        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertTrue(rig.controller.isAtEnd)
        await settle()
        XCTAssertEqual(timer.option, .minutes(30), "Undo back to the end is not the end")
        XCTAssertGreaterThan(timer.remaining, 0)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)

        timer.select(.off)
    }

    /// The other side of the rule: played to the end, a minute timer turns
    /// off, even after a jump that moved nothing (a Contents pick of the
    /// sentence already playing), which changes no status.
    func testAMinuteTimerTurnsOffWhenTheListenerPlaysToTheEnd() async throws {
        let (rig, timer) = await harness(sentences: 3, cue: 1, clipDuration: 1)
        timer.select(.minutes(60))
        let mark = rig.statuses.count
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip(after: mark)
        await settle()

        let serial = rig.controller.jumpSerial
        rig.controller.jump(to: rig.controller.currentSentence, origin: .chapter)
        XCTAssertEqual(rig.controller.jumpSerial, serial &+ 1)
        XCTAssertEqual(rig.controller.status, .playing, "a pick of where the voice is just scrolls")

        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended, "the book plays to its end")
        await settle()
        XCTAssertEqual(timer.option, .off, "nothing is left to sleep through")
        XCTAssertFalse(timer.isFading)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    /// Play over a speaking voice sample from a pause carries the sample on
    /// as the book with no status change (it was .playing already). Played
    /// on to the natural end, that is the listener's end all the same: an
    /// armed timer turns off.
    func testPlayOverASampleThenOnToTheEndTurnsTheTimerOff() async throws {
        let (rig, timer) = await harness(sentences: 3, cue: 1, clipDuration: 1)
        timer.select(.minutes(60))
        var mark = rig.statuses.count
        rig.controller.selectVoice(PlaybackTestRig.voiceB)
        try await rig.waitUntilPlayingOrSkip(after: mark)
        await settle()
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertFalse(rig.controller.isListenerPlaying, "a sample over the pause, not the book")

        mark = rig.statuses.count
        rig.controller.play()
        XCTAssertTrue(rig.controller.isListenerPlaying, "Play carries the sample on as the book")
        XCTAssertEqual(Array(rig.statuses[mark...]), [], "with no status change for the timer to see")

        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended, "the book plays on to its end")
        await settle()
        XCTAssertEqual(timer.option, .off, "nothing is left to sleep through")
        XCTAssertFalse(timer.isFading)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testASeekOutOfTheChapterReaimsAtTheChapterItReached() async {
        let pages = Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6) + Array(repeating: 2, count: 6)
        let (rig, timer) = await harness(pages: pages, cue: 3)
        timer.select(.endOfChapter)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5)

        rig.controller.seek(to: 8, andPlay: false)
        await settle()
        XCTAssertEqual(rig.controller.scheduledStopSentence, 11, "past the boundary: the next chapter")

        rig.controller.seek(to: 2, andPlay: false)
        await settle()
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5, "back into the first chapter")

        rig.controller.seek(to: 14, andPlay: false)
        await settle()
        XCTAssertNil(rig.controller.scheduledStopSentence, "the last chapter ends with the book")
        XCTAssertEqual(timer.option, .endOfChapter)
        XCTAssertEqual(timer.chipText, "Chapter end")
    }

    /// The same text under a new id (a book deleted, then added again, or a
    /// second copy) is a new load: the load drops the stop, and the timer
    /// aims again, though the hash and the chapter it opens in are the ones
    /// it saw last. It once stayed on the old chapter with no stop, faded at
    /// its end, and read on through the next.
    func testEndOfChapterReaimsWhenTheSameTextLoadsUnderANewID() async throws {
        let pages = Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6)
        let (rig, timer) = await harness(pages: pages, cue: 0)
        let hash = try XCTUnwrap(rig.controller.content?.contentHash)
        func reload() {
            rig.controller.load(document: PlaybackTestRig.makeDocument(hash: hash, sentences: pages.count),
                                content: PlaybackTestRig.makeContent(hash: hash, count: pages.count, pages: pages))
        }
        timer.select(.endOfChapter)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5)

        reload()
        await settle()
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5, "a second copy opening in the chapter")

        rig.controller.unload()
        await settle()
        XCTAssertNil(rig.controller.scheduledStopSentence)
        XCTAssertEqual(timer.option, .endOfChapter, "a delete leaves the timer armed")

        reload()
        await settle()
        XCTAssertEqual(rig.controller.currentSentence, 0)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5, "deleted and added again")
        XCTAssertEqual(timer.chipText, "Chapter end")
        timer.select(.off)
    }

    // MARK: - Dropping a fade mid-restart

    /// A tap on an earlier sentence (or skip back on the lock screen) while
    /// the chapter's last sentence fades restarts playback through
    /// .buffering, and the fade's ramp survives the restart. The timer drops
    /// the fade while the restart is still buffering, so the voice must come
    /// back anyway: the cold start keeps a running ramp, and a fade left
    /// running would carry the rest of the chapter to silence.
    func testASeekDuringTheChapterEndFadeBringsTheVoiceBack() async throws {
        // 1 s sentences, so the fade lasts about a second; sentence 2 waits
        // for the gate, so the restart onto it buffers until the test says.
        let gate = GatedEngine(sentence: 2, clipDuration: 1)
        defer { gate.open() }
        let (rig, timer) = await harness(pages: Array(repeating: 0, count: 6) + Array(repeating: 1, count: 6),
                                         cue: 4, clipDuration: 1, routes: [PlaybackTestRig.voiceA.id: gate])
        timer.select(.endOfChapter)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5)
        try await playAtFullLevel(rig)
        let fading = await rig.waitUntil(3) {
            rig.controller.currentSentence == 5 && timer.isFading && rig.controller.requestedOutputVolume < 1
        }
        XCTAssertTrue(fading, "the chapter's last sentence fades")

        rig.controller.seek(to: 2, andPlay: true)
        XCTAssertEqual(rig.controller.status, .buffering)
        let dropped = await rig.waitUntil(1) { !timer.isFading }
        XCTAssertTrue(dropped, "back from the last sentence: the fade is dropped")
        XCTAssertEqual(rig.controller.status, .buffering, "dropped while the restart buffers")

        try await restartAndExpectFullVolume(rig, gate: gate)
        XCTAssertLessThan(rig.controller.currentSentence, 5, "still before the chapter's end")
        XCTAssertEqual(timer.option, .endOfChapter)
        XCTAssertFalse(timer.isFading)
        XCTAssertEqual(rig.controller.scheduledStopSentence, 5, "the stop still waits at the chapter's end")

        timer.select(.off)
        rig.controller.pause()
    }

    /// "+15 min" tapped while a seek restarts mid-fade: the fade survives
    /// the restart, so the tap must replace it even though nothing is
    /// .playing yet, or the extra 15 minutes play silent.
    func testPlusFifteenDuringARestartBringsTheVoiceBack() async throws {
        let gate = GatedEngine(sentence: Self.gatedSentence, clipDuration: 1)
        defer { gate.open() }
        let (rig, timer) = try await minuteFadeThenRestart(gate: gate)

        timer.addFifteenMinutes()
        XCTAssertFalse(timer.isFading)
        XCTAssertEqual(timer.option, .minutes(15))

        try await restartAndExpectFullVolume(rig, gate: gate)
        XCTAssertFalse(timer.isFading, "15 minutes on the clock, no fade yet")
        XCTAssertEqual(timer.option, .minutes(15))

        timer.select(.off)
        rig.controller.pause()
    }

    /// Off picked while a seek restarts mid-fade: no timer is left to undo
    /// the fade later, so turning it off must bring the voice back now.
    func testOffDuringARestartBringsTheVoiceBack() async throws {
        let gate = GatedEngine(sentence: Self.gatedSentence, clipDuration: 1)
        defer { gate.open() }
        let (rig, timer) = try await minuteFadeThenRestart(gate: gate)

        timer.select(.off)
        XCTAssertFalse(timer.isFading)

        try await restartAndExpectFullVolume(rig, gate: gate)
        XCTAssertEqual(timer.option, .off)
        XCTAssertNil(rig.controller.stopped)

        rig.controller.pause()
    }

    /// Never synthesized before the seek: the minute tests play from 0.
    private static let gatedSentence = 30

    /// A 15 "minute" timer (3 s) fading on 1 s sentences, then a seek ahead
    /// to the gated sentence: a live restart, held in .buffering, with the
    /// fade still on.
    private func minuteFadeThenRestart(gate: GatedEngine) async throws -> (PlaybackTestRig, SleepTimer) {
        let (rig, timer) = await harness(sentences: 80, clipDuration: 1,
                                         routes: [PlaybackTestRig.voiceA.id: gate])
        try await playAtFullLevel(rig)
        timer.select(.minutes(15))
        let fading = await rig.waitUntil(4) { timer.isFading && rig.controller.requestedOutputVolume < 1 }
        XCTAssertTrue(fading, "the timer's last second fades")

        rig.controller.seek(to: Self.gatedSentence, andPlay: true)
        XCTAssertEqual(rig.controller.status, .buffering)
        await settle()
        XCTAssertEqual(rig.controller.status, .buffering, "the restart waits for the gate")
        XCTAssertTrue(timer.isFading, "a minute timer's fade carries on across a restart")
        XCTAssertTrue(rig.controller.isRampingVolume, "the fade's ramp survived the restart")
        return (rig, timer)
    }

    /// Opens the gate, so the restart's first clip cold-starts the audio,
    /// then expects full volume at once and still well after the old fade
    /// would have reached silence (it ran about a second). A fade left
    /// running would have been kept by that cold start.
    private func restartAndExpectFullVolume(_ rig: PlaybackTestRig, gate: GatedEngine,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let mark = rig.statuses.count
        gate.open()
        try await rig.waitUntilPlayingOrSkip(after: mark, file: file, line: line)
        let restored = await rig.waitUntil(0.5) { rig.controller.requestedOutputVolume == 1 }
        XCTAssertTrue(restored, "full volume again within 0.5 s, got \(rig.controller.requestedOutputVolume)",
                      file: file, line: line)
        await settle(1.4)
        XCTAssertEqual(rig.controller.requestedOutputVolume, 1, "nothing pulls the voice back down",
                       file: file, line: line)
        XCTAssertEqual(rig.controller.status, .playing, file: file, line: line)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0, "the muted mixer stayed at 0", file: file, line: line)
    }

    /// Holds one sentence's synthesis until `open()`, so a restart onto it
    /// stays in .buffering for exactly as long as a test needs; every other
    /// sentence is silence of `clipDuration` at once.
    private final class GatedEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let base: PlaybackTestRig.RecordingEngine
        /// "Line<n> word word.": the trailing space keeps 3 from matching 30.
        private let prefix: String
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        @MainActor
        init(sentence: Int, clipDuration: TimeInterval) {
            base = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA], clipDuration: clipDuration)
            voices = base.voices
            prefix = "Line\(sentence) "
        }

        func open() {
            let parked: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                let parked = waiters
                waiters = []
                return parked
            }
            for continuation in parked { continuation.resume() }
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            if text.hasPrefix(prefix) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let passes: Bool = lock.withLock {
                        if isOpen { return true }
                        waiters.append(continuation)
                        return false
                    }
                    if passes { continuation.resume() }
                }
            }
            return try await base.synthesize(text, voice: voice)
        }
    }

    // MARK: - Harness

    /// A text book of `sentences` (chapters by `pages`) loaded paused at
    /// `cue` on a silent rig, watched by a fast timer on its own suite.
    /// `routes` replaces the rig's engine for a voice id.
    private func harness(sentences: Int? = nil, pages: [Int]? = nil, cue: Int = 0,
                         clipDuration: TimeInterval = 0.25,
                         routes: [String: any TtsEngine] = [:]) async -> (PlaybackTestRig, SleepTimer) {
        let count = sentences ?? pages?.count ?? 12
        let rig = PlaybackTestRig(sentences: count, clipDuration: clipDuration, extraRoutes: routes)
        let timer = SleepTimer(timing: Self.fast, defaults: PlaybackTestRig.freshDefaults())
        timer.attach(to: rig.controller)
        let hash = "sleep-timer-\(count)-\(pages?.max() ?? 0)"
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: hash, sentences: count, progressSentence: cue),
                            content: PlaybackTestRig.makeContent(hash: hash, count: count, pages: pages))
        // The timer hears of the load a run-loop turn later, and reads the
        // book's chapters off the main actor.
        await settle()
        if Set(pages ?? []).count >= 2 {
            _ = await rig.waitUntil(2) { timer.endsAtChapter }
        }
        return (rig, timer)
    }

    /// Loads a Finished book of `sentences`, which opens at its end (it loads
    /// .paused, then .ended).
    private func openFinishedBook(_ rig: PlaybackTestRig, sentences: Int) {
        let hash = "finished-\(sentences)"
        let document = PlaybackTestRig.makeDocument(hash: hash, sentences: sentences,
                                                    progressSentence: sentences - 1, progressFraction: 1.0)
        XCTAssertTrue(document.isFinished)
        rig.controller.load(document: document, content: PlaybackTestRig.makeContent(hash: hash, count: sentences))
    }

    /// Playing, with the start's own fade-in finished, so every level below
    /// 1 from here on is the timer's.
    private func playAtFullLevel(_ rig: PlaybackTestRig) async throws {
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let settled = await rig.waitUntil(2) {
            !rig.controller.isRampingVolume && rig.controller.requestedOutputVolume == 1
        }
        XCTAssertTrue(settled, "the start's fade-in finished")
    }

    /// Lets the main run loop deliver the timer's observations.
    private func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func scheduledSentences(_ rig: PlaybackTestRig) -> [Int] {
        rig.events.compactMap {
            if case .scheduled(let sentence, _) = $0 { return sentence }
            return nil
        }
    }

    /// One page per chapter, one paragraph per sentence (so a one-sentence
    /// chapter is heading-only).
    private func book(_ chapters: [[String]]) -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        for (page, chapter) in chapters.enumerated() {
            for text in chapter {
                let id = sentences.count
                paragraphs.append(Paragraph(id: id, sentenceIDs: id..<(id + 1), page: page))
                sentences.append(Sentence(id: id, text: text, para: id, page: page))
            }
        }
        return DocContent(title: "Book", pageCount: chapters.count, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "sleep-timer-book")
    }
}
