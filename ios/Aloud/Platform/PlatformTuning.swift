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
    #endif
}

/// Where audio goes when nobody should hear it.
enum PlatformAudio {
    #if os(iOS)
    /// Debug builds play aloud unless a test condition mutes them.
    static let debugBuildsStartMuted = false
    static let mutedOutputMode: MutedOutputMode = .deviceAtZeroVolume
    #endif
}
