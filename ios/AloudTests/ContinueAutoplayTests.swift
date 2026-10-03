import Combine
import XCTest
@testable import Aloud

/// The Continue Listening card's autoplay contract, as the reader calls it:
/// arriving at a book that is NOT speaking starts it; arriving at the book
/// that never stopped speaking continues it — the sentence in flight is never
/// cut off and restarted.
@MainActor
final class ContinueAutoplayTests: XCTestCase {

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

    private func makeContent(hash: String = "test-hash") -> DocContent {
        let sentences = ["One.", "Two.", "Three.", "Four."]
        return DocContent(title: "Test",
                          pageCount: 1,
                          sentences: sentences.enumerated().map {
                              Sentence(id: $0.offset, text: $0.element, para: 0, page: 0)
                          },
                          paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<sentences.count, page: 0)],
                          contentHash: hash)
    }

    private func makeDocument(hash: String = "test-hash") -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Test", fileName: "test.txt",
                        addedAt: Date(), pageCount: 1, sentenceCount: 4,
                        contentHash: hash, kind: .text)
    }

    private func loadedController() -> PlaybackController {
        let controller = makeController()
        controller.load(document: makeDocument(), content: makeContent())
        return controller
    }

    // MARK: - Starting

    func testAutoplayStartsACuedBook() {
        let controller = loadedController()
        XCTAssertEqual(controller.status, .paused)

        controller.startAutoplay()
        XCTAssertTrue(controller.isActive, "The card promises playback on arrival")
        XCTAssertEqual(controller.userPlayAction, 1,
                       "Autoplay goes through the user-play path so the reader centers")
    }

    func testAutoplayStartsTheNewBookAfterSwitchingDocuments() {
        let controller = loadedController()
        controller.play()
        XCTAssertTrue(controller.isActive)

        // Opening a different book from the shelf: load cues it paused, and
        // the hero's autoplay must start THIS book.
        controller.load(document: makeDocument(hash: "other-hash"),
                        content: makeContent(hash: "other-hash"))
        XCTAssertEqual(controller.status, .paused)

        controller.startAutoplay()
        XCTAssertTrue(controller.isActive)
    }

    // MARK: - Continuing

    func testAutoplayOnTheBookAlreadyPlayingDoesNotRestartTheSentence() {
        let controller = loadedController()
        controller.seek(to: 2, andPlay: true)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.currentSentence, 2)
        let playActions = controller.userPlayAction

        // A restart is visible as a fresh .buffering transition (the schedule
        // is invalidated and the sentence re-synthesized from its start).
        var transitions = 0
        let subscription = controller.$status.dropFirst().sink { _ in transitions += 1 }
        defer { subscription.cancel() }

        controller.startAutoplay()

        XCTAssertEqual(transitions, 0,
                       "Re-entering the reader mid-sentence must not restart playback")
        XCTAssertEqual(controller.currentSentence, 2)
        XCTAssertEqual(controller.userPlayAction, playActions)
        XCTAssertTrue(controller.isActive)

        // Pin the reason the guard exists: a plain play() here DOES restart.
        controller.play()
        XCTAssertGreaterThan(transitions, 0)
    }

    func testAutoplayWhileBufferingIsAlsoLeftAlone() {
        let controller = loadedController()
        controller.play()
        XCTAssertEqual(controller.status, .buffering,
                       "Synthesis of the first clip is in flight")

        var transitions = 0
        let subscription = controller.$status.dropFirst().sink { _ in transitions += 1 }
        defer { subscription.cancel() }

        controller.startAutoplay()
        XCTAssertEqual(transitions, 0, "Buffering is playback intended — leave it running")
    }
}
