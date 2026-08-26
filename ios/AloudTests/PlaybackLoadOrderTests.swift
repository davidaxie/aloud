import XCTest
@testable import Aloud

/// `load()` ordering: the per-book preference hook (`onDocumentLoaded`, where
/// AppModel applies the incoming book's rate and voice) must run BEFORE the
/// controller cues prefetch — otherwise the new book's first sentences are
/// synthesized under the OUTGOING voice and immediately purged, paying a cold
/// neural warm-up for clips nobody hears and delaying the first real clip.
@MainActor
final class PlaybackLoadOrderTests: XCTestCase {

    /// Instant silence, recording the voice every request was made with.
    private final class RecordingEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        private let lock = NSLock()
        private var requested: [String] = []

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            // Scoped, so the lock is never held across a suspension point
            // (`NSLock.lock()` is unavailable from async contexts under Swift 6).
            lock.withLock { requested.append(voice.id) }
            return .silence(duration: 0.05)
        }

        var requestedVoiceIDs: [String] {
            lock.withLock { requested }
        }
    }

    private func voice(_ id: String) -> TtsVoice {
        TtsVoice(id: id, name: id, lang: "en-US", gender: "f", engine: .avSpeech, quality: 1)
    }

    private func makeDocument() -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "Test", fileName: "test.txt",
                        addedAt: Date(), pageCount: 1, sentenceCount: 4,
                        contentHash: "test-hash", kind: .text)
    }

    private func makeContent() -> DocContent {
        DocContent(title: "Test",
                   pageCount: 1,
                   sentences: (0..<4).map {
                       Sentence(id: $0, text: "Sentence \($0).", para: 0, page: 0)
                   },
                   paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<4, page: 0)],
                   contentHash: "test-hash")
    }

    func testPerBookVoiceAppliesBeforeAnythingIsSynthesized() async {
        let outgoing = voice("outgoing")
        let perBook = voice("per-book")
        let engine = RecordingEngine()
        let cache = AudioClipCache()
        let anchorSuite = "aloud.tests.loadOrder"
        let defaults = UserDefaults(suiteName: anchorSuite)!
        defaults.removePersistentDomain(forName: anchorSuite)

        let controller = PlaybackController(
            engine: engine,
            defaultVoice: outgoing,
            scheduler: SynthesisScheduler(engine: engine, cache: cache),
            cache: cache,
            audioSession: AudioSessionManager(),
            anchorStore: ResumeAnchorStore(defaults: defaults))

        // Exactly what AppModel does from this hook for a book with its own voice.
        controller.onDocumentLoaded = { [weak controller] _ in
            controller?.voice = perBook
        }
        controller.load(document: makeDocument(), content: makeContent())

        // Let the prefetch lane drain.
        let deadline = Date().addingTimeInterval(3)
        while engine.requestedVoiceIDs.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(engine.requestedVoiceIDs.isEmpty, "the cued sentences were synthesized")
        XCTAssertFalse(engine.requestedVoiceIDs.contains(outgoing.id),
                       "no sentence of the incoming book is synthesized under the outgoing voice")
        XCTAssertEqual(controller.voice.id, perBook.id)
    }
}
