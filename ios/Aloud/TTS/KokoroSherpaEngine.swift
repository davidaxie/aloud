import Foundation
import OSLog
import SherpaOnnx

/// Never shown: callers map these to the fixed R11/R21 copy.
enum KokoroEngineError: Error, Equatable {
    case modelNotInstalled
    case modelDamaged
    case bundleAssetsMissing
}

/// Kokoro neural TTS via sherpa-onnx (`kokoro-multi-lang-v1_0`, fp32, 24 kHz).
///
/// Every wrapper touch — creation, generation, release — happens on one serial
/// dispatch queue: sherpa-onnx's espeak-ng G2P has global state, and the model
/// load itself takes seconds and ~800 MB. Blocking work stays off both the main
/// thread and the Swift cooperative pool. `SynthesisScheduler` additionally
/// guarantees only one synthesize call is pending at a time.
final class KokoroSherpaEngine: WarmableTtsEngine, @unchecked Sendable {

    let voices: [TtsVoice] = KokoroVoiceCatalog.curatedVoices
    var defaultVoice: TtsVoice { KokoroVoiceCatalog.defaultVoice }

    /// ONNX Runtime's intra-op threads (S15: `PlatformTuning.kokoroThreads`).
    let numThreads: Int
    /// Whether the session turns ONNX Runtime's thread spinning off, through
    /// a provider config file (`runtimeProvider`).
    let stopsThreadSpinning: Bool

    private let modelDirectory: URL
    /// Where the provider config file is written: the app's caches.
    private let runtimeConfigDirectory: URL?
    private let queue = DispatchQueue(label: "com.davidxie.aloud.kokoro", qos: .userInitiated)
    /// Touched only on `queue`.
    private var tts: SherpaOnnxOfflineTtsWrapper?

    private let stateLock = NSLock()
    private var warmFlag = false
    private var damagedHandler: (@Sendable () -> Void)?
    /// `synthesize` calls handed to `queue` and not yet begun.
    private var waitingSyntheses = 0

    private static let log = Logger(subsystem: "com.davidxie.Aloud", category: "kokoro")

    init(modelDirectory: URL,
         numThreads: Int = PlatformTuning.kokoroThreads,
         stopsThreadSpinning: Bool = PlatformTuning.kokoroStopsThreadSpinning,
         runtimeConfigDirectory: URL? = KokoroSherpaEngine.cachesDirectory) {
        self.modelDirectory = modelDirectory
        self.numThreads = max(1, numThreads)
        self.stopsThreadSpinning = stopsThreadSpinning
        self.runtimeConfigDirectory = runtimeConfigDirectory
    }

