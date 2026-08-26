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
        didSet { UserDefaults.standard.set(wordHighlight, forKey: PrefKey.wordHighlight) }
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

        #if DEBUG
        // UI-test hook: start from a clean voice preference.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset-voice-pref") {
            defaults.removeObject(forKey: PrefKey.voiceID)
        }
        #endif

        migratePreferences(defaults)
        restorePreferences(from: defaults)
        persistPreferenceChanges(to: defaults)
        observeModelRemoval()
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

        #if DEBUG
        // UI-test hook: seed the library with the first bookshelf classic.
        if ProcessInfo.processInfo.arguments.contains("-uitest-seed-first-classic"),
           let first = bookshelf.first {
            _ = try? await documentStore.addClassic(first)
        }
        #endif
    }

    /// Scene-phase hook (from RootView): a backgrounded, non-playing app
    /// gives back the neural engine's memory.
    func handleScenePhaseChange(toBackground: Bool) {
        guard toBackground else { return }
        playback.releaseNeuralEngineIfIdle()
    }

    // MARK: - Model lifecycle

    /// Model deleted (or download reverted) while a Kokoro voice is active →
    /// drop back to the system default voice and free the engine.
    private func observeModelRemoval() {
        modelManager.$state
            .map { state -> Bool in
                if case .installed = state { return true }
                return false
            }
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.playback.voice.engine == .kokoro {
                        self.playback.voice = self.engine.defaultVoice
                    }
                    self.kokoroEngine.release()
                }
            }
            .store(in: &cancellables)
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
    /// V2: skip-brackets became the default (existing installs flip to ON
    /// once; anything the user chooses afterwards stands), and the voice
    /// roster was curated to eight — a stored id outside the roster (a
    /// retired Kokoro speaker, an old system voice) remaps to the new
    /// default once.
    private func migratePreferences(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: PrefKey.migratedV2) else { return }
        defaults.set(true, forKey: PrefKey.skipBrackets)
        let curated = kokoroEngine.voices + engine.voices
        if let voiceID = defaults.string(forKey: PrefKey.voiceID),
           !curated.contains(where: { $0.id == voiceID }) {
            let preferred = modelManager.isInstalled
                ? kokoroEngine.defaultVoice : engine.defaultVoice
            defaults.set(preferred.id, forKey: PrefKey.voiceID)
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
        restoreVoice(from: defaults)
    }

    /// Restores the voice preference against the curated roster (stale ids
    /// were already remapped by `migratePreferences`). Kokoro voices only
    /// restore while the model is installed; a curated Kokoro pref without
    /// the model keeps its stored id and the system voice silently stands in
    /// (it restores itself when the model installs).
    private func restoreVoice(from defaults: UserDefaults) {
        let curated = kokoroEngine.voices + engine.voices
        let preferredDefault = modelManager.isInstalled
            ? kokoroEngine.defaultVoice : engine.defaultVoice
        guard let voiceID = defaults.string(forKey: PrefKey.voiceID),
              let voice = curated.first(where: { $0.id == voiceID }) else {
            playback.voice = preferredDefault
            return
        }
        if voice.engine == .kokoro, !modelManager.isInstalled {
            playback.voice = engine.defaultVoice   // stand-in; pref kept
        } else {
            playback.voice = voice
        }
    }

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

        playback.$voice
            .dropFirst()
            .map(\.id)
            .removeDuplicates()
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
