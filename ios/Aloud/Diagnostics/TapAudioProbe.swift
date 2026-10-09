#if DEBUG
import Combine
import Foundation

/// C1: tap to first audio, for the TapLatency UI tests on both apps (the
/// debug.tapAudio probe `UITestProbeOverlay` shows). Active only in a
/// UI-test launch, which is always muted: the player node still starts, so
/// the reading holds with no sound (it leaves out the output's own
/// latency). DEBUG only; nothing here changes what the app plays.
///
/// Its value, after each seek that played or gave up:
/// `n=<seeks that sounded> ms=<seek to the started node's play>
/// path=hit|lead|phrase|whole wait=<ms behind a job in flight> cold=0|1
/// swallowed=<taps a coasting scroll ate> gaveUp=<seeks that never
/// sounded>`, plus `fromClick=<ms from the click>` when a click led to it
/// (the Mac's, held for a double-click).
@MainActor
final class TapAudioProbe: ObservableObject {

    static let shared = TapAudioProbe()

    @Published private(set) var value = "n=0"

    private var sounded = 0
    private var gaveUp = 0
    private var swallowed = 0
    private var began: ContinuousClock.Instant?
    private var cold = false
    private var path: String?
    private var clickLanded: ContinuousClock.Instant?
    private var fromClick: ContinuousClock.Instant?
    private var last: (ms: Int, path: String, wait: Int, cold: Bool, fromClick: Int?)?

    /// A click older than this led to no seek of its own (a double-click,
    /// a click that gave way): the next seek is not its.
    private static let clickLeadsWithin: Duration = .seconds(2)

    private var isActive: Bool { UITestHooks.isUITestLaunch }

    /// The Mac's click on a sentence, before its hold.
    func noteClick() {
        guard isActive else { return }
        clickLanded = .now
    }

    /// A tap or click on moving text that only stopped the scroll.
    func noteSwallowed() {
        guard isActive else { return }
        swallowed += 1
        publish()
    }

    /// A seek that will play began (`PlaybackController.seek`); one still
    /// open gave up.
    func tapBegan(cold: Bool) {
        guard isActive else { return }
        if began != nil { gaveUp += 1 }
        let now = ContinuousClock.now
        began = now
        self.cold = cold
        path = nil
        fromClick = clickLanded.flatMap { now - $0 <= Self.clickLeadsWithin ? $0 : nil }
        clickLanded = nil
        Self.tally.reset()
    }

    /// How the start's first clip came: the first note after a seek wins.
    func notePath(_ path: String) {
        guard isActive, began != nil, self.path == nil else { return }
        self.path = path
    }

    /// The status left `.buffering`: `.playing` (the started node's first
    /// buffer) or a start that gave up.
    func settled(playing: Bool) {
        guard isActive, let began else { return }
        self.began = nil
        if playing {
            sounded += 1
            let now = ContinuousClock.now
            last = (ms: Self.milliseconds(now - began), path: path ?? "hit",
                    wait: Int((Self.tally.take() * 1000).rounded()), cold: cold,
                    fromClick: fromClick.map { Self.milliseconds(now - $0) })
        } else {
            gaveUp += 1
        }
        fromClick = nil
        publish()
    }

    /// A start's wait behind a job in flight (`SynthesisScheduler`), from
    /// the scheduler's actor.
    nonisolated static func noteQueueWait(seconds: Double) {
        tally.add(seconds)
    }

    private func publish() {
        var parts = ["n=\(sounded)"]
        if let last {
            parts += ["ms=\(last.ms)", "path=\(last.path)", "wait=\(last.wait)", "cold=\(last.cold ? 1 : 0)"]
        }
        parts += ["swallowed=\(swallowed)", "gaveUp=\(gaveUp)"]
        if let click = last?.fromClick { parts.append("fromClick=\(click)") }
        value = parts.joined(separator: " ")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
    }

    /// The queue waits since the last seek, written from the scheduler.
    private nonisolated static let tally = WaitTally()

    private final class WaitTally: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 0

        func add(_ wait: Double) { lock.withLock { seconds += wait } }
        func reset() { lock.withLock { seconds = 0 } }
        func take() -> Double { lock.withLock { defer { seconds = 0 }; return seconds } }
    }
}
#endif
