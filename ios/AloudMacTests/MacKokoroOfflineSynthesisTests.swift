import XCTest
@testable import Aloud

/// The natural voice on the Mac, offline (M4 on a plane): Kokoro loads the
/// pinned model from /Users/Shared/AloudKokoroModel (the Debug entitlement's
/// one read-only exception) and the bundled espeak data, and speaks one
/// sentence into samples. No audio graph, no device, no network: the
/// buffer is all there is.
final class MacKokoroOfflineSynthesisTests: XCTestCase {

    private static let modelDirectory = URL(fileURLWithPath: "/Users/Shared/AloudKokoroModel", isDirectory: true)

    func testOneSentenceSynthesizesIntoABuffer() async throws {
        let directory = Self.modelDirectory
        for name in ["model.onnx", "voices.bin"] {
            let path = directory.appendingPathComponent(name).path
            try XCTSkipUnless(FileManager.default.isReadableFile(atPath: path),
                              "\(path) is missing or unreadable: run ios/tools/fetch_kokoro_model.sh (353 MB, "
                                + "with the owner's OK); a sandboxed Release host can't read it at all")
        }
        XCTAssertTrue(ModelManager.installedFilesLookIntact(in: directory),
                      "the seed doesn't match ModelManager's pinned sizes: rerun ios/tools/fetch_kokoro_model.sh")

        let engine = KokoroSherpaEngine(modelDirectory: directory)
        defer { engine.release() }
        let audio = try await engine.synthesize("Aloud reads on the plane, with no network at all.",
                                                voice: engine.defaultVoice)

        XCTAssertEqual(audio.sampleRate, 24_000)
        let seconds = Double(audio.samples.count) / audio.sampleRate
        XCTAssertGreaterThan(seconds, 1, "too short for the sentence")
        XCTAssertLessThan(seconds, 10, "too long for the sentence")
        let peak = audio.samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.01, "speech, not silence")
        XCTAssertLessThanOrEqual(peak, 1.5, "no runaway samples")
    }
}
