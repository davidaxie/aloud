import XCTest
@testable import Aloud

/// Aloud's blends against the real model: the derived voices file built from
/// the pinned voices.bin in /Users/Shared/AloudKokoroModel matches the
/// reference mix bit for bit, sherpa-onnx loads it, and a blend speaks
/// differently from Michael. Samples only: no audio graph, no device,
/// nothing plays.
final class MacKokoroBlendSynthesisTests: XCTestCase {

    private static let modelDirectory = URL(fileURLWithPath: "/Users/Shared/AloudKokoroModel", isDirectory: true)

    /// The SHA-256 of the derived file from the reference mix (numpy,
    /// float32, multiply then add in recipe order): what the voices were
    /// auditioned with.
    private static let referenceSHA256 = "ea4fbaa4097458e7dabbae7298b78611069146fb0cab88623d475921a08bb8f2"

    private var blendFolder: URL!

    override func setUpWithError() throws {
        for name in ["model.onnx", "voices.bin"] {
            let path = Self.modelDirectory.appendingPathComponent(name).path
            try XCTSkipUnless(FileManager.default.isReadableFile(atPath: path),
                              "\(path) is missing or unreadable: run ios/tools/fetch_kokoro_model.sh (353 MB, "
                                + "with the owner's OK); a sandboxed Release host can't read it at all")
        }
        blendFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacKokoroBlendSynthesisTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: blendFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let blendFolder { try? FileManager.default.removeItem(at: blendFolder) }
    }

    func testTheDerivedFileMatchesTheReferenceMix() throws {
        let copy = try XCTUnwrap(KokoroVoiceBlends.preparedVoicesFile(
            source: Self.modelDirectory.appendingPathComponent("voices.bin"), in: blendFolder))
        XCTAssertEqual(try ModelManager.sha256Hex(of: copy), Self.referenceSHA256,
                       "the mix must be multiply then add in recipe order, never fused")
    }

    func testABlendLoadsAndSpeaksUnlikeMichael() async throws {
        let engine = KokoroSherpaEngine(modelDirectory: Self.modelDirectory, blendDirectory: blendFolder)
        defer { engine.release() }
        let sentence = "The rain had stopped by morning, and the road was quiet."
        let michael = try await engine.synthesize(sentence, voice: engine.defaultVoice)
        let velvetVoice = try XCTUnwrap(engine.voices.first { $0.id == KokoroVoiceBlends.velvet.voiceID })
        let velvet = try await engine.synthesize(sentence, voice: velvetVoice)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: blendFolder.appendingPathComponent(KokoroVoiceBlends.fileName).path))
        for audio in [michael, velvet] {
            let seconds = Double(audio.samples.count) / audio.sampleRate
            XCTAssertGreaterThan(seconds, 1, "too short for the sentence")
            XCTAssertLessThan(seconds, 10, "too long for the sentence")
            let peak = audio.samples.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertGreaterThan(peak, 0.01, "speech, not silence")
            XCTAssertLessThanOrEqual(peak, 1.5, "no runaway samples")
        }
        XCTAssertNotEqual(velvet.samples, michael.samples, "Velvet speaks from its own table, not Michael's")
    }
}
