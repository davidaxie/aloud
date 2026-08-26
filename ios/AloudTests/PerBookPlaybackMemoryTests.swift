import Combine
import XCTest
@testable import Aloud

/// Per-book playback memory: the optional `preferredRate` / `preferredVoiceID`
/// fields decode forward-compatibly from old library indexes, roundtrip when
/// set, and resolve with the documented fallback matrix — a stored per-book
/// voice engages only while still curated, anything else falls back to the
/// GLOBAL preference without persisting the fallback.
@MainActor
final class PerBookPlaybackMemoryTests: XCTestCase {

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

    // MARK: - Rate resolution

    private func document(preferredRate: Double? = nil,
                          wordCount: Int = 16_500,
                          progressFraction: Double = 0) -> LibraryDocument {
        LibraryDocument(id: UUID(),
                        title: "Walden",
                        fileName: "walden.txt",
                        addedAt: Date(),
                        pageCount: 1,
                        sentenceCount: 4021,
                        progressFraction: progressFraction,
                        contentHash: "abc123",
                        kind: .text,
                        wordCount: wordCount,
                        preferredRate: preferredRate)
    }

    func testEffectiveRatePrefersThePinThenTheGlobalDefault() {
        XCTAssertEqual(document(preferredRate: 1.5).effectiveRate(globalDefault: 2.0), 1.5,
                       "a pinned per-book rate wins")
        XCTAssertEqual(document().effectiveRate(globalDefault: 2.0), 2.0,
                       "an unpinned book follows the current global default")
    }

    /// The shelf's time-left estimate must run at the book's OWN rate: a book
    /// pinned to 2× reads half the time of the same book at the 1× global,
    /// and an unpinned book is unaffected by whatever the last-loaded book
    /// was playing at.
    func testEstimateUsesPerBookRateNotTheLoadedBookRate() throws {
        let pinned = document(preferredRate: 2.0)      // 16 500 words @ 165 wpm
        let unpinned = document()

        let pinnedSeconds = try XCTUnwrap(
            pinned.estimatedSecondsRemaining(rate: pinned.effectiveRate(globalDefault: 1.0)))
        let unpinnedSeconds = try XCTUnwrap(
            unpinned.estimatedSecondsRemaining(rate: unpinned.effectiveRate(globalDefault: 1.0)))

        XCTAssertEqual(unpinnedSeconds, 6000, accuracy: 0.5, "100 minutes at 1×")
        XCTAssertEqual(pinnedSeconds, 3000, accuracy: 0.5,
                       "the hero's own 2× halves its estimate, whatever is loaded")
    }

    // MARK: - Pin target

    /// Where a deliberate pick is written. Deleting the loaded book leaves it
    /// loaded in the controller, and a write against a vanished id would be
    /// dropped by the store — so the pick falls through to the global default.
    func testPinTargetSkipsAMissingOrDeletedDocument() {
        let loaded = document()
        let other = document()

        XCTAssertEqual(AppModel.pinTarget(scope: .book,
                                          loadedDocumentID: loaded.id,
                                          in: [other, loaded]),
                       loaded.id,
                       "a loaded book still in the library takes the pin")
        XCTAssertNil(AppModel.pinTarget(scope: .book,
                                        loadedDocumentID: loaded.id, in: [other]),
                     "a deleted book's id must not swallow the pick — it goes global")
        XCTAssertNil(AppModel.pinTarget(scope: .book, loadedDocumentID: loaded.id, in: []),
                     "an emptied library pins nothing")
        XCTAssertNil(AppModel.pinTarget(scope: .book, loadedDocumentID: nil, in: [loaded]),
                     "no document loaded means the global default, as before")
    }

    /// The Settings screen edits the DEFAULTS, and a book stays loaded in the
    /// controller long after the reader is gone (nothing calls `unload`). So a
    /// `.global` pick must never pin — otherwise the first book a user opens
    /// captures every later change to the default voice and speed, and the
    /// globals become unwritable for the life of the install.
    func testGlobalScopePickNeverPinsHoweverLongABookHasBeenLoaded() {
        let loaded = document()

        XCTAssertNil(AppModel.pinTarget(scope: .global,
                                        loadedDocumentID: loaded.id,
                                        in: [loaded]),
                     "a Settings pick writes the global default, not the last book read")
        XCTAssertNil(AppModel.pinTarget(scope: .global, loadedDocumentID: nil, in: [loaded]))

        // The same inputs, differing only in intent, do pin from the reader —
        // so the scope is genuinely what decides, not the loaded document.
        XCTAssertEqual(AppModel.pinTarget(scope: .book,
                                          loadedDocumentID: loaded.id,
                                          in: [loaded]),
                       loaded.id)
    }

    // MARK: - Voice resolution matrix

