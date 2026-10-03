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
    #endif
}

#if os(iOS)
private final class FrameTickerTarget: NSObject {
    private let tick: () -> Void

    init(_ tick: @escaping () -> Void) {
        self.tick = tick
    }

    @objc func fire() {
        tick()
    }
}
#endif
