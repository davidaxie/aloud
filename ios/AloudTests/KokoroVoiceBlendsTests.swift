import XCTest
@testable import Aloud

/// Aloud's blended voices: the recipes, the mix, and the derived voices file
/// built from voices.bin. A synthetic 53 × 510 × 256 table stands in for the
/// model's; files go in this test's own temporary folders. Nothing loads a
/// model and nothing plays.
final class KokoroVoiceBlendsTests: XCTestCase {

    private var folder: URL!
    private var sourceFolder: URL!
    private var blendFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroVoiceBlendsTests-\(UUID().uuidString)", isDirectory: true)
        sourceFolder = folder.appendingPathComponent("model", isDirectory: true)
        blendFolder = folder.appendingPathComponent("blends", isDirectory: true)
        for directory in [sourceFolder!, blendFolder!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
    }

    // MARK: - A stand-in voices file

    private static func float(_ data: Data, sid: Int, element: Int) -> Float {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: (sid * KokoroVoiceBlends.tableFloats + element) * 4, as: Float.self)
        }
    }

    private static func sid(_ speaker: String) -> Int {
        KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.voiceIDPrefix + speaker)!
    }

    private func writeSource(_ data: Data = KokoroVoiceTablesFixture.synthetic) throws -> (url: URL, sha: String) {
        let url = sourceFolder.appendingPathComponent("voices.bin")
        try data.write(to: url, options: .atomic)   // a new file each time, as an install leaves
        return (url, try ModelManager.sha256Hex(of: url))
    }

    private func stamp(_ url: URL) -> ModelInstallRecord.File? {
        ModelInstallRecord.stamp(at: url, name: url.lastPathComponent, sha256: "")
    }

    private var copyURL: URL { blendFolder.appendingPathComponent(KokoroVoiceBlends.fileName) }

    // MARK: - Recipes

    func testRecipesAreWellFormed() {
        let curatedSids = Set(KokoroVoiceCatalog.curatedVoices.compactMap { KokoroVoiceCatalog.sid(for: $0.id) })
        var slots: Set<Int> = []
        for blend in KokoroVoiceBlends.all {
            XCTAssertTrue(blend.speaker.hasPrefix("aloud_"), blend.speaker)
            XCTAssertTrue(slots.insert(blend.slot).inserted, "\(blend.speaker): slot \(blend.slot) is taken")
            XCTAssertTrue((28..<53).contains(blend.slot), "\(blend.speaker) overwrites a stock English speaker")
            XCTAssertFalse(curatedSids.contains(blend.slot), blend.speaker)
            XCTAssertNotNil(KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.voiceIDPrefix + blend.fallbackSpeaker))
            for half in [blend.timbre, blend.prosody] {
                XCTAssertEqual(half.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-6, blend.speaker)
                for part in half {
                    let sid = KokoroVoiceCatalog.sid(for: KokoroVoiceCatalog.voiceIDPrefix + part.speaker)
                    XCTAssertNotNil(sid, part.speaker)
                    XCTAssertTrue(KokoroVoiceBlends.sourceSids.contains(sid ?? -1),
                                  "\(blend.speaker) reads \(part.speaker), which a blend may overwrite")
                }
            }
        }
    }

    /// The text kept in the record: any change to a weight rebuilds the copy.
    func testTheRecipeTextNamesEveryWeight() {
        XCTAssertEqual(KokoroVoiceBlends.recipe(),
                       "v1|28:T am_michael*0.6+am_onyx*0.2+am_adam*0.2|P am_michael*0.6+am_onyx*0.2+am_adam*0.2;"
                       + "29:T am_michael*0.5+am_fenrir*0.3+am_onyx*0.2|P am_michael*0.5+am_fenrir*0.3+am_onyx*0.2;"
                       + "30:T am_michael*0.7+am_fenrir*0.3|P am_michael*0.7+am_fenrir*0.3")
    }

    /// No voice is named after another product.
    func testNoVoiceBorrowsAProductsName() {
        for voice in KokoroVoiceCatalog.curatedVoices {
            for word in ["speechify", "nate"] {
                XCTAssertFalse(voice.name.lowercased().contains(word), voice.name)
                XCTAssertFalse(voice.subtitle.lowercased().contains(word), voice.subtitle)
            }
        }
    }

    // MARK: - Mixing

    /// Every value of every blend is the weighted sum, multiply then add, in
    /// recipe order from zero; the other 50 tables are untouched.
    func testTheMixIsTheWeightedSumAndNothingElseMoves() throws {
        let source = KokoroVoiceTablesFixture.synthetic
        var table = source
        try KokoroVoiceBlends.derive(into: &table)
        XCTAssertEqual(table.count, source.count)
        for blend in KokoroVoiceBlends.all {
            for element in 0..<KokoroVoiceBlends.tableFloats {
                let parts = element % KokoroVoiceBlends.width < KokoroVoiceBlends.half ? blend.timbre : blend.prosody
                var expected: Float = 0
                for part in parts {
                    let product = Self.float(source, sid: Self.sid(part.speaker), element: element) * part.weight
                    expected = expected + product
                }
                let got = Self.float(table, sid: blend.slot, element: element)
                guard got.bitPattern == expected.bitPattern else {
                    return XCTFail("\(blend.speaker) element \(element): \(got) != \(expected)")
                }
            }
        }
        let slotBytes = KokoroVoiceBlends.tableFloats * 4
        let blendSlots = Set(KokoroVoiceBlends.all.map(\.slot))
        for sid in 0..<KokoroVoiceBlends.speakers where !blendSlots.contains(sid) {
            let range = (sid * slotBytes)..<((sid + 1) * slotBytes)
            XCTAssertEqual(table[range], source[range], "slot \(sid) changed")
        }
    }

    /// The timbre columns follow the timbre weights and the prosody columns
    /// the prosody weights.
    func testEachHalfFollowsItsOwnWeights() throws {
        let split = KokoroVoiceBlend(speaker: "aloud_split", name: "Split", subtitle: "", slot: 40,
                                     fallbackSpeaker: "am_michael",
                                     timbre: [.init(speaker: "am_michael", weight: 1)],
                                     prosody: [.init(speaker: "am_onyx", weight: 1)])
        let source = KokoroVoiceTablesFixture.synthetic
        var table = source
        try KokoroVoiceBlends.derive(into: &table, blends: [split])
        for row in [0, 99, 509] {
            for column in [0, 127, 128, 255] {
                let element = row * KokoroVoiceBlends.width + column
                let from = column < KokoroVoiceBlends.half ? "am_michael" : "am_onyx"
                XCTAssertEqual(Self.float(table, sid: 40, element: element),
                               Self.float(source, sid: Self.sid(from), element: element), "row \(row) col \(column)")
            }
        }
    }

    func testAWrongSizeOrARecipeThatReadsABlendSlotIsRefused() {
        var short = Data(count: 1024)
        XCTAssertThrowsError(try KokoroVoiceBlends.derive(into: &short)) {
            XCTAssertEqual($0 as? KokoroVoiceBlendError, .wrongSize)
        }
        var table = KokoroVoiceTablesFixture.synthetic
        let readsASlot = KokoroVoiceBlend(speaker: "aloud_bad", name: "Bad", subtitle: "", slot: 31,
                                          mix: [.init(speaker: "ef_dora", weight: 1)])
        XCTAssertThrowsError(try KokoroVoiceBlends.derive(into: &table, blends: [readsASlot])) {
            XCTAssertEqual($0 as? KokoroVoiceBlendError, .badRecipe)
        }
        let overwritesMichael = KokoroVoiceBlend(speaker: "aloud_bad", name: "Bad", subtitle: "", slot: 16,
                                                 mix: [.init(speaker: "am_onyx", weight: 1)])
        XCTAssertThrowsError(try KokoroVoiceBlends.derive(into: &table, blends: [overwritesMichael])) {
            XCTAssertEqual($0 as? KokoroVoiceBlendError, .badRecipe)
        }
    }

    // MARK: - The derived file

    /// Built once at the exact size with its record; a second load only
    /// looks (the copy keeps its inode and mtime).
    func testTheCopyIsBuiltOnceThenTrusted() throws {
        let source = try writeSource()
        let built = KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                         pinnedSHA256: source.sha)
        XCTAssertEqual(built, copyURL)
        XCTAssertEqual(stamp(copyURL)?.bytes, Int64(KokoroVoiceBlends.expectedBytes))
        let record = try XCTUnwrap(KokoroBlendRecord.load(from: blendFolder))
        XCTAssertEqual(record.recipe, KokoroVoiceBlends.recipe())
        XCTAssertEqual(record.source.sha256, source.sha)
        var expected = KokoroVoiceTablesFixture.synthetic
        try KokoroVoiceBlends.derive(into: &expected)
        XCTAssertEqual(try Data(contentsOf: copyURL), expected)

        let first = stamp(copyURL)
        XCTAssertEqual(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                            pinnedSHA256: source.sha), copyURL)
        XCTAssertEqual(stamp(copyURL), first, "a current copy is never written again")
    }

    func testATouchedOrReplacedSourceRebuilds() throws {
        let source = try writeSource()
        _ = KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder, pinnedSHA256: source.sha)
        let first = try XCTUnwrap(stamp(copyURL))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: source.url.path)
        XCTAssertEqual(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                            pinnedSHA256: source.sha), copyURL)
        let second = try XCTUnwrap(stamp(copyURL))
        XCTAssertNotEqual(second, first, "a touched voices.bin builds the copy again")

        _ = try writeSource()   // a reinstall: a new file in its place
        XCTAssertEqual(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                            pinnedSHA256: source.sha), copyURL)
        XCTAssertNotEqual(stamp(copyURL), second)
        XCTAssertEqual(KokoroBlendRecord.load(from: blendFolder)?.source,
                       ModelInstallRecord.stamp(at: source.url, name: "voices.bin", sha256: source.sha))
    }

    func testATruncatedCopyIsBuiltAgain() throws {
        let source = try writeSource()
        _ = KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder, pinnedSHA256: source.sha)
        let handle = try FileHandle(forWritingTo: copyURL)
        try handle.truncate(atOffset: 4096)
        try handle.close()
        XCTAssertEqual(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                            pinnedSHA256: source.sha), copyURL)
        XCTAssertEqual(stamp(copyURL)?.bytes, Int64(KokoroVoiceBlends.expectedBytes))
    }

    func testANewRecipeRebuilds() throws {
        let source = try writeSource()
        _ = KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder, pinnedSHA256: source.sha)
        let first = stamp(copyURL)
        let edited = [KokoroVoiceBlend(speaker: "aloud_velvet", name: "Velvet", subtitle: "", slot: 28,
                                       mix: [.init(speaker: "am_michael", weight: 0.5),
                                             .init(speaker: "am_onyx", weight: 0.5)])]
        XCTAssertEqual(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                            pinnedSHA256: source.sha, blends: edited), copyURL)
        XCTAssertNotEqual(stamp(copyURL), first)
        XCTAssertEqual(KokoroBlendRecord.load(from: blendFolder)?.recipe, KokoroVoiceBlends.recipe(for: edited))
    }

    /// Removed voices: the folder is gone, and a late load never makes it again.
    func testAMissingFolderIsNeverCreated() throws {
        let source = try writeSource()
        let gone = folder.appendingPathComponent("removed", isDirectory: true)
        XCTAssertNil(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: gone, pinnedSHA256: source.sha))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    /// Only bytes that hash to the pin are mixed; a wrong size isn't read.
    func testAnUnverifiedSourceLeavesNoCopy() throws {
        let source = try writeSource()
        XCTAssertNil(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                          pinnedSHA256: String(repeating: "0", count: 64)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path), [])

        _ = try writeSource(Data(count: 4096))
        XCTAssertNil(KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder,
                                                          pinnedSHA256: try ModelManager.sha256Hex(of: source.url)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path), [])
    }

    /// F074: bytes that don't hash to the pin say the install is damaged,
    /// apart from every other reason to load the original.
    func testAWrongSourceHashIsReportedAsDamaged() throws {
        let source = try writeSource()
        XCTAssertEqual(KokoroVoiceBlends.prepareVoicesFile(source: source.url, in: blendFolder,
                                                           pinnedSHA256: String(repeating: "0", count: 64)),
                       .sourceDamaged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path), [])

        let gone = folder.appendingPathComponent("removed", isDirectory: true)
        XCTAssertEqual(KokoroVoiceBlends.prepareVoicesFile(source: source.url, in: gone, pinnedSHA256: source.sha),
                       .original, "no folder is no damage")
        XCTAssertEqual(KokoroVoiceBlends.prepareVoicesFile(source: source.url, in: blendFolder,
                                                           pinnedSHA256: source.sha),
                       .blended(copyURL))
    }

    /// F074: the engine reports a voices.bin that fails its pin as damaged
    /// and loads nothing. The files are sparse at their pinned sizes, so
    /// the size check passes and only the blend build's hash can tell; the
    /// report comes before sherpa-onnx is ever created.
    func testTheEngineReportsAVoicesFileThatFailsItsPin() async throws {
        for asset in [("tokens", "txt"), ("lexicon-us-en", "txt"), ("lexicon-gb-en", "txt")] {
            try XCTSkipUnless(Bundle.main.path(forResource: asset.0, ofType: asset.1) != nil,
                              "this host doesn't bundle Kokoro's assets")
        }
        try XCTSkipUnless(Bundle.main.path(forResource: "espeak-ng-data", ofType: nil) != nil,
                          "this host doesn't bundle Kokoro's assets")
        for file in ModelManager.remoteFiles {
            let url = sourceFolder.appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.expectedBytes))
            try handle.close()
        }
        XCTAssertTrue(ModelManager.installedFilesLookIntact(in: sourceFolder))

        final class Reports: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func add() { lock.lock(); count += 1; lock.unlock() }
            var total: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let reports = Reports()
        let engine = KokoroSherpaEngine(modelDirectory: sourceFolder, stopsThreadSpinning: false,
                                        runtimeConfigDirectory: nil, blendDirectory: blendFolder)
        engine.onModelDamaged = { reports.add() }
        do {
            try await engine.warmUp()
            XCTFail("a voices.bin that fails its pin must not load")
        } catch {
            XCTAssertEqual(error as? KokoroEngineError, .modelDamaged)
        }
        XCTAssertEqual(reports.total, 1)
        XCTAssertFalse(engine.isWarm)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path), [])
    }

    /// The pinned original is only read, and a build leaves only its two files.
    func testTheSourceIsNeverTouchedAndNothingIsLeftOver() throws {
        let source = try writeSource()
        let before = stamp(source.url)
        _ = KokoroVoiceBlends.preparedVoicesFile(source: source.url, in: blendFolder, pinnedSHA256: source.sha)
        XCTAssertEqual(stamp(source.url), before)
        XCTAssertEqual(try ModelManager.sha256Hex(of: source.url), source.sha)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path)),
                       [KokoroVoiceBlends.fileName, KokoroBlendRecord.fileName])

        KokoroVoiceBlends.removeDerivedFiles(in: blendFolder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blendFolder.path), [])
    }

    /// The pin the derived file is built from is voices.bin's.
    func testTheSourcePinIsVoicesBin() {
        XCTAssertEqual(ModelManager.voicesFile.name, "voices.bin")
        XCTAssertEqual(ModelManager.voicesFile.expectedBytes, Int64(KokoroVoiceBlends.expectedBytes))
    }
}

/// A stand-in voices.bin with a distinct value for every speaker, row and
/// column, built once per run.
enum KokoroVoiceTablesFixture {
    static let synthetic: Data = {
        var floats = [Float](repeating: 0, count: KokoroVoiceBlends.speakers * KokoroVoiceBlends.tableFloats)
        for index in floats.indices {
            floats[index] = Float((index &* 2_654_435_761) % 10_007) / 10_007 - 0.5
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}