    private let neuralDefault = KokoroVoiceCatalog.defaultVoice
    private let systemDefault = TtsVoice(id: AVSpeechEngine.systemVoiceID,
                                         name: "System voice",
                                         lang: "en-US",
                                         gender: "",
                                         engine: .avSpeech,
                                         quality: 1)
    private var curated: [TtsVoice] { KokoroVoiceCatalog.curatedVoices + [systemDefault] }

    private func resolve(doc: String?, global: String?, installed: Bool = true) -> TtsVoice {
        AppModel.resolvePlaybackVoice(documentVoiceID: doc,
                                      globalStoredID: global,
                                      curated: curated,
                                      neuralDefault: neuralDefault,
                                      systemDefault: systemDefault,
                                      modelInstalled: installed)
    }

    func testStoredCuratedVoiceApplies() {
        XCTAssertEqual(resolve(doc: "kokoro:af_heart", global: nil).id, "kokoro:af_heart")
        // Still resolves without the model — the caller applies the system
        // stand-in without touching the stored per-book pref.
        XCTAssertEqual(resolve(doc: "kokoro:af_heart", global: nil, installed: false).id,
                       "kokoro:af_heart")
        XCTAssertEqual(resolve(doc: "system", global: "kokoro:af_heart").id, "system",
                       "an explicit per-book system choice stays put")
    }

    func testRetiredStoredVoiceFallsBackToGlobalPreference() {
        // kokoro:am_adam is not on the curated roster (retired speaker).
        XCTAssertEqual(resolve(doc: "kokoro:am_adam", global: "kokoro:af_heart").id,
                       "kokoro:af_heart",
                       "a retired per-book voice falls back to the global pick")
        XCTAssertEqual(resolve(doc: "kokoro:am_adam", global: nil, installed: true).id,
                       KokoroVoiceCatalog.defaultVoiceID)
        XCTAssertEqual(resolve(doc: "kokoro:am_adam", global: nil, installed: false).id,
                       "system")
    }

    func testNothingStoredFollowsGlobalResolution() {
        XCTAssertEqual(resolve(doc: nil, global: "kokoro:af_heart").id, "kokoro:af_heart")
        XCTAssertEqual(resolve(doc: nil, global: nil, installed: true).id,
                       KokoroVoiceCatalog.defaultVoiceID)
        XCTAssertEqual(resolve(doc: nil, global: nil, installed: false).id, "system")
    }

    func testLegacyConcreteIdentifierFallsBackToGlobal() {
        XCTAssertEqual(resolve(doc: "com.apple.voice.premium.en-US.Ava",
                               global: nil, installed: false).id,
                       "system")
    }

    // MARK: - Non-persisting fallback seam

    private func makeController() -> PlaybackController {
        let engine = AVSpeechEngine()
        let cache = AudioClipCache()
        return PlaybackController(
            engine: engine,
            defaultVoice: engine.defaultVoice,
            scheduler: SynthesisScheduler(engine: engine, cache: cache),
            cache: cache,
            audioSession: AudioSessionManager())
    }

    /// Rate persistence is opt-in exactly like voice: an apply (or any step of
    /// a live slider drag) sets `rate` directly and never reaches
    /// `rateSelections`, while a deliberate pick ALWAYS emits — including a
    /// pick whose value equals the rate the book just inherited, which is the
    /// only way to pin that book against a later global change.
    func testRatePersistsOnlyFromDeliberatePicksIncludingSameValueOnes() {
        let playback = makeController()

        var emitted: [Double] = []
        let subscription = playback.rateSelections.sink { emitted.append($0) }
        defer { subscription.cancel() }

        playback.rate = 1.5                 // the apply-on-load / drag path
        XCTAssertEqual(emitted, [], "an applied rate must never persist itself")

        playback.selectRate(1.5)            // re-picking the inherited value
        XCTAssertEqual(emitted, [1.5],
                       "a same-value pick is a deliberate pin, not a no-op")

        playback.selectRate(2.0)
        XCTAssertEqual(emitted, [1.5, 2.0])

        playback.selectRate(9.0)            // clamped to the 0.5…3.0 range
        XCTAssertEqual(emitted, [1.5, 2.0, 3.0],
                       "the emitted value is the clamped one that is playing")
    }

    /// Applying a per-book (or fallback) voice sets `voice` directly and never
    /// reaches `voiceSelections` — the only seam AppModel persists from — so a
    /// retired voice's fallback is never written into any record.
    func testAppliedFallbackVoiceDoesNotEmitForPersistence() {
        let engine = AVSpeechEngine()
        let playback = makeController()

        var emitted: [String] = []
        let subscription = playback.voiceSelections.sink { emitted.append($0.id) }
        defer { subscription.cancel() }

        playback.voice = KokoroVoiceCatalog.defaultVoice   // the apply/fallback path
        XCTAssertEqual(emitted, [], "an applied voice must never persist itself")

        playback.selectVoice(engine.defaultVoice)          // a deliberate pick does
        XCTAssertEqual(emitted, ["system"])
    }
}
