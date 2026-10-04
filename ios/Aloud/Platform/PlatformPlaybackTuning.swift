import Foundation

/// How far ahead of the voice each platform synthesizes.
enum PlatformPlaybackTuning {
    #if os(iOS)
    /// None: an iPhone keeps a fixed two sentences ahead
    /// (`PlaybackController.lookAhead`).
    static let lookAheadSeconds: TimeInterval? = nil
    static let lookAheadSentences = 2...2
    #elseif os(macOS)
    /// About this much listening, at the current speed, queued past the
    /// playhead. Two sentences ran dry at 2.95x: two short lines of
    /// dialogue are about a second of listening, less than one synthesis.
    static let lookAheadSeconds: TimeInterval? = 12
    /// Never fewer than 3 sentences, nor more than 10: the R5 voice
    /// handoff splices after the last queued sentence, so a deeper queue
    /// would delay it.
    static let lookAheadSentences = 3...10
    #endif
}
