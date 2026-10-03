import Foundation

/// The transport state shown beside the Now Playing info.
enum NowPlayingState: Sendable {
    case playing, paused, stopped
}

/// What Now Playing needs beyond its info dictionary. (S10)
enum PlatformNowPlaying {
    #if os(iOS)
    /// Nothing to set: iOS reads the state from the audio session and the
    /// published playback rate.
    static func setState(_ state: NowPlayingState) {}

    /// Whether a muted process (UI tests) still publishes Now Playing info.
    static let publishesWhenMuted = true
    #endif
}
