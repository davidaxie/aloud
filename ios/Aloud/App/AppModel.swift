import Combine
import Foundation
import UIKit

/// What a speed or voice pick is FOR. The speed sheet and the voice picker are
/// each presented from two places that mean different things by the same tap,
/// and only the presenting screen knows which: the player bar is choosing for
/// the book on screen, Settings is choosing the default every unpinned book
/// follows. Nothing downstream can infer this — a book stays loaded in the
/// controller long after the reader is gone — so the pick site declares it.
enum PreferenceScope {
    /// The player bar, inside the reader: pins the loaded book.
    case book
    /// The Settings screen: writes the global default.
    case global
}

/// Composition root. Builds the object graph once, restores preferences,
/// and persists them as they change.
@MainActor
final class AppModel: ObservableObject {

    let documentStore: DocumentStore
    let engine: AVSpeechEngine
    let kokoroEngine: KokoroSherpaEngine
    let modelManager: ModelManager
    let clipCache: AudioClipCache
    let scheduler: SynthesisScheduler
    let audioSession: AudioSessionManager
    let playback: PlaybackController
    let nowPlaying = NowPlayingManager()
    let bookshelf: [BookshelfBook]

    /// Memory gate: the 800 MB neural engine is only offered on ≥6 GB devices
    /// (simulators inherit the Mac's memory and pass).
    let neuralVoiceOffered = ModelManager.deviceSupportsNeuralVoice

    @Published var autoScroll: Bool {
        didSet { UserDefaults.standard.set(autoScroll, forKey: PrefKey.autoScroll) }
    }

    /// Color-only tint of the spoken word in the reader. OFF by default —
    /// the default experience is the calm sentence pill only.
    @Published var wordHighlight: Bool {
        didSet {
            UserDefaults.standard.set(wordHighlight, forKey: PrefKey.wordHighlight)
            // The controller gates its 30 fps word-timing display link on this.
            playback.wordHighlightEnabled = wordHighlight
        }
    }

    /// The global default speed: the baseline every book without a pin of its
    /// own follows. Published so the shelf's time-left estimates track it —
    /// `playback.rate` is the LOADED book's rate and says nothing about the
    /// other cards.
    @Published private(set) var globalRate: Double

    /// The global default voice, resolved against the curated roster. Same
    /// relationship to `playback.voice` as `globalRate` has to `playback.rate`:
    /// the controller's voice belongs to the loaded book (which may be pinned
    /// to something else, or standing in as system while the model is absent),
    /// so Settings shows and edits THIS.
    @Published private(set) var globalVoice: TtsVoice

    private var cancellables: Set<AnyCancellable> = []
    private var didRunLaunchTasks = false

