import AVFoundation
import Combine
import XCTest
@testable import Aloud

/// The shared silent harness for PlaybackController tests: a controller built
/// with `outputMuted: true` over stub engines that return silence, with every
/// observable output recorded. No test built on it can make a sound, and its
/// anchor and stop stores live on a fresh defaults suite, never the app's.
///
/// The engine routes by voice id — `voiceA` to `engineA`, `voiceB` to
/// `engineB`, plus any `extraRoutes` — so a test can tell which voice was
/// asked to speak what. `init(sentences:clipDuration:neural:)` adds `michael`
/// on a FakeNeuralEngine whose warm-up the test finishes by hand. `failing`
/// makes `voiceA` throw for the texts it matches.
///
/// Frozen in Phase 3 wave 2: later tests add helpers in their own files.
@MainActor
final class PlaybackTestRig {

    // MARK: - Engines

    /// Silence of a fixed length for every request, recording (text, voice id).
    final class RecordingEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let clipDuration: TimeInterval
        private let sampleRate: Double
        private let lock = NSLock()
        private var log: [(text: String, voiceID: String)] = []

        init(voices: [TtsVoice], clipDuration: TimeInterval = 0.25, sampleRate: Double = 22_050) {
            self.voices = voices
            self.clipDuration = clipDuration
            self.sampleRate = sampleRate
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            // Scoped, so the lock is never held across a suspension point.
            lock.withLock { log.append((text, voice.id)) }
            return .silence(duration: clipDuration, sampleRate: sampleRate)
        }

