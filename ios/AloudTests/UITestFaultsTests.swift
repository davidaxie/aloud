import AVFoundation
import XCTest
@testable import Aloud

/// The `-uitest-fault` synthesis switch and the engine it gates (R11's
/// fault-injection UI tests depend on both). Each test builds its own switch,
/// never the shared one, and the base engine returns silence. The output
/// faults are read back, never posted: the host app observes the real
/// notifications.
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

    // MARK: - Output faults (S8)

    /// Each output fault reads back, through the iPhone monitor's own
    /// parsing, as the event it stands for.
    func testOutputFaultsReadBackAsTheirEvents() {
        let (routeName, routeInfo) = AudioOutputFaults.notification(for: .routeLost)
        XCTAssertEqual(routeName, AVAudioSession.routeChangeNotification)
        XCTAssertTrue(AudioSessionManager.routeRequiresPause(routeInfo))
        XCTAssertNil(AudioSessionManager.interruption(from: routeInfo))

        let interruptions: [(AudioOutputFaults.Fault, AudioInterruption)] = [
            (.interruptionBegan, .began),
            (.interruptionEnded(shouldResume: true), .ended(shouldResume: true)),
            (.interruptionEnded(shouldResume: false), .ended(shouldResume: false)),
        ]
        for (fault, event) in interruptions {
            let (name, info) = AudioOutputFaults.notification(for: fault)
            XCTAssertEqual(name, AVAudioSession.interruptionNotification, "\(fault)")
            XCTAssertEqual(AudioSessionManager.interruption(from: info), event, "\(fault)")
            XCTAssertFalse(AudioSessionManager.routeRequiresPause(info), "\(fault)")
        }
    }

    /// Only the playing device going away pauses: a device arriving doesn't.
    func testOnlyALostDeviceRequiresAPause() {
        XCTAssertFalse(AudioSessionManager.routeRequiresPause([
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
        ]))
        XCTAssertFalse(AudioSessionManager.routeRequiresPause(nil))
        XCTAssertNil(AudioSessionManager.interruption(from: nil))
    }

    /// The iPhone's monitor is the session manager. Before anything has
    /// played it has no engine to follow, so a configuration change is
    /// left alone (S7b).
    func testIPhoneMonitorIgnoresConfigurationChangesBeforeAnyPlay() {
        let monitor = PlatformAudioOutput.makeMonitor()
        XCTAssertTrue(monitor is AudioSessionManager)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .ignore)
    }

    /// A car's Bluetooth or AirPlay taking over stops the engine: the change
    /// settles first (an unplug's pause may still be on its way), then the
    /// monitor posts it again for the engine, and that one is followed. On
    /// a private center, so the host app's session hears nothing.
    func testIPhoneMonitorFollowsASettledConfigurationChange() {
        let monitor = AudioSessionManager(center: NotificationCenter(), settleInterval: 0.05)
        let engine = AVAudioEngine()   // never started, as after the engine stops itself
        monitor.bindOutput(of: engine)
        let posted = expectation(forNotification: .AVAudioEngineConfigurationChange, object: engine)

        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .ignore, "not at once")
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .ignore, "one settle per change")
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .follow, "the settled change is followed")
        withExtendedLifetime(engine) {}
    }

    /// With no settle the change is followed at once.
    func testIPhoneMonitorWithNoSettleFollowsAtOnce() {
        let monitor = AudioSessionManager(center: NotificationCenter(), settleInterval: 0)
        let engine = AVAudioEngine()
        monitor.bindOutput(of: engine)
        XCTAssertEqual(monitor.decisionAfterConfigurationChange(), .follow)
    }

    /// A call, or a session that outranks Aloud, refusing the activation is
    /// an interruption; any other session error isn't.
    func testHeldElsewhereErrorsAreTold() {
        func sessionError(_ code: AVAudioSession.ErrorCode) -> Error {
            NSError(domain: NSOSStatusErrorDomain, code: code.rawValue)
        }
        XCTAssertTrue(AudioSessionManager.isHeldElsewhere(sessionError(.insufficientPriority)))
        XCTAssertTrue(AudioSessionManager.isHeldElsewhere(sessionError(.cannotInterruptOthers)))
        XCTAssertFalse(AudioSessionManager.isHeldElsewhere(sessionError(.isBusy)))
        XCTAssertFalse(AudioSessionManager.isHeldElsewhere(sessionError(.mediaServicesFailed)))
    }
}
