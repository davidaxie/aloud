import Foundation

/// The seam between speech engines. Every engine synthesizes at its natural
/// rate; playback speed is applied downstream at the audio graph.

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
}

protocol TtsEngine: AnyObject, Sendable {
    var voices: [TtsVoice] { get }
    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio
}

enum TtsError: Error {
    case emptyAudio
    case voiceUnavailable
}

extension SynthesizedAudio {
    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    static func silence(duration: TimeInterval, sampleRate: Double = 24_000) -> SynthesizedAudio {
        let count = max(1, Int(duration * sampleRate))
        return SynthesizedAudio(samples: [Float](repeating: 0, count: count), sampleRate: sampleRate)
    }
}