    init() {
        let defaults = UserDefaults.standard

        // UI-test hook (compiled out of Release): start from an empty shelf so
        // leftover container state never leaks into a test run. Destructive,
        // so it happens here at the composition root — before the store is
        // built — next to the other launch-argument hooks, never as a side
        // effect of constructing a store.
        #if DEBUG
        if UITestHooks.resetLibrary {
            DocumentStore.wipeAllData()
        }
        #endif

        documentStore = DocumentStore()
        engine = AVSpeechEngine()
        modelManager = ModelManager()
        kokoroEngine = KokoroSherpaEngine(modelDirectory: modelManager.installDirectory)
        clipCache = AudioClipCache()
        let router = EngineRouter(system: engine, kokoro: kokoroEngine)
        scheduler = SynthesisScheduler(engine: router, cache: clipCache)
        audioSession = AudioSessionManager()
        playback = PlaybackController(engine: router,
                                      kokoro: kokoroEngine,
                                      defaultVoice: engine.defaultVoice,
                                      scheduler: scheduler,
                                      cache: clipCache,
                                      audioSession: audioSession)
        bookshelf = BookshelfCatalog.load(from: .main)
        nowPlaying.configure(playback: playback, store: documentStore)
        globalRate = PlaybackController.clampedRate(
            defaults.object(forKey: PrefKey.rate) as? Double ?? 1.0)
        globalVoice = engine.defaultVoice   // provisional; restorePreferences resolves it
        autoScroll = defaults.object(forKey: PrefKey.autoScroll) as? Bool ?? true
        wordHighlight = defaults.object(forKey: PrefKey.wordHighlight) as? Bool ?? false
        playback.wordHighlightEnabled = wordHighlight   // didSet doesn't fire in init

        // UI-test hook (no-op in Release): start from a clean voice preference.
        if UITestHooks.resetVoicePref {
            defaults.removeObject(forKey: PrefKey.voiceID)
        }

        migratePreferences(defaults)
        restorePreferences(from: defaults)
        persistPreferenceChanges(to: defaults)
        observeModelState()
        observeMemoryWarnings()

        // Persist progress even when playback continues outside the reader.
        playback.onProgress = { [weak documentStore] id, sentence, fraction in
            documentStore?.saveProgress(id: id, sentence: sentence, fraction: fraction)
        }

        // Per-book playback memory: a freshly loaded document applies its
        // stored rate/voice (else the global defaults).
        playback.onDocumentLoaded = { [weak self] document in
            self?.applyDocumentPreferences(document)
        }
    }

    /// One-time work on first appearance of the root view.
    func performLaunchTasks() async {
        guard !didRunLaunchTasks else { return }
        didRunLaunchTasks = true

        // UI-test hook (no-op in Release): seed the library with the first
        // bookshelf classic.
        if UITestHooks.seedFirstClassic, let first = bookshelf.first {
            _ = try? await documentStore.addClassic(first)
        }
    }

    /// Scene-phase hook (from RootView): a backgrounded, non-playing app
    /// gives back the neural engine's memory.
    func handleScenePhaseChange(toBackground: Bool) {
        guard toBackground else { return }
        playback.releaseNeuralEngineIfIdle()
    }

    // MARK: - Model lifecycle

