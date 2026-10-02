import XCTest
@testable import Aloud

/// Resume rewind: a USER play after a real break backs up a couple of
/// sentences to rebuild context — 2 after >5 minutes, 4 after >30 —
/// clamped to the document start, skipped entirely near the beginning,
/// on programmatic resumes, and when the document changed underneath.
///
/// The rest itself is an anchor value (document, sentence, timestamps):
/// measured on a monotonic clock so a device clock change can neither invent
/// a rest nor erase one, dropped by any explicit navigation, never inherited
/// by another book, and persisted so an overnight break survives the app
/// being jettisoned.
@MainActor
final class ResumeRewindTests: XCTestCase {

    // MARK: - Clamping table (pure)

    func testRewindDistanceTable() {
        let table: [(elapsed: TimeInterval, rewind: Int)] = [
            (0, 0),
            (30, 0),
            (5 * 60 - 1, 0),
            (5 * 60, 0),          // boundary: exactly 5 min is not "over"
            (5 * 60 + 1, 2),
            (12 * 60, 2),
            (30 * 60, 2),         // boundary: exactly 30 min stays at 2
            (30 * 60 + 1, 4),
            (4 * 3600, 4),
        ]
        for row in table {
            XCTAssertEqual(PlaybackController.resumeRewindSentences(elapsed: row.elapsed),
                           row.rewind,
                           "elapsed \(row.elapsed)s should rewind \(row.rewind)")
        }
    }

    // MARK: - Elapsed measurement (pure)

    func testElapsedPrefersTheMonotonicReading() {
        // Wall clock says 40 minutes; the monotonic clock says 30 seconds —
        // e.g. an NTP/carrier correction landed while the app was paused.
        let anchor = ResumeAnchor(documentID: UUID(),
                                  sentenceIndex: 5,
                                  wallClock: Date(timeIntervalSinceNow: -40 * 60),
                                  monotonic: MonotonicClock.now - 30)
        XCTAssertEqual(anchor.elapsed(), 30, accuracy: 1,
                       "an in-session rest is measured on a clock the user can't move")
    }

    func testElapsedClampsABackwardsClockJumpToZero() {
        // A restored anchor has only wall clock — and the clock moved back,
        // so its stamp now reads as the future.
        let anchor = ResumeAnchor(documentID: UUID(),
                                  sentenceIndex: 5,
                                  wallClock: Date(timeIntervalSinceNow: 45 * 60),
                                  monotonic: nil)
        XCTAssertEqual(anchor.elapsed(), 0,
                       "a negative gap is no rest, never a rewind in reverse")
    }

