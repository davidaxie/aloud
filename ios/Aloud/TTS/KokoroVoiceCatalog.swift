import Foundation

/// Speaker table for `kokoro-multi-lang-v1_0` (53 speakers, sid 0–52).
/// Source: k2-fsa sherpa-onnx docs, "Map between speaker ID and speaker name"
/// (https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html).
/// Anchors verified: af_heart=3, af_bella=2, af_nicole=6, am_adam=11, am_michael=16.
///
/// Only a curated eight of the English speakers (af_/am_ = US, bf_ = GB)
/// surface as selectable `TtsVoice`s — the best-graded per the model card,
/// led by the deep narrator. The full map stays internal so a future
/// expansion is a table edit, not a redesign.
enum KokoroVoiceCatalog {

    /// Voice IDs are namespaced `kokoro:<speaker>` so they can never collide
    /// with AVSpeech identifiers in preferences or cache keys.
    static let voiceIDPrefix = "kokoro:"

    static let defaultVoiceID = voiceIDPrefix + "am_michael"

    /// The curated eight, in display order. Michael leads as the default.
    static let curatedVoices: [TtsVoice] = [
        voice("am_michael", "Michael", subtitle: "Deep, warm narrator"),
        voice("am_fenrir", "Fenrir", subtitle: "Strong, spirited"),
        voice("am_puck", "Puck", subtitle: "Light, playful"),
        voice("af_heart", "Heart", subtitle: "Bright, expressive"),
        voice("af_bella", "Bella", subtitle: "Warm, smooth"),
        voice("af_nicole", "Nicole", subtitle: "Soft, hushed"),
        voice("af_sarah", "Sarah", subtitle: "Clear, friendly"),
        voice("bf_emma", "Emma", subtitle: "Gentle, mellow"),
    ]

    static var defaultVoice: TtsVoice {
        curatedVoices.first { $0.id == defaultVoiceID } ?? curatedVoices[0]
    }

    /// Speaker id for a `TtsVoice.id`; nil for non-Kokoro or unknown ids.
    static func sid(for voiceID: String) -> Int? {
        guard voiceID.hasPrefix(voiceIDPrefix) else { return nil }
        let name = String(voiceID.dropFirst(voiceIDPrefix.count))
        return sidByName[name]
    }

    // MARK: - Internal table

    private struct Speaker {
        let sid: Int
        let name: String
    }

    /// Full sid → speaker map for kokoro-multi-lang-v1_0 (order is the model's).
    private static let speakers: [Speaker] = [
        Speaker(sid: 0, name: "af_alloy"),
        Speaker(sid: 1, name: "af_aoede"),
        Speaker(sid: 2, name: "af_bella"),
        Speaker(sid: 3, name: "af_heart"),
        Speaker(sid: 4, name: "af_jessica"),
        Speaker(sid: 5, name: "af_kore"),
        Speaker(sid: 6, name: "af_nicole"),
        Speaker(sid: 7, name: "af_nova"),
        Speaker(sid: 8, name: "af_river"),
        Speaker(sid: 9, name: "af_sarah"),
        Speaker(sid: 10, name: "af_sky"),
        Speaker(sid: 11, name: "am_adam"),
        Speaker(sid: 12, name: "am_echo"),
        Speaker(sid: 13, name: "am_eric"),
        Speaker(sid: 14, name: "am_fenrir"),
        Speaker(sid: 15, name: "am_liam"),
        Speaker(sid: 16, name: "am_michael"),
        Speaker(sid: 17, name: "am_onyx"),
        Speaker(sid: 18, name: "am_puck"),
        Speaker(sid: 19, name: "am_santa"),
        Speaker(sid: 20, name: "bf_alice"),
        Speaker(sid: 21, name: "bf_emma"),
        Speaker(sid: 22, name: "bf_isabella"),
        Speaker(sid: 23, name: "bf_lily"),
        Speaker(sid: 24, name: "bm_daniel"),
        Speaker(sid: 25, name: "bm_fable"),
        Speaker(sid: 26, name: "bm_george"),
        Speaker(sid: 27, name: "bm_lewis"),
        Speaker(sid: 28, name: "ef_dora"),
        Speaker(sid: 29, name: "em_alex"),
        Speaker(sid: 30, name: "ff_siwis"),
        Speaker(sid: 31, name: "hf_alpha"),
        Speaker(sid: 32, name: "hf_beta"),
        Speaker(sid: 33, name: "hm_omega"),
        Speaker(sid: 34, name: "hm_psi"),
        Speaker(sid: 35, name: "if_sara"),
        Speaker(sid: 36, name: "im_nicola"),
        Speaker(sid: 37, name: "jf_alpha"),
        Speaker(sid: 38, name: "jf_gongitsune"),
        Speaker(sid: 39, name: "jf_nezumi"),
        Speaker(sid: 40, name: "jf_tebukuro"),
        Speaker(sid: 41, name: "jm_kumo"),
        Speaker(sid: 42, name: "pf_dora"),
        Speaker(sid: 43, name: "pm_alex"),
        Speaker(sid: 44, name: "pm_santa"),
        Speaker(sid: 45, name: "zf_xiaobei"),
        Speaker(sid: 46, name: "zf_xiaoni"),
        Speaker(sid: 47, name: "zf_xiaoxiao"),
        Speaker(sid: 48, name: "zf_xiaoyi"),
        Speaker(sid: 49, name: "zm_yunjian"),
        Speaker(sid: 50, name: "zm_yunxi"),
        Speaker(sid: 51, name: "zm_yunxia"),
        Speaker(sid: 52, name: "zm_yunyang"),
    ]

    private static let sidByName: [String: Int] =
        Dictionary(uniqueKeysWithValues: speakers.map { ($0.name, $0.sid) })

    private static func voice(_ speaker: String, _ name: String,
                              subtitle: String) -> TtsVoice {
        TtsVoice(id: voiceIDPrefix + speaker,
                 name: name,
                 lang: speaker.hasPrefix("b") ? "en-GB" : "en-US",
                 gender: speaker.dropFirst().hasPrefix("f") ? "female" : "male",
                 engine: .kokoro,
                 quality: 4,
                 subtitle: subtitle)
    }
}
