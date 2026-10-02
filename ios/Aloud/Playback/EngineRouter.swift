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
        switch voice.engine {
        case .kokoro: return try await kokoro.synthesize(text, voice: voice)
        case .avSpeech: return try await system.synthesize(text, voice: voice)
        }
    }
}
