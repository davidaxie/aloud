import AVFoundation
import Combine
import Foundation

enum PlayerStatus: String, Sendable {
    case idle, buffering, playing, paused, ended, error
}

/// The app's heart. Drives an AVAudioEngine → player → time-pitch graph with
/// gapless look-ahead scheduling. Sentences are the atom of playback: clips are
/// synthesized at 1×, speed applied by the time-pitch unit, and every async
/// continuation is guarded by a monotonic play token.
@MainActor
final class PlaybackController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: PlayerStatus = .idle {
        didSet { wordTimingStatusChanged(status) }   // M3 karaoke display link
    }
    @Published private(set) var currentSentence: Int = -1 {
        didSet {
            currentWord = -1   // a stale word highlight never bleeds into a new sentence
            reportProgress()
        }
    }
    /// Active word (token index into `tokenizeSentence` of the current
    /// sentence), driven by PlaybackController+WordTiming.swift; -1 = none.
    @Published private(set) var currentWord: Int = -1
    @Published var rate: Double = 1.0 {
        didSet {
            let clamped = min(max(rate, 0.5), 3.0)
            if clamped != rate { rate = clamped; return }
            timePitch.rate = Float(rate)
        }
    }
    @Published var voice: TtsVoice {
        didSet {
            guard oldValue != voice else { return }
            applyVoiceOrSkipChange()
        }
    }
    /// Deliberate voice choices only (picker taps, via `selectVoice`).
    /// Programmatic changes — the pre-install system stand-in,
    /// `fallBackToSystemVoice()` — set `voice` directly and never emit here,
    /// so a temporary fallback can't overwrite the stored preference
    /// (AppModel persists from this subject, not from `$voice`).
    let voiceSelections = PassthroughSubject<TtsVoice, Never>()
    @Published var skipBrackets: Bool = true {
        didSet {
            guard oldValue != skipBrackets else { return }
            applyVoiceOrSkipChange()
        }
    }
    @Published var toast: String?
    @Published private(set) var skippedSentences: Set<Int> = []
    @Published private(set) var document: LibraryDocument?
    /// True while the neural engine is loading its model ("Preparing voice…").
    @Published private(set) var isPreparingVoice = false
    /// Bumped when the USER starts playback from a non-active state (play
    /// button, lock-screen play, restart after the end) — never on internal
    /// status flips, buffering blips, or interruption auto-resume. The reader
    /// centers the playhead on these, honoring the Auto-scroll pref.
    @Published private(set) var userPlayAction = 0

    /// True while audio is playing or buffering — "playback is intended".
    /// The single definition every surface (player bar, reader, sleep timer)
    /// consults, so a future status case is classified once.
    var isActive: Bool { status == .playing || status == .buffering }

    /// Mirrored from the word-highlight pref (AppModel). The 30 fps karaoke
    /// display link exists only to feed the reader's word tint, so it runs
    /// only while this is on — the default-off configuration pays zero
    /// per-frame cost. Word windows are still recorded at schedule time, so
    /// flipping the pref on mid-sentence lights up immediately.
    var wordHighlightEnabled = false {
        didSet {
            guard oldValue != wordHighlightEnabled else { return }
            wordTimingStatusChanged(status)
            if !wordHighlightEnabled {
                wordTiming.lastPublished = (-1, -1)
                updateCurrentWord(-1)
            }
        }
    }

    private(set) var content: DocContent?

    /// Progress sink — wire to `DocumentStore.saveProgress` with a weak capture:
    /// `playback.onProgress = { [weak store] in store?.saveProgress(id: $0, sentence: $1, fraction: $2) }`
    var onProgress: ((_ documentID: UUID, _ sentence: Int, _ fraction: Double) -> Void)?

    // MARK: - Dependencies & graph

    private let engine: any TtsEngine
    private let kokoro: KokoroSherpaEngine?
    private let fallbackVoice: TtsVoice
    private let scheduler: SynthesisScheduler
    private let cache: AudioClipCache
    private let audioSession: AudioSessionManager

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var graphFormat: AVAudioFormat?

    // MARK: - Scheduling state

    /// M3 word karaoke: clip windows + display link (PlaybackController+WordTiming.swift).
    let wordTiming = WordKaraokeState()

    private var playToken: UInt64 = 0
    private var scheduleTask: Task<Void, Never>?
    private var lastScheduled = -1
    private var hasActiveSchedule = false
    private var consecutiveFailures = 0
    private var resumeAfterInterruption = false
    private var toastTask: Task<Void, Never>?

    private static let lookAhead = 2
    private static let synthesisAttempts = 3   // 1 try + 2 retries per sentence
    private static let skippedClipDuration = 0.05

    // MARK: - Init

    init(engine: any TtsEngine,
         kokoro: KokoroSherpaEngine? = nil,
         defaultVoice: TtsVoice,
         scheduler: SynthesisScheduler,
         cache: AudioClipCache,
         audioSession: AudioSessionManager) {
        self.engine = engine
        self.kokoro = kokoro
        self.fallbackVoice = defaultVoice
        self.scheduler = scheduler
        self.cache = cache
        self.audioSession = audioSession
        self.voice = defaultVoice

        audioEngine.attach(player)
        audioEngine.attach(timePitch)
        timePitch.rate = 1.0

        audioSession.onInterruption = { [weak self] event in
            self?.handleInterruption(event)
        }
        audioSession.onRouteRequiresPause = { [weak self] in
            self?.pause()
        }
        configureWordTiming()
    }

    // MARK: - Word-timing hooks (implementation in PlaybackController+WordTiming.swift)

    /// Playhead position in 1× media seconds since the player's last stop.
    /// `playerTime` counts source frames, so the time-pitch rate is already
    /// folded in — word windows laid out at natural duration map directly.
    var playerMediaSeconds: TimeInterval? {
        guard let nodeTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: nodeTime),
              time.sampleRate > 0, time.sampleTime >= 0 else { return nil }
        return Double(time.sampleTime) / time.sampleRate
    }

    /// Publishes `currentWord` on change only (called by the display link).
    func updateCurrentWord(_ index: Int) {
        if currentWord != index { currentWord = index }
    }

    // MARK: - Loading

    /// Loads a document, cueing at its saved position. Reloading the document
    /// already playing is a no-op so re-entering the reader never restarts audio.
    func load(document: LibraryDocument, content: DocContent) {
        if self.document?.id == document.id,
           self.content?.contentHash == content.contentHash {
            self.document = document
            return
        }
        invalidateSchedule()
        cache.removeAll()   // clips from the previous document can never replay
        self.document = document
        self.content = content
        skippedSentences = []
        toast = nil
        consecutiveFailures = 0

        if content.sentences.isEmpty {
            status = .idle
            currentSentence = -1
        } else {
            status = .paused
            currentSentence = min(max(document.progressSentence, 0), content.sentences.count - 1)
            cuePrefetch()
        }
    }

    func unload() {
        invalidateSchedule()
        document = nil
        content = nil
        skippedSentences = []
        currentSentence = -1
        status = .idle
    }

    // MARK: - Transport

    /// `userInitiated` marks a deliberate start (button, remote command) as
    /// opposed to programmatic resumes like interruption recovery; only the
    /// former bumps `userPlayAction`.
    func play(userInitiated: Bool = true) {
        guard let content, !content.sentences.isEmpty else { return }
        if userInitiated, !isActive { userPlayAction &+= 1 }
        if status == .ended {
            startPlayback(at: 0)
            return
        }
        if status == .paused, hasActiveSchedule {
            do { try startAudioHardware() } catch { failPlayback(); return }
            player.play()
            status = .playing
            return
        }
        startPlayback(at: max(currentSentence, 0))
    }

    func pause() {
        switch status {
        case .playing:
            player.pause()
            status = .paused
        case .buffering:
            invalidateSchedule()
            status = .paused
            cuePrefetch()
        default:
            break
        }
    }

    func togglePlayPause() {
        if isActive {
            pause()
        } else {
            play()
        }
    }

    /// Sentence-granular seek. Playing keeps playing from the target; paused
    /// cues the target (and warms synthesis) without starting audio.
    func seek(to sentence: Int, andPlay: Bool) {
        guard let content, !content.sentences.isEmpty else { return }
        let target = min(max(sentence, 0), content.sentences.count - 1)
        skippedSentences.remove(target)   // an explicit seek gives it another chance

        if andPlay, !isActive { userPlayAction &+= 1 }   // e.g. restart after .ended
        if andPlay || isActive {
            startPlayback(at: target)
        } else {
            invalidateSchedule()
            status = .paused
            currentSentence = target
            cuePrefetch()
        }
    }

    func nextSentence() { seek(to: currentSentence + 1, andPlay: false) }
    func previousSentence() { seek(to: currentSentence - 1, andPlay: false) }

    // MARK: - Playback core

    private func startPlayback(at index: Int) {
        guard let content, !content.sentences.isEmpty else { return }
        let target = min(max(index, 0), content.sentences.count - 1)
        invalidateSchedule()
        status = .buffering
        if voice.engine == .kokoro, let kokoro, !kokoro.isWarm {
            isPreparingVoice = true   // first synthesis pays the model load
        }
        currentSentence = target
        lastScheduled = target - 1
        consecutiveFailures = 0
        chainTopUp(token: playToken)
    }

    /// Serializes top-up runs by chaining on the previous task, so two loops
    /// can never double-schedule a sentence.
    private func chainTopUp(token: UInt64) {
        let previous = scheduleTask
        scheduleTask = Task { [weak self] in
            _ = await previous?.value
            await self?.topUpSchedule(token: token)
        }
    }

    /// Keeps the player node loaded `lookAhead` sentences past the playhead.
    /// The current sentence rides the `now` lane; look-ahead uses `prefetch`.
    private func topUpSchedule(token: UInt64) async {
        while token == playToken, let content {
            let lastIndex = content.sentences.count - 1
            let horizon = min(currentSentence + Self.lookAhead, lastIndex)
            guard lastScheduled < horizon else { return }

            let next = lastScheduled + 1
            let spoken = SentenceSegmenter.spokenText(content.sentences[next].text,
                                                     skipBrackets: skipBrackets)
            let clip: SynthesizedAudio
            if skippedSentences.contains(next)
                || spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Citation-only / aside-only sentences (spokenText == "" with
                // skip-brackets on) ride this branch: a beat of silence whose
                // completion callback advances to the next sentence.
                clip = .silence(duration: Self.skippedClipDuration)
            } else {
                let key = AudioClipCache.key(voice: voice, skipBrackets: skipBrackets,
                                             contentHash: content.contentHash, sentenceID: next)
                let priority: SynthesisPriority = next == currentSentence ? .now : .prefetch
                do {
                    clip = try await synthesizeWithRetry(spoken, key: key, priority: priority, token: token)
                    guard token == playToken else { return }
                    consecutiveFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    guard token == playToken else { return }
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        // A neural engine that fails globally degrades to the
                        // system voice instead of erroring out.
                        if voice.engine == .kokoro {
                            fallBackToSystemVoice()
                        } else {
                            failPlayback()
                        }
                        return
                    }
                    // Skip-and-continue: one bad sentence never stops the book.
                    skippedSentences.insert(next)
                    showToast("Skipped a sentence the voice couldn't read")
                    scheduleSilence(forSentence: next, token: token)
                    continue
                }
            }
            guard token == playToken else { return }
            scheduleClip(clip, forSentence: next, token: token)
        }
    }

    private func synthesizeWithRetry(_ text: String,
                                     key: String,
                                     priority: SynthesisPriority,
                                     token: UInt64) async throws -> SynthesizedAudio {
        var lastError: Error = TtsError.emptyAudio
        for _ in 0..<Self.synthesisAttempts {
            guard token == playToken else { throw CancellationError() }
            do {
                return try await scheduler.synthesize(text, voice: voice, key: key, priority: priority)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func scheduleSilence(forSentence index: Int, token: UInt64) {
        scheduleClip(.silence(duration: Self.skippedClipDuration), forSentence: index, token: token)
    }

    private func scheduleClip(_ clip: SynthesizedAudio, forSentence index: Int, token: UInt64) {
        if graphFormat == nil || (!hasActiveSchedule && graphFormat?.sampleRate != clip.sampleRate) {
            connectGraph(sampleRate: clip.sampleRate)
        }
        guard let format = graphFormat,
              let buffer = Self.pcmBuffer(from: clip, in: format) else {
            lastScheduled = index   // unplayable clip: bookkeeping moves on
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sentenceFinished(index, token: token)
            }
        }
        lastScheduled = index
        wordTimingRecordScheduled(sentence: index,
                                  frameLength: buffer.frameLength,
                                  sampleRate: format.sampleRate)
        isPreparingVoice = false   // first clip through means the engine is warm

        if !hasActiveSchedule {
            do { try startAudioHardware() } catch { failPlayback(); return }
            player.play()
            hasActiveSchedule = true
            if status == .buffering { status = .playing }
        }
    }

    private func sentenceFinished(_ index: Int, token: UInt64) {
        guard token == playToken, isActive, let content else { return }

        if index >= content.sentences.count - 1 {
            hasActiveSchedule = false
            status = .ended
            reportProgress()
            player.stop()
            return
        }
        currentSentence = index + 1
        chainTopUp(token: token)
    }

    private func invalidateSchedule() {
        playToken &+= 1
        scheduleTask?.cancel()
        hasActiveSchedule = false
        isPreparingVoice = false
        player.stop()
        wordTiming.reset()   // player.stop() rewound the node's sample time
    }

    private func failPlayback() {
        invalidateSchedule()
        isPreparingVoice = false
        status = .error
    }

    // MARK: - Voice / skip changes

    /// A user's explicit voice pick: becomes the active voice and (via
    /// `voiceSelections`) the persisted preference.
    func selectVoice(_ newVoice: TtsVoice) {
        voice = newVoice
        voiceSelections.send(newVoice)
    }

    /// The web app's `reloadCurrent`: purge mismatched clips, drop the queue,
    /// and re-synthesize from the current sentence keeping position and state.
    /// Switching to a cold Kokoro voice warms the engine first, surfacing
    /// "Preparing voice…", and degrades to the system voice on failure.
    private func applyVoiceOrSkipChange() {
        if let content {
            cache.purge(keepingPrefix: AudioClipCache.keyPrefix(
                voice: voice, skipBrackets: skipBrackets, contentHash: content.contentHash))
        } else {
            cache.removeAll()
        }
        Task { await scheduler.cancelPending() }

        guard content != nil, currentSentence >= 0 else { return }
        if voice.engine == .kokoro {
            guard let kokoro else { fallBackToSystemVoice(); return }
            if !kokoro.isWarm {
                prepareNeuralVoice(kokoro)
                return
            }
        }
        reloadCurrent()
    }

    /// Restart or re-cue at the current sentence with the active voice/skip.
    private func reloadCurrent() {
        guard content != nil, currentSentence >= 0 else { return }
        if isActive {
            startPlayback(at: currentSentence)
        } else {
            invalidateSchedule()
            cuePrefetch()
        }
    }

    /// Warms the neural engine off-main (seconds, ~800 MB) before resuming.
    /// A warm-up failure is a global engine failure → automatic system-voice
    /// fallback with a toast, never an error state.
    private func prepareNeuralVoice(_ kokoro: KokoroSherpaEngine) {
        let expected = voice
        if status == .playing {
            invalidateSchedule()
            status = .buffering
        }
        isPreparingVoice = true   // after invalidate, which clears the flag
        Task { [weak self] in
            do {
                try await kokoro.warmUp()
                guard let self, self.voice == expected else {
                    self?.isPreparingVoice = false
                    return
                }
                self.isPreparingVoice = false
                self.reloadCurrent()
            } catch {
                guard let self, self.voice == expected else {
                    self?.isPreparingVoice = false
                    return
                }
                self.isPreparingVoice = false
                self.fallBackToSystemVoice()
            }
        }
    }

    /// Global neural failure: keep reading with the system default voice.
    private func fallBackToSystemVoice() {
        isPreparingVoice = false
        showToast("Neural voice unavailable — using system voice")
        if voice != fallbackVoice {
            voice = fallbackVoice   // didSet re-runs applyVoiceOrSkipChange
        } else {
            reloadCurrent()
        }
    }

    /// Frees the ~800 MB neural engine when it won't be missed: app
    /// backgrounded while paused, or a memory warning while not playing.
    /// The next synthesis transparently re-warms.
    func releaseNeuralEngineIfIdle() {
        guard !isActive else { return }
        kokoro?.release()
    }

    /// Picker/preview hook: a preview may have warmed the ~800 MB neural
    /// engine just for its sample — give it back when the active voice isn't
    /// neural. Playback with a non-neural voice never touches Kokoro (pending
    /// neural work was cancelled on the switch), so this is safe even
    /// mid-play; the next neural synthesis transparently re-warms.
    func releaseNeuralEngineIfUnused() {
        guard voice.engine != .kokoro else { return }
        kokoro?.release()
    }

    /// Warms the cache for the cued sentence and its successor (tap-while-paused cue).
    private func cuePrefetch() {
        guard let content, currentSentence >= 0 else { return }
        let voice = voice
        let skip = skipBrackets
        let upper = min(currentSentence + 1, content.sentences.count - 1)
        for index in currentSentence...upper where !skippedSentences.contains(index) {
            let spoken = SentenceSegmenter.spokenText(content.sentences[index].text, skipBrackets: skip)
            guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = AudioClipCache.key(voice: voice, skipBrackets: skip,
                                         contentHash: content.contentHash, sentenceID: index)
            Task { await scheduler.prefetch(spoken, voice: voice, key: key) }
        }
    }

    // MARK: - Audio graph

    private func connectGraph(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return }
        audioEngine.connect(player, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        graphFormat = format
    }

    private func startAudioHardware() throws {
        try? audioSession.activate()   // session failure alone shouldn't block simulator playback
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    /// Builds a PCM buffer in the graph's format, resampling when a clip's
    /// rate differs from the established connection (keeps gapless scheduling).
    private static func pcmBuffer(from clip: SynthesizedAudio,
                                  in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !clip.samples.isEmpty,
              let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: clip.sampleRate,
                                               channels: 1,
                                               interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { return nil }

        source.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { pointer in
            source.floatChannelData![0].update(from: pointer.baseAddress!, count: clip.samples.count)
        }
        if format.sampleRate == clip.sampleRate { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
        let capacity = AVAudioFrameCount(
            (Double(clip.samples.count) * format.sampleRate / clip.sampleRate).rounded(.up) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        converter.convert(to: converted, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        return converted.frameLength > 0 ? converted : nil
    }

    // MARK: - Interruptions

    private func handleInterruption(_ event: AudioSessionManager.Interruption) {
        switch event {
        case .began:
            if isActive {
                resumeAfterInterruption = true
                pause()
            }
        case .ended(let shouldResume):
            // Auto-resume is not a user action — no `userPlayAction` bump,
            // so the reader never re-centers on interruption recovery.
            if resumeAfterInterruption && shouldResume { play(userInitiated: false) }
            resumeAfterInterruption = false
        }
    }

    // MARK: - Progress & toast

    private func reportProgress() {
        guard let document, let content, !content.sentences.isEmpty, currentSentence >= 0 else { return }
        let fraction = status == .ended
            ? 1.0
            : Double(currentSentence) / Double(content.sentences.count)
        onProgress?(document.id, currentSentence, fraction)
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
