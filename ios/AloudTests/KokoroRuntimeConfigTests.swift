import AVFoundation
import XCTest
@testable import Aloud

/// Kokoro's ONNX Runtime options (S15): the spinning-off config file and
/// the provider string that names it, and when the warm-up line is spoken.
/// sherpa-onnx ends the whole process when a named config file can't be
/// opened, so every way the file could be unusable must come back as plain
/// "cpu". Files go in a temporary folder of this test's own; nothing loads
/// a model and nothing plays.
final class KokoroRuntimeConfigTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroRuntimeConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
    }

    private var configURL: URL {
        folder.appendingPathComponent(KokoroSherpaEngine.runtimeConfigFileName)
    }

    /// Spinning left on is plain "cpu", and nothing is written.
    func testSpinningOnIsPlainCPU() {
        XCTAssertEqual(KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: false, configDirectory: folder), "cpu")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    /// Spinning off names the file, written with exactly the two entries.
    func testSpinningOffNamesTheWrittenFile() throws {
        let provider = KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: folder)
        XCTAssertEqual(provider, "cpu:" + configURL.path)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(text, KokoroSherpaEngine.threadSpinningOffConfig)
        XCTAssertTrue(text.contains("SessionConfig.session.intra_op.allow_spinning=0"))
        XCTAssertTrue(text.contains("SessionConfig.session.inter_op.allow_spinning=0"))
    }

    /// No folder to write in: plain "cpu", never a path.
    func testNoFolderIsPlainCPU() {
        XCTAssertEqual(KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: nil), "cpu")
    }

    /// A folder whose path holds a colon: sherpa would split the provider
    /// there and open the wrong file, so it's never named.
    func testAPathWithAColonIsNeverNamed() throws {
        let colon = folder.appendingPathComponent("a:b", isDirectory: true)
        try FileManager.default.createDirectory(at: colon, withIntermediateDirectories: true)
        XCTAssertEqual(KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: colon), "cpu")
    }

    /// Something else already at the file's path (a folder here) can't be
    /// written over: plain "cpu".
    func testAnUnwritableFileIsPlainCPU() throws {
        try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        XCTAssertNil(KokoroSherpaEngine.preparedRuntimeConfig(in: folder))
        XCTAssertEqual(KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: folder), "cpu")
    }

    /// A file with other contents is put right before it's named.
    func testOtherContentsAreRewritten() throws {
        try Data("SessionConfig.session.intra_op.allow_spinning=1\n".utf8).write(to: configURL)
        XCTAssertEqual(KokoroSherpaEngine.preparedRuntimeConfig(in: folder), configURL)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), KokoroSherpaEngine.threadSpinningOffConfig)
    }

    /// Emptied caches between loads: each load writes it again.
    func testADeletedFileIsWrittenAgain() throws {
        _ = KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: folder)
        try FileManager.default.removeItem(at: configURL)
        XCTAssertEqual(KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: true, configDirectory: folder),
                       "cpu:" + configURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    /// The warm line is spoken only by a warm-up ahead of any reading: a
    /// sentence waiting pays the graph build itself, sooner.
    func testTheWarmLineOnlyWhenNothingWaits() {
        XCTAssertTrue(KokoroSherpaEngine.speaksWarmLine(onDemand: false, sentenceWaiting: false))
        XCTAssertFalse(KokoroSherpaEngine.speaksWarmLine(onDemand: false, sentenceWaiting: true))
        XCTAssertFalse(KokoroSherpaEngine.speaksWarmLine(onDemand: true, sentenceWaiting: false))
        XCTAssertFalse(KokoroSherpaEngine.speaksWarmLine(onDemand: true, sentenceWaiting: true))
    }

    /// The engine never runs on fewer than one thread, whatever it's given.
    func testTheEngineKeepsAtLeastOneThread() {
        let engine = KokoroSherpaEngine(modelDirectory: folder, numThreads: 0, stopsThreadSpinning: false,
                                        runtimeConfigDirectory: folder)
        XCTAssertEqual(engine.numThreads, 1)
        XCTAssertFalse(engine.isWarm, "building it loads nothing")
    }

    // MARK: - Text the English frontend can't say (F072)

    /// A line of nothing but Han characters gives sherpa-onnx no tokens, so
    /// it is a short silence, decided before any model is needed (this
    /// folder holds none), never a failure that counts against the voice.
    func testALineOfOnlyHanCharactersIsASilence() async throws {
        let engine = KokoroSherpaEngine(modelDirectory: folder, stopsThreadSpinning: false,
                                        runtimeConfigDirectory: nil)
        for line in ["第一回", "静夜思", "床前明月光", "第一回 第二回"] {
            let audio = try await engine.synthesize(line, voice: engine.defaultVoice)
            XCTAssertFalse(audio.samples.isEmpty, line)
            XCTAssertTrue(audio.samples.allSatisfy { $0 == 0 }, "\(line): silence")
        }
        XCTAssertFalse(engine.isWarm, "nothing loaded")
    }

    func testOnlyAllHanTextIsUnvoiceable() {
        for line in ["第一回", "静夜思", "第一回 第二回"] {
            XCTAssertFalse(KokoroSherpaEngine.frontendCanVoice(line), line)
        }
        for line in ["Chapter one", "第一回。", "Chapter 第一回", "ひらがな", "1984", "", "Hello, world"] {
            XCTAssertTrue(KokoroSherpaEngine.frontendCanVoice(line), line)
        }
    }

    // MARK: - Blends without their table (F073)

    /// A blend speaking as its fallback is paced as its fallback, and the
    /// engine says whether the blends are in once a load has decided.
    func testABlendWithoutItsTableIsPacedAsItsFallback() {
        let velvet = KokoroVoiceBlends.velvet.voiceID
        XCTAssertEqual(KokoroSherpaEngine.speakingVoiceID(for: velvet, blendsLoaded: false), "kokoro:am_michael")
        XCTAssertEqual(KokoroSherpaEngine.speakingVoiceID(for: velvet, blendsLoaded: true), velvet)
        XCTAssertEqual(KokoroSherpaEngine.speakingVoiceID(for: "kokoro:af_heart", blendsLoaded: false),
                       "kokoro:af_heart")
        let engine = KokoroSherpaEngine(modelDirectory: folder, stopsThreadSpinning: false,
                                        runtimeConfigDirectory: nil, blendDirectory: folder)
        XCTAssertNil(engine.blendsAvailable, "no load has decided yet")
    }
}

