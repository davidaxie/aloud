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
}

/// The live path, from NWPathMonitor.
final class SystemNetworkPath: NetworkPathSource, @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// The latest path the monitor delivered; nil until the first update.
    private var latest: NWPath?
    private var changeHandler: (@Sendable () -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "com.davidxie.aloud.netpath", qos: .utility))
    }

    deinit {
        monitor.cancel()
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
        lock.unlock()
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
}
