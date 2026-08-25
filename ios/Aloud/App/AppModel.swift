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
    }

    private func restorePreferences(from defaults: UserDefaults) {
        if let rate = defaults.object(forKey: PrefKey.rate) as? Double {
            playback.rate = rate
        }
        if let skip = defaults.object(forKey: PrefKey.skipBrackets) as? Bool {
            playback.skipBrackets = skip
        }
        if let voiceID = defaults.string(forKey: PrefKey.voiceID) {
            // Kokoro voices only restore while the model is installed;
            // otherwise the system default silently stands in.
            var candidates = engine.voices
            if modelManager.isInstalled { candidates += kokoroEngine.voices }
            if let voice = candidates.first(where: { $0.id == voiceID }) {
                playback.voice = voice
            }
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
