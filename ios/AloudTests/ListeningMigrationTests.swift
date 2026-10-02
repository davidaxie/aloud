import XCTest
@testable import Aloud

/// R7 migration: the most recently opened book's own pins become the one
/// app-wide voice and speed, once, so nobody hears their current book change.
/// It never writes a resolved default or the System stand-in (including a
/// "system" pinned before the model was installed, when System was the only
/// row), never touches skipBrackets, and leaves the per-book values on disk
/// for one release.
@MainActor
final class ListeningMigrationTests: XCTestCase {

    private static let suite = "aloud.tests.r7migration"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suite)
        defaults.removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suite)
        defaults = nil
        super.tearDown()
    }

    private typealias Key = AppModel.PrefKey

    private func document(_ title: String,
                          openedHoursAgo: Double?,
                          rate: Double? = nil,
                          voiceID: String? = nil) -> LibraryDocument {
        LibraryDocument(id: UUID(),
                        title: title,
                        fileName: "\(title).txt",
                        addedAt: Date(timeIntervalSinceNow: -30 * 24 * 3600),
                        lastOpenedAt: openedHoursAgo.map { Date(timeIntervalSinceNow: -$0 * 3600) },
                        pageCount: 1,
                        sentenceCount: 10,
                        contentHash: "hash-\(title)",
                        kind: .text,
                        wordCount: 1000,
                        preferredRate: rate,
                        preferredVoiceID: voiceID)
    }

    private func migrate(_ documents: [LibraryDocument], modelInstalled: Bool = true) {
        AppModel.runListeningMigrationIfNeeded(defaults, documents: documents,
                                               modelInstalled: modelInstalled)
    }

    /// What R5's install resolves the stored global to.
    private func voiceAfterInstall() -> TtsVoice {
        let system = TtsVoice(id: AVSpeechEngine.systemVoiceID, name: "System voice", lang: "en-US",
                              gender: "", engine: .avSpeech, quality: 1)
        return AppModel.resolveVoicePreference(storedID: defaults.string(forKey: Key.voiceID),
                                               curated: KokoroVoiceCatalog.curatedVoices + [system],
                                               neuralDefault: KokoroVoiceCatalog.defaultVoice,
                                               systemDefault: system,
                                               modelInstalled: true)
    }

    // MARK: -

    func testMostRecentPinnedBookBecomesGlobal() throws {
        defaults.set(1.0, forKey: Key.rate)
        defaults.set("kokoro:am_michael", forKey: Key.voiceID)
        defaults.set(false, forKey: Key.skipBrackets)

        let a = document("A", openedHoursAgo: 72, rate: 2.0, voiceID: "kokoro:am_fenrir")
        let b = document("B", openedHoursAgo: 24)
        let c = document("C", openedHoursAgo: 1, rate: 1.2, voiceID: "kokoro:af_heart")
        let documents = [a, b, c]

        migrate(documents)

        XCTAssertEqual(defaults.double(forKey: Key.rate), 1.2)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:af_heart")
        XCTAssertEqual(defaults.object(forKey: Key.skipBrackets) as? Bool, false,
                       "the migration never touches skipBrackets")
        XCTAssertTrue(defaults.bool(forKey: Key.migratedV3))

        // The per-book values survive on disk, unapplied, for one release.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([LibraryDocument].self, from: encoder.encode(documents))
        XCTAssertEqual(decoded.first { $0.id == c.id }?.preferredRate, 1.2)
        XCTAssertEqual(decoded.first { $0.id == a.id }?.preferredVoiceID, "kokoro:am_fenrir")
    }

    /// The most recent book was playing at the globals, so they stay; an
    /// older book's pins never win.
    func testUnpinnedMostRecentLeavesGlobalsUntouched() {
        defaults.set(1.25, forKey: Key.rate)
        defaults.set("kokoro:am_puck", forKey: Key.voiceID)

        migrate([
            document("A", openedHoursAgo: 72, rate: 2.0, voiceID: "kokoro:am_fenrir"),
            document("B", openedHoursAgo: 1),
        ])

        XCTAssertEqual(defaults.double(forKey: Key.rate), 1.25)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:am_puck")
        XCTAssertTrue(defaults.bool(forKey: Key.migratedV3))
    }

    func testRetiredOrLegacyVoiceIgnoredRateApplied() {
        for retired in ["kokoro:am_adam", "com.apple.voice.premium.en-US.Ava"] {
            defaults.removePersistentDomain(forName: Self.suite)
            defaults.set(1.0, forKey: Key.rate)
            defaults.set("kokoro:am_michael", forKey: Key.voiceID)

            migrate([document("A", openedHoursAgo: 1, rate: 1.5, voiceID: retired)])

            XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:am_michael",
                           "\(retired) is not curated, so the global voice stays")
            XCTAssertEqual(defaults.double(forKey: Key.rate), 1.5,
                           "the rate pin still applies alongside \(retired)")
        }
    }

    func testOutOfRangeRateClamped() {
        migrate([document("A", openedHoursAgo: 1, rate: 5.0)])

        XCTAssertEqual(defaults.double(forKey: Key.rate), 3.0)
        XCTAssertNil(defaults.object(forKey: Key.voiceID),
                     "no voice pin writes no voice, never a resolved default")
    }

    func testNoOpenedBooksChangesNothing() {
        migrate([document("A", openedHoursAgo: nil, rate: 2.0, voiceID: "kokoro:af_heart")])

        XCTAssertNil(defaults.object(forKey: Key.rate))
        XCTAssertNil(defaults.object(forKey: Key.voiceID))
        XCTAssertNil(defaults.object(forKey: Key.skipBrackets))
        XCTAssertTrue(defaults.bool(forKey: Key.migratedV3))
        XCTAssertEqual(defaults.persistentDomain(forName: Self.suite)?.keys.sorted(),
                       [Key.migratedV3], "only the guard is written")
    }

    func testRunsOnce() {
        migrate([document("A", openedHoursAgo: 1, rate: 1.2, voiceID: "kokoro:af_heart")])
        migrate([document("B", openedHoursAgo: 0.5, rate: 2.5, voiceID: "kokoro:bf_emma")])

        XCTAssertEqual(defaults.double(forKey: Key.rate), 1.2)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:af_heart")
    }

    // MARK: - "system" before the model

    /// The old reader voice sheet listed only System, already checked, and a
    /// tap on it pinned "system" to the book. Without the model that pin is
    /// no choice, so it must not block R5's switch to Michael.
    func testSystemPinWithoutModelWritesNoVoice() {
        migrate([document("A", openedHoursAgo: 1, rate: 1.25, voiceID: AVSpeechEngine.systemVoiceID)],
                modelInstalled: false)

        XCTAssertNil(defaults.object(forKey: Key.voiceID),
                     "a pre-install System pin is the stand-in, never a preference")
        XCTAssertEqual(defaults.double(forKey: Key.rate), 1.25, "the rate pin still applies")
        XCTAssertEqual(voiceAfterInstall().id, KokoroVoiceCatalog.defaultVoiceID,
                       "after the R5 download this user hears Michael")
    }

    /// The old Settings picker had the same single checked System row and
    /// wrote "system" straight to the global key.
    func testStoredGlobalSystemWithoutModelIsCleared() {
        defaults.set(AVSpeechEngine.systemVoiceID, forKey: Key.voiceID)

        migrate([document("A", openedHoursAgo: 1)], modelInstalled: false)

        XCTAssertNil(defaults.object(forKey: Key.voiceID))
        XCTAssertEqual(voiceAfterInstall().id, KokoroVoiceCatalog.defaultVoiceID)
    }

    /// With the model installed, System sat beside the natural voices, so
    /// picking it was a real choice and survives.
    func testSystemChoiceWithModelInstalledIsKept() {
        migrate([document("A", openedHoursAgo: 1, voiceID: AVSpeechEngine.systemVoiceID)],
                modelInstalled: true)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), AVSpeechEngine.systemVoiceID)

        defaults.removePersistentDomain(forName: Self.suite)
        defaults.set(AVSpeechEngine.systemVoiceID, forKey: Key.voiceID)
        migrate([], modelInstalled: true)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), AVSpeechEngine.systemVoiceID)
        XCTAssertEqual(voiceAfterInstall().id, AVSpeechEngine.systemVoiceID)
    }

    /// A natural-voice pin from an earlier install is a real choice even
    /// while the model is gone: it engages once the model is back.
    func testKokoroPinWithoutModelIsKept() {
        migrate([document("A", openedHoursAgo: 1, voiceID: "kokoro:af_heart")], modelInstalled: false)
        XCTAssertEqual(defaults.string(forKey: Key.voiceID), "kokoro:af_heart")
    }
}
