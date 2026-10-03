import Foundation

/// How a muted process (UI tests) keeps its audio silent.
enum MutedOutputMode: Sendable {
    /// The real output device, with the main mixer at volume 0.
    case deviceAtZeroVolume
    /// No output device at all: the engine renders offline, paced in real
    /// time.
    case manualRendering
}

/// Numbers tuned per platform. (S15)
enum PlatformTuning {
    #if os(iOS)
    /// Kokoro's ONNX threads: two keeps synthesis ahead of speech without
    /// heating the phone.
    static let kokoroThreads = 2
    /// Whether going to the background releases an idle neural voice, so
    /// iOS doesn't end the process for its memory.
    static let releasesNeuralOnBackground = true
    /// How long the audio engine runs on once nothing plays: nil keeps it
    /// running, as the iPhone always has.
    static let idleEngineStopDelay: TimeInterval? = nil
    #elseif os(macOS)
    /// Two, for the battery on a plane (M19). Pending the user's on-device
    /// measurement: raised to 4 only if synthesis measures below 5× real
    /// time at 2 on the floor machine (an M1 with 8 GB, on battery).
    static let kokoroThreads = 2
    /// A Mac never ends an app for its memory, and a hidden window keeps
    /// reading.
    static let releasesNeuralOnBackground = false
    /// M19: a running engine keeps the output device open, and coreaudiod
    /// holds off idle sleep while it is. 30 s after playback stops the
    /// engine stops too, so a paused Mac on battery can sleep.
    static let idleEngineStopDelay: TimeInterval? = 30
    #endif
}

/// Where audio goes when nobody should hear it.
enum PlatformAudio {
    #if os(iOS)
    /// Debug builds play aloud unless a test condition mutes them.
    static let debugBuildsStartMuted = false
    static let mutedOutputMode: MutedOutputMode = .deviceAtZeroVolume
    #elseif os(macOS)
    /// A Debug build launched by anything but Xcode's Run action (Finder,
    /// `open`, a test) stays silent: `ALOUD_AUDIBLE=1` lifts it.
    static let debugBuildsStartMuted = true
    /// A muted Mac process opens no output device at all, so not even a
    /// stream of zeros can pull AirPods over from another device.
    static let mutedOutputMode: MutedOutputMode = .manualRendering
    #endif
}
