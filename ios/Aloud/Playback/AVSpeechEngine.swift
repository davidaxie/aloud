import AVFoundation
import Foundation

/// System-voice engine. Synthesizes with `AVSpeechSynthesizer.write` into mono
/// Float32 PCM so system and neural voices share one playback path.
///
/// Exposes exactly one voice — "System voice", with the stable id `system` —
/// which exists purely as the fallback before the neural model is installed
/// and on low-memory devices. The concrete AVSpeech voice behind it is
/// resolved per synthesis (`bestSystemVoice`), so a persisted preference
/// survives any change to the device's installed-voice set.
final class AVSpeechEngine: TtsEngine {

    /// Stable roster/preference id of the single "System voice" entry —
    /// never a concrete `AVSpeechSynthesisVoice` identifier, which changes
    /// whenever the user adds or removes voices in iOS Settings.
    static let systemVoiceID = "system"

    let voices: [TtsVoice]
    let defaultVoice: TtsVoice
    /// Zeroes the utterance volume (UI tests, hosted unit tests, previews).
    let mutesOutput: Bool

    init(mutesOutput: Bool = UITestHooks.muteAudio) {
        self.mutesOutput = mutesOutput
        defaultVoice = TtsVoice(
            id: Self.systemVoiceID,
            name: "System voice",
            lang: "en-US",
            gender: "",
            engine: .avSpeech,
            quality: 1,
            subtitle: "Built-in fallback")
        voices = [defaultVoice]
    }

    // MARK: - Best-voice resolution

    /// A rankable installed voice — plain values so the ranking is unit-testable.
    struct VoiceCandidate {
        let name: String
        let language: String
        /// 3 premium, 2 enhanced, 1 default.
        let quality: Int
        /// The OS's own pick for the user's locale — tie-break within a tier.
        var isLocaleDefault: Bool = false
    }

    /// Novelty/character voices Apple ships at `.default` quality (Albert
    /// sorts first alphabetically on a stock device!). Never a sensible
    /// reading voice, so they rank below every regular voice. The compact
    /// Eloquence voices are robotic but legitimate — not listed here.
    static let noveltyVoiceNames: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
        "Deranged", "Fred", "Good News", "Hysterical", "Jester", "Organ",
        "Pipe Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox",
    ]

    /// Strict weak ordering for `min(by:)`: English first, then premium >
    /// enhanced > default, then regular voices before novelty ones, then the
    /// locale's own default voice, then name.
    static func ranks(_ lhs: VoiceCandidate, above rhs: VoiceCandidate) -> Bool {
        let lhsEnglish = lhs.language.hasPrefix("en")
        let rhsEnglish = rhs.language.hasPrefix("en")
        if lhsEnglish != rhsEnglish { return lhsEnglish }
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        let lhsNovelty = noveltyVoiceNames.contains(lhs.name)
        let rhsNovelty = noveltyVoiceNames.contains(rhs.name)
        if lhsNovelty != rhsNovelty { return rhsNovelty }
        if lhs.isLocaleDefault != rhs.isLocaleDefault { return lhs.isLocaleDefault }
        return lhs.name < rhs.name
    }

    /// The best installed voice right now — resolved per synthesis call so it
    /// tracks the live installed-voice set. Single pass; no sorted array
    /// (only the winner is ever used).
    static func bestSystemVoice() -> AVSpeechSynthesisVoice? {
        let localeDefaultID = AVSpeechSynthesisVoice(language: "en-US")?.identifier
        return AVSpeechSynthesisVoice.speechVoices().min { lhs, rhs in
            ranks(VoiceCandidate(lhs, localeDefaultID: localeDefaultID),
                  above: VoiceCandidate(rhs, localeDefaultID: localeDefaultID))
        }
    }

    // MARK: - The System row's name (M10)

    /// The voice the System row speaks in right now, as the Mac's row names
    /// it: "Ava (Premium)". Resolved by `bestSystemVoice`, as synthesis
    /// resolves it, so it never names a voice other than the one heard. Nil
    /// with no installed voice.
    static func resolvedVoiceDisplayName() -> String? {
        bestSystemVoice().map { displayName(of: VoiceCandidate($0, localeDefaultID: nil)) }
    }

    /// A voice's name with its tier, as System Settings lists it: "Ava
    /// (Premium)", "Samantha (Enhanced)", plain "Samantha". A name that
    /// already ends in a parenthesis keeps its own.
    static func displayName(of candidate: VoiceCandidate) -> String {
        let tier: String
        switch candidate.quality {
        case 3: tier = "Premium"
        case 2: tier = "Enhanced"
        default: return candidate.name
        }
        return candidate.name.hasSuffix(")") ? candidate.name : "\(candidate.name) (\(tier))"
    }

    /// Posted when voices are added or removed in System Settings, so the
    /// row's name can be resolved again.
    static let installedVoicesDidChange = AVSpeechSynthesizer.availableVoicesDidChangeNotification

    /// Always synthesizes at the default speech rate — playback rate handles speed.
    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .silence(duration: 0.1) }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // Belt and braces under the DEBUG mute: write() renders offline and
        // never reaches a speaker; the PlaybackController mixer is the guarantee.
        utterance.volume = mutesOutput ? 0 : 1
        // The stable "system" id resolves to the best installed voice at
        // synthesis time; a concrete identifier (legacy pref) still resolves
        // directly while that voice remains installed.
        let concrete = voice.id == Self.systemVoiceID
            ? nil : AVSpeechSynthesisVoice(identifier: voice.id)
        utterance.voice = concrete
            ?? Self.bestSystemVoice()
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

private extension AVSpeechEngine.VoiceCandidate {
    init(_ voice: AVSpeechSynthesisVoice, localeDefaultID: String?) {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 3
        case .enhanced: quality = 2
        default: quality = 1
        }
        self.init(name: voice.name,
                  language: voice.language,
                  quality: quality,
                  isLocaleDefault: voice.identifier == localeDefaultID)
    }
}
