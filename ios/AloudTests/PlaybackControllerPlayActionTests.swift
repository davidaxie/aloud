import XCTest
@testable import Aloud

/// Pins the `userPlayAction` hint the reader uses to center the playhead:
/// it bumps only on a USER-initiated start from a non-active state — never
/// on internal status flips (buffering blips), repeated plays while active,
/// or interruption auto-resume (`play(userInitiated: false)`).
@MainActor
final class PlaybackControllerPlayActionTests: XCTestCase {

    /// Instant silence for every request — playback wiring without real TTS.
    private final class StubEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            .silence(duration: 0.05)
        }
    }

    private func makeController() -> PlaybackController {
        let engine = StubEngine()
        let cache = AudioClipCache()
        let voice = TtsVoice(id: "stub", name: "Stub", lang: "en-US",
                             gender: "f", engine: .avSpeech, quality: 1)
        return PlaybackController(engine: engine,
                                  defaultVoice: voice,
                                  scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                  cache: cache,
                                  audioSession: PlatformAudioOutput.makeMonitor(),
                                  anchorStore: ResumeAnchorStore(defaults: PlaybackTestRig.freshDefaults()),
                                  stopStore: PlaybackStopStore(defaults: PlaybackTestRig.freshDefaults()),
                                  outputMuted: true)
    }

    private func makeContent(sentences: [String]) -> DocContent {
        DocContent(title: "Test",
                   pageCount: 1,
                   sentences: sentences.enumerated().map {
                       Sentence(id: $0.offset, text: $0.element, para: 0, page: 0)
                   },
                   paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<sentences.count, page: 0)],
                   contentHash: "test-hash")
    }

    private func makeDocument() -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Test", fileName: "test.txt",
                        addedAt: Date(), pageCount: 1, sentenceCount: 3,
                        contentHash: "test-hash", kind: .text)
    }

    private func loadedController() -> PlaybackController {
        let controller = makeController()
        controller.load(document: makeDocument(),
                        content: makeContent(sentences: ["One.", "Two.", "Three."]))
        return controller
    }

    func testUserPlayFromPausedBumpsOnce() {
        let controller = loadedController()
        XCTAssertEqual(controller.userPlayAction, 0)
        XCTAssertEqual(controller.status, .paused)

        controller.play()
        XCTAssertEqual(controller.userPlayAction, 1)

        // Already active (buffering/playing): pressing play again is not a
        // fresh start and must not re-center the reader.
        controller.play()
        XCTAssertEqual(controller.userPlayAction, 1)
    }

    func testProgrammaticResumeDoesNotBump() {
        let controller = loadedController()
        controller.play(userInitiated: false)   // interruption auto-resume path
        XCTAssertEqual(controller.userPlayAction, 0)
    }

    func testInternalStatusFlipsDoNotBump() {
        let controller = loadedController()
        controller.play()
        XCTAssertEqual(controller.userPlayAction, 1)

        // A seek while active restarts the schedule (playing → buffering →
        // playing) — a mid-listen blip, not a user play-start.
        controller.seek(to: 1, andPlay: false)
        XCTAssertEqual(controller.userPlayAction, 1)
    }

    func testSeekAndPlayFromNonActiveBumps() {
        let controller = loadedController()
        // e.g. restart after .ended, or an explicit "play from here".
        controller.seek(to: 2, andPlay: true)
        XCTAssertEqual(controller.userPlayAction, 1)
    }

    func testSeekWhilePausedDoesNotBump() {
        let controller = loadedController()
        controller.seek(to: 1, andPlay: false)
        XCTAssertEqual(controller.userPlayAction, 0)
        XCTAssertEqual(controller.status, .paused)
    }
}
