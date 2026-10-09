import AVFoundation
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
    /// Kokoro's ONNX threads: two, until a device measurement says
    /// otherwise. IOSSynthesisPerfTests (ALOUD_PERF=1, on a device) times
    /// 2 threads spinning, 2 not spinning and 3 not spinning; a third
    /// thread is worth taking only if it reads at least 15% faster for no
    /// more CPU-seconds per second of audio on the A14 floor (an iPhone 12
    /// Pro), and then the count follows the cores (`hw.perflevel0` and
    /// `hw.perflevel1`: every performance core and one efficiency core,
    /// at most 3).
    /// The iPhone's budgets (M19): synthesis at least 2.5x real time at the
    /// 2x speed tier, first audio within 1 s warm and 4 s cold.
    static let kokoroThreads = 2
    /// ONNX Runtime's idle threads spin for work by default, competing with
    /// the main and audio threads and heating the phone toward R11's switch
    /// to the System voice. Off, through the engine's provider config file
    /// (`KokoroSherpaEngine.runtimeProvider`), which falls back to plain
    /// "cpu" whenever the file can't be used.
    static let kokoroStopsThreadSpinning = true
    /// R18: the Library's Continue card warms the neural voice, and so does
    /// the reader for a book loaded in it (LaunchRestore reopens the last
    /// reader at launch, where no card ever shows).
    static let prewarmsForLoadedBook = true
    /// A bare launch never warms it: only a book or the card asks.
    static let prewarmsAtLaunch = false
    /// Classics on screen warms it too: a book picked there would otherwise
    /// load the model cold. Never the bare Library root.
    static let prewarmsOnClassics = true
    /// A memory warning's hold on the warm-up ends when the app comes back
    /// to the foreground, as when the card shows again or another book
    /// loads: the listener has returned.
    static let memoryHoldEndsOnReturn = true
    /// Whether going to the background releases an idle neural voice, so
    /// iOS doesn't end the process for its memory.
    static let releasesNeuralOnBackground = true
    /// How long the audio engine runs on once nothing plays. A running
    /// engine keeps iOS from suspending a paused Aloud in the background,
    /// rendering silence all night, and keeps the audio from an app it
    /// interrupted; a minute after playback stops the engine stops and the
    /// session goes, quietly after a pause (that app is told it may resume
    /// only at the book's end), and a natural voice paused in the
    /// background goes with it. A shorter pause still
    /// resumes mid-sentence; a longer one reads on from the sentence start,
    /// and lock-screen Play claims the session again on the way.
    static let idleEngineStopDelay: TimeInterval? = 60
    /// The speed track waits for the scrub's 8pt of sideways travel before
    /// it moves the speed: a touch that only presses it, or drags it
    /// downward, stays the sheet's and the list's (R3-09).
    static let speedTrackSetsOnClick = false
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
    static let prewarmsForLoadedBook = true
    static let prewarmsAtLaunch = true
    /// The launch already warms it, so Classics asks for nothing more.
    static let prewarmsOnClassics = false
    /// A window coming back to the front isn't the listener returning: a
    /// memory warning's hold ends only with the card or another book.
    static let memoryHoldEndsOnReturn = false
    /// A Mac never ends an app for its memory, and a hidden window keeps
    /// reading.
    static let releasesNeuralOnBackground = false
    /// M19: a running engine keeps the output device open, and coreaudiod
    /// holds off idle sleep while it is. 30 s after playback stops the
    /// engine stops too, so a paused Mac on battery can sleep.
    static let idleEngineStopDelay: TimeInterval? = 30
    /// A click on the speed track sets the speed where it lands, as the
    /// stock macOS slider did and as MacScrub's click seeks; no pointer
    /// drag there belongs to a sheet.
    static let speedTrackSetsOnClick = true

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
    /// Posted when the media server restarts, taking every audio object
    /// made before it along (`PlaybackController.mediaServicesWereReset`).
    static let mediaServicesReset: Notification.Name? = AVAudioSession.mediaServicesWereResetNotification
    #elseif os(macOS)
    /// A Debug build launched by anything but Xcode's Run action (Finder,
    /// `open`, a test) stays silent: `ALOUD_AUDIBLE=1` lifts it.
    static let debugBuildsStartMuted = true
    /// A muted Mac process opens no output device at all, so not even a
    /// stream of zeros can pull AirPods over from another device.
    static let mutedOutputMode: MutedOutputMode = .manualRendering
    /// A Mac has no audio session, and no media server to reset under it.
    static let mediaServicesReset: Notification.Name? = nil
    #endif
}
