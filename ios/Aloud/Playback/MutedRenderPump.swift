#if DEBUG
import AVFoundation
import Foundation

/// Plays a muted engine that has no output device: the engine renders
/// offline (manual rendering), and every 10 ms this renders the frames the
/// wall clock says have passed into a scratch buffer nobody hears. The
/// player's render time, its buffer completions and the word timing then
/// advance in real time, as they would through speakers. DEBUG and muted
/// processes only.
///
/// Renders run on the pump's serial queue. Anything that rewires the graph
/// goes through `exclusively`, so no render is ever in flight across it.
final class MutedRenderPump: @unchecked Sendable {

    static let interval = DispatchTimeInterval.milliseconds(10)
    /// A longer gap (a debugger pause) isn't caught up in one burst.
    static let longestCatchUp: TimeInterval = 0.5

    private let engine: AVAudioEngine
    private let queue = DispatchQueue(label: "Aloud.MutedRenderPump", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // Queue-confined.
    private var scratch: AVAudioPCMBuffer?
    private var lastTick: UInt64?
    private var owedFrames: Double = 0

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    deinit {
        timer?.cancel()
    }

    /// Starts pacing; a second call while running does nothing. The engine
    /// must already be in manual rendering mode.
    func start() {
        queue.sync {
            guard timer == nil else { return }
            lastTick = nil
            owedFrames = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Runs `change` between renders, on the pump's queue: for connecting
    /// nodes while the engine renders.
    func exclusively(_ change: () -> Void) {
        queue.sync(execute: change)
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastTick = now }
        // A stopped engine owes nothing: the clock restarts with it.
        guard engine.isInManualRenderingMode, engine.isRunning, let previous = lastTick else {
            owedFrames = 0
            return
        }
        let elapsed = min(Double(now &- previous) / 1_000_000_000, Self.longestCatchUp)
        owedFrames += elapsed * engine.manualRenderingFormat.sampleRate
        guard let scratch = scratchBuffer() else { return }
        while owedFrames >= 1 {
            let frames = min(AVAudioFrameCount(owedFrames), scratch.frameCapacity)
            let status = try? engine.renderOffline(frames, to: scratch)
            guard status == .success else {
                owedFrames = 0   // nothing to pull now: try again next tick
                return
            }
            owedFrames -= Double(frames)
        }
    }

    private func scratchBuffer() -> AVAudioPCMBuffer? {
        let format = engine.manualRenderingFormat
        if let scratch, scratch.format == format { return scratch }
        scratch = AVAudioPCMBuffer(pcmFormat: format,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)
        return scratch
    }
}
#endif
