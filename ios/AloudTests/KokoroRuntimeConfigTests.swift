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
