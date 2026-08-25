import Foundation

/// In-memory LRU of synthesized clips, keyed `voice|skip|sentenceID`.
/// Small by design: a dozen sentence clips cover the playback look-ahead.
final class AudioClipCache: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: SynthesizedAudio] = [:]
    private var recency: [String] = []   // last = most recently used
    private let capacity: Int

    init(capacity: Int = 12) {
        self.capacity = capacity
    }

    static func key(voice: TtsVoice, skipBrackets: Bool, sentenceID: Int) -> String {
        keyPrefix(voice: voice, skipBrackets: skipBrackets) + String(sentenceID)
    }

    static func keyPrefix(voice: TtsVoice, skipBrackets: Bool) -> String {
        "\(voice.id)|\(skipBrackets ? "s" : "f")|"
    }

    func clip(forKey key: String) -> SynthesizedAudio? {
        lock.lock(); defer { lock.unlock() }
        guard let clip = storage[key] else { return nil }
        touch(key)
        return clip
    }

    func store(_ clip: SynthesizedAudio, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = clip
        touch(key)
        while storage.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// Voice or skip-brackets change: drop every clip not matching the new prefix.
    func purge(keepingPrefix prefix: String) {
        lock.lock(); defer { lock.unlock() }
        for key in storage.keys where !key.hasPrefix(prefix) {
            storage.removeValue(forKey: key)
        }
        recency.removeAll { !$0.hasPrefix(prefix) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
        recency.removeAll()
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}
