import Foundation
import OSLog
import SherpaOnnx

enum KokoroEngineError: Error, LocalizedError {
    case modelNotInstalled
    case bundleAssetsMissing

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "The neural voice model is not installed."
        case .bundleAssetsMissing: return "The neural voice assets are missing from the app."
        }
    }
}

/// Kokoro neural TTS via sherpa-onnx (`kokoro-multi-lang-v1_0`, fp32, 24 kHz).
///
/// Every wrapper touch — creation, generation, release — happens on one serial
/// dispatch queue: sherpa-onnx's espeak-ng G2P has global state, and the model
/// load itself takes seconds and ~800 MB. Blocking work stays off both the main
/// thread and the Swift cooperative pool. `SynthesisScheduler` additionally
/// guarantees only one synthesize call is pending at a time.
final class KokoroSherpaEngine: TtsEngine, @unchecked Sendable {

    let voices: [TtsVoice] = KokoroVoiceCatalog.curatedVoices
    var defaultVoice: TtsVoice { KokoroVoiceCatalog.defaultVoice }

    private let modelDirectory: URL
    private let queue = DispatchQueue(label: "com.davidxie.aloud.kokoro", qos: .userInitiated)
    /// Touched only on `queue`.
    private var tts: SherpaOnnxOfflineTtsWrapper?

    private let stateLock = NSLock()
    private var warmFlag = false

    private static let log = Logger(subsystem: "com.davidxie.Aloud", category: "kokoro")

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// True once the wrapper exists (cheap, lock-guarded — safe from any thread).
    var isWarm: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return warmFlag
    }

    /// Creates the engine and pays the one-time graph-build cost (~seconds)
    /// with a short warm-up utterance. Idempotent once warm; throws if the
    /// model files or bundled assets are missing.
    func warmUp() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.warmUpOnQueue()
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
            queue.async {
                do {
                    try self.warmUpOnQueue()   // auto-recovers after release()
                    guard let tts = self.tts else { throw KokoroEngineError.modelNotInstalled }
                    let start = Date()
                    let audio = tts.generate(text: spoken, sid: sid, speed: 1.0)
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

    // MARK: - Queue-confined

    private func warmUpOnQueue() throws {
        guard tts == nil else { return }

        let modelPath = modelDirectory.appendingPathComponent("model.onnx").path
        let voicesPath = modelDirectory.appendingPathComponent("voices.bin").path
        guard FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: voicesPath) else {
            throw KokoroEngineError.modelNotInstalled
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
        let model = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro,
                                                    numThreads: 2,
                                                    provider: "cpu")
        var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 1)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)

        // Pays the graph build once so the first real sentence starts fast.
        let warmSid = KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.defaultVoiceID) ?? 0
        _ = wrapper.generate(text: "Aloud is ready.", sid: warmSid, speed: 1.0)

        tts = wrapper
        setWarm(true)
        Self.log.info("kokoro warm-up \(String(format: "%.2f", Date().timeIntervalSince(warmStart))) s (model load + graph build + warm utterance)")
    }

    private func setWarm(_ value: Bool) {
        stateLock.lock()
        warmFlag = value
        stateLock.unlock()
    }
}
