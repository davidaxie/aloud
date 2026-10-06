import Foundation

/// Resolves the engine for every synthesis request by the voice's engine kind,
/// so the scheduler and controller stay engine-agnostic.
final class EngineRouter: TtsEngine {

    private let system: any TtsEngine
    private let kokoro: any TtsEngine

    init(system: any TtsEngine, kokoro: any TtsEngine) {
        self.system = system
        self.kokoro = kokoro
    }

    var voices: [TtsVoice] { kokoro.voices + system.voices }

    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        try await synthesize(text, voice: voice, speed: 1.0)
    }

    /// Forwards the pace: an engine that can't speak faster returns its
    /// natural pace, and says so in the clip.
    func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
        switch voice.engine {
        case .kokoro: return try await kokoro.synthesize(text, voice: voice, speed: speed)
        case .avSpeech: return try await system.synthesize(text, voice: voice, speed: speed)
        }
    }
}
