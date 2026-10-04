import XCTest
@testable import Aloud

/// The curated roster is a contract: exactly eleven voices, in this order
/// (Michael, Aloud's three blends of him, then the stock seven), with the
/// sids the model card assigns — and Michael as the default.
final class KokoroVoiceCatalogTests: XCTestCase {

    func testCuratedRosterOrderAndSids() {
        let expected: [(id: String, name: String, sid: Int?)] = [
            ("kokoro:am_michael", "Michael", 16),
            ("kokoro:aloud_velvet", "Velvet", nil),
            ("kokoro:aloud_anchor", "Anchor", nil),
            ("kokoro:aloud_ember", "Ember", nil),
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
                           "\(entry.id) should map to sid \(String(describing: entry.sid))")
        }
    }

    /// A blend speaks from its slot in the derived voices file while the
    /// engine holds it, and as Michael otherwise; a stock voice is itself
    /// either way.
    func testBlendsSpeakFromTheirSlotOrAsMichael() {
        let slots = ["kokoro:aloud_velvet": 28, "kokoro:aloud_anchor": 29, "kokoro:aloud_ember": 30]
        for (id, slot) in slots {
            XCTAssertEqual(KokoroVoiceCatalog.speakerID(for: id, blendsLoaded: true), slot, id)
            XCTAssertEqual(KokoroVoiceCatalog.speakerID(for: id, blendsLoaded: false), 16, id)
        }
        XCTAssertEqual(KokoroVoiceCatalog.speakerID(for: "kokoro:af_heart", blendsLoaded: true), 3)
        XCTAssertEqual(KokoroVoiceCatalog.speakerID(for: "kokoro:af_heart", blendsLoaded: false), 3)
        XCTAssertNil(KokoroVoiceCatalog.speakerID(for: "kokoro:aloud_unknown", blendsLoaded: true))
        XCTAssertNil(KokoroVoiceCatalog.speakerID(for: "system", blendsLoaded: true))
    }

    /// Blends are US English men's voices, like the speakers they mix (the
    /// stock helper would read their letters as a language and gender).
    func testBlendRowsAreUSMale() {
        for blend in KokoroVoiceBlends.all {
            let voice = KokoroVoiceCatalog.curatedVoices.first { $0.id == blend.voiceID }
            XCTAssertEqual(voice?.lang, "en-US", blend.speaker)
            XCTAssertEqual(voice?.gender, "male", blend.speaker)
            XCTAssertEqual(voice?.engine, .kokoro, blend.speaker)
            XCTAssertEqual(voice?.subtitle, blend.subtitle, blend.speaker)
        }
    }

    /// The player chip keeps a voice's first word: every name is one word.
    func testEveryNameFitsTheChip() {
        for voice in KokoroVoiceCatalog.curatedVoices {
            XCTAssertFalse(voice.name.contains(" "), "\(voice.name) would be cut on the chip")
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
        XCTAssertEqual(ids.count, 11)
        XCTAssertFalse(ids.contains("kokoro:am_adam"))
        XCTAssertFalse(ids.contains("kokoro:bm_george"))
        // The internal 0–52 table still resolves retired speakers.
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:am_adam"), 11)
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:bm_george"), 26)
        XCTAssertEqual(KokoroVoiceCatalog.sid(for: "kokoro:zm_yunyang"), 52)
        XCTAssertNil(KokoroVoiceCatalog.sid(for: "not-a-kokoro-id"))
    }
}
