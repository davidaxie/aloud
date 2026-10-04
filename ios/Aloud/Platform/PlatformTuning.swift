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
    /// ONNX Runtime keeps its default spinning threads: the provider stays
    /// plain "cpu".
    static let kokoroStopsThreadSpinning = false
    /// R18: only the Library's Continue card warms the neural voice.
    static let prewarmsBeyondTheContinueCard = false
    /// Whether going to the background releases an idle neural voice, so
    /// iOS doesn't end the process for its memory.
    static let releasesNeuralOnBackground = true
    /// How long the audio engine runs on once nothing plays: nil keeps it
    /// running, as the iPhone always has.
    static let idleEngineStopDelay: TimeInterval? = nil
    #elseif os(macOS)
    /// Two kept synthesis at 3.0x real time on an M4 Pro (10 P + 4 E
    /// cores), level with a listener at 2.95x, so reading fell behind.
    /// Measured with the app's own sherpa-onnx: 4 threads 4.8x, 6 threads
    /// 6.3x, 8 threads 6.8x. Two performance cores stay free for the
    /// window and the audio; never fewer than 4, and never more than 6,
    /// past which the gain is small and the heat isn't.
    static let kokoroThreads = kokoroThreadCount(performanceCores: performanceCoreCount)
    /// ONNX Runtime's idle threads spin for work by default, which burned
    /// CPU for nothing at the higher thread count: with spinning off, 6
    /// threads read at 6.2x for 0.709 CPU-seconds per second of audio
    /// (2 threads spinning: 0.665). The engine passes the setting in a
    /// provider config file (`KokoroSherpaEngine.runtimeProvider`).
    static let kokoroStopsThreadSpinning = true
    /// The natural voice also warms with a book loaded in it and at launch
    /// when it is the saved voice, not only behind the Continue card: a
    /// Mac's reader is often opened without the Library's card showing.
    static let prewarmsBeyondTheContinueCard = true
    /// A Mac never ends an app for its memory, and a hidden window keeps
    /// reading.
    static let releasesNeuralOnBackground = false
    /// M19: a running engine keeps the output device open, and coreaudiod
    /// holds off idle sleep while it is. 30 s after playback stops the
    /// engine stops too, so a paused Mac on battery can sleep.
    static let idleEngineStopDelay: TimeInterval? = 30

    /// All but two performance cores, clamped to 4...6.
    static func kokoroThreadCount(performanceCores: Int) -> Int {
        min(6, max(4, performanceCores - 2))
    }

    /// The performance cores (`hw.perflevel0.physicalcpu`), or half the
    /// active processors where the system doesn't say.
    static var performanceCoreCount: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return Int(cores)
        }
        return ProcessInfo.processInfo.activeProcessorCount / 2
    }
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