/// The System voice is ranked once, not per sentence, and ranked again
/// when the installed voices change. A private notification center; no
/// voice speaks.
final class SystemVoiceCacheTests: XCTestCase {

    private let samantha = "com.apple.voice.compact.en-US.Samantha"

    func testTheCachedVoiceIsForgottenWhenVoicesChange() {
        let center = NotificationCenter()
        let cache = AVSpeechEngine.BestVoiceCache(center: center)
        cache.store(samantha, rankedWith: "default", ifStill: cache.generation)
        XCTAssertEqual(cache.identifier(rankedWith: "default"), samantha)
        center.post(name: AVSpeechEngine.installedVoicesDidChange, object: nil)
        XCTAssertNil(cache.identifier(rankedWith: "default"), "a voice added or removed: rank again")
    }

    /// The English default changed in System Settings, nothing installed or
    /// removed: the pick ranked with the old default isn't used.
    func testANewEnglishDefaultRanksAgain() {
        let cache = AVSpeechEngine.BestVoiceCache(center: NotificationCenter())
        cache.store(samantha, rankedWith: "old default", ifStill: cache.generation)
        XCTAssertNil(cache.identifier(rankedWith: "new default"))
        XCTAssertEqual(cache.identifier(rankedWith: "old default"), samantha)
    }

    /// Voices that changed while a ranking ran: its pick is never kept.
    func testAPickRankedAcrossAChangeIsNotKept() {
        let center = NotificationCenter()
        let cache = AVSpeechEngine.BestVoiceCache(center: center)
        let before = cache.generation
        center.post(name: AVSpeechEngine.installedVoicesDidChange, object: nil)   // mid-ranking
        cache.store(samantha, rankedWith: "default", ifStill: before)
        XCTAssertNil(cache.identifier(rankedWith: "default"))
    }

    /// L003: each language keeps its own pick beside the English one,
    /// "none installed" included, and a change of voices forgets them all.
    func testEachLanguageKeepsItsOwnPick() {
        let center = NotificationCenter()
        let cache = AVSpeechEngine.BestVoiceCache(center: center)
        let thomas = "com.apple.voice.compact.fr-FR.Thomas"
        cache.store(samantha, rankedWith: "default", ifStill: cache.generation)
        cache.store(thomas, reading: "fr", rankedWith: "fr default", ifStill: cache.generation)
        cache.store(nil, reading: "de", rankedWith: nil, ifStill: cache.generation)
        XCTAssertEqual(cache.identifier(rankedWith: "default"), samantha)
        XCTAssertEqual(cache.pick(reading: "fr", rankedWith: "fr default"), .some(thomas))
        XCTAssertEqual(cache.pick(reading: "de", rankedWith: nil), .some(nil), "ranked: no German voice")
        XCTAssertNil(cache.pick(reading: "fr", rankedWith: "new default"))
        center.post(name: AVSpeechEngine.installedVoicesDidChange, object: nil)
        XCTAssertNil(cache.pick(reading: "fr", rankedWith: "fr default"))
        XCTAssertNil(cache.pick(reading: "de", rankedWith: nil))
    }

