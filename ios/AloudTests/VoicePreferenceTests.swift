import Combine
import XCTest
@testable import Aloud

/// The voice-preference invariants: the system voice keeps the stable id
/// "system" (never a concrete AVSpeech identifier), stored ids resolve
/// against the curated roster with deferred upgrades for retired Kokoro
/// speakers, the best-voice ranking never picks a novelty voice over a
/// regular one, and temporary fallbacks never reach the persistence seam.
@MainActor
final class VoicePreferenceTests: XCTestCase {

    private let neuralDefault = KokoroVoiceCatalog.defaultVoice
    private let systemDefault = TtsVoice(id: AVSpeechEngine.systemVoiceID,
                                         name: "System voice",
                                         lang: "en-US",
                                         gender: "",
                                         engine: .avSpeech,
                                         quality: 1)
    private var curated: [TtsVoice] { KokoroVoiceCatalog.curatedVoices + [systemDefault] }

    // MARK: - Stable system id

    func testSystemVoiceHasStableID() {
        XCTAssertEqual(AVSpeechEngine.systemVoiceID, "system")
        let engine = AVSpeechEngine(mutesOutput: true)
        XCTAssertEqual(engine.defaultVoice.id, "system",
                       "The roster row must never carry a concrete AVSpeech identifier")
        XCTAssertEqual(engine.voices.map(\.id), ["system"])
        XCTAssertEqual(engine.defaultVoice.engine, .avSpeech)
    }

    // MARK: - Stored-id resolution

    private func resolve(_ storedID: String?, modelInstalled: Bool) -> TtsVoice {
        AppModel.resolveVoicePreference(storedID: storedID,
                                        curated: curated,
                                        neuralDefault: neuralDefault,
                                        systemDefault: systemDefault,
                                        modelInstalled: modelInstalled)
    }

    func testCuratedIDsResolveToThemselves() {
        for voice in curated {
            XCTAssertEqual(resolve(voice.id, modelInstalled: true).id, voice.id)
        }
        // A curated Kokoro id resolves to itself even without the model —
        // the caller applies the system stand-in without touching the pref.
        XCTAssertEqual(resolve("kokoro:af_heart", modelInstalled: false).id, "kokoro:af_heart")
    }

    func testRetiredKokoroIDResolvesToNeuralDefault() {
        // Deferred upgrade: the retired id resolves to the default each
        // launch regardless of install state (the stored pref is only
        // rewritten once the model install makes the upgrade final).
        for installed in [true, false] {
            XCTAssertEqual(resolve("kokoro:am_adam", modelInstalled: installed).id,
                           KokoroVoiceCatalog.defaultVoiceID)
        }
    }

    func testLegacyConcreteAVSpeechIDResolvesToSystem() {
        XCTAssertEqual(resolve("com.apple.voice.premium.en-US.Ava", modelInstalled: true).id,
                       "system")
        XCTAssertEqual(resolve("com.apple.ttsbundle.siri_female_en-US_compact",
                               modelInstalled: false).id,
                       "system")
    }

    func testNothingStoredResolvesToPreferredDefault() {
        XCTAssertEqual(resolve(nil, modelInstalled: true).id, KokoroVoiceCatalog.defaultVoiceID)
        XCTAssertEqual(resolve(nil, modelInstalled: false).id, "system")
    }

    // MARK: - Best-voice ranking

    private func candidate(_ name: String,
                           lang: String = "en-US",
                           quality: Int = 1,
                           localeDefault: Bool = false) -> AVSpeechEngine.VoiceCandidate {
        AVSpeechEngine.VoiceCandidate(name: name,
                                      language: lang,
                                      quality: quality,
                                      isLocaleDefault: localeDefault)
    }

    func testNoveltyVoicesRankBelowRegularDefaults() {
        // Alphabetical order alone would pick Albert on a stock device.
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Samantha"), above: candidate("Albert")))
        XCTAssertFalse(AVSpeechEngine.ranks(candidate("Albert"), above: candidate("Samantha")))
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Samantha"), above: candidate("Bad News")))
    }

