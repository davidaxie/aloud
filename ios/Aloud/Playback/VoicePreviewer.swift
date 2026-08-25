import AVFoundation
import Combine
import Foundation

/// One-at-a-time voice preview for the voice picker. Owns a private
/// AVAudioEngine → player graph, fully separate from PlaybackController's
/// graph and clip cache, so a preview can never disturb real playback.
/// Synthesis goes through the same `TtsEngine` instances as playback
/// (pass the engine per call — the view resolves it from `AppModel`).
@MainActor
final class VoicePreviewer: ObservableObject {

    enum Phase: Equatable {
        case synthesizing
        case playing
    }

    /// Voice currently previewing (or synthesizing toward a preview).
    @Published private(set) var activeVoiceID: String?
    @Published private(set) var phase: Phase?

    static let sampleText = "Aloud reads to you, naturally."

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    /// Monotonic guard: bumping it orphans every in-flight continuation.
    private var token: UInt64 = 0
    private var synthesisTask: Task<Void, Never>?

    func isActive(_ voice: TtsVoice) -> Bool {
        activeVoiceID == voice.id
    }

    func isSynthesizing(_ voice: TtsVoice) -> Bool {
        activeVoiceID == voice.id && phase == .synthesizing
    }

    /// Play/stop toggle for one row. Starting a preview stops any other.
    func toggle(_ voice: TtsVoice, engine: any TtsEngine) {
        if isActive(voice) {
            stop()
        } else {
            start(voice, engine: engine)
        }
    }

    /// Also called on picker dismiss — a preview never outlives its sheet.
    func stop() {
        token &+= 1
        synthesisTask?.cancel()
        synthesisTask = nil
        player.stop()
        if audioEngine.isRunning { audioEngine.stop() }
        activeVoiceID = nil
        phase = nil
    }

    // MARK: - Internals

    private func start(_ voice: TtsVoice, engine: any TtsEngine) {
        stop()
        let current = token
        activeVoiceID = voice.id
        phase = .synthesizing   // covers a cold Kokoro warm-up too

        synthesisTask = Task { [weak self] in
            let clip: SynthesizedAudio
            do {
                clip = try await engine.synthesize(Self.sampleText, voice: voice)
            } catch {
                self?.finishIfCurrent(current)
                return
            }
            guard let self, self.token == current else { return }
            do {
                try self.play(clip, token: current)
                self.phase = .playing
            } catch {
                self.finishIfCurrent(current)
            }
        }
    }

    private func play(_ clip: SynthesizedAudio, token: UInt64) throws {
        guard !clip.samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: clip.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { throw TtsError.emptyAudio }

        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!,
                                               count: clip.samples.count)
        }

        // Reconnect per preview: system and neural clips differ in sample rate.
        if !attached {
            audioEngine.attach(player)
            attached = true
        }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        try audioEngine.start()

        player.scheduleBuffer(buffer, at: nil, options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishIfCurrent(token)
            }
        }
        player.play()
    }

    /// Natural end (or failure) of the current preview clears the row state.
    private func finishIfCurrent(_ expected: UInt64) {
        guard token == expected else { return }
        player.stop()
        if audioEngine.isRunning { audioEngine.stop() }
        activeVoiceID = nil
        phase = nil
    }
}
