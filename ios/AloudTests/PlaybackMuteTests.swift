import AVFoundation
import XCTest
@testable import Aloud

/// The silence guarantee: a test host is muted, a muted controller's main
/// mixer stays at zero even while playing, and the AVSpeech utterance-volume
/// mute doesn't stop synthesis from producing samples.
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
                                            audioSession: AudioSessionManager(),
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
                                            audioSession: AudioSessionManager(),
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
}
