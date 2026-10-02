import Foundation

/// The audio edges' durations (R20): a user pause or resume ramps rather than
/// clicking, and autoplay fades in.
enum AudioEdge {
    static let pauseRamp: TimeInterval = 0.12
    static let resumeRamp: TimeInterval = 0.12
    static let autoplayFadeIn: TimeInterval = 0.3
}

/// The pure arithmetic behind `PlaybackController.rampOutputVolume`.
enum VolumeRamp {

    /// Linear from `from` to `to`; progress is clamped to 0...1 and the ends
    /// are exact, so a finished ramp lands on its target with no float drift.
    nonisolated static func level(from: Float, to: Float, progress: Double) -> Float {
        if progress <= 0 { return from }
        if progress >= 1 { return to }
        return from + (to - from) * Float(progress)
    }

    /// 10 ms steps keep a short edge smooth (12 steps over 120 ms); a long
    /// fade such as the sleep timer's 15 s needs no more than 20 a second.
    nonisolated static func stepInterval(for duration: TimeInterval) -> TimeInterval {
        duration <= 1 ? 0.01 : 0.05
    }
}
