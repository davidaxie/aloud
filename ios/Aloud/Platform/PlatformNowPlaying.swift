import Foundation
#if os(macOS)
import MediaPlayer
#endif

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
    #elseif os(macOS)
    /// The Mac reads the transport state from here: with no audio session,
    /// the Now Playing module and the media keys follow `playbackState`.
    static func setState(_ state: NowPlayingState) {
        let playbackState: MPNowPlayingPlaybackState
        switch state {
        case .playing: playbackState = .playing
        case .paused: playbackState = .paused
        case .stopped: playbackState = .stopped
        }
        MPNowPlayingInfoCenter.default().playbackState = playbackState
    }

    /// A muted Mac process (a test, a plain Debug launch) never takes Now
    /// Playing, or the media keys, from the listener's own player.
    static let publishesWhenMuted = false
    #endif
}
