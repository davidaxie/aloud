import Foundation

/// The stop the listener didn't ask for, and which book it belongs to (R11).
struct PlaybackStop: Equatable, Codable, Sendable {
    let reason: StopReason
    let documentID: UUID
}

/// Where audio was when this launch last confirmed it was speaking.
struct LiveSession: Equatable, Codable, Sendable {
    let documentID: UUID
    let sentenceIndex: Int
    let wallClock: Date
    /// When and where this session's audio first played, so a session iOS
    /// ended still lands in "Where you stopped" (`PlaceStop.recovered`).
    /// Optional with defaults: a marker written before them still decodes.
    var startedAt: Date? = nil
    var startSentence: Int? = nil
    /// Whether the listener jumped away during it ("Where you stopped" keeps
    /// the place they left). Optional, so an older marker still decodes.
    var movedAway: Bool? = nil
}

/// One-slot stop + the live-session marker (written while audio plays,
/// cleared by every orderly stop and by willTerminate; still present at the
/// next launch means iOS ended the app while it was speaking). Injectable so
/// tests never touch the standard defaults.
struct PlaybackStopStore {

    static let stopKey = "aloud.playback.stop.v1"
    static let liveSessionKey = "aloud.playback.liveSession.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Undecodable reads as no stop: a stale schema never blocks Play.
    func load() -> PlaybackStop? {
        decode(PlaybackStop.self, forKey: Self.stopKey)
    }

    func save(_ stop: PlaybackStop) {
        encode(stop, forKey: Self.stopKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.stopKey)
    }

    func markLive(_ session: LiveSession) {
        encode(session, forKey: Self.liveSessionKey)
    }

    func clearLive() {
        defaults.removeObject(forKey: Self.liveSessionKey)
    }

    /// Reads AND removes the marker, so one crash is reported once.
    func takeLiveSession() -> LiveSession? {
        let session = decode(LiveSession.self, forKey: Self.liveSessionKey)
        clearLive()
        return session
    }

    func clearAll() {
        clear()
        clearLive()
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
