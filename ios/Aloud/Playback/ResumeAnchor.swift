import Foundation

/// Seconds on a clock that only moves forward. Immune to wall-clock changes
/// (a manual set, an NTP/carrier correction, a DST shift) — and, unlike
/// `ProcessInfo.systemUptime`, it keeps counting while the device sleeps,
/// which is exactly the overnight rest the longest rewind tier exists for.
/// (On Darwin `CLOCK_MONOTONIC` is `mach_continuous_time`; `CLOCK_UPTIME_RAW`
/// is the one that freezes during sleep.) The epoch is the last boot, so the
/// reading is comparable only within one boot — never persist it.
enum MonotonicClock {
    static var now: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// Where and when playback last left an active state — the whole input to the
/// resume rewind, as one value. A rewind belongs to the document that was
/// playing, at the sentence it stopped on, after a rest measured on a clock
/// the user cannot move.
struct ResumeAnchor: Equatable {

    /// The document that was playing. A rewind never crosses a document change.
    let documentID: UUID
    /// The sentence playback stopped on.
    let sentenceIndex: Int
    /// Wall clock at stamp time — the only reading that survives a relaunch.
    let wallClock: Date
    /// Monotonic reading at stamp time, or nil for an anchor read back in a
    /// later launch, where the boot epoch makes the number meaningless.
    let monotonic: TimeInterval?

    init(documentID: UUID,
         sentenceIndex: Int,
         wallClock: Date = Date(),
         monotonic: TimeInterval? = MonotonicClock.now) {
        self.documentID = documentID
        self.sentenceIndex = sentenceIndex
        self.wallClock = wallClock
        self.monotonic = monotonic
    }

    /// Seconds of rest. Within a session this reads the monotonic clock, so a
    /// device clock change can neither invent a rest nor erase one; only a
    /// restored anchor falls back to the persisted wall clock. Either way a
    /// negative gap — a clock that jumped backwards — clamps to zero, so the
    /// worst case is "no rewind", never a rewind pointing the wrong way.
    func elapsed(now: Date = Date(),
                 monotonicNow: TimeInterval = MonotonicClock.now) -> TimeInterval {
        if let monotonic { return max(monotonicNow - monotonic, 0) }
        return max(now.timeIntervalSince(wallClock), 0)
    }
}

// The monotonic reading is deliberately not encoded: it is boot-relative, so
// a value written in one launch means nothing in the next.
extension ResumeAnchor: Codable {

    private enum CodingKeys: String, CodingKey {
        case documentID, sentenceIndex, wallClock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(documentID: try container.decode(UUID.self, forKey: .documentID),
                  sentenceIndex: try container.decode(Int.self, forKey: .sentenceIndex),
                  wallClock: try container.decode(Date.self, forKey: .wallClock),
                  monotonic: nil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(sentenceIndex, forKey: .sentenceIndex)
        try container.encode(wallClock, forKey: .wallClock)
    }
}

/// One-slot, versioned persistence for the resume anchor, so the flagship
/// break — pause at night, iOS jettisons the app, resume next morning —
/// still rewinds. Injectable so tests never touch the standard defaults.
struct ResumeAnchorStore {

    static let key = "aloud.playback.resumeAnchor.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ResumeAnchor? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ResumeAnchor.self, from: data)
    }

    func save(_ anchor: ResumeAnchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