    func testTheMonotonicReadingIsNeverPersisted() throws {
        let anchor = ResumeAnchor(documentID: UUID(), sentenceIndex: 3)
        XCTAssertNotNil(anchor.monotonic)

        let store = makeStore()
        store.save(anchor)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored.documentID, anchor.documentID)
        XCTAssertEqual(restored.sentenceIndex, 3)
        XCTAssertEqual(restored.wallClock.timeIntervalSinceReferenceDate,
                       anchor.wallClock.timeIntervalSinceReferenceDate,
                       accuracy: 0.001)
        XCTAssertNil(restored.monotonic,
                     "the boot-relative reading means nothing in a new launch")
    }

    // MARK: - Harness

    /// Instant silence for every request — playback wiring without real TTS.
    private final class StubEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            .silence(duration: 0.05)
        }
    }

    /// A clean anchor slot on its own defaults suite — the app's real
    /// preferences are never touched by a test.
    private func makeStore() -> ResumeAnchorStore {
        let suite = "aloud.tests.resumeAnchor"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ResumeAnchorStore(defaults: defaults)
    }

    private func makeController(store: ResumeAnchorStore) -> PlaybackController {
        let engine = StubEngine()
        let cache = AudioClipCache()
        let voice = TtsVoice(id: "stub", name: "Stub", lang: "en-US",
                             gender: "f", engine: .avSpeech, quality: 1)
        return PlaybackController(engine: engine,
                                  defaultVoice: voice,
                                  scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                  cache: cache,
                                  audioSession: AudioSessionManager(),
                                  anchorStore: store,
                                  // A fresh stop slot per controller: a "launch" here never
                                  // inherits the last one's live session.
                                  stopStore: PlaybackStopStore(defaults: PlaybackTestRig.freshDefaults()),
                                  outputMuted: true)
    }

    private func makeContent(count: Int, contentHash: String = "test-hash") -> DocContent {
        DocContent(title: "Test",
                   pageCount: 1,
                   sentences: (0..<count).map {
                       Sentence(id: $0, text: "Sentence \($0).", para: 0, page: 0)
                   },
                   paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<count, page: 0)],
                   contentHash: contentHash)
    }

    private func makeDocument(sentenceCount: Int = 8,
                              progressSentence: Int = 0,
                              contentHash: String = "test-hash") -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Test", fileName: "test.txt",
                        addedAt: Date(), pageCount: 1, sentenceCount: sentenceCount,
                        progressSentence: progressSentence,
                        contentHash: contentHash, kind: .text)
    }

    /// Everything one rewind scenario needs, so the anchor store stays
    /// addressable (a rest lives on disk as well as in memory).
    private struct Rig {
        let controller: PlaybackController
        let store: ResumeAnchorStore
        let document: LibraryDocument
    }

    /// Stamps the anchor exactly as a real pause does: in memory and on disk.
    private func stamp(_ anchor: ResumeAnchor, on rig: Rig) {
        rig.controller.resumeAnchor = anchor
        rig.store.save(anchor)
    }

    /// A controller cued (paused) at `sentence`, resting since `elapsed` ago.
    private func restingRig(at sentence: Int,
                            elapsed: TimeInterval,
                            sentenceCount: Int = 8) -> Rig {
        let store = makeStore()
        let controller = makeController(store: store)
        let document = makeDocument(sentenceCount: sentenceCount)
        controller.load(document: document, content: makeContent(count: sentenceCount))
        controller.seek(to: sentence, andPlay: false)
        let rig = Rig(controller: controller, store: store, document: document)
        stamp(ResumeAnchor(documentID: document.id,
                           sentenceIndex: sentence,
                           wallClock: Date(timeIntervalSinceNow: -elapsed),
                           monotonic: MonotonicClock.now - elapsed),
              on: rig)
        return rig
    }

    // MARK: - Recording seam

    func testLeavingActivePlaybackRecordsPauseAnchor() {
        let rig = restingRig(at: 0, elapsed: 0)
        rig.controller.resumeAnchor = nil
        rig.store.clear()

        rig.controller.play()   // paused → buffering: entering active records nothing
        XCTAssertNil(rig.controller.resumeAnchor)

        rig.controller.pause()  // buffering → paused: leaving active records the anchor
        XCTAssertEqual(rig.controller.resumeAnchor?.documentID, rig.document.id)
        XCTAssertEqual(rig.controller.resumeAnchor?.sentenceIndex, 0)
        XCTAssertNotNil(rig.controller.resumeAnchor?.monotonic,
                        "an in-session stamp carries the monotonic reading")
        XCTAssertEqual(rig.store.load()?.documentID, rig.document.id,
                       "the rest is mirrored to disk the moment it starts")
    }

    // MARK: - User resume behavior

    func testShortBreakResumesInPlace() {
        let rig = restingRig(at: 5, elapsed: 60)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertNil(rig.controller.notice)
    }

    func testMediumBreakRewindsTwoWithNotice() {
        let rig = restingRig(at: 5, elapsed: 6 * 60)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(rig.controller.notice, .backedUp(sentences: 2))
        XCTAssertEqual(rig.controller.userPlayAction, 1, "the rewound start is ONE user play")
        XCTAssertNil(rig.controller.resumeAnchor, "a consumed anchor never rewinds twice")
        XCTAssertNil(rig.store.load(), "and it can't be resurrected by a relaunch")
    }

    func testLongBreakRewindsFour() {
        let rig = restingRig(at: 6, elapsed: 45 * 60)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 2)
        XCTAssertEqual(rig.controller.notice, .backedUp(sentences: 4))
    }

    func testRewindClampsToDocumentStart() {
        let rig = restingRig(at: 2, elapsed: 45 * 60)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 0, "2 − 4 clamps to 0, never negative")
        XCTAssertEqual(rig.controller.notice, .backedUp(sentences: 2), "the notice names the real distance")
    }

    func testNoRewindWithinFirstTwoSentences() {
        for sentence in [0, 1] {
            let rig = restingRig(at: sentence, elapsed: 45 * 60)
            rig.controller.play()
            XCTAssertEqual(rig.controller.currentSentence, sentence,
                           "sentence \(sentence) skips the rewind entirely")
            XCTAssertNil(rig.controller.notice)
        }
    }

    func testProgrammaticResumeNeverRewinds() {
        let rig = restingRig(at: 5, elapsed: 45 * 60)
        rig.controller.play(userInitiated: false)   // interruption end / route recovery
        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertNil(rig.controller.notice)
        XCTAssertEqual(rig.controller.userPlayAction, 0)
    }

    func testDocumentChangeInvalidatesTheAnchor() {
        let rig = restingRig(at: 5, elapsed: 45 * 60)
        stamp(ResumeAnchor(documentID: UUID(),   // rest belonged to another book
                           sentenceIndex: 5,
                           wallClock: Date(timeIntervalSinceNow: -45 * 60),
                           monotonic: MonotonicClock.now - 45 * 60),
              on: rig)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 5)
        XCTAssertNil(rig.controller.notice)
    }

    // MARK: - Clock changes

    func testForwardClockJumpDoesNotInventARewind() {
        let rig = restingRig(at: 5, elapsed: 30)
        // The device clock jumped 40 minutes forward during a 30-second rest.
        stamp(ResumeAnchor(documentID: rig.document.id,
                           sentenceIndex: 5,
                           wallClock: Date(timeIntervalSinceNow: -40 * 60),
                           monotonic: MonotonicClock.now - 30),
              on: rig)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 5,
                       "30 seconds of rest is 30 seconds, whatever the clock says")
        XCTAssertNil(rig.controller.notice)
    }

    func testBackwardClockJumpNeverRewinds() {
        let rig = restingRig(at: 5, elapsed: 0)
        // A restored anchor (wall clock only) whose stamp now reads as the
        // future: the clock moved back after the rest began.
        stamp(ResumeAnchor(documentID: rig.document.id,
                           sentenceIndex: 5,
                           wallClock: Date(timeIntervalSinceNow: 45 * 60),
                           monotonic: nil),
              on: rig)
        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 5,
                       "a negative gap resumes in place — it never rewinds")
        XCTAssertNil(rig.controller.notice)
    }

    // MARK: - Explicit navigation

    func testSeekWhilePausedClearsTheAnchor() {
        let rig = restingRig(at: 5, elapsed: 45 * 60)
        // A search match, chapter row, sentence tap or scrubber drag while paused.
        rig.controller.seek(to: 7, andPlay: false)

        XCTAssertNil(rig.controller.resumeAnchor)
        XCTAssertNil(rig.store.load())

        rig.controller.play()
        XCTAssertEqual(rig.controller.currentSentence, 7,
                       "an explicit choice of position is never second-guessed")
        XCTAssertNil(rig.controller.notice)
    }

    func testAnotherBooksStoredRestSurvivesASeekHere() {
        let store = makeStore()
        let resting = makeDocument(progressSentence: 6)
        let restingAnchor = ResumeAnchor(documentID: resting.id,
                                         sentenceIndex: 6,
                                         wallClock: Date(timeIntervalSinceNow: -8 * 3600),
                                         monotonic: nil)
        store.save(restingAnchor)

        let controller = makeController(store: store)
        let other = makeDocument(progressSentence: 3, contentHash: "hash-b")
        controller.load(document: other, content: makeContent(count: 8, contentHash: "hash-b"))
        controller.seek(to: 4, andPlay: false)

        XCTAssertEqual(store.load()?.documentID, resting.id,
                       "navigating in one book must not drop another book's rest")
    }

    // MARK: - Document switching

    func testSwitchingDocumentsWhilePlayingNeverAnchorsTheIncomingBook() {
        let store = makeStore()
        let controller = makeController(store: store)

        let bookA = makeDocument(progressSentence: 5)
        controller.load(document: bookA, content: makeContent(count: 8))
        controller.play()
        XCTAssertTrue(controller.isActive, "A is playing when the user opens B")

        let bookB = makeDocument(progressSentence: 5, contentHash: "hash-b")
        controller.load(document: bookB, content: makeContent(count: 8, contentHash: "hash-b"))

        XCTAssertNil(controller.resumeAnchor, "B never played — it inherits no rest")
        XCTAssertEqual(store.load()?.documentID, bookA.id,
                       "the stop belongs to the book that was playing")
        XCTAssertEqual(store.load()?.sentenceIndex, 5)

        controller.play()   // first ever play on B, after reading silently
        XCTAssertEqual(controller.currentSentence, 5, "no phantom rewind in a book that never played")
        XCTAssertNil(controller.notice)
    }

    func testReturningToTheBookThatWasPlayingRewinds() throws {
        let store = makeStore()
        let controller = makeController(store: store)

        let bookA = makeDocument(progressSentence: 5)
        let contentA = makeContent(count: 8)
        controller.load(document: bookA, content: contentA)
        controller.play()

        let bookB = makeDocument(progressSentence: 5, contentHash: "hash-b")
        controller.load(document: bookB, content: makeContent(count: 8, contentHash: "hash-b"))

        // A's rest is on disk; age it into the long tier and reopen A.
        let stopped = try XCTUnwrap(store.load())
        store.save(ResumeAnchor(documentID: stopped.documentID,
                                sentenceIndex: stopped.sentenceIndex,
                                wallClock: Date(timeIntervalSinceNow: -45 * 60),
                                monotonic: nil))
        controller.load(document: bookA, content: contentA)

        XCTAssertEqual(controller.resumeAnchor?.documentID, bookA.id)
        controller.play()
        XCTAssertEqual(controller.currentSentence, 1, "5 − 4: A resumes with its context rebuilt")
        XCTAssertEqual(controller.notice, .backedUp(sentences: 4))
    }

    // MARK: - Across app launches

    func testCrossLaunchAnchorRewindsOnceThenClears() {
        let store = makeStore()
        let book = makeDocument(progressSentence: 6)
        // Last night's stop, exactly as the previous launch left it on disk.
        store.save(ResumeAnchor(documentID: book.id,
                                sentenceIndex: 6,
                                wallClock: Date(timeIntervalSinceNow: -8 * 3600),
                                monotonic: nil))

        let morning = makeController(store: store)
        morning.load(document: book, content: makeContent(count: 8))
        XCTAssertEqual(morning.resumeAnchor?.documentID, book.id,
                       "reopening the same book restores its rest")

        morning.play()   // the Continue Listening hero's autoplay
        XCTAssertEqual(morning.currentSentence, 2, "6 − 4 after an overnight break")
        XCTAssertEqual(morning.notice, .backedUp(sentences: 4))
        XCTAssertNil(store.load(), "a consumed anchor never rewinds again")

        // A later launch of the same book resumes exactly where it was left.
        let later = makeController(store: store)
        later.load(document: book, content: makeContent(count: 8))
        XCTAssertNil(later.resumeAnchor)
        later.play()
        XCTAssertEqual(later.currentSentence, 6)
        XCTAssertNil(later.notice)
    }

    func testCrossLaunchAnchorNeverAppliesToAnotherBook() {
        let store = makeStore()
        let stopped = makeDocument(progressSentence: 6)
        store.save(ResumeAnchor(documentID: stopped.id,
                                sentenceIndex: 6,
                                wallClock: Date(timeIntervalSinceNow: -8 * 3600),
                                monotonic: nil))

        let controller = makeController(store: store)
        let other = makeDocument(progressSentence: 6, contentHash: "hash-b")
        controller.load(document: other, content: makeContent(count: 8, contentHash: "hash-b"))

        XCTAssertNil(controller.resumeAnchor, "another book's rest is not this book's")
        controller.play()
        XCTAssertEqual(controller.currentSentence, 6)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(store.load()?.documentID, stopped.id,
                       "and the book it belongs to keeps it")
    }
}
