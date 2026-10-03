import Foundation
import Network

/// Whether the current network costs the user something (cellular, a
/// personal hotspot, Low Data Mode). The natural-voice download asks before
/// it moves a byte on such a path (R5), and says when a Wi-Fi-only download
/// is waiting for Wi-Fi (R21).
protocol NetworkPathSource: AnyObject, Sendable {
    var isExpensiveOrConstrained: Bool { get }
    /// Whether the Wi-Fi-only session can move bytes right now. An unknown
    /// path reads true, so nothing claims "waiting" before the first update.
    var allowsWiFiOnlyTransfer: Bool { get }
    /// Called (on any queue) whenever the path changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
    /// Starts watching the path; later calls do nothing. Nothing watches
    /// the network before the first call (M4), so a launch never does.
    /// Waits up to `timeout` for the first path when this call starts the
    /// watch, so a question asked right after isn't answered blind.
    func start(waitingUpTo timeout: TimeInterval)
}

/// The live path, from NWPathMonitor. Building it watches nothing: the
/// monitor is made and started by the first `start` (M4).
final class SystemNetworkPath: NetworkPathSource, @unchecked Sendable {

    private let lock = NSLock()
    /// Nil until `start`.
    private var monitor: NWPathMonitor?
    /// Signalled by the first path after `start`, then dropped.
    private var firstPath: DispatchSemaphore?
    /// The latest path the monitor delivered; nil until the first update.
    private var latest: NWPath?
    private var changeHandler: (@Sendable () -> Void)?

    deinit {
        monitor?.cancel()
    }

    #if DEBUG
    /// Whether `start` has made the monitor. NetworkBoundaryTests reads it.
    var isMonitoring: Bool {
        lock.lock(); defer { lock.unlock() }
        return monitor != nil
    }
    #endif

    /// The first path lands within milliseconds, so the wait is short and
    /// bounded. Past it the path still reads unknown, the safe direction
    /// (see `isExpensiveOrConstrained`). The queue runs at the main
    /// thread's QoS, since the main thread may be waiting on it: a lower
    /// one would be a priority inversion.
    func start(waitingUpTo timeout: TimeInterval) {
        let arrived = DispatchSemaphore(value: 0)
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        firstPath = arrived
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "com.davidxie.aloud.netpath", qos: .userInteractive))
        if timeout > 0 { _ = arrived.wait(timeout: .now() + timeout) }
    }

    /// An unknown or unsatisfied path reads false. That direction is safe:
    /// the default session is Wi-Fi only, so it simply waits for Wi-Fi.
    var isExpensiveOrConstrained: Bool {
        guard let path = currentPath else { return false }
        return path.status == .satisfied && (path.isExpensive || path.isConstrained)
    }

    /// Satisfied and neither expensive nor constrained: the only path the
    /// Wi-Fi-only session (no expensive, no constrained access) can use.
    var allowsWiFiOnlyTransfer: Bool {
        guard let path = currentPath else { return true }
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }

    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        changeHandler = handler
    }

    private var currentPath: NWPath? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    private func update(_ path: NWPath) {
        lock.lock()
        latest = path
        let handler = changeHandler
        let first = firstPath
        firstPath = nil
        lock.unlock()
        first?.signal()
        handler?()
    }
}

/// A constant path, for tests and the `-uitest-expensive-network` hook.
final class FixedNetworkPath: NetworkPathSource {

    let isExpensiveOrConstrained: Bool
    let allowsWiFiOnlyTransfer: Bool

    /// `wifiAvailable` defaults to the opposite of an expensive path: a
    /// cellular-only phone has no Wi-Fi, an inexpensive path is Wi-Fi.
    init(isExpensiveOrConstrained: Bool, wifiAvailable: Bool? = nil) {
        self.isExpensiveOrConstrained = isExpensiveOrConstrained
        allowsWiFiOnlyTransfer = wifiAvailable ?? !isExpensiveOrConstrained
    }

    /// A fixed path never changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    /// Nor is there anything to watch.
    func start(waitingUpTo timeout: TimeInterval) {}
}
