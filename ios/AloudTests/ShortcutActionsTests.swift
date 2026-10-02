import XCTest
@testable import Aloud

/// R26: what the two shortcuts do, through ShortcutActions on the frozen
/// muted rig. Continue listening plays the Continue card's book through the
/// card's own ContinuePlayback, never pauses or restarts a speaking book,
/// refuses a book at its end or an empty shelf, and settles on real speech
/// (never a skipped sentence's silence), .error or its deadline. Set sleep
/// timer arms the reader chip's timer.
///
/// Silent: every controller is the rig's muted one, the shelf is a fake, and
/// no test runs an App Intent or touches the app's shared model.
@MainActor
final class ShortcutActionsTests: XCTestCase {

    // MARK: - Fakes

    /// A load that waits until the test opens it.
    @MainActor
    private final class LoadGate {
        private var waiter: CheckedContinuation<Void, Error>?
        private var outcome: Result<Void, Error>?

        func wait() async throws {
            if let outcome { return try outcome.get() }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func open() { resume(.success(())) }

        private func resume(_ result: Result<Void, Error>) {
            guard let waiter else { outcome = result; return }
            self.waiter = nil
            waiter.resume(with: result)
        }
    }

    private struct LoadFailed: Error {}

    /// A neural voice from cold: every synthesis first waits for the fake's
    /// warm-up (parked until the test calls finishWarmUp), then speaks.
    private final class ColdNeuralEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let base: PlaybackTestRig.FakeNeuralEngine

        init(base: PlaybackTestRig.FakeNeuralEngine) {
            self.voices = base.voices
            self.base = base
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await base.warmUp()
            return try await base.synthesize(text, voice: voice)
        }
    }

    /// A voice slower than the 50 ms beat a skipped sentence plays, so the
    /// playhead reaches a sentence still being synthesized. Sentence 2 always
    /// fails at once. Once armed, each later sentence waits for `release`,
    /// then fails or speaks (5 s clips). Unarmed, they fail at once, so the
    /// load's cue prefetch caches nothing.
    private final class StallingEngine: TtsEngine, @unchecked Sendable {
        enum Verdict { case fail, speak }

        let voices: [TtsVoice]
        private let lock = NSLock()
        private var armed = false
        private var verdict: Verdict?
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var log: [Int] = []

        init(voices: [TtsVoice]) {
            self.voices = voices
        }

        /// Sentence indices asked for, in order.
        var requestedSentences: [Int] { lock.withLock { log } }
        var parkedCount: Int { lock.withLock { parked.count } }

        func arm() { lock.withLock { armed = true } }

