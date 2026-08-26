import Combine
import Foundation
import UIKit

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

    private var cancellables: Set<AnyCancellable> = []
    private var didRunLaunchTasks = false

    init() {
        let defaults = UserDefaults.standard

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
        playback.voice = resolved
        if let stored = defaults.string(forKey: PrefKey.voiceID), stored != resolved.id {
            defaults.set(resolved.id, forKey: PrefKey.voiceID)
        }
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
        if let rate = defaults.object(forKey: PrefKey.rate) as? Double {
            playback.rate = rate
        }
        if let skip = defaults.object(forKey: PrefKey.skipBrackets) as? Bool {
            playback.skipBrackets = skip
        }
        applyVoicePreference(resolvedVoicePreference(from: defaults))
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

    /// Rate and skip-brackets persist on every change; the voice persists
    /// only through `voiceSelections` — deliberate picker choices — so
    /// temporary fallbacks (the pre-install stand-in, neural-failure
    /// degradation) never overwrite the stored preference.
    private func persistPreferenceChanges(to defaults: UserDefaults) {
        playback.$rate
            .dropFirst()
            .removeDuplicates()
            .sink { defaults.set($0, forKey: PrefKey.rate) }
            .store(in: &cancellables)

        playback.$skipBrackets
            .dropFirst()
            .removeDuplicates()
            .sink { defaults.set($0, forKey: PrefKey.skipBrackets) }
            .store(in: &cancellables)

        playback.voiceSelections
            .map(\.id)
            .sink { defaults.set($0, forKey: PrefKey.voiceID) }
            .store(in: &cancellables)
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
