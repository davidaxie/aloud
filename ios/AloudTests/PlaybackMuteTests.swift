import AVFoundation
import XCTest
@testable import Aloud

/// The silence guarantee: a test host is muted, a muted controller's main
/// mixer stays at zero even while playing, and the AVSpeech utterance-volume
/// mute doesn't stop synthesis from producing samples. The Mac's muted mode,
/// manual rendering with no device, is forced here on the iPhone, so the
/// graph both platforms share is pinned in both modes.
@MainActor
final class PlaybackMuteTests: XCTestCase {

    func testHostIsMuted() {
        XCTAssertTrue(UITestHooks.muteAudio, "XCTest is loaded, so the whole process is muted")

        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let controller = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlatformAudioOutput.makeMonitor(),
                                            anchorStore: ResumeAnchorStore(defaults: PlaybackTestRig.freshDefaults()),
                                            stopStore: PlaybackStopStore(defaults: PlaybackTestRig.freshDefaults()))
        XCTAssertTrue(controller.isOutputMuted, "the default comes from UITestHooks.muteAudio")
        XCTAssertEqual(controller.mixerOutputVolume, 0)
        XCTAssertFalse(controller.isAutoplaySuppressed,
                       "hosted unit tests are muted but keep autoplay, so its tests still run")
    }

    func testMutedControllerKeepsMixerAtZeroWhilePlaying() async throws {
        let rig = PlaybackTestRig()
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0,
                       "starting the engine re-asserts the volume through the mute")
    }

    /// Launch builds no audio output: touching the mixer is an audio-server
    /// round trip, and one that timed out aborted the app at launch. The first
    /// play builds it, already muted.
    func testOnlyPlayingBuildsTheAudioOutput() async throws {
        let rig = PlaybackTestRig()
        XCTAssertFalse(rig.controller.hasBuiltAudioOutput)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
        XCTAssertFalse(rig.controller.hasBuiltAudioOutput, "reading the level builds nothing")
        rig.loadDefault()
        XCTAssertFalse(rig.controller.hasBuiltAudioOutput, "a cue is not a play")
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertTrue(rig.controller.hasBuiltAudioOutput)
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0)
    }

    func testUnmutedControllerNeverStartedIsAtUnity() {
        // Never loaded, never played: the engine never starts, so nothing is heard.
        let engine = PlaybackTestRig.RecordingEngine(voices: [PlaybackTestRig.voiceA])
        let cache = AudioClipCache()
        let controller = PlaybackController(engine: engine,
                                            defaultVoice: PlaybackTestRig.voiceA,
                                            scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                            cache: cache,
                                            audioSession: PlatformAudioOutput.makeMonitor(),
                                            anchorStore: ResumeAnchorStore(defaults: PlaybackTestRig.freshDefaults()),
                                            stopStore: PlaybackStopStore(defaults: PlaybackTestRig.freshDefaults()),
                                            outputMuted: false)
        XCTAssertFalse(controller.isOutputMuted)
        XCTAssertEqual(controller.mixerOutputVolume, 1)
    }

    func testEffectiveOutputVolume() {
        XCTAssertEqual(PlaybackController.effectiveOutputVolume(1, muted: true), 0)
        XCTAssertEqual(PlaybackController.effectiveOutputVolume(0.5, muted: false), 0.5)
    }

    /// `write()` renders offline, so a zero utterance volume must not cost
    /// the samples. If this ever fails, delete the utterance.volume line in
    /// AVSpeechEngine, not this test: the mixer mute is the guarantee.
    func testMutedSystemSynthesisStillReturnsSamples() async throws {
        try XCTSkipIf(AVSpeechSynthesisVoice.speechVoices().isEmpty, "no system voices installed")
        let engine = AVSpeechEngine(mutesOutput: true)
        XCTAssertTrue(engine.mutesOutput)
        let clip = try await engine.synthesize("Hello there.", voice: engine.defaultVoice)
        XCTAssertFalse(clip.samples.isEmpty)
    }

    // MARK: - Muted output modes

    #if os(iOS)
    /// The iPhone keeps today's mute: the real device, mixer at zero.
    func testIPhoneMutesOnTheDeviceAtZeroVolume() {
        XCTAssertEqual(PlatformAudio.mutedOutputMode, .deviceAtZeroVolume)
        XCTAssertFalse(PlaybackTestRig().controller.rendersOffline)
        XCTAssertTrue(PlaybackTestRig(mutedOutputMode: .manualRendering).controller.rendersOffline)
    }
    #else
    /// A muted Mac process renders offline and never opens a device. No
    /// Mac test forces the device mode, so none builds a device-bound rig.
    func testMacMutesByRenderingOffline() {
        XCTAssertEqual(PlatformAudio.mutedOutputMode, .manualRendering)
        XCTAssertTrue(PlaybackTestRig().controller.rendersOffline)
    }
    #endif

    /// Manual rendering plays in real time with no device: the render clock
    /// keeps wall time, a buffer's completion moves playback on, and no
    /// real-time engine (no device) ever starts.
    func testManualRenderingAdvancesWithoutADevice() async throws {
        let rig = PlaybackTestRig(clipDuration: 1, mutedOutputMode: .manualRendering)
        rig.loadDefault()
        rig.controller.play()
        _ = await rig.waitUntil { rig.statuses.contains(.playing) || rig.statuses.contains(.error) }
        XCTAssertFalse(rig.statuses.contains(.error), "rendering offline needs no device, so it always starts")
        XCTAssertTrue(rig.statuses.contains(.playing))

        let rendering = await rig.waitUntil { (rig.controller.renderedSeconds ?? 0) > 0 }
        XCTAssertTrue(rendering, "the pump renders")
        let clock = ContinuousClock()
        let wallStart = clock.now
        let renderStart = try XCTUnwrap(rig.controller.renderedSeconds)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let renderEnd = try XCTUnwrap(rig.controller.renderedSeconds)
        let wall = Self.seconds(wallStart.duration(to: clock.now))
        XCTAssertEqual((renderEnd - renderStart) / wall, 1, accuracy: 0.1,
                       "rendered \(renderEnd - renderStart) s in \(wall) s of wall time")

        let advanced = await rig.waitUntil(3) { rig.controller.currentSentence >= 1 }
        XCTAssertTrue(advanced, "the first 1 s clip's completion fired")
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.realtimeEngineStarts, 0)
        XCTAssertEqual(rig.audioSession.bindings, 0, "no device to bind")
        XCTAssertEqual(rig.controller.mixerOutputVolume, 0, "the mixer mute holds as well")
    }

    /// The mixer's output is exactly zero for over a second while a loud tone
    /// reaches its input: the silence is the mute's. The tone plays only
    /// offline, where there is no device to hear it if the mute ever broke;
    /// the mixer is the same node in both modes, and on the device the rig
    /// plays silent clips behind the same mute and tripwire.
    func testMutedMixerOutputIsDigitalSilence() async throws {
        let tone = ToneEngine(voices: [PlaybackTestRig.voiceA])
        let rig = PlaybackTestRig(clipDuration: 2, mutedOutputMode: .manualRendering,
                                  extraRoutes: [PlaybackTestRig.voiceA.id: tone])
        guard rig.controller.rendersOffline else {
            return XCTFail("never a tone through a device")
        }
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        let premix = PeakMeter()
        let mixer = PeakMeter()
        XCTAssertTrue(rig.controller.installPeakTaps(premix: { premix.record($0, $1) },
                                                     mixerOutput: { mixer.record($0, $1) }))
        let measured = await rig.waitUntil(5) { premix.seconds >= 1.2 && mixer.seconds >= 1.2 }
        rig.controller.removePeakTaps()
        rig.controller.pause(rampsOut: false)

        XCTAssertTrue(measured, "over a second through both taps")
        XCTAssertGreaterThan(premix.peak, 0.25, "the tone reaches the mixer")
        XCTAssertEqual(mixer.peak, 0.0, "the mixer's output is digital silence")
        XCTAssertEqual(rig.controller.realtimeEngineStarts, 0, "no device ever started")
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// A 440 Hz tone at half scale for every sentence, two seconds long.
private final class ToneEngine: TtsEngine, @unchecked Sendable {
    let voices: [TtsVoice]

    init(voices: [TtsVoice]) {
        self.voices = voices
    }

    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        let rate = 22_050.0
        let samples = (0..<Int(rate * 2)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        return SynthesizedAudio(samples: samples, sampleRate: rate)
    }
}

/// The loudest sample and the seconds seen, from the render thread.
private final class PeakMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var loudest: Float = 0
    private var seen: TimeInterval = 0

    func record(_ peak: Float, _ seconds: TimeInterval) {
        lock.withLock {
            loudest = max(loudest, peak)
            seen += seconds
        }
    }

    var peak: Float { lock.withLock { loudest } }
    var seconds: TimeInterval { lock.withLock { seen } }
}