        var requests: [(text: String, voiceID: String)] { lock.withLock { log } }
        var requestedTexts: [String] { requests.map(\.text) }
    }

    /// Throws `TtsError.voiceUnavailable` for every text `failing` matches;
    /// forwards everything else to `base`.
    final class FailingEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let base: any TtsEngine
        private let failing: @Sendable (String) -> Bool

        init(base: any TtsEngine, failing: @escaping @Sendable (String) -> Bool) {
            self.voices = base.voices
            self.base = base
            self.failing = failing
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await synthesize(text, voice: voice, speed: 1.0)
        }

        func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
            if failing(text) { throw TtsError.voiceUnavailable }
            return try await base.synthesize(text, voice: voice, speed: speed)
        }
    }

    /// Hands each request to the engine registered for its voice id.
    final class RoutingEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        private let routes: [String: any TtsEngine]
        private let fallback: any TtsEngine

        init(routes: [String: any TtsEngine], fallback: any TtsEngine) {
            self.routes = routes
            self.fallback = fallback
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await synthesize(text, voice: voice, speed: 1.0)
        }

        /// The pace reaches the routed engine (`NativeSpeed`).
        func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
            try await (routes[voice.id] ?? fallback).synthesize(text, voice: voice, speed: speed)
        }
    }

    /// A stand-in for Kokoro: silent 24 kHz clips (the system stubs use
    /// 22.05 kHz, so a splice also exercises the resampler), and a warm-up
    /// that stays pending until the test calls `finishWarmUp`.
    final class FakeNeuralEngine: WarmableTtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = [KokoroVoiceCatalog.defaultVoice]
        private let lock = NSLock()
        private var warm: Bool
        private var waiters: [CheckedContinuation<Void, Error>] = []
        /// A failing finish that came before anyone waited fails the next wait.
        private var failsNextWarmUp = false
        private var warmUps = 0
        private var log: [(text: String, voiceID: String)] = []

        init(warm: Bool = false) {
            self.warm = warm
        }

        var isWarm: Bool { lock.withLock { warm } }

        /// Every `warmUp()` call, warm or not.
        var warmUpCalls: Int { lock.withLock { warmUps } }

        func warmUp() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome: Result<Void, Error>? = lock.withLock {
                    warmUps += 1
                    if warm { return .success(()) }
                    if failsNextWarmUp {
                        failsNextWarmUp = false
                        return .failure(TtsError.voiceUnavailable)
                    }
                    waiters.append(continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        }

        /// Ends the warm-up: warm (unless `failing`), and every parked wait
        /// resumes, throwing when `failing`. A finish before the wait never
        /// hangs it.
        func finishWarmUp(failing: Bool = false) {
            let parked: [CheckedContinuation<Void, Error>] = lock.withLock {
                if failing {
                    failsNextWarmUp = waiters.isEmpty
                } else {
                    warm = true
                }
                let parked = waiters
                waiters = []
                return parked
            }
            for continuation in parked {
                if failing {
                    continuation.resume(throwing: TtsError.voiceUnavailable)
                } else {
                    continuation.resume()
                }
            }
        }

        func release() {
            lock.withLock { warm = false }
        }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            lock.withLock { log.append((text, voice.id)) }
            return .silence(duration: 0.25, sampleRate: 24_000)
        }

        var requests: [(text: String, voiceID: String)] { lock.withLock { log } }
    }

    /// The output monitor, driven by hand: `onRouteRequiresPause` and
    /// `onInterruption` are fired directly, a configuration change gets
    /// `decision` (`.ignore` unless a test sets it), and what the controller
    /// asked is counted. Activation still goes to the real session, as the
    /// app's does, so the engine starts as it always has, unless a test sets
    /// `activationError` (a call holding the audio).
    @MainActor
    final class FakeAudioOutput: AudioOutputMonitoring {
        var onInterruption: ((AudioInterruption) -> Void)?
        var onRouteRequiresPause: (() -> Void)?
        var decision: RouteDecision = .ignore
        var activationError: (any Error)?
        private(set) var decisionsAsked = 0
        private(set) var bindings = 0
        private(set) var activations = 0
        private(set) var deactivations = 0
        private let session = PlatformAudioOutput.makeMonitor()

        func activate() throws {
            activations += 1
            if let activationError { throw activationError }
            try session.activate()
        }
        func deactivate() {
            deactivations += 1
            session.deactivate()
        }
        func bindOutput(of engine: AVAudioEngine) { bindings += 1 }

        func decisionAfterConfigurationChange() -> RouteDecision {
            decisionsAsked += 1
            return decision
        }
    }

    static let voiceA = TtsVoice(id: "test:a", name: "Alpha", lang: "en-US",
                                 gender: "f", engine: .avSpeech, quality: 1)
    static let voiceB = TtsVoice(id: "test:b", name: "Bravo", lang: "en-US",
                                 gender: "f", engine: .avSpeech, quality: 1)
    /// The R5 install target, "Michael".
    static let michael = KokoroVoiceCatalog.defaultVoice

    // MARK: - Parts

    let engineA: RecordingEngine
    let engineB: RecordingEngine
    let controller: PlaybackController
    let scheduler: SynthesisScheduler
    let cache: AudioClipCache
    /// Drive `onRouteRequiresPause` / `onInterruption` directly; never post
    /// the global AVAudioSession notifications (the host app observes them).
    let audioSession: FakeAudioOutput
    /// Where the controller's lifecycle events (system sleep) arrive, so a
    /// test never posts them to the host app.
    let lifecycle = NotificationCenter()
    /// The rig's own suite: both stores live here.
    let defaults: UserDefaults
    let anchorStore: ResumeAnchorStore
    let stopStore: PlaybackStopStore
    /// The rig's default book: `sentences` sentences of `wordsPerSentence` words.
    let content: DocContent
    let document: LibraryDocument

    // MARK: - Recorded outputs

    private(set) var events: [PlaybackController.AudioScheduleEvent] = []
    private(set) var statuses: [PlayerStatus] = []
    private(set) var announcements: [String] = []
    private(set) var progress: [(documentID: UUID, sentence: Int, fraction: Double)] = []
    /// Every audio edge, stamped on the monotonic clock.
    private(set) var edges: [(time: TimeInterval, event: PlaybackController.AudioEdgeEvent)] = []
    /// What the controller's `isAppActive` answers.
    var appActive = true
    private var subscriptions: Set<AnyCancellable> = []

    init(sentences: Int = 12,
         wordsPerSentence: Int = 3,
         clipDuration: TimeInterval = 0.25,
         autoplaySuppressed: Bool = false,
         mutedOutputMode: MutedOutputMode = PlatformAudio.mutedOutputMode,
         kokoro: (any WarmableTtsEngine)? = nil,
         extraRoutes: [String: any TtsEngine] = [:],
         failing: (@Sendable (String) -> Bool)? = nil) {
        // A local, not `self.engineA`: the closure below may not capture
        // self before every stored property is set.
        let recordingA = RecordingEngine(voices: [Self.voiceA], clipDuration: clipDuration)
        engineA = recordingA
        engineB = RecordingEngine(voices: [Self.voiceB], clipDuration: clipDuration)
        let voiceAEngine: any TtsEngine = failing.map { FailingEngine(base: recordingA, failing: $0) } ?? recordingA
        var routes: [String: any TtsEngine] = [Self.voiceA.id: voiceAEngine, Self.voiceB.id: engineB]
        routes.merge(extraRoutes) { _, extra in extra }
        let router = RoutingEngine(routes: routes, fallback: engineA)

        // A fresh defaults suite per rig: the app's real anchor and stop are
        // never touched.
        defaults = Self.freshDefaults()
        anchorStore = ResumeAnchorStore(defaults: defaults)
        stopStore = PlaybackStopStore(defaults: defaults)

        cache = AudioClipCache()
        audioSession = FakeAudioOutput()
        scheduler = SynthesisScheduler(engine: router, cache: cache)
        controller = PlaybackController(engine: router,
                                        kokoro: kokoro,
                                        defaultVoice: Self.voiceA,
                                        scheduler: scheduler,
                                        cache: cache,
                                        audioSession: audioSession,
                                        anchorStore: anchorStore,
                                        stopStore: stopStore,
                                        outputMuted: true,
                                        mutedOutputMode: mutedOutputMode,
                                        autoplaySuppressed: autoplaySuppressed,
                                        lifecycle: lifecycle)
        content = Self.makeContent(hash: "rig-hash", count: sentences, wordsPerSentence: wordsPerSentence)
        document = Self.makeDocument(hash: "rig-hash", sentences: sentences)

        controller.announce = { [weak self] in self?.announcements.append($0) }
        controller.isAppActive = { [weak self] in self?.appActive ?? true }
        controller.onAudioEdge = { [weak self] in self?.edges.append((MonotonicClock.now, $0)) }
        controller.onAudioScheduleEvent = { [weak self] in self?.events.append($0) }
        controller.onProgress = { [weak self] id, sentence, fraction in
            self?.progress.append((id, sentence, fraction))
        }
        controller.$status
            .sink { [weak self] in self?.statuses.append($0) }
            .store(in: &subscriptions)
    }

    /// `voiceA` is the system voice; `michael` speaks through `neural`, which
    /// is also the controller's warmable engine.
    convenience init(sentences: Int = 12, clipDuration: TimeInterval = 0.25, neural: FakeNeuralEngine) {
        self.init(sentences: sentences, clipDuration: clipDuration,
                  kokoro: neural, extraRoutes: [Self.michael.id: neural])
    }

    /// Forgets the recorded statuses, schedule events, announcements and
    /// audio edges, so a test can assert on what happens from here on.
    func clearRecordings() {
        statuses = []
        events = []
        announcements = []
        edges = []
    }

    /// The requested levels written from edge index `mark` on.
    func volumes(from mark: Int = 0) -> [(time: TimeInterval, value: Float)] {
        edges[min(mark, edges.count)...].compactMap { edge in
            if case .volume(let value) = edge.event { return (edge.time, value) }
            return nil
        }
    }

    /// When the player node paused, from edge index `mark` on.
    func nodePauseTimes(from mark: Int = 0) -> [TimeInterval] {
        edges[min(mark, edges.count)...].compactMap { $0.event == .nodePaused ? $0.time : nil }
    }

    // MARK: - Fixtures

    /// An empty defaults suite of its own, for any store a test builds.
    static func freshDefaults() -> UserDefaults {
        let suite = "aloud.tests.playbackRig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Sentence `i` reads "Line<i> word word…" with `wordsPerSentence` words,
    /// so an engine request names the sentence it was for. `pages` gives
    /// each sentence's page (chapters for a text book); each run of one page
    /// is a paragraph. Nil puts everything on page 0.
    static func makeContent(hash: String, count: Int, wordsPerSentence: Int = 3,
                            pages: [Int]? = nil) -> DocContent {
        precondition(pages == nil || pages?.count == count, "one page per sentence")
        let pageOf: (Int) -> Int = { pages?[$0] ?? 0 }
        var paragraphs: [Paragraph] = []
        var sentences: [Sentence] = []
        for index in 0..<count {
            if index == 0 || pageOf(index) != pageOf(index - 1) {
                paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: index..<index, page: pageOf(index)))
            }
            let last = paragraphs.removeLast()
            paragraphs.append(Paragraph(id: last.id, sentenceIDs: last.sentenceIDs.lowerBound..<(index + 1),
                                        page: last.page))
            let words = ["Line\(index)"] + Array(repeating: "word", count: max(wordsPerSentence - 1, 0))
            sentences.append(Sentence(id: index, text: words.joined(separator: " ") + ".",
                                      para: last.id, page: pageOf(index)))
        }
        return DocContent(title: "Rig",
                          pageCount: (pages?.max() ?? 0) + 1,
                          sentences: sentences,
                          paragraphs: paragraphs,
                          contentHash: hash)
    }

    static func makeDocument(hash: String,
                             sentences: Int,
                             progressSentence: Int = 0,
                             progressFraction: Double = 0) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Rig \(hash)", fileName: "\(hash).txt",
                        addedAt: Date(), pageCount: 1, sentenceCount: sentences,
                        progressSentence: progressSentence, progressFraction: progressFraction,
                        contentHash: hash, kind: .text)
    }

    /// Loads the rig's default book, cued (paused) at `sentence`.
    func loadDefault(at sentence: Int = 0) {
        var cued = document
        cued.progressSentence = sentence
        controller.load(document: cued, content: content)
    }

    /// The sentence index an engine request was made for (see `makeContent`).
    static func sentenceIndex(ofRequest text: String) -> Int? {
        guard text.hasPrefix("Line") else { return nil }
        return Int(text.dropFirst(4).prefix { $0.isNumber })
    }

    /// Requests `engine` made for sentence indices (the sample line excluded).
    func requestedSentences(_ engine: RecordingEngine) -> [Int] {
        engine.requestedTexts.compactMap(Self.sentenceIndex(ofRequest:))
    }

    // MARK: - Waiting

    /// Polls `condition` every 20 ms; false when `timeout` passes first.
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Waits until the statuses recorded from index `mark` on include
    /// `.playing` (so a brief audition can't slip between polls). Throws
    /// XCTSkip when `.error` comes first: the headless audio engine couldn't
    /// start in this test host.
    func waitUntilPlayingOrSkip(after mark: Int = 0,
                                timeout: TimeInterval = 5,
                                file: StaticString = #filePath,
                                line: UInt = #line) async throws {
        _ = await waitUntil(timeout) {
            statuses[mark...].contains(.playing) || statuses[mark...].contains(.error)
        }
        let tail = statuses[mark...]
        if let error = tail.firstIndex(of: .error),
           tail.firstIndex(of: .playing).map({ error < $0 }) ?? true {
            throw XCTSkip("The audio engine can't start in this test host")
        }
        XCTAssertTrue(tail.contains(.playing), "never reached .playing", file: file, line: line)
    }
}
