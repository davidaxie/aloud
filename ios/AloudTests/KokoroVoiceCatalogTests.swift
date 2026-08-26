import XCTest
@testable import Aloud

/// The curated roster is a contract: exactly eight voices, in this order,
/// with the sids the model card assigns — and Michael as the default.
final class KokoroVoiceCatalogTests: XCTestCase {

    func testCuratedRosterOrderAndSids() {
        let expected: [(id: String, name: String, sid: Int)] = [
            ("kokoro:am_michael", "Michael", 16),
            ("kokoro:am_fenrir", "Fenrir", 14),
            ("kokoro:am_puck", "Puck", 18),
            ("kokoro:af_heart", "Heart", 3),
            ("kokoro:af_bella", "Bella", 2),
            ("kokoro:af_nicole", "Nicole", 6),
            ("kokoro:af_sarah", "Sarah", 9),
            ("kokoro:bf_emma", "Emma", 21),
        ]
        let voices = KokoroVoiceCatalog.curatedVoices
        XCTAssertEqual(voices.map(\.id), expected.map(\.id))
        XCTAssertEqual(voices.map(\.name), expected.map(\.name))
        for entry in expected {
            XCTAssertEqual(KokoroVoiceCatalog.sid(for: entry.id), entry.sid,
                           "\(entry.id) should map to sid \(entry.sid)")
        }
    }

    func testDefaultVoiceIsMichael() {
        XCTAssertEqual(KokoroVoiceCatalog.defaultVoiceID, "kokoro:am_michael")
        XCTAssertEqual(KokoroVoiceCatalog.defaultVoice.name, "Michael")
        XCTAssertEqual(KokoroVoiceCatalog.defaultVoice.gender, "male")
        XCTAssertEqual(KokoroVoiceCatalog.defaultVoice.lang, "en-US")
    }

    func testEveryCuratedVoiceHasASubtitle() {
        for voice in KokoroVoiceCatalog.curatedVoices {
            XCTAssertFalse(voice.subtitle.isEmpty,
                           "\(voice.id) needs a picker subtitle")
        }
    }

    func testRetiredVoicesNoLongerListedButSidTableIntact() {
        let ids = Set(KokoroVoiceCatalog.curatedVoices.map(\.id))
        XCTAssertEqual(ids.count, 8)
        XCTAssertFalse(ids.contains("kokoro:am_adam"))
        XCTAssertFalse(ids.contains("kokoro:bm_george"))
        // The internal 0–52 table still resolves retired speakers.
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:am_adam"), 11)
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:bm_george"), 26)
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:zm_yunyang"), 52)
        XCTAssertNil(KokoroVoiceCatalog.sid(for: "not-a-kokoro-id"))
    }
}