        /// Settles every parked request, and every later one at once.
        func release(_ verdict: Verdict) {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                self.verdict = verdict
                let waiting = parked
                parked = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            // "Line<i> word…" (PlaybackTestRig.makeContent).
            let index = text.hasPrefix("Line") ? Int(text.dropFirst(4).prefix { $0.isNumber }) : nil
            guard let index else { return .silence(duration: 5, sampleRate: 22_050) }
            // Logged and judged in one step, so arming right after a request
            // shows up in the log never parks that request.
            let stalls = lock.withLock { () -> Bool in
                log.append(index)
                return armed
            }
            if index < 2 { return .silence(duration: 5, sampleRate: 22_050) }
            guard index > 2, stalls else { throw TtsError.voiceUnavailable }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parks = lock.withLock { () -> Bool in
                    guard verdict == nil else { return false }
                    parked.append(continuation)
                    return true
                }
                if !parks { continuation.resume() }
            }
            if lock.withLock({ verdict }) == .speak { return .silence(duration: 5, sampleRate: 22_050) }
            throw TtsError.voiceUnavailable
        }
    }

    /// What a Continue listening run in flight has settled on, if anything.
    @MainActor
    private final class Settled {
        var outcome: ContinueListeningOutcome?
    }

    /// The shelf: records every book loaded and opened. Its liveContent
    /// follows DocumentStore's rule: a record deleted while it loaded is a
    /// CancellationError.
    @MainActor
    private final class FakeContinueLibrary: ContinueLibrary {
        var documents: [LibraryDocument] = []
        /// When set, every load waits for the test to open it.
        var gate: LoadGate?
        /// When set, every load fails with it.
        var failure: Error?
        private(set) var liveContentCalls: [UUID] = []
        private(set) var openedIDs: [UUID] = []
        private let content: DocContent

        init(content: DocContent) {
            self.content = content
        }

        func liveContent(for document: LibraryDocument) async throws -> (document: LibraryDocument, content: DocContent) {
            liveContentCalls.append(document.id)
            if let gate { try await gate.wait() }
            if let failure { throw failure }
            guard let live = documents.first(where: { $0.id == document.id }) else { throw CancellationError() }
            return (live, content)
        }

        func noteOpened(id: UUID) {
            openedIDs.append(id)
        }
    }

    /// The rig, the shelf, and the app's two shared parts, wired as AppModel
    /// wires them.
    @MainActor
    private final class Harness {
        let rig: PlaybackTestRig
        let library: FakeContinueLibrary
        let continuePlayback = ContinuePlayback()
        let sleepTimer: SleepTimer
        var startTimeout = ShortcutActions.defaultStartTimeout

        /// 5 s clips by default, so a sentence holds still while it is checked.
        init(rig: PlaybackTestRig? = nil) {
            let rig = rig ?? PlaybackTestRig(clipDuration: 5)
            self.rig = rig
            library = FakeContinueLibrary(content: rig.content)
            sleepTimer = SleepTimer(timing: .standard, defaults: rig.defaults)
            sleepTimer.attach(to: rig.controller)
        }

        var actions: ShortcutActions {
            ShortcutActions(library: library, playback: rig.controller, continuePlayback: continuePlayback,
                            sleepTimer: sleepTimer, startTimeout: startTimeout)
        }

        var mixerVolume: Float { rig.controller.mixerOutputVolume }
    }

    /// A shelf record of the rig's book, opened `openedAgo` seconds ago and
    /// listened up to `sentence`: the rig's own record, or a `distinct` one
    /// (a new id over the same content).
    private static func record(_ rig: PlaybackTestRig, at sentence: Int, openedAgo: TimeInterval = 60,
                               distinct: Bool = false) -> LibraryDocument {
        var document = distinct
            ? PlaybackTestRig.makeDocument(hash: rig.content.contentHash, sentences: rig.content.sentences.count)
            : rig.document
        document.progressSentence = sentence
        document.progressFraction = Double(sentence) / Double(rig.content.sentences.count)
        document.lastOpenedAt = Date().addingTimeInterval(-openedAgo)
        return document
    }

    /// The started path needs the host's audio engine. A host that can't
    /// start it errors every start, as PlaybackTestRig.waitUntilPlayingOrSkip
    /// allows for. Only for rigs with no failing engine.
    private func skipIfTheHostCantPlay(_ outcome: ContinueListeningOutcome, _ rig: PlaybackTestRig) throws {
        if case .failed = outcome, rig.statuses.contains(.error) {
            throw XCTSkip("The audio engine can't start in this test host")
        }
    }

    /// For rigs whose voice fails some sentences, where .error can be the
    /// real outcome: the host's audio engine never started when no status
    /// reached .playing (a skipped sentence's silence starts it like any clip).
    private func skipUnlessTheAudioStarted(_ rig: PlaybackTestRig) throws {
        if !rig.statuses.contains(.playing) {
            throw XCTSkip("The audio engine can't start in this test host")
        }
    }

    /// The rig's book loaded at sentence 2 over a StallingEngine, its cue
    /// prefetch settled and the engine armed, with Continue listening
    /// running until the playhead has crossed sentence 2's silence onto
    /// sentence 3, whose synthesis is parked.
    private func continueOntoAStalledSentence(startTimeout: TimeInterval = ShortcutActions.defaultStartTimeout)
        async throws -> (h: Harness, engine: StallingEngine, book: LibraryDocument,
                         run: Task<ContinueListeningOutcome, Never>) {
        let engine = StallingEngine(voices: [PlaybackTestRig.voiceA])
        addTeardownBlock { engine.release(.fail) }   // never leave a synthesis parked
        let h = Harness(rig: PlaybackTestRig(clipDuration: 5, extraRoutes: [PlaybackTestRig.voiceA.id: engine]))
        h.startTimeout = startTimeout
        let book = Self.record(h.rig, at: 2)
        h.library.documents = [book]
        h.rig.loadDefault(at: 2)
        let prefetched = await h.rig.waitUntil { engine.requestedSentences.contains(3) }
        XCTAssertTrue(prefetched, "the load cues sentences 2 and 3")
        engine.arm()

        let settled = Settled()
        let actions = h.actions
        let run = Task { () -> ContinueListeningOutcome in
            let outcome = await actions.continueListening()
            settled.outcome = outcome
            return outcome
        }
        let onThree = await h.rig.waitUntil { h.rig.controller.currentSentence == 3 || settled.outcome != nil }
        try skipUnlessTheAudioStarted(h.rig)
        XCTAssertTrue(onThree)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "past sentence 2's beat of silence")
        XCTAssertEqual(h.rig.controller.skippedSentences, [2])
        XCTAssertEqual(engine.parkedCount, 1, "sentence 3 is still being synthesized")
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertNil(settled.outcome, "nothing has been heard yet, so nothing is reported")
        return (h, engine, book, run)
    }

    // MARK: - Continue listening plays the card's book

    func testContinueResumesTheLoadedPausedBook() async throws {
        let h = Harness()
        h.library.documents = [Self.record(h.rig, at: 5)]
        h.rig.loadDefault(at: 5)

        let outcome = await h.actions.continueListening()

        try skipIfTheHostCantPlay(outcome, h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.currentSentence, 5, "it plays from where it was cued")
        XCTAssertEqual(h.library.liveContentCalls, [], "the loaded book is never reloaded")
        XCTAssertEqual(h.mixerVolume, 0)
    }

    func testContinueNeverPausesASpeakingBook() async throws {
        let h = Harness()
        h.library.documents = [Self.record(h.rig, at: 2)]
        h.rig.loadDefault(at: 2)
        h.rig.controller.play()
        try await h.rig.waitUntilPlayingOrSkip()
        let edgeMark = h.rig.edges.count
        let statusMark = h.rig.statuses.count
        let plays = h.rig.controller.userPlayAction

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.nodePauseTimes(from: edgeMark), [], "never paused")
        XCTAssertEqual(Array(h.rig.statuses[statusMark...]), [], "never restarted")
        XCTAssertEqual(h.rig.controller.userPlayAction, plays, "not even a Play")
        XCTAssertEqual(h.library.liveContentCalls, [])
        XCTAssertEqual(h.mixerVolume, 0)
    }

    func testContinueLoadsTheCandidateWhenNothingIsLoaded() async throws {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(h.library.liveContentCalls, [book.id], "loaded once")
        XCTAssertEqual(h.library.openedIDs, [book.id], "stamped opened, as a circle tap is")
        XCTAssertEqual(h.rig.controller.document?.id, book.id)
        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the card's arc is gone")
        try skipIfTheHostCantPlay(outcome, h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "from the saved sentence")
        XCTAssertEqual(h.mixerVolume, 0)
    }

    /// The shortcut and the card agree on which book is "yours": the most
    /// recent in-progress book, or the loaded one at any progress.
    func testContinuePicksTheCardsHero() async throws {
        do {
            let h = Harness()
            let older = Self.record(h.rig, at: 4, openedAgo: 3600, distinct: true)
            let newer = Self.record(h.rig, at: 2, openedAgo: 60, distinct: true)
            let unstarted = Self.record(h.rig, at: 0, openedAgo: 10, distinct: true)
            let shelf = [unstarted, older, newer]
            h.library.documents = shelf
            let hero = try XCTUnwrap(ShelfLayout(for: shelf, loadedID: nil).hero)
            XCTAssertEqual(hero.id, newer.id)

            _ = await h.actions.continueListening()

            XCTAssertEqual(h.library.liveContentCalls, [hero.id])
            XCTAssertEqual(h.rig.controller.document?.id, hero.id)
            XCTAssertEqual(h.mixerVolume, 0)
        }
        do {
            let h = Harness()
            let loaded = Self.record(h.rig, at: 4, openedAgo: 3600)
            let newer = Self.record(h.rig, at: 2, openedAgo: 60, distinct: true)
            let shelf = [loaded, newer]
            h.library.documents = shelf
            h.rig.controller.load(document: loaded, content: h.rig.content)
            let hero = try XCTUnwrap(ShelfLayout(for: shelf, loadedID: loaded.id).hero)
            XCTAssertEqual(hero.id, loaded.id)

            _ = await h.actions.continueListening()

            XCTAssertEqual(h.library.liveContentCalls, [], "the loaded hero just plays")
            XCTAssertEqual(h.rig.controller.document?.id, hero.id)
            XCTAssertEqual(h.mixerVolume, 0)
        }
    }

    // MARK: - Continue listening refuses

    func testNothingToContinue() async {
        let shelves: [(String, (PlaybackTestRig) -> [LibraryDocument])] = [
            ("an empty shelf", { _ in [] }),
            ("only unstarted books", { rig in
                var opened = Self.record(rig, at: 0, distinct: true)
                opened.progressFraction = 0
                return [rig.document, opened]
            }),
        ]
        for (name, shelf) in shelves {
            let h = Harness()
            h.library.documents = shelf(h.rig)

            let outcome = await h.actions.continueListening()

            XCTAssertEqual(outcome, .nothingToContinue, name)
            XCTAssertNil(h.rig.controller.document, name)
            XCTAssertEqual(h.rig.controller.status, .idle, name)
            XCTAssertEqual(h.rig.engineA.requests.count, 0, "\(name): nothing was synthesized")
            XCTAssertEqual(h.library.liveContentCalls, [], name)
            XCTAssertNil(h.continuePlayback.pendingDocumentID, name)
        }
    }

    /// A Finished book on the card is never restarted from a pocket: "Listen
    /// again" is a choice made looking at the screen.
    func testFinishedBookIsNotRestarted() async {
        let h = Harness()
        var finished = Self.record(h.rig, at: h.rig.content.sentences.count - 1)
        finished.progressFraction = 1
        h.library.documents = [finished]
        h.rig.controller.load(document: finished, content: h.rig.content)
        // Let the load's own cue prefetch settle, so only what the shortcut
        // asks for is counted.
        _ = await h.rig.waitUntil(0.3) { false }
        let status = h.rig.controller.status
        let sentence = h.rig.controller.currentSentence
        let statusMark = h.rig.statuses.count
        let requests = h.rig.engineA.requests.count
        let plays = h.rig.controller.userPlayAction

        let outcome = await h.actions.continueListening()
        _ = await h.rig.waitUntil(0.3) { false }

        XCTAssertEqual(outcome, .finished(title: finished.title))
        XCTAssertEqual(h.rig.controller.status, status)
        XCTAssertEqual(h.rig.controller.currentSentence, sentence)
        XCTAssertEqual(Array(h.rig.statuses[statusMark...]), [])
        XCTAssertEqual(h.rig.engineA.requests.count, requests, "nothing was synthesized")
        XCTAssertEqual(h.rig.controller.userPlayAction, plays)
        XCTAssertEqual(h.library.liveContentCalls, [])
    }

    /// The loaded book paused two sentences from its end: its record is past
    /// the Finished threshold (0.99, no word count), but nothing would
    /// restart. Play reads the rest, as the card's circle would.
    func testLoadedBookPausedJustShortOfItsEndResumes() async throws {
        let h = Harness(rig: PlaybackTestRig(sentences: 200, clipDuration: 5))
        let book = Self.record(h.rig, at: 198)
        XCTAssertTrue(book.isFinished, "the record reads Finished")
        h.library.documents = [book]
        h.rig.loadDefault(at: 198)
        XCTAssertEqual(h.rig.controller.status, .paused, "the controller is not at the end")
        let plays = h.rig.controller.userPlayAction

        let outcome = await h.actions.continueListening()

        XCTAssertNotEqual(outcome, .finished(title: book.title))
        XCTAssertEqual(h.rig.controller.userPlayAction, plays + 1, "a Play")
        XCTAssertEqual(h.library.liveContentCalls, [], "the loaded book is never reloaded")
        try skipIfTheHostCantPlay(outcome, h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.currentSentence, 198, "from where it paused, not the top")
        XCTAssertEqual(h.mixerVolume, 0)
    }

    func testLoadFailureReportsCouldNotPlay() async {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        h.library.failure = LoadFailed()

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(outcome, .failed(title: book.title))
        XCTAssertEqual(h.library.liveContentCalls, [book.id])
        XCTAssertEqual(h.library.openedIDs, [])
        XCTAssertNil(h.rig.controller.document)
        XCTAssertNil(h.continuePlayback.pendingDocumentID)
        XCTAssertEqual(h.rig.engineA.requests.count, 0)
    }

    /// Each failed sentence plays a beat of silence, which reaches .playing
    /// before the third failure stops the book. That silence isn't a start:
    /// the shortcut waits for real speech, and the error that comes instead
    /// is said ("Couldn't play …").
    func testSynthesisFailureReportsCouldNotPlay() async {
        let h = Harness(rig: PlaybackTestRig(failing: { _ in true }))
        let book = Self.record(h.rig, at: 2)
        h.library.documents = [book]
        h.rig.loadDefault(at: 2)

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(outcome, .failed(title: book.title))
        XCTAssertEqual(h.rig.controller.status, .error)
        XCTAssertEqual(h.rig.controller.stopReason(for: book.id), .playbackError,
                       "the card and the reader say why, like any failed Play")
        XCTAssertEqual(h.mixerVolume, 0)
    }

    // MARK: - Continue listening yields to the listener

    func testDeletedWhileLoadingIsSuperseded() async {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        let gate = LoadGate()
        h.library.gate = gate
        let actions = h.actions
        let run = Task { await actions.continueListening() }
        let asked = await h.rig.waitUntil { h.library.liveContentCalls.count == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(h.continuePlayback.pendingDocumentID, book.id, "the card shows the shortcut's load")

        h.library.documents = []
        gate.open()
        let outcome = await run.value

        XCTAssertEqual(outcome, .superseded, "nothing to play, nothing to report")
        XCTAssertNil(h.rig.controller.document)
        XCTAssertNil(h.continuePlayback.pendingDocumentID)
        XCTAssertEqual(h.library.openedIDs, [])
        XCTAssertEqual(h.rig.events, [])
    }

    /// A circle tap already loading the hero: the shortcut waits on that load
    /// instead of starting or cancelling one, so the book loads and plays once.
    func testJoinsAPendingCircleLoad() async throws {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        let gate = LoadGate()
        h.library.gate = gate
        let library = h.library
        h.continuePlayback.toggle(book, playback: h.rig.controller,
                                  loader: { try await library.liveContent(for: book) },
                                  onLoaded: { library.noteOpened(id: $0) })
        let plays = h.rig.controller.userPlayAction

        let actions = h.actions
        let run = Task { await actions.continueListening() }
        _ = await h.rig.waitUntil(0.2) { false }   // both loads have had their turn
        XCTAssertEqual(h.continuePlayback.pendingDocumentID, book.id, "joined, never cancelled")
        XCTAssertEqual(h.library.liveContentCalls, [book.id], "the shortcut started no load of its own")

        gate.open()
        let outcome = await run.value

        XCTAssertEqual(h.library.liveContentCalls, [book.id], "the loader ran once")
        XCTAssertEqual(h.library.openedIDs, [book.id])
        XCTAssertEqual(h.rig.controller.document?.id, book.id)
        XCTAssertEqual(h.rig.controller.userPlayAction, plays + 1, "the book was played once")
        try skipIfTheHostCantPlay(outcome, h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.statuses.filter { $0 == .buffering }.count, 1, "one start")
        XCTAssertEqual(h.mixerVolume, 0)
    }

    /// The listener taps the card's circle while the shortcut's load runs:
    /// the tap stops the arc, and the shortcut steps aside.
    func testCircleTapDuringShortcutLoadSupersedes() async {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        let gate = LoadGate()
        h.library.gate = gate
        let actions = h.actions
        let run = Task { await actions.continueListening() }
        let asked = await h.rig.waitUntil { h.library.liveContentCalls.count == 1 }
        XCTAssertTrue(asked)

        h.continuePlayback.toggle(book, playback: h.rig.controller, loader: {
            XCTFail("a second tap on a loading book loads nothing")
            throw CancellationError()
        })
        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the tap stops the arc")
        gate.open()
        let outcome = await run.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(h.rig.controller.document, "the late result is ignored")
        XCTAssertEqual(h.library.openedIDs, [])
        XCTAssertEqual(h.rig.events, [], "nothing was scheduled")
    }

    /// Mark as finished on the card while the shortcut's load runs: the load
    /// stops, so the book is never reopened at its end and played from the
    /// top, and the shortcut steps aside.
    func testMarkAsFinishedDuringShortcutLoadSupersedes() async {
        let h = Harness()
        let book = Self.record(h.rig, at: 3)
        h.library.documents = [book]
        let gate = LoadGate()
        h.library.gate = gate
        let actions = h.actions
        let run = Task { await actions.continueListening() }
        let asked = await h.rig.waitUntil { h.library.liveContentCalls.count == 1 }
        XCTAssertTrue(asked)

        // What LibraryView's Mark as finished does.
        h.continuePlayback.letGo(of: book.id, playback: h.rig.controller)
        h.library.documents = [DocumentStore.markingFinished(book)]
        XCTAssertNil(h.continuePlayback.pendingDocumentID, "the arc stops at once")
        gate.open()
        let outcome = await run.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertNil(h.rig.controller.document, "the late result is ignored")
        XCTAssertEqual(h.library.openedIDs, [])
        XCTAssertEqual(h.rig.events, [], "nothing was scheduled")
    }

    // MARK: - Settling

    /// A cold neural voice can outlast the wait: the deadline counts as
    /// started (the voice is on its way), and playback carries on after it.
    func testDeadlineWhilePreparingCountsAsStarted() async throws {
        let neural = PlaybackTestRig.FakeNeuralEngine()
        // Michael's synthesis waits for the fake's warm-up, as Kokoro's first
        // synthesis pays its model load. The rig's `neural:` init routes him
        // straight to the fake, whose synthesis never waits.
        let rig = PlaybackTestRig(clipDuration: 5, kokoro: neural,
                                  extraRoutes: [PlaybackTestRig.michael.id: ColdNeuralEngine(base: neural)])
        let h = Harness(rig: rig)
        h.rig.controller.voice = PlaybackTestRig.michael
        h.library.documents = [Self.record(h.rig, at: 2)]
        h.rig.loadDefault(at: 2)
        h.startTimeout = 0.2

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.status, .buffering, "still preparing at the deadline")
        XCTAssertTrue(h.rig.controller.isPreparingVoice)
        let mark = h.rig.statuses.count
        neural.finishWarmUp()
        try await h.rig.waitUntilPlayingOrSkip(after: mark)
        XCTAssertEqual(h.mixerVolume, 0)
    }

    /// One sentence the voice can't read: started means the voice is
    /// reading, so it settles once the playhead reaches sentence 3, never
    /// on sentence 2's beat of silence.
    func testOneSkippedSentenceSettlesWhenTheVoiceSpeaks() async throws {
        let h = Harness(rig: PlaybackTestRig(clipDuration: 5, failing: { $0.hasPrefix("Line2 ") }))
        h.library.documents = [Self.record(h.rig, at: 2)]
        h.rig.loadDefault(at: 2)

        let outcome = await h.actions.continueListening()

        try skipUnlessTheAudioStarted(h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "settled on the first sentence spoken")
        XCTAssertEqual(h.rig.controller.skippedSentences, [2])
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.mixerVolume, 0)
    }

    /// The playhead crosses a skipped sentence's silence onto one whose
    /// synthesis hasn't finished, still .playing. Nothing is heard there, so
    /// it isn't a start: a voice failing every sentence slowly is "Couldn't
    /// play", like one failing them at once. Three failures in a row are the
    /// voice's, so the stop hands sentences 2 and 3 back and waits on 2, the
    /// first one never heard (R11's one tap at the same sentence).
    func testPlayheadOnASentenceStillSynthesizingIsNotAStart() async throws {
        let (h, engine, book, run) = try await continueOntoAStalledSentence()

        engine.release(.fail)
        let outcome = await run.value

        XCTAssertEqual(outcome, .failed(title: book.title))
        XCTAssertEqual(h.rig.controller.status, .error)
        XCTAssertEqual(h.rig.controller.stopReason(for: book.id), .playbackError)
        XCTAssertEqual(h.rig.controller.skippedSentences, [])
        XCTAssertEqual(h.rig.controller.currentSentence, 2)
        XCTAssertEqual(h.mixerVolume, 0)
    }

    /// The same stall, then the voice speaks: it settles as sentence 3's
    /// clip reaches the node, not when the playhead next moves (a 5 s clip
    /// later) and not at the deadline (8 s, past that move).
    func testClipLandingUnderThePlayheadSettlesAsStarted() async throws {
        let (h, engine, _, run) = try await continueOntoAStalledSentence(startTimeout: 8)

        engine.release(.speak)
        let outcome = await run.value

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.rig.controller.currentSentence, 3, "settled on sentence 3, still speaking")
        XCTAssertEqual(h.rig.controller.status, .playing)
        XCTAssertEqual(h.rig.controller.skippedSentences, [2])
        XCTAssertEqual(h.mixerVolume, 0)
    }

    func testStartOutcomeTable() {
        let title = "Emma"
        typealias Row = (status: PlayerStatus, speaking: Bool,
                         initial: ContinueListeningOutcome?, later: ContinueListeningOutcome?)
        var expected: [Row] = [
            (.playing, true, .started, .started),
            // A skipped sentence's silence, or a sentence not yet on the node.
            (.playing, false, nil, nil),
        ]
        for speaking in [true, false] {
            expected += [
                (.buffering, speaking, nil, nil),
                (.error, speaking, .failed(title: title), .failed(title: title)),
                (.paused, speaking, .failed(title: title), .superseded),
                (.idle, speaking, .failed(title: title), .superseded),
                (.ended, speaking, .failed(title: title), .superseded),
            ]
        }
        for row in expected {
            XCTAssertEqual(ShortcutActions.startOutcome(status: row.status, speaking: row.speaking,
                                                        initial: true, title: title), row.initial,
                           "\(row.status), speaking \(row.speaking), at the first look")
            XCTAssertEqual(ShortcutActions.startOutcome(status: row.status, speaking: row.speaking,
                                                        initial: false, title: title), row.later,
                           "\(row.status), speaking \(row.speaking), while waiting")
        }
    }

    #if DEBUG
    /// R20: haptics answer the hand. A start from a pocket buzzes nothing.
    func testContinueEmitsNoHaptic() async throws {
        let h = Harness()
        h.library.documents = [Self.record(h.rig, at: 3)]
        TransportHaptics.shared.resetLog()

        let outcome = await h.actions.continueListening()

        XCTAssertEqual(TransportHaptics.shared.log, [])
        try skipIfTheHostCantPlay(outcome, h.rig)
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(h.mixerVolume, 0)
    }
    #endif

    // MARK: - Set sleep timer

    /// The shortcut arms the app's one timer, the one the reader's chip
    /// shows, even with no book loaded.
    func testSetSleepTimerArmsTheChipsTimer() {
        let h = Harness()
        let actions = h.actions

        XCTAssertEqual(actions.setSleepTimer(.thirty), "Sleep timer set for 30 minutes")
        XCTAssertEqual(h.sleepTimer.option, .minutes(30))
        XCTAssertEqual(h.sleepTimer.chipText, "30:00")
        XCTAssertEqual(h.sleepTimer.menuOptions.first, .minutes(30), "listed first next time, like a menu pick")

        XCTAssertEqual(actions.setSleepTimer(.sixty), "Sleep timer set for 1 hour")
        XCTAssertEqual(h.sleepTimer.option, .minutes(60))

        XCTAssertEqual(actions.setSleepTimer(.off), "Sleep timer off")
        XCTAssertFalse(h.sleepTimer.isArmed)

        XCTAssertEqual(actions.setSleepTimer(.endOfChapter), "Sleep timer set for the end of the chapter",
                       "no book yet: the choice's own name")
        XCTAssertEqual(h.sleepTimer.option, .endOfChapter)

        h.rig.loadDefault()
        XCTAssertEqual(actions.setSleepTimer(.endOfChapter), "Sleep timer set for the end of the book")
        XCTAssertFalse(h.sleepTimer.endsAtChapter, "the rig's book has no chapter list")
        XCTAssertEqual(h.sleepTimer.chipText, SleepTimer.Copy.bookEnd)
    }
}
