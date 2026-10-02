import Combine
import XCTest
@testable import Aloud

/// R7 retired per-book voice and speed. The `preferredRate` /
/// `preferredVoiceID` fields still decode from old library indexes and
/// roundtrip unchanged — the values survive on disk for one release — but
/// nothing applies them. Persistence is opt-in: only deliberate picks reach
/// `rateSelections` / `voiceSelections`, the seams AppModel writes from.
@MainActor
final class LegacyPerBookFieldsTests: XCTestCase {

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Forward-compatible decoding

    /// A pre-feature index record (exactly what an old library.json holds).
    private let oldBlob = """
    {
        "id": "6F2A5D14-9C1B-4E8A-8D33-0A1B2C3D4E5F",
        "title": "Walden",
        "fileName": "walden.txt",
        "addedAt": "2025-11-02T09:00:00Z",
        "pageCount": 1,
        "sentenceCount": 4021,
        "progressSentence": 120,
        "progressFraction": 0.03,
        "contentHash": "abc123",
        "kind": "text",
        "wordCount": 114000
    }
    """

    func testOldIndexBlobDecodesWithNilPreferences() throws {
        let document = try Self.decoder.decode(LibraryDocument.self,
                                               from: Data(oldBlob.utf8))
        XCTAssertNil(document.preferredRate)
        XCTAssertNil(document.preferredVoiceID)
        XCTAssertEqual(document.title, "Walden")
        XCTAssertEqual(document.progressSentence, 120)
    }

    /// The values survive on disk for one release.
    func testPreferencesRoundtrip() throws {
        var document = try Self.decoder.decode(LibraryDocument.self,
                                               from: Data(oldBlob.utf8))
        document.preferredRate = 1.7
        document.preferredVoiceID = "kokoro:af_heart"

        let data = try Self.encoder.encode(document)
        let decoded = try Self.decoder.decode(LibraryDocument.self, from: data)
        XCTAssertEqual(decoded.preferredRate, 1.7)
        XCTAssertEqual(decoded.preferredVoiceID, "kokoro:af_heart")
        XCTAssertEqual(decoded.id, document.id)
    }

    func testNilPreferencesEncodeAsAbsentKeys() throws {
        let document = try Self.decoder.decode(LibraryDocument.self,
                                               from: Data(oldBlob.utf8))
        let json = String(decoding: try Self.encoder.encode(document), as: UTF8.self)
        XCTAssertFalse(json.contains("preferredRate"),
                       "nil prefs must not add keys — old records stay byte-stable")
        XCTAssertFalse(json.contains("preferredVoiceID"))
    }

    // MARK: - Deliberate-pick seams (silent rig)

    /// Instant silence for every request — playback wiring without real TTS.
    private final class StubEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            .silence(duration: 0.05)
        }
    }

    private static let voiceA = TtsVoice(id: "test:a", name: "Alpha", lang: "en-US",
                                         gender: "f", engine: .avSpeech, quality: 1)
    private static let voiceB = TtsVoice(id: "test:b", name: "Bravo", lang: "en-US",
                                         gender: "m", engine: .avSpeech, quality: 1)

    /// Muted and on a stub engine: nothing here can reach a speaker.
    private func makeController() -> PlaybackController {
        let engine = StubEngine()
        let cache = AudioClipCache()
        let suite = "aloud.tests.legacyPerBook"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PlaybackController(engine: engine,
                                  defaultVoice: Self.voiceA,
                                  scheduler: SynthesisScheduler(engine: engine, cache: cache),
                                  cache: cache,
                                  audioSession: AudioSessionManager(),
                                  anchorStore: ResumeAnchorStore(defaults: defaults),
                                  // The suite, never the host app's stop slot: init
                                  // takes (and removes) any live-session marker it finds.
                                  stopStore: PlaybackStopStore(defaults: defaults),
                                  outputMuted: true)
    }

    private func loadDocument(into playback: PlaybackController) {
        let sentences = ["One.", "Two.", "Three.", "Four."]
        let content = DocContent(title: "Test",
                                 pageCount: 1,
                                 sentences: sentences.enumerated().map {
                                     Sentence(id: $0.offset, text: $0.element, para: 0, page: 0)
                                 },
                                 paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<sentences.count, page: 0)],
                                 contentHash: "legacy-hash")
        let document = LibraryDocument(id: UUID(), title: "Test", fileName: "test.txt",
                                       addedAt: Date(), pageCount: 1, sentenceCount: sentences.count,
                                       contentHash: "legacy-hash", kind: .text)
        playback.load(document: document, content: content)
    }

    /// A programmatic rate (launch restore, each step of a live slider drag)
    /// never reaches `rateSelections`; a deliberate pick always emits, even
    /// one that re-picks the value already playing.
    func testRateSelectionsEmitOnlyFromDeliberatePicks() {
        let playback = makeController()

        var emitted: [Double] = []
        let subscription = playback.rateSelections.sink { emitted.append($0) }
        defer { subscription.cancel() }

        playback.rate = 1.5                 // the restore / drag path
        XCTAssertEqual(emitted, [], "a programmatic rate must never persist itself")

        playback.selectRate(1.5)            // re-picking the current value
        XCTAssertEqual(emitted, [1.5], "a same-value pick is still a deliberate pick")

        playback.selectRate(2.0)
        XCTAssertEqual(emitted, [1.5, 2.0])

        playback.selectRate(9.0)            // clamped to the 0.5…3.0 range
        XCTAssertEqual(emitted, [1.5, 2.0, 3.0],
                       "the emitted value is the clamped one that is playing")
    }

    /// A stand-in or fallback voice sets `voice` directly and never reaches
    /// `voiceSelections`, so it is never written as the preference. The book
    /// is loaded first, so a pick auditions its sentence (muted) rather than
    /// speaking the no-book sample line.
    func testAppliedFallbackVoiceDoesNotEmitForPersistence() {
        let playback = makeController()
        loadDocument(into: playback)

        var emitted: [String] = []
        let subscription = playback.voiceSelections.sink { emitted.append($0.id) }
        defer { subscription.cancel() }

        playback.voice = Self.voiceB                       // the stand-in / apply path
        XCTAssertEqual(emitted, [], "an applied voice must never persist itself")

        playback.voice = KokoroVoiceCatalog.defaultVoice   // no neural engine: falls back
        XCTAssertEqual(playback.voice, Self.voiceA, "the rig has no neural engine")
        XCTAssertEqual(emitted, [], "a neural fallback must never persist itself")

        playback.selectVoice(Self.voiceB)                  // a deliberate pick does
        XCTAssertEqual(emitted, [Self.voiceB.id])

        playback.selectVoice(Self.voiceB)                  // R5: re-picking writes nothing
        XCTAssertEqual(emitted, [Self.voiceB.id])
    }
}
