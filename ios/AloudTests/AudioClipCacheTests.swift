import XCTest
@testable import Aloud

/// Pins the clip-cache key contract: keys carry DOCUMENT identity (a
/// content-hash prefix) alongside voice, skip setting, and sentence index —
/// sentence indices repeat across books, and a clip synthesized for Book A
/// must never be served for Book B's sentence at the same index.
final class AudioClipCacheTests: XCTestCase {

    private let voice = TtsVoice(id: "kokoro:am_michael", name: "Michael",
                                 lang: "en-US", gender: "m",
                                 engine: .kokoro, quality: 3)
    private let otherVoice = TtsVoice(id: "com.apple.voice.premium.en-US.Ava",
                                      name: "System voice", lang: "en-US",
                                      gender: "f", engine: .avSpeech, quality: 2)

    private let bookA = "aaaa1111bbbb2222cccc3333"   // stand-in contentHash
    private let bookB = "dddd4444eeee5555ffff6666"

    private func clip(_ marker: Float) -> SynthesizedAudio {
        SynthesizedAudio(samples: [marker], sampleRate: 24_000)
    }

    // MARK: - Key identity

    func testKeyDiffersAcrossDocumentsForSameVoiceSkipAndSentence() {
        let keyA = AudioClipCache.key(voice: voice, skipBrackets: true,
                                      contentHash: bookA, sentenceID: 0)
        let keyB = AudioClipCache.key(voice: voice, skipBrackets: true,
                                      contentHash: bookB, sentenceID: 0)
        XCTAssertNotEqual(keyA, keyB,
                          "same sentence index in two documents must never share a cache key")
    }

    func testKeyDiffersAcrossVoiceSkipAndSentence() {
        let base = AudioClipCache.key(voice: voice, skipBrackets: true,
                                      contentHash: bookA, sentenceID: 3)
        XCTAssertNotEqual(base, AudioClipCache.key(voice: otherVoice, skipBrackets: true,
                                                   contentHash: bookA, sentenceID: 3))
        XCTAssertNotEqual(base, AudioClipCache.key(voice: voice, skipBrackets: false,
                                                   contentHash: bookA, sentenceID: 3))
        XCTAssertNotEqual(base, AudioClipCache.key(voice: voice, skipBrackets: true,
                                                   contentHash: bookA, sentenceID: 4))
    }

    func testKeyStartsWithPrefix() {
        let prefix = AudioClipCache.keyPrefix(voice: voice, skipBrackets: true,
                                              contentHash: bookA)
        let key = AudioClipCache.key(voice: voice, skipBrackets: true,
                                     contentHash: bookA, sentenceID: 7)
        XCTAssertTrue(key.hasPrefix(prefix))
        XCTAssertEqual(key, prefix + "7")
    }

    // MARK: - Cross-document behavior (the stale-audio regression)

    func testClipCachedForBookAIsNotServedForBookB() {
        let cache = AudioClipCache()
        let keyA = AudioClipCache.key(voice: voice, skipBrackets: true,
                                      contentHash: bookA, sentenceID: 0)
        let keyB = AudioClipCache.key(voice: voice, skipBrackets: true,
                                      contentHash: bookB, sentenceID: 0)

        cache.store(clip(1), forKey: keyA)

        XCTAssertNil(cache.clip(forKey: keyB),
                     "Book B's sentence 0 must miss — Book A's audio would be spoken otherwise")
        XCTAssertEqual(cache.clip(forKey: keyA)?.samples, [1])
    }

    func testPurgeKeepingPrefixDropsOtherDocuments() {
        let cache = AudioClipCache()
        for index in 0..<3 {
            cache.store(clip(Float(index)),
                        forKey: AudioClipCache.key(voice: voice, skipBrackets: true,
                                                   contentHash: bookA, sentenceID: index))
            cache.store(clip(Float(index) + 100),
                        forKey: AudioClipCache.key(voice: voice, skipBrackets: true,
                                                   contentHash: bookB, sentenceID: index))
        }

        cache.purge(keepingPrefix: AudioClipCache.keyPrefix(voice: voice, skipBrackets: true,
                                                            contentHash: bookB))

        for index in 0..<3 {
            XCTAssertNil(cache.clip(forKey: AudioClipCache.key(
                voice: voice, skipBrackets: true, contentHash: bookA, sentenceID: index)))
            XCTAssertNotNil(cache.clip(forKey: AudioClipCache.key(
                voice: voice, skipBrackets: true, contentHash: bookB, sentenceID: index)))
        }
    }

    func testRemoveAllEmptiesTheCache() {
        let cache = AudioClipCache()
        let key = AudioClipCache.key(voice: voice, skipBrackets: true,
                                     contentHash: bookA, sentenceID: 0)
        cache.store(clip(1), forKey: key)
        cache.removeAll()
        XCTAssertNil(cache.clip(forKey: key))
    }

    // MARK: - LRU

    func testLRUEvictsLeastRecentlyUsed() {
        let cache = AudioClipCache(capacity: 2)
        let k0 = AudioClipCache.key(voice: voice, skipBrackets: true,
                                    contentHash: bookA, sentenceID: 0)
        let k1 = AudioClipCache.key(voice: voice, skipBrackets: true,
                                    contentHash: bookA, sentenceID: 1)
        let k2 = AudioClipCache.key(voice: voice, skipBrackets: true,
                                    contentHash: bookA, sentenceID: 2)

        cache.store(clip(0), forKey: k0)
        cache.store(clip(1), forKey: k1)
        _ = cache.clip(forKey: k0)        // k0 now most recent
        cache.store(clip(2), forKey: k2)  // evicts k1

        XCTAssertNotNil(cache.clip(forKey: k0))
        XCTAssertNil(cache.clip(forKey: k1))
        XCTAssertNotNil(cache.clip(forKey: k2))
    }
}