    /// A book in a language no installed voice speaks reads in the English
    /// pick, exactly as an English book does.
    func testALanguageWithNoInstalledVoiceReadsInTheEnglishPick() {
        XCTAssertEqual(AVSpeechEngine.cachedBestSystemVoice(reading: "x-none")?.identifier,
                       AVSpeechEngine.cachedBestSystemVoice()?.identifier)
        XCTAssertEqual(AVSpeechEngine.cachedBestSystemVoice(reading: "en-US")?.identifier,
                       AVSpeechEngine.cachedBestSystemVoice()?.identifier)
    }

    /// With a voice installed for a book's language, synthesis resolves the
    /// System voice to it (only listed, never spoken).
    func testAnInstalledLanguageVoiceReadsItsBook() throws {
        guard let other = AVSpeechSynthesisVoice.speechVoices().first(where: { !$0.language.hasPrefix("en") }) else {
            throw XCTSkip("no voice for a language other than English is installed")
        }
        let language = String(other.language.prefix { $0 != "-" })
        let pick = try XCTUnwrap(AVSpeechEngine.cachedBestSystemVoice(reading: language))
        XCTAssertTrue(pick.language.hasPrefix(language), "\(pick.language) for \(language)")
    }

    /// The System row names the voice synthesis speaks with.
    func testTheRowNamesTheCachedPick() {
        let pick = AVSpeechEngine.cachedBestSystemVoice()
        XCTAssertEqual(AVSpeechEngine.resolvedVoiceDisplayName() != nil, pick != nil)
    }

    func testTheCachedVoiceIsTheBestVoice() {
        XCTAssertEqual(AVSpeechEngine.cachedBestSystemVoice()?.identifier,
                       AVSpeechEngine.bestSystemVoice()?.identifier)
        XCTAssertEqual(AVSpeechEngine.cachedBestSystemVoice()?.identifier,
                       AVSpeechEngine.bestSystemVoice()?.identifier, "the same from the cache")
    }
}

/// L000: every Kokoro sentence names its voice's language, so Emma, the one
/// British speaker, is phonemized as British English. Kokoro needs the model
/// to speak, so the choice is tested as a value and the call by its source.
final class KokoroPhonemeLanguageTests: XCTestCase {

    func testEmmaIsPhonemizedAsBritish() throws {
        let emma = try XCTUnwrap(KokoroVoiceCatalog.curatedVoices.first { $0.id == "kokoro:bf_emma" })
        XCTAssertEqual(KokoroSherpaEngine.phonemeLanguage(for: emma.lang), "en-gb")
    }

    /// The American speakers and the blends (American too) keep en-us,
    /// what sherpa used for every voice before.
    func testEveryOtherVoiceIsPhonemizedAsAmerican() {
        for voice in KokoroVoiceCatalog.curatedVoices where voice.id != "kokoro:bf_emma" {
            XCTAssertEqual(KokoroSherpaEngine.phonemeLanguage(for: voice.lang), "en-us", voice.id)
        }
        for blend in KokoroVoiceBlends.all {
            let voice = KokoroVoiceCatalog.curatedVoices.first { $0.id == blend.voiceID }
            XCTAssertEqual(voice.map { KokoroSherpaEngine.phonemeLanguage(for: $0.lang) }, "en-us", blend.voiceID)
        }
    }

    /// The sentence call passes the language in its generation config; the
    /// plain generate(text:sid:speed:) carries none, and sherpa then falls
    /// back to the model's en-us for every speaker.
    func testEverySentenceCallNamesTheLanguage() throws {
        let path = "TTS/KokoroSherpaEngine.swift"
        let code = try SourceTree.sources(only: [path]).mapValues(SwiftLiterals.code(in:))
        let source = try XCTUnwrap(code[path])
        let synthesize = try XCTUnwrap(source.range(of: "speed requested: Double)"))
        let release = try XCTUnwrap(source.range(of: "func release()"))
        let body = String(source[synthesize.upperBound..<release.lowerBound])
        XCTAssertTrue(body.contains("tts.generateWithConfig(text: spoken, config: config"))
        XCTAssertTrue(body.contains("Self.phonemeLanguage(for: voice.lang)"))
        XCTAssertFalse(body.contains("tts.generate(text:"), "the plain call drops the language")
    }
}
