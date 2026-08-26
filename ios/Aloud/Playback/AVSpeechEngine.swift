import AVFoundation
import Foundation

/// System-voice engine. Synthesizes with `AVSpeechSynthesizer.write` into mono
/// Float32 PCM so system and neural voices share one playback path.
///
/// Exposes exactly one voice — "System voice", the best installed English
/// voice — which exists purely as the fallback before the neural model is
/// installed and on low-memory devices.
final class AVSpeechEngine: TtsEngine {

    let voices: [TtsVoice]
    let defaultVoice: TtsVoice

    init() {
        // Best installed voice: English first, then premium > enhanced >
        // default, then name — surfaced as the single "System voice" entry.
        let best = AVSpeechSynthesisVoice.speechVoices()
            .map(TtsVoice.init(systemVoice:))
            .sorted { lhs, rhs in
                let lhsEnglish = lhs.lang.hasPrefix("en")
                let rhsEnglish = rhs.lang.hasPrefix("en")
                if lhsEnglish != rhsEnglish { return lhsEnglish }
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                return lhs.name < rhs.name
            }
            .first
        defaultVoice = TtsVoice(
            id: best?.id ?? "com.apple.ttsbundle.siri_female_en-US_compact",
            name: "System voice",
            lang: best?.lang ?? "en-US",
            gender: best?.gender ?? "",
            engine: .avSpeech,
            quality: best?.quality ?? 1,
            subtitle: "Built-in fallback")
        voices = [defaultVoice]
    }

    /// Always synthesizes at the default speech rate — playback rate handles speed.
    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .silence(duration: 0.1) }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
            ?? AVSpeechSynthesisVoice(language: voice.lang)

        let session = WriteSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.begin(utterance: utterance, continuation: continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }
}

// MARK: - One write pass

/// Accumulates the buffers of a single `write` call. The callback may deliver
/// many small buffers and signals completion with an empty one.
private final class WriteSession: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SynthesizedAudio, Error>?
    private var synthesizer: AVSpeechSynthesizer?
    private var samples: [Float] = []
    private var sampleRate: Double = 0

    func begin(utterance: AVSpeechUtterance,
               continuation: CheckedContinuation<SynthesizedAudio, Error>) {
        lock.lock()
        self.continuation = continuation
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        lock.unlock()

        synthesizer.write(utterance) { [weak self] buffer in
            self?.consume(buffer)
        }
    }

    func cancel() {
        lock.lock()
        synthesizer?.stopSpeaking(at: .immediate)
        finishLocked(with: .failure(CancellationError()))
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }

        if pcm.frameLength == 0 {
            let result: Result<SynthesizedAudio, Error> = samples.isEmpty
                ? .failure(TtsError.emptyAudio)
                : .success(SynthesizedAudio(samples: samples, sampleRate: sampleRate))
            finishLocked(with: result)
            return
        }
        sampleRate = pcm.format.sampleRate
        samples.append(contentsOf: Self.monoSamples(from: pcm))
        lock.unlock()
    }

    /// Consumes the held lock; resumes the continuation exactly once.
    private func finishLocked(with result: Result<SynthesizedAudio, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        self.synthesizer = nil
        lock.unlock()
        switch result {
        case .success(let audio): continuation?.resume(returning: audio)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    /// Downmixes any PCM layout the synthesizer produces to mono Float32.
    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        let channels = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        let channelScale = 1 / Float(channels)

        if let data = buffer.floatChannelData {
            if channels == 1 {
                return Array(UnsafeBufferPointer(start: data[0], count: frames))
            }
            return downmix(frames: frames, channels: channels, interleaved: interleaved,
                           scale: channelScale) { c, i in
                interleaved ? data[0][i * channels + c] : data[c][i]
            }
        }
        if let data = buffer.int16ChannelData {
            let scale = channelScale / Float(Int16.max)
            return downmix(frames: frames, channels: channels, interleaved: interleaved,
                           scale: 1) { c, i in
                Float(interleaved ? data[0][i * channels + c] : data[c][i]) * scale
            }
        }
        if let data = buffer.int32ChannelData {
            let scale = channelScale / Float(Int32.max)
            return downmix(frames: frames, channels: channels, interleaved: interleaved,
                           scale: 1) { c, i in
                Float(interleaved ? data[0][i * channels + c] : data[c][i]) * scale
            }
        }
        return []
    }

    private static func downmix(frames: Int, channels: Int, interleaved: Bool,
                                scale: Float, sample: (Int, Int) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += sample(c, i) }
            out[i] = sum * scale
        }
        return out
    }
}

// MARK: - Mapping

private extension TtsVoice {
    init(systemVoice voice: AVSpeechSynthesisVoice) {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 3
        case .enhanced: quality = 2
        default: quality = 1
        }
        let gender: String
        switch voice.gender {
        case .male: gender = "male"
        case .female: gender = "female"
        default: gender = ""
        }
        self.init(id: voice.identifier,
                  name: voice.name,
                  lang: voice.language,
                  gender: gender,
                  engine: .avSpeech,
                  quality: quality)
    }
}