    /// True once the wrapper exists (cheap, lock-guarded — safe from any thread).
    var isWarm: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return warmFlag
    }

    /// Called on the engine's queue when warm-up finds the installed files
    /// damaged (R21). Lock-guarded: the app sets it from the main actor.
    var onModelDamaged: (@Sendable () -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return damagedHandler }
        set { stateLock.lock(); damagedHandler = newValue; stateLock.unlock() }
    }

    /// Creates the engine and pays the one-time graph-build cost (~seconds)
    /// with a short warm-up utterance, unless a sentence is waiting by the
    /// time the model has loaded (`speaksWarmLine`). Idempotent once warm;
    /// throws if the
    /// model files or bundled assets are missing, or the files are damaged.
    func warmUp() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.warmUpOnQueue(onDemand: false)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        guard let sid = KokoroVoiceCatalog.sid(for: voice.id) else {
            throw TtsError.voiceUnavailable
        }
        let spoken = TextNormalizer.normalize(text)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .silence(duration: 0.1)
        }
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { cont in
            setWaiting(+1)
            queue.async {
                self.setWaiting(-1)
                do {
                    try self.warmUpOnQueue(onDemand: true)   // auto-recovers after release()
                    guard let tts = self.tts else { throw KokoroEngineError.modelNotInstalled }
                    let start = Date()
                    let audio = tts.generate(text: spoken, sid: sid, speed: 1.0)
                    // sherpa-onnx returns a NULL audio pointer when it produces
                    // nothing (e.g. text its English frontend can't tokenize,
                    // like a CJK-only line); reading `.samples` would trap.
                    guard audio.audio != nil else { throw TtsError.emptyAudio }
                    let samples = audio.samples
                    Self.log.info("kokoro synth \(String(format: "%.2f", Date().timeIntervalSince(start))) s → \(samples.count) samples (\(spoken.count) chars)")
                    guard !samples.isEmpty else { throw TtsError.emptyAudio }
                    cont.resume(returning: SynthesizedAudio(samples: samples,
                                                            sampleRate: Double(audio.sampleRate)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Frees the ~800 MB engine. Safe at any time — the next synthesize
    /// transparently re-warms.
    func release() {
        queue.async {
            self.tts = nil
            self.setWarm(false)
        }
    }

    // MARK: - The warm line

    /// Spoken once by a warm-up, so the first real sentence starts fast.
    static let warmLine = "Aloud is ready."

    /// Only a warm-up ahead of any reading (the pre-warm, a voice switch)
    /// speaks the warm line: when a sentence waits, it pays the graph build
    /// itself, sooner than the line would.
    static func speaksWarmLine(onDemand: Bool, sentenceWaiting: Bool) -> Bool {
        !onDemand && !sentenceWaiting
    }

    private var hasWaitingSynthesis: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return waitingSyntheses > 0
    }

    private func setWaiting(_ delta: Int) {
        stateLock.lock()
        waitingSyntheses += delta
        stateLock.unlock()
    }

    // MARK: - ONNX Runtime options (S15)

    /// The app's caches, where the provider config file lives.
    static var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    static let runtimeConfigFileName = "kokoro-onnxruntime.config"

    /// ONNX Runtime session entries that stop idle threads spinning for
    /// work: sherpa-onnx forwards `SessionConfig.`-prefixed keys to the
    /// session.
    static let threadSpinningOffConfig = """
        SessionConfig.session.intra_op.allow_spinning=0
        SessionConfig.session.inter_op.allow_spinning=0

        """

    /// The provider string sherpa-onnx is created with: "cpu:<path>" names
    /// the spinning-off config, plain "cpu" keeps ONNX Runtime's defaults.
    ///
    /// sherpa-onnx ends the whole process when a named config file can't be
    /// opened, so a path is only ever named once the file is there with
    /// these exact contents, read back just now. Anything else (no
    /// directory, a failed write, a path sherpa would split at its colon)
    /// is plain "cpu".
    static func runtimeProvider(stopsThreadSpinning: Bool, configDirectory: URL?,
                                fileManager: FileManager = .default) -> String {
        guard stopsThreadSpinning, let configDirectory,
              let config = preparedRuntimeConfig(in: configDirectory, fileManager: fileManager) else {
            return "cpu"
        }
        return "cpu:" + config.path
    }

    /// Writes the config file unless it already holds these contents (once
    /// per caches directory, in practice), then verifies it. Nil when it
    /// can't be used.
    static func preparedRuntimeConfig(in directory: URL, fileManager: FileManager = .default) -> URL? {
        let url = directory.appendingPathComponent(runtimeConfigFileName, isDirectory: false)
        // sherpa splits the provider string at its first colon and trims
        // what follows: the path must survive both unchanged.
        let path = url.path
        guard path.hasPrefix("/"), !path.contains(":"),
              path.rangeOfCharacter(from: .newlines) == nil,
              path.trimmingCharacters(in: .whitespaces) == path else {
            return nil
        }
        if !runtimeConfigIsInPlace(at: url, fileManager: fileManager) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(threadSpinningOffConfig.utf8).write(to: url, options: .atomic)
            } catch {
                // The error's domain and code, never its own text (the copy
                // table owns every user-facing word; this is a log).
                let failure = error as NSError
                log.error("kokoro runtime config not written: \(failure.domain, privacy: .public) \(failure.code)")
                return nil
            }
        }
        return runtimeConfigIsInPlace(at: url, fileManager: fileManager) ? url : nil
    }

    private static func runtimeConfigIsInPlace(at url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path),
              let data = fileManager.contents(atPath: url.path) else { return false }
        return data == Data(threadSpinningOffConfig.utf8)
    }

    // MARK: - Queue-confined

    /// `onDemand`: a sentence is waiting on this load.
    private func warmUpOnQueue(onDemand: Bool) throws {
        guard tts == nil else { return }

        let modelPath = modelDirectory.appendingPathComponent("model.onnx").path
        let voicesPath = modelDirectory.appendingPathComponent("voices.bin").path
        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: voicesPath) else {
            throw KokoroEngineError.modelNotInstalled
        }
        // A truncated or corrupt download is caught here, before sherpa maps
        // ~350 MB of it. The files are reported, never deleted.
        guard ModelManager.installedFilesLookIntact(in: modelDirectory) else {
            onModelDamaged?()
            throw KokoroEngineError.modelDamaged
        }
        guard let tokens = Bundle.main.path(forResource: "tokens", ofType: "txt"),
              let dataDir = Bundle.main.path(forResource: "espeak-ng-data", ofType: nil),
              let lexiconUS = Bundle.main.path(forResource: "lexicon-us-en", ofType: "txt"),
              let lexiconGB = Bundle.main.path(forResource: "lexicon-gb-en", ofType: "txt") else {
            throw KokoroEngineError.bundleAssetsMissing
        }

        let warmStart = Date()
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: modelPath,
            voices: voicesPath,
            tokens: tokens,
            dataDir: dataDir,
            dictDir: "",
            lexicon: lexiconUS + "," + lexiconGB)
        // Checked on every load, never cached: the caches directory can be
        // emptied between loads, and a named file that's gone ends the app.
        let provider = Self.runtimeProvider(stopsThreadSpinning: stopsThreadSpinning,
                                            configDirectory: runtimeConfigDirectory)
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro,
                                                    numThreads: numThreads,
                                                    provider: provider)
        var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 1)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        // A failed create yields a wrapper around NULL: never cache it as warm.
        guard wrapper.tts != nil else {
            onModelDamaged?()
            throw KokoroEngineError.modelDamaged
        }

        // Pays the graph build once so the first real sentence starts fast,
        // unless a sentence is already waiting: it pays the build itself,
        // sooner. Asked after the load, which takes seconds.
        let speaksWarmLine = Self.speaksWarmLine(onDemand: onDemand, sentenceWaiting: hasWaitingSynthesis)
        if speaksWarmLine {
            let warmSid = KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.defaultVoiceID) ?? 0
            _ = wrapper.generate(text: Self.warmLine, sid: warmSid, speed: 1.0)
        }

        tts = wrapper
        setWarm(true)
        Self.log.info("kokoro warm-up \(String(format: "%.2f", Date().timeIntervalSince(warmStart))) s (model load + graph build\(speaksWarmLine ? " + warm utterance" : "", privacy: .public)), \(self.numThreads) threads, provider \(provider == "cpu" ? "cpu" : "cpu + spinning off", privacy: .public)")
    }

    private func setWarm(_ value: Bool) {
        stateLock.lock()
        warmFlag = value
        stateLock.unlock()
    }
}
