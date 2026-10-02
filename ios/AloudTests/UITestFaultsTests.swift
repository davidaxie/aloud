import XCTest
@testable import Aloud

/// The `-uitest-fault` synthesis switch and the engine it gates (R11's
/// fault-injection UI tests depend on both). Each test builds its own switch,
/// never the shared one, and the base engine returns silence.
@MainActor
final class UITestFaultsTests: XCTestCase {

    private typealias RecordingEngine = PlaybackTestRig.RecordingEngine
    private static let system = PlaybackTestRig.voiceA
    private static let michael = PlaybackTestRig.michael

    func testOffFailsNothing() {
        let faults = UITestFaultSwitch()
        XCTAssertEqual(faults.mode, .off)
        XCTAssertFalse(faults.shouldFail(text: "One.", engine: .avSpeech))
        XCTAssertFalse(faults.shouldFail(text: "One.", engine: .kokoro))
    }

    func testFailAllFailsEveryEngine() {
        let faults = UITestFaultSwitch()
        faults.mode = .failAll
        XCTAssertTrue(faults.shouldFail(text: "One.", engine: .avSpeech))
        XCTAssertTrue(faults.shouldFail(text: "Two.", engine: .kokoro))
    }

    func testFailNeuralFailsOnlyKokoro() {
        let faults = UITestFaultSwitch()
        faults.mode = .failNeural
        XCTAssertTrue(faults.shouldFail(text: "One.", engine: .kokoro))
        XCTAssertFalse(faults.shouldFail(text: "One.", engine: .avSpeech))
    }

    func testFailOneSentenceFailsOnlyThePinnedText() {
        let faults = UITestFaultSwitch()
        faults.mode = .failOneSentence
        XCTAssertTrue(faults.shouldFail(text: "First.", engine: .avSpeech), "the first text asked for is pinned")
        XCTAssertFalse(faults.shouldFail(text: "Second.", engine: .avSpeech))
        XCTAssertTrue(faults.shouldFail(text: "First.", engine: .avSpeech), "every retry of it fails too")
        XCTAssertTrue(faults.shouldFail(text: "First.", engine: .kokoro))

        // Setting the mode again forgets the pin.
        faults.mode = .failOneSentence
        XCTAssertTrue(faults.shouldFail(text: "Second.", engine: .avSpeech))
        XCTAssertFalse(faults.shouldFail(text: "First.", engine: .avSpeech))
    }

    func testEngineForwardsWhenOff() async throws {
        let base = RecordingEngine(voices: [Self.system])
        let engine = UITestFaultEngine(base: base, faults: UITestFaultSwitch())

        let audio = try await engine.synthesize("Line0 word.", voice: Self.system)

        XCTAssertGreaterThan(audio.samples.count, 0)
        XCTAssertEqual(base.requestedTexts, ["Line0 word."])
        XCTAssertEqual(engine.voices, base.voices)
    }

    func testEngineThrowsWithoutAskingTheBase() async {
        let base = RecordingEngine(voices: [Self.system, Self.michael])
        let faults = UITestFaultSwitch()
        let engine = UITestFaultEngine(base: base, faults: faults)
        faults.mode = .failNeural

        do {
            _ = try await engine.synthesize("Line0 word.", voice: Self.michael)
            XCTFail("the neural voice should fail")
        } catch {
            XCTAssertEqual(error as? TtsError, .voiceUnavailable)
        }
        _ = try? await engine.synthesize("Line1 word.", voice: Self.system)

        XCTAssertEqual(base.requestedTexts, ["Line1 word."], "a failed request never reaches the base")
    }
}
