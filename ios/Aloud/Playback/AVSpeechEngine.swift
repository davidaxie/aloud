import AVFoundation
import Foundation
import NaturalLanguage

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
            subtitle: DeviceCopy.systemVoiceFallback)
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

    /// `bestSystemVoice`, ranked once and kept until the installed voices
    /// change: ranking scans every voice (about 47 ms with 180 installed),
    /// and synthesis asks for every sentence.
    static func cachedBestSystemVoice() -> AVSpeechSynthesisVoice? {
        // The ranking breaks ties by the system's English default, which
        // can change in System Settings without a voice coming or going.
        let defaultID = AVSpeechSynthesisVoice(language: "en-US")?.identifier
        if let id = bestVoiceCache.identifier(rankedWith: defaultID),
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        let generation = bestVoiceCache.generation
        let best = bestSystemVoice()
        bestVoiceCache.store(best?.identifier, rankedWith: defaultID, ifStill: generation)
        return best
    }

    private static let bestVoiceCache = BestVoiceCache()

    // MARK: - A book in another language (L003)

    /// The language the System voice reads a book in, as NLLanguageRecognizer
    /// names it ("fr", "zh-Hans"): the book's dominant language when that
    /// isn't English, nil for English or when unsure, which keeps the
    /// English pick. Sentences are sampled across the whole book, so front
    /// matter or a quoted line never decides alone.
    static func readingLanguage<Sentences: RandomAccessCollection>(of sentences: Sentences) -> String?
    where Sentences.Element == String {
        guard !sentences.isEmpty else { return nil }
        let picks = min(sentences.count, 64)
        let sample = (0..<picks).map { k in
            String(sentences[sentences.index(sentences.startIndex, offsetBy: k * sentences.count / picks)].prefix(240))
        }
        // One look at the whole sample: an English book ends here.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample.joined(separator: "\n"))
        guard let guess = recognizer.dominantLanguage, guess != .english, guess != .undetermined else { return nil }
        // Names can sway that look (an English translation full of French
        // ones reads as French), so each sampled sentence then votes by its
        // letters, and the language must carry three quarters of them.
        // Either script of Chinese votes for the other.
        func base(_ language: NLLanguage?) -> Substring? { language?.rawValue.prefix { $0 != "-" } }
        var votes = 0, letters = 0
        for sentence in sample {
            let weight = sentence.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            guard weight > 0 else { continue }
            recognizer.reset()
            recognizer.processString(sentence)
            letters += weight
            if base(recognizer.dominantLanguage) == base(guess) { votes += weight }
        }
        return Double(votes) >= 0.75 * Double(letters) ? guess.rawValue : nil
    }

    /// `voice` as playback hands it to synthesis for a book in `language`:
    /// the System voice carries the book's language, which synthesis
    /// resolves to that language's best installed voice. Any other voice,
    /// or no language (an English book), is returned as it is.
    static func voice(_ voice: TtsVoice, reading language: String?) -> TtsVoice {
        guard voice.id == systemVoiceID, let language else { return voice }
        return TtsVoice(id: voice.id, name: voice.name, lang: language, gender: voice.gender,
                        engine: voice.engine, quality: voice.quality, subtitle: voice.subtitle)
    }

    /// The dialect a reading language most likely means, by the locale
    /// data's likely region: "fr" France's, "pt" Brazil's, "zh-Hans"
    /// mainland Mandarin, "zh-Hant" Taiwan's. The language itself when
    /// the data names no region.
    static func preferredDialect(for language: String) -> String {
        let likely = Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier)
        guard let code = likely.languageCode?.identifier, let region = likely.region?.identifier else {
            return language
        }
        return code + "-" + region
    }

    /// How well a voice in `voiceLanguage` ("fr-CA") reads `language`
    /// ("fr"): 2 in its preferred dialect, 1 in the same language, 0 not.
    static func fluency(_ voiceLanguage: String, reading language: String) -> Int {
        func base(_ tag: String) -> Substring { tag.lowercased().prefix { $0 != "-" && $0 != "_" } }
        if voiceLanguage.caseInsensitiveCompare(preferredDialect(for: language)) == .orderedSame { return 2 }
        return base(voiceLanguage) == base(language) ? 1 : 0
    }

    /// `ranks(_:above:)` for a book in `language`: its own dialect first,
    /// then its language, then the usual order.
    static func ranks(_ lhs: VoiceCandidate, above rhs: VoiceCandidate, reading language: String) -> Bool {
        let lhsFluency = fluency(lhs.language, reading: language)
        let rhsFluency = fluency(rhs.language, reading: language)
        if lhsFluency != rhsFluency { return lhsFluency > rhsFluency }
        return ranks(lhs, above: rhs)
    }

    /// The best of `voices` to read `language`; nil when none speaks it,
    /// and the English pick reads on.
    static func best<Voice>(_ voices: [Voice], reading language: String,
                            as candidate: (Voice) -> VoiceCandidate) -> Voice? {
        voices.filter { fluency(candidate($0).language, reading: language) > 0 }
            .min { ranks(candidate($0), above: candidate($1), reading: language) }
    }

    /// The best installed voice for a book in `language`, nil when none
    /// speaks it.
    static func bestSystemVoice(reading language: String) -> AVSpeechSynthesisVoice? {
        let localeDefaultID = AVSpeechSynthesisVoice(language: preferredDialect(for: language))?.identifier
        return best(AVSpeechSynthesisVoice.speechVoices(), reading: language) {
            VoiceCandidate($0, localeDefaultID: localeDefaultID)
        }
    }

    /// Ranks the System voice for `language` off the main thread and keeps
    /// it, so the System row's first look (the Voice & speed sheet's first
    /// frame) finds the pick cached instead of ranking every installed voice
    /// there. The cache is lock-guarded and never keeps a ranking that
    /// straddled a change of the installed voices; a miss still ranks in
    /// place.
    @discardableResult
    static func warmSystemVoice(reading language: String?) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            _ = cachedBestSystemVoice(reading: language)
        }
    }

    /// The voice the System voice reads `language` in, ranked once per
    /// language like the English pick: that language's best installed
    /// voice, or the English pick when none is installed. Nil, or any
    /// English, is the English pick itself.
    static func cachedBestSystemVoice(reading language: String?) -> AVSpeechSynthesisVoice? {
        guard let language, !language.lowercased().hasPrefix("en") else { return cachedBestSystemVoice() }
        let defaultID = AVSpeechSynthesisVoice(language: preferredDialect(for: language))?.identifier
        switch bestVoiceCache.pick(reading: language, rankedWith: defaultID) {
        case .some(.some(let id)):
            if let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        case .some(.none):
            return cachedBestSystemVoice()
        case .none:
            break
        }
        let generation = bestVoiceCache.generation
        let best = bestSystemVoice(reading: language)
        bestVoiceCache.store(best?.identifier, reading: language, rankedWith: defaultID, ifStill: generation)
        return best ?? cachedBestSystemVoice()
    }

    /// Each language's best voice ("" the English pick) and the default it
    /// was ranked with, forgotten when a voice is added or removed (System
    /// Settings › Spoken Content). A pick ranked across such a change is
    /// never kept.
    final class BestVoiceCache: @unchecked Sendable {
        /// A ranking's result: nil when no installed voice reads the language.
        private struct Entry {
            let identifier: String?
            let defaultID: String?
        }
        private let lock = NSLock()
        private var stored: [String: Entry] = [:]
        private var changes = 0
        private let center: NotificationCenter
        private var observer: NSObjectProtocol?

        init(center: NotificationCenter = .default) {
            self.center = center
            observer = center.addObserver(forName: AVSpeechEngine.installedVoicesDidChange, object: nil,
                                          queue: nil) { [weak self] _ in
                self?.forget()
            }
        }

        deinit {
            if let observer { center.removeObserver(observer) }
        }

        /// Bumped by every change of the installed voices.
        var generation: Int { lock.withLock { changes } }

        /// The kept English pick, if it was ranked with `defaultID`.
        func identifier(rankedWith defaultID: String?) -> String? {
            pick(reading: "", rankedWith: defaultID) ?? nil
        }

        /// Keeps the English pick unless the voices changed since
        /// `generation` was read, when the ranking may describe a list
        /// that's gone. No pick (no voice at all) keeps nothing.
        func store(_ identifier: String?, rankedWith defaultID: String?, ifStill generation: Int) {
            lock.withLock {
                guard changes == generation else { return }
                stored[""] = identifier.map { Entry(identifier: $0, defaultID: defaultID) }
            }
        }

        /// The kept pick for `language`, if it was ranked with `defaultID`:
        /// `.some(nil)` when no installed voice reads it.
        func pick(reading language: String, rankedWith defaultID: String?) -> String?? {
            lock.withLock {
                guard let entry = stored[language], entry.defaultID == defaultID else { return nil }
                return .some(entry.identifier)
            }
        }

        /// Keeps `language`'s pick, none included, as `store` keeps English's.
        func store(_ identifier: String?, reading language: String, rankedWith defaultID: String?,
                   ifStill generation: Int) {
            lock.withLock {
                guard changes == generation else { return }
                stored[language] = Entry(identifier: identifier, defaultID: defaultID)
            }
        }

        func forget() {
            lock.withLock {
                changes += 1
                stored = [:]
            }
        }
    }

    // MARK: - The System row's name (M10)

    /// The voice the System row speaks in right now, as the Mac's row names
    /// it: "Ava (Premium)". Resolved by `bestSystemVoice`, as synthesis
    /// resolves it, so it never names a voice other than the one heard. Nil
    /// with no installed voice. `language` is the open book's
    /// (`readingLanguage`), nil for an English one.
    static func resolvedVoiceDisplayName(reading language: String? = nil) -> String? {
        // The same pick synthesis speaks with, cached or ranked now.
        cachedBestSystemVoice(reading: language).map { displayName(of: VoiceCandidate($0, localeDefaultID: nil)) }
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

    /// The tier of the voice the System row speaks in right now: the same
    /// pick as `resolvedVoiceDisplayName`, so the row's hint about better
    /// voices never contradicts the name beside it. Nil with no installed
    /// voice.
    static func resolvedVoiceQuality(reading language: String? = nil) -> AVSpeechSynthesisVoiceQuality? {
        cachedBestSystemVoice(reading: language).map { quality(of: VoiceCandidate($0, localeDefaultID: nil)) }
    }

    /// A ranked candidate's tier as AVFoundation names it.
    static func quality(of candidate: VoiceCandidate) -> AVSpeechSynthesisVoiceQuality {
        switch candidate.quality {
        case 3: return .premium
        case 2: return .enhanced
        default: return .default
        }
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
        // synthesis time, for the book's language when playback names one
        // (`voice(_:reading:)`); a concrete identifier (legacy pref) still
        // resolves directly while that voice remains installed.
        let concrete = voice.id == Self.systemVoiceID
            ? nil : AVSpeechSynthesisVoice(identifier: voice.id)
        utterance.voice = concrete
            ?? Self.cachedBestSystemVoice(reading: voice.lang)
            ?? AVSpeechSynthesisVoice(language: Self.preferredDialect(for: voice.lang))

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