    func testQualityOutranksNoveltyAndName() {
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Ava", quality: 3),
                                           above: candidate("Aaron", quality: 1)))
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Zoe", quality: 2),
                                           above: candidate("Aaron", quality: 1)))
    }

    func testEnglishOutranksHigherQualityNonEnglish() {
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Samantha"),
                                           above: candidate("Amelie", lang: "fr-FR", quality: 3)))
    }

    // MARK: - A book in another language (L003)

    /// A device with an English voice and voices for other languages.
    private var installed: [AVSpeechEngine.VoiceCandidate] {
        [candidate("Samantha", quality: 2, localeDefault: true),
         candidate("Amelie", lang: "fr-CA"),
         candidate("Thomas", lang: "fr-FR", localeDefault: true),
         candidate("Sinji", lang: "zh-HK"),
         candidate("Meijia", lang: "zh-TW"),
         candidate("Tingting", lang: "zh-CN")]
    }

    /// The French book reads in a French voice; the English pick, which
    /// every English book reads in, is unchanged.
    func testAFrenchBookReadsInAnInstalledFrenchVoice() {
        XCTAssertEqual(AVSpeechEngine.best(installed, reading: "fr") { $0 }?.name, "Thomas")
        XCTAssertEqual(installed.min(by: AVSpeechEngine.ranks(_:above:))?.name, "Samantha")
    }

    /// Simplified Chinese prefers mainland Mandarin, Traditional Taiwan's,
    /// never Cantonese first.
    func testChineseReadsInItsOwnDialect() {
        XCTAssertEqual(AVSpeechEngine.best(installed, reading: "zh-Hans") { $0 }?.name, "Tingting")
        XCTAssertEqual(AVSpeechEngine.best(installed, reading: "zh-Hant") { $0 }?.name, "Meijia")
    }

    /// No German voice installed: no pick, so the English pick reads on.
    func testALanguageWithNoVoiceHasNoPick() {
        XCTAssertNil(AVSpeechEngine.best(installed, reading: "de") { $0 })
    }

    /// Only the System voice carries a book's language, and only a book
    /// that isn't English gives it one.
    func testOnlyTheSystemVoiceCarriesTheBooksLanguage() {
        let french = AVSpeechEngine.voice(systemDefault, reading: "fr")
        XCTAssertEqual(french.lang, "fr")
        XCTAssertEqual(french.id, AVSpeechEngine.systemVoiceID)
        XCTAssertEqual(AVSpeechEngine.voice(systemDefault, reading: nil), systemDefault)
        XCTAssertEqual(AVSpeechEngine.voice(neuralDefault, reading: "fr"), neuralDefault)
    }

    /// A book's language from its sentences: English, and an English book
    /// with French lines in it, give none.
    func testABooksLanguageIsFoundFromItsSentences() {
        let french = ["Il était une fois une petite fille qui vivait au bord de la forêt.",
                      "Elle allait chaque matin chercher de l'eau à la rivière.",
                      "Sa grand-mère habitait de l'autre côté du bois."]
        let english = ["It was the best of times, it was the worst of times.",
                       "She walked down to the river every morning.",
                       "Eh bien, mon prince, Gênes et Lucques ne sont plus que des apanages.",
                       "The old house stood at the edge of the wood, and nobody went near it."]
        XCTAssertEqual(AVSpeechEngine.readingLanguage(of: french), "fr")
        XCTAssertEqual(AVSpeechEngine.readingLanguage(of: ["从前有一个小女孩，她住在森林的边上。", "她每天早上去河边打水。"]),
                       "zh-Hans")
        XCTAssertNil(AVSpeechEngine.readingLanguage(of: english))
        XCTAssertNil(AVSpeechEngine.readingLanguage(of: [String]()))
    }

    /// Playback finds the book's language once, at load, and hands it to
    /// the System voice on the sentence path and the warm-ups alike.
    func testPlaybackHandsTheSystemVoiceTheBooksLanguage() throws {
        let path = "Playback/PlaybackController.swift"
        let code = try SourceTree.sources(only: [path]).mapValues(SwiftLiterals.code(in:))
        let source = try XCTUnwrap(code[path])
        XCTAssertTrue(source.contains("systemVoiceLanguage = AVSpeechEngine.readingLanguage(of: content.sentences"))
        XCTAssertEqual(source.components(separatedBy: "AVSpeechEngine.voice(voice, reading: systemVoiceLanguage)").count - 1,
                       2, "the sentence path and the warm-ups")
    }

    func testLocaleDefaultBreaksTiesWithinATier() {
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Samantha", localeDefault: true),
                                           above: candidate("Aaron")))
        // ...but never outranks quality.
        XCTAssertTrue(AVSpeechEngine.ranks(candidate("Ava", quality: 3),
                                           above: candidate("Samantha", localeDefault: true)))
    }

    func testDenylistCoversTheKnownNoveltySet() {
        for name in ["Albert", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
                     "Wobble", "Whisper", "Zarvox", "Trinoids", "Organ",
                     "Jester", "Good News", "Bad News", "Superstar", "Fred"] {
            XCTAssertTrue(AVSpeechEngine.noveltyVoiceNames.contains(name),
                          "\(name) should be denylisted")
        }
        for name in ["Samantha", "Ava", "Allison", "Nicky", "Aaron"] {
            XCTAssertFalse(AVSpeechEngine.noveltyVoiceNames.contains(name),
                           "\(name) is a regular voice and must not be denylisted")
        }
    }

    // MARK: - Non-persisting fallback seam

    /// Instant silence: a pick re-speaks the current sentence (R8), and it
    /// must never reach a real synthesizer or a speaker from a test.
    private final class SilentEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            .silence(duration: 0.05)
        }
    }

    /// Temporary fallbacks (the pre-install stand-in, neural-failure
    /// degradation) set `voice` directly; only `selectVoice` reaches the
    /// `voiceSelections` subject AppModel persists the preference from, and
    /// only when the voice actually changes.
    func testOnlyDeliberateSelectionsEmitForPersistence() {
        let engine = SilentEngine()
        let cache = AudioClipCache()
        let standIn = TtsVoice(id: "test:standIn", name: "Stand-in", lang: "en-US",
                               gender: "", engine: .avSpeech, quality: 1)
        let playback = PlaybackController(
            engine: engine,
            defaultVoice: systemDefault,
            scheduler: SynthesisScheduler(engine: engine, cache: cache),
            cache: cache,
            audioSession: PlatformAudioOutput.makeMonitor(),
            anchorStore: ResumeAnchorStore(defaults: PlaybackTestRig.freshDefaults()),
            stopStore: PlaybackStopStore(defaults: PlaybackTestRig.freshDefaults()),
            outputMuted: true)
        // A loaded book, so a pick re-speaks a muted stub sentence rather than
        // synthesizing the no-book sample line.
        playback.load(
            document: LibraryDocument(id: UUID(), title: "Two", fileName: "two.txt",
                                      addedAt: Date(), pageCount: 1, sentenceCount: 2,
                                      contentHash: "two-hash", kind: .text),
            content: DocContent(title: "Two", pageCount: 1,
                                sentences: [Sentence(id: 0, text: "One.", para: 0, page: 0),
                                            Sentence(id: 1, text: "Two.", para: 0, page: 0)],
                                paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<2, page: 0)],
                                contentHash: "two-hash"))

        var emitted: [String] = []
        let subscription = playback.voiceSelections.sink { emitted.append($0.id) }
        defer { subscription.cancel() }

        // Programmatic assignment — the fallback/stand-in path.
        playback.voice = standIn
        XCTAssertEqual(emitted, [], "A programmatic voice change must not persist")
        XCTAssertEqual(playback.voice.id, standIn.id, "...but it does become the active voice")

        // Deliberate pick — the picker path.
        playback.selectVoice(systemDefault)
        XCTAssertEqual(emitted, ["system"])
        XCTAssertEqual(playback.voice.id, "system")

        // Re-picking the selected voice writes nothing (R5).
        playback.selectVoice(playback.voice)
        XCTAssertEqual(emitted, ["system"])
    }
}