    /// Tracks install-state transitions both ways. Model deleted (or download
    /// reverted) while a Kokoro voice is active → drop back to the system
    /// voice (a stand-in — the stored pref survives) and free the engine.
    /// Model installed mid-session → re-engage the voice preference so the
    /// neural default speaks without a relaunch.
    private func observeModelState() {
        modelManager.$state
            .map { state -> Bool in
                if case .installed = state { return true }
                return false
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] installed in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if installed {
                        self.handleModelInstalled()
                    } else {
                        if self.playback.voice.engine == .kokoro {
                            self.playback.voice = self.engine.defaultVoice   // stand-in; pref kept
                        }
                        self.kokoroEngine.release()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// The model just installed: re-apply the resolved preference — the
    /// stored Kokoro pref the system voice was standing in for, an explicit
    /// "system" choice (which stays put), or the neural default when nothing
    /// was ever chosen. A retired Kokoro id's upgrade to the current default
    /// becomes final now, so persist that resolution once.
    private func handleModelInstalled() {
        let defaults = UserDefaults.standard
        let resolved = resolvedVoicePreference(from: defaults)
        globalVoice = resolved
        if let stored = defaults.string(forKey: PrefKey.voiceID), stored != resolved.id {
            defaults.set(resolved.id, forKey: PrefKey.voiceID)
        }
        // The loaded book re-resolves through the same seam a Settings pick
        // uses — its own Kokoro pick was standing in as system until now, and
        // a book with no stored voice resolves to exactly `resolved` anyway,
        // so there is no second precedence rule here.
        reapplyPlaybackPreferences()
    }

    private func observeMemoryWarnings() {
        NotificationCenter.default
            .publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.playback.releaseNeuralEngineIfIdle()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Preferences

    private enum PrefKey {
        static let voiceID = "aloud.prefs.v1.voiceID"
        static let rate = "aloud.prefs.v1.rate"
        static let skipBrackets = "aloud.prefs.v1.skipBrackets"
        static let autoScroll = "aloud.prefs.v1.autoScroll"
        static let wordHighlight = "aloud.prefs.v1.wordHighlight"
        static let migratedV2 = "aloud.prefs.migratedV2"
    }

    /// One-shot versioned migrations, guarded by `migratedV2`.
    /// V2: skip-brackets became the default — an install that had explicitly
    /// turned it OFF flips to ON once (an unset value keeps following the
    /// compiled-in default, so future default changes still flow), and the
    /// system roster collapsed to the single stable "system" id — a stored
    /// concrete AVSpeech identifier becomes "system" so the pref survives
    /// installed-voice changes. Retired Kokoro ids are deliberately NOT
    /// rewritten here: `resolveVoicePreference` maps them per launch, and the
    /// upgrade to the current default only persists once a model install
    /// makes it final (`handleModelInstalled`).
    private func migratePreferences(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: PrefKey.migratedV2) else { return }
        if defaults.object(forKey: PrefKey.skipBrackets) != nil {
            defaults.set(true, forKey: PrefKey.skipBrackets)
        }
        if let voiceID = defaults.string(forKey: PrefKey.voiceID),
           !voiceID.hasPrefix(KokoroVoiceCatalog.voiceIDPrefix),
           voiceID != AVSpeechEngine.systemVoiceID {
            defaults.set(AVSpeechEngine.systemVoiceID, forKey: PrefKey.voiceID)
        }
        defaults.set(true, forKey: PrefKey.migratedV2)
    }

    private func restorePreferences(from defaults: UserDefaults) {
        playback.rate = globalRate
        if let skip = defaults.object(forKey: PrefKey.skipBrackets) as? Bool {
            playback.skipBrackets = skip
        }
        globalVoice = resolvedVoicePreference(from: defaults)
        applyVoicePreference(globalVoice)
    }

    // MARK: - Voice preference

    /// Pure resolution of a stored voice id against the curated roster:
    /// a curated id maps to its voice; a retired Kokoro speaker maps to the
    /// neural default; any other id (a legacy concrete AVSpeech identifier)
    /// maps to the stable system voice; nothing stored means the preferred
    /// default for the device. Static so it's unit-testable.
    nonisolated static func resolveVoicePreference(storedID: String?,
                                                   curated: [TtsVoice],
                                                   neuralDefault: TtsVoice,
                                                   systemDefault: TtsVoice,
                                                   modelInstalled: Bool) -> TtsVoice {
        guard let storedID else { return modelInstalled ? neuralDefault : systemDefault }
        if let voice = curated.first(where: { $0.id == storedID }) { return voice }
        return storedID.hasPrefix(KokoroVoiceCatalog.voiceIDPrefix)
            ? neuralDefault : systemDefault
    }

    private func resolvedVoicePreference(from defaults: UserDefaults) -> TtsVoice {
        Self.resolveVoicePreference(storedID: defaults.string(forKey: PrefKey.voiceID),
                                    curated: kokoroEngine.voices + engine.voices,
                                    neuralDefault: kokoroEngine.defaultVoice,
                                    systemDefault: engine.defaultVoice,
                                    modelInstalled: modelManager.isInstalled)
    }

    /// Applies a resolved preference: Kokoro voices only engage while the
    /// model is installed — otherwise the system voice silently stands in
    /// and the stored pref survives (`handleModelInstalled` re-engages it).
    private func applyVoicePreference(_ voice: TtsVoice) {
        if voice.engine == .kokoro, !modelManager.isInstalled {
            playback.voice = engine.defaultVoice   // stand-in; pref kept
        } else {
            playback.voice = voice
        }
    }

    /// Speed and voice persist ONLY through the controller's deliberate-pick
    /// seams — `rateSelections` (preset chips, slider release) and
    /// `voiceSelections` (picker taps). Every programmatic write goes to
    /// `rate`/`voice` directly and is structurally excluded: launch restore,
    /// the per-book apply on load, the pre-install voice stand-in,
    /// neural-failure degradation, and each intermediate step of a live
    /// slider drag. So an apply — or a fallback — can never be written back
    /// as a preference, and both channels are opt-in the same way.
    ///
    /// These two subjects carry the READER's picks only. Settings' picks mean
    /// the global defaults and arrive through `selectGlobalRate` /
    /// `selectGlobalVoice`; both intents meet again at `persistUserSelection`.
    /// Skip-brackets has no per-book dimension and still persists on change.
    private func persistPreferenceChanges(to defaults: UserDefaults) {
        playback.rateSelections
            .sink { [weak self] rate in
                self?.persistUserSelection(rate: rate, scope: .book)
            }
            .store(in: &cancellables)

        playback.$skipBrackets
            .dropFirst()
            .removeDuplicates()
            .sink { defaults.set($0, forKey: PrefKey.skipBrackets) }
            .store(in: &cancellables)

        playback.voiceSelections
            .sink { [weak self] voice in
                self?.persistUserSelection(voice: voice, scope: .book)
            }
            .store(in: &cancellables)
    }

    // MARK: - Per-book playback memory

    /// The one write seam for a deliberate user pick: `pinTarget` decides
    /// whether it lands on a book or on the global defaults, and this is the
    /// only place that decision is acted on.
    private func persistUserSelection(rate: Double? = nil,
                                      voice: TtsVoice? = nil,
                                      scope: PreferenceScope) {
        if let id = Self.pinTarget(scope: scope,
                                   loadedDocumentID: playback.document?.id,
                                   in: documentStore.documents) {
            documentStore.setPreferredPlayback(id: id, rate: rate, voiceID: voice?.id)
        } else {
            persistGlobalDefault(rate: rate, voice: voice)
        }
    }

    // MARK: - Global defaults (the Settings screen's seam)

    /// Settings' speed pick. Writes the default every unpinned book follows,
    /// then re-resolves the loaded book against it: a book with a pin of its
    /// own keeps that pin, an unpinned one follows the new default at once
    /// instead of waiting for a reload.
    func selectGlobalRate(_ rate: Double) {
        persistUserSelection(rate: PlaybackController.clampedRate(rate), scope: .global)
        reapplyPlaybackPreferences()
    }

    /// Settings' voice pick — the global-default twin of `selectGlobalRate`.
    func selectGlobalVoice(_ voice: TtsVoice) {
        persistUserSelection(voice: voice, scope: .global)
        reapplyPlaybackPreferences()
    }

    /// The one place the global defaults are written, reached either by a
    /// Settings pick or by a reader pick with no pinnable book to land on.
    private func persistGlobalDefault(rate: Double? = nil, voice: TtsVoice? = nil) {
        let defaults = UserDefaults.standard
        if let rate {
            defaults.set(rate, forKey: PrefKey.rate)
            globalRate = rate
        }
        if let voice {
            defaults.set(voice.id, forKey: PrefKey.voiceID)
            globalVoice = voice
        }
    }

    /// Re-resolves what the loaded book should be playing at, against the
    /// CURRENT globals — used whenever a global shifts underneath it (a
    /// Settings pick, a model install). Same precedence as a fresh load, and
    /// through the same non-persisting seams, so nothing here is written back
    /// as a preference.
    private func reapplyPlaybackPreferences() {
        if let id = playback.document?.id,
           let record = documentStore.documents.first(where: { $0.id == id }) {
            applyDocumentPreferences(record)
        } else {
            playback.rate = globalRate
            applyVoicePreference(globalVoice)
        }
    }

    /// Which record a pick pins to, or nil for "write the global default".
    ///
    /// A `.global` pick — made on the Settings screen — never pins, no matter
    /// what is loaded. This is the whole rule: `playback.document` is set by
    /// `load()` and cleared only by `unload()`, which nothing calls, so once
    /// the user has opened a single book it stays non-nil for the rest of the
    /// process. Inferring intent from it would quietly pin every later change
    /// to the *defaults* onto the last book read, leaving the global voice and
    /// speed unwritable forever after the first book.
    ///
    /// A `.book` pick pins the loaded document, but only while the library
    /// still holds it: deleting the loaded book leaves it loaded in the
    /// controller, and `setPreferredPlayback` drops a write for an id it can't
    /// find — so a pick made after that delete falls through to the global
    /// default rather than vanishing. Static so it's unit-testable.
    nonisolated static func pinTarget(scope: PreferenceScope,
                                      loadedDocumentID: UUID?,
                                      in documents: [LibraryDocument]) -> UUID? {
        guard scope == .book else { return nil }
        guard let loadedDocumentID,
              documents.contains(where: { $0.id == loadedDocumentID }) else { return nil }
        return loadedDocumentID
    }

    /// Per-book voice: a stored per-book id engages only while it's still on
    /// the curated roster (the eight Kokoro voices or the stable "system"
    /// id). Anything else — a retired speaker, a legacy identifier, nothing
    /// stored — falls back to the GLOBAL preference resolution, and the
    /// caller must not persist that fallback. Static so it's unit-testable.
    nonisolated static func resolvePlaybackVoice(documentVoiceID: String?,
                                                 globalStoredID: String?,
                                                 curated: [TtsVoice],
                                                 neuralDefault: TtsVoice,
                                                 systemDefault: TtsVoice,
                                                 modelInstalled: Bool) -> TtsVoice {
        if let documentVoiceID,
           let voice = curated.first(where: { $0.id == documentVoiceID }) {
            return voice
        }
        return resolveVoicePreference(storedID: globalStoredID,
                                      curated: curated,
                                      neuralDefault: neuralDefault,
                                      systemDefault: systemDefault,
                                      modelInstalled: modelInstalled)
    }

    /// Applies a just-loaded document's stored playback prefs — else the
    /// global defaults, so a fresh book inherits the current baseline and a
    /// book left at 2× never bleeds into the next one. Both values go in
    /// through the non-persisting seams (`rate` and `voice` directly, never
    /// `selectRate`/`selectVoice`), so the apply itself — and a retired
    /// voice's fallback — can never be written into any record. No
    /// re-entrancy guard is needed: persistence is opt-in on both channels.
    private func applyDocumentPreferences(_ document: LibraryDocument) {
        let defaults = UserDefaults.standard

        playback.rate = document.effectiveRate(globalDefault: globalRate)

        let voice = Self.resolvePlaybackVoice(
            documentVoiceID: document.preferredVoiceID,
            globalStoredID: defaults.string(forKey: PrefKey.voiceID),
            curated: kokoroEngine.voices + engine.voices,
            neuralDefault: kokoroEngine.defaultVoice,
            systemDefault: engine.defaultVoice,
            modelInstalled: modelManager.isInstalled)
        applyVoicePreference(voice)
    }
}

// MARK: - Engine registry

/// Resolves the engine for every synthesis request by the voice's engine kind,
/// so the scheduler and controller stay engine-agnostic.
private final class EngineRouter: TtsEngine {

    private let system: AVSpeechEngine
    private let kokoro: KokoroSherpaEngine

    init(system: AVSpeechEngine, kokoro: KokoroSherpaEngine) {
        self.system = system
        self.kokoro = kokoro
    }

    var voices: [TtsVoice] { kokoro.voices + system.voices }

    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        switch voice.engine {
        case .kokoro: return try await kokoro.synthesize(text, voice: voice)
        case .avSpeech: return try await system.synthesize(text, voice: voice)
        }
    }
}
