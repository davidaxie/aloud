import Foundation
#if os(iOS)
import QuartzCore
#endif

/// A steady per-frame callback on the main run loop that needs no view:
/// word timing resolves the spoken word 30 times a second. Main thread only.
/// Releasing the ticker stops it. (S9)
final class FrameTicker {

    private let framesPerSecond: Int
    private let tick: () -> Void

    #if os(iOS)
    private var link: CADisplayLink?
    #elseif os(macOS)
    private var timer: Timer?
    #endif

    init(framesPerSecond: Int = 30, tick: @escaping () -> Void) {
        self.framesPerSecond = framesPerSecond
        self.tick = tick
    }

    deinit {
        invalidate()
    }

    #if os(iOS)
    /// Starts ticking; a second call while running does nothing.
    func start() {
        guard link == nil else { return }
        // The link retains its target, so it gets a proxy, never the ticker:
        // releasing the ticker still ends the link.
        let link = CADisplayLink(target: FrameTickerTarget(tick), selector: #selector(FrameTickerTarget.fire))
        // 30 fps is plenty for word-boundary resolution and halves the
        // wakeups; under load the system may halve it again.
        let rate = Float(framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops ticking. Safe to call when stopped; `start()` begins again.
    func invalidate() {
        link?.invalidate()
        link = nil
    }
    #elseif os(macOS)
    /// Starts ticking; a second call while running does nothing.
    func start() {
        guard timer == nil else { return }
        // A Mac's display link belongs to a view or a screen; word timing
        // needs neither, so a run-loop timer at the same 30 fps. It too
        // retains its target, so it gets the proxy, never the ticker.
        let interval = 1 / TimeInterval(framesPerSecond)
        let timer = Timer(timeInterval: interval, target: FrameTickerTarget(tick),
                          selector: #selector(FrameTickerTarget.fire), userInfo: nil, repeats: true)
        // A little slack lets the system coalesce wakeups; the timer keeps
        // its 30 fps grid.
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops ticking. Safe to call when stopped; `start()` begins again.
    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
    #endif
}

private final class FrameTickerTarget: NSObject {
    private let tick: () -> Void

    init(_ tick: @escaping () -> Void) {
        self.tick = tick
    }

    @objc func fire() {
        tick()
    }
}
