import Foundation
import Network

/// Whether the current network costs the user something (cellular, a
/// personal hotspot, Low Data Mode). The natural-voice download asks before
/// it moves a byte on such a path (R5), and says when a Wi-Fi-only download
/// is waiting for Wi-Fi (R21).
protocol NetworkPathSource: AnyObject, Sendable {
    var isExpensiveOrConstrained: Bool { get }
    /// Whether the path runs over cellular. A costly path that doesn't is
    /// a Wi-Fi with Low Data Mode on or another phone's Personal Hotspot,
    /// and the copy never calls that cellular. An unknown path reads false.
    var usesCellular: Bool { get }
    /// Whether the Wi-Fi-only session can move bytes right now. An unknown
    /// path reads true, so nothing claims "waiting" before the first update.
    var allowsWiFiOnlyTransfer: Bool { get }
    /// Whether a path has landed since `start`. Until it has, the two
    /// answers above are the unknown path's.
    var hasPath: Bool { get }
    /// Called (on any queue) whenever the path changes, the first path
    /// included.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
    /// Starts watching the path; later calls do nothing. Nothing watches
    /// the network before the first call (M4), so a launch never does.
    /// Returns at once: the first path arrives through the change handler.
    func start()
}

extension NetworkPathSource {
    /// A source that can't tell reads a costly path as cellular, the
    /// iPhone's usual costly path.
    var usesCellular: Bool { isExpensiveOrConstrained }
}

/// The live path, from NWPathMonitor. Building it watches nothing: the
/// monitor is made and started by the first `start` (M4).
final class SystemNetworkPath: NetworkPathSource, @unchecked Sendable {

    private let lock = NSLock()
    /// Nil until `start`.
    private var monitor: NWPathMonitor?
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

    /// The first path lands within milliseconds. The queue runs at the
    /// main thread's QoS, since a Download the user just tapped waits on
    /// that first path.
    func start() {
        lock.lock()
        guard monitor == nil else {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "com.davidxie.aloud.netpath", qos: .userInteractive))
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

    /// Satisfied over a cellular interface: Low Data Mode or a hotspot
    /// over Wi-Fi is costly, never cellular.
    var usesCellular: Bool {
        guard let path = currentPath else { return false }
        return path.status == .satisfied && path.usesInterfaceType(.cellular)
    }

    var hasPath: Bool { currentPath != nil }

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
        lock.unlock()
        handler?()
    }
}

/// A constant path, for tests and the `-uitest-expensive-network` hook.
final class FixedNetworkPath: NetworkPathSource {

    let isExpensiveOrConstrained: Bool
    let allowsWiFiOnlyTransfer: Bool
    let usesCellular: Bool
    /// Known from the start, so a Download decides at once.
    let hasPath = true

    /// `wifiAvailable` defaults to the opposite of an expensive path: a
    /// cellular-only phone has no Wi-Fi, an inexpensive path is Wi-Fi.
    /// `usesCellular` defaults to an expensive path too; false with an
    /// expensive path is a Low Data or hotspot Wi-Fi.
    init(isExpensiveOrConstrained: Bool, wifiAvailable: Bool? = nil, usesCellular: Bool? = nil) {
        self.isExpensiveOrConstrained = isExpensiveOrConstrained
        allowsWiFiOnlyTransfer = wifiAvailable ?? !isExpensiveOrConstrained
        self.usesCellular = usesCellular ?? isExpensiveOrConstrained
    }

    /// A fixed path never changes.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    /// Nor is there anything to watch.
    func start() {}

    /// No usable network at all, as on a plane (`-uitest-offline`): the
    /// answers `SystemNetworkPath` gives for an unsatisfied path, known from
    /// the start. Nothing reads as costly, so nothing asks, and the
    /// Wi-Fi-only download can't move a byte, so it waits rather than
    /// claiming progress.
    static var unsatisfied: FixedNetworkPath {
        FixedNetworkPath(isExpensiveOrConstrained: false, wifiAvailable: false)
    }
}
