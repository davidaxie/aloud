import Foundation

/// The seam between speech engines. An engine may speak faster itself when
/// asked (`synthesize(_:voice:speed:)`, Kokoro does), and says in each clip
/// what pace it spoke at; the audio graph's time-pitch unit plays the
/// remainder of the listener's speed.

struct TtsVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lang: String
    let gender: String
    let engine: EngineKind
    let quality: Int
    /// One-line character note for picker rows ("Deep, warm narrator").
    var subtitle: String = ""
}

enum EngineKind: String, Codable, Sendable {
    case kokoro
    case avSpeech
}

/// Mono Float32 PCM.
struct SynthesizedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// The pace the engine spoke at: 1.0 is its natural pace, 2.0 twice as
    /// fast. Playback plays the clip at the listener's speed divided by it.
    var nativeSpeed: Double = 1.0
}

protocol TtsEngine: AnyObject, Sendable {
    var voices: [TtsVoice] { get }
    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio
    /// Speaks at `speed` where the engine can, and says in the clip what pace
    /// it really spoke at. An engine that can't returns natural-pace audio
    /// (the default below), which playback then speeds up itself.
    func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio
}

extension TtsEngine {
    func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
        try await synthesize(text, voice: voice)
    }
}

/// An engine with an expensive model load (Kokoro): playback warms it before
/// the first sentence and frees it while idle. A protocol so tests can stand
/// in a fake neural engine.
protocol WarmableTtsEngine: TtsEngine {
    var isWarm: Bool { get }
    func warmUp() async throws
    func release()
}

enum TtsError: Error {
    case emptyAudio
    case voiceUnavailable
}

extension SynthesizedAudio {
    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// Seconds of listening at 1x: what the clip lasts at its natural pace.
    var naturalDuration: TimeInterval { duration * nativeSpeed }

    static func silence(duration: TimeInterval, sampleRate: Double = 24_000,
                        nativeSpeed: Double = 1.0) -> SynthesizedAudio {
        let count = max(1, Int(duration * sampleRate))
        return SynthesizedAudio(samples: [Float](repeating: 0, count: count), sampleRate: sampleRate,
                                nativeSpeed: nativeSpeed)
    }
}
