import Combine
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The app-wide state the shared core asks the system about: whether the app
// is frontmost (S4), the lifecycle moments it saves at (S5), and the
// activity that keeps look-ahead from being throttled (S13).

enum PlatformApp {
    #if os(iOS)
    /// Whether the app is in front now: a stop recorded in the background
    /// waits to be announced, and a background launch never warms the
    /// natural voice.
    @MainActor static var isActive: Bool {
        UIApplication.shared.applicationState == .active
    }
    #elseif os(macOS)
    /// Whether Aloud is the frontmost app. No app (a bare test process)
    /// reads as not.
    @MainActor static var isActive: Bool {
        NSApp?.isActive ?? false
    }
    #endif
}

/// The lifecycle moments the store, the playback and the voice offer act on,
/// by what they mean rather than by the notification that brings them.
enum PlatformLifecycle {

    enum Event: CaseIterable, Sendable {
        /// The process is going away: flush synchronously.
        case willTerminate
        /// The last reliable moment to save before the process may be killed.
        case didEnterBackground
        /// Give back memory that can be rebuilt (the warm neural voice), as
        /// far as its `MemoryPressure` says.
        case memoryWarning
        /// The machine is about to sleep: audio is about to die.
        case systemWillSleep

        #if os(iOS)
        /// The notification this event arrives as.
        var name: Notification.Name {
            switch self {
            case .willTerminate: return UIApplication.willTerminateNotification
            case .didEnterBackground: return UIApplication.didEnterBackgroundNotification
            case .memoryWarning: return UIApplication.didReceiveMemoryWarningNotification
            // An iPhone never tells an app it is sleeping (the lock screen
            // keeps background audio playing), so nothing posts this
            // outside a test.
            case .systemWillSleep: return Notification.Name("AloudSystemWillSleep")
            }
        }
        #elseif os(macOS)
        /// The notification this event arrives as.
        var name: Notification.Name {
            switch self {
            case .willTerminate: return NSApplication.willTerminateNotification
            // A Mac app never goes to the background: losing the front is
            // the last reliable moment to save before a force quit or a
            // flat battery.
            case .didEnterBackground: return NSApplication.didResignActiveNotification
            // AppKit has no memory warning; the kernel's pressure source
            // posts this one.
            case .memoryWarning: return MemoryPressureRelay.name
            case .systemWillSleep: return NSWorkspace.willSleepNotification
            }
        }
        #endif
    }

    /// How hard a memory warning asks (M19), read from the warning itself
    /// so shared code never asks which platform sent it.
    enum MemoryPressure: String, CaseIterable, Sendable {
        /// Give back what nothing is waiting on: a load in flight, an idle
        /// engine.
        case warning
        /// Give back everything that isn't reading: a paused engine too.
        case critical

        /// Where a memory warning carries its level.
        static let userInfoKey = "AloudMemoryPressure"

        /// The kernel's pressure source, as the Mac's relay hears it: nil
        /// once pressure is back to normal, which asks for nothing.
        init?(_ event: DispatchSource.MemoryPressureEvent) {
            if event.contains(.critical) {
                self = .critical
            } else if event.contains(.warning) {
                self = .warning
            } else {
                return nil
            }
        }

        /// The level `notification` carries. One that carries none (UIKit's
        /// own `didReceiveMemoryWarning`) is critical, which is what that
        /// warning has always meant here: a paused engine is freed too.
        init(of notification: Notification) {
            self = Self.carried(by: notification) ?? .critical
        }

        /// The level `notification` carries, if it carries one.
        static func carried(by notification: Notification) -> Self? {
            (notification.userInfo?[userInfoKey] as? String).flatMap(Self.init(rawValue:))
        }

        /// What a memory warning at this level carries.
        var userInfo: [AnyHashable: Any] { [Self.userInfoKey: rawValue] }
    }

    #if os(iOS)
    /// Where `event` is posted when the caller doesn't inject a center.
    static func center(for event: Event) -> NotificationCenter {
        .default
    }
    #elseif os(macOS)
    /// Where `event` is posted when the caller doesn't inject a center:
    /// sleep on the workspace's own center, the rest on the default one.
    static func center(for event: Event) -> NotificationCenter {
        switch event {
        case .systemWillSleep:
            return NSWorkspace.shared.notificationCenter
        case .memoryWarning, .willTerminate, .didEnterBackground:
            return .default
        }
    }
    #endif

    /// Block-based, like `NotificationCenter.addObserver(forName:…)`: keep
    /// the token and remove it from the same center. With no `queue` the
    /// block runs synchronously on the posting thread, which is what a
    /// `willTerminate` flush needs. Tests inject `center`.
    static func observe(_ event: Event,
                        in center: NotificationCenter? = nil,
                        queue: OperationQueue? = nil,
                        using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        observed(center, for: event).addObserver(forName: event.name, object: nil, queue: queue, using: block)
    }

    /// The same event as a Combine publisher, for the observers that keep
    /// their subscriptions in a cancellable set.
    static func publisher(for event: Event,
                          in center: NotificationCenter? = nil) -> NotificationCenter.Publisher {
        observed(center, for: event).publisher(for: event.name)
    }

    /// Each memory warning at its level (M19), for the observers that free
    /// memory by it. The kernel's pressure source names the level on both
    /// platforms (`MemoryPressureRelay`, started here for the default
    /// center). On an iPhone UIKit's own warning, which names none, is the
    /// safety net and reads as critical, unless the relay names a level
    /// within `window` of it (nil: `MemoryPressureRelay.coalescingWindow`
    /// on the default center, none on a test's own), which then stands for
    /// both: a `.warning` keeps a paused natural voice warm.
    static func memoryPressure(in center: NotificationCenter? = nil,
                               window: TimeInterval? = nil) -> AnyPublisher<MemoryPressure, Never> {
        #if os(iOS)
        let center = observed(center, for: .memoryWarning)
        let isDefault = center === NotificationCenter.default
        if isDefault { MemoryPressureRelay.start() }
        let window = window ?? (isDefault ? MemoryPressureRelay.coalescingWindow : 0)
        // A warning that carries its level (the relay's, or one a test
        // posts) acts at once; UIKit's own carries none.
        let warnings = center.publisher(for: MemoryPressureRelay.name)
            .map { Optional(MemoryPressure(of: $0)) }
            .merge(with: center.publisher(for: Event.memoryWarning.name).map { MemoryPressure.carried(by: $0) })
        return Deferred { () -> AnyPublisher<MemoryPressure, Never> in
            let coalescer = MemoryWarningCoalescer(window: window)
            let feed = warnings.sink { coalescer.receive($0) }
            return coalescer.output
                .handleEvents(receiveCancel: {
                    feed.cancel()
                    coalescer.cancel()
                })
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
        #elseif os(macOS)
        // The relay is the Mac's only warning, and it always names a level.
        _ = window
        return publisher(for: .memoryWarning, in: center)
            .map { MemoryPressure(of: $0) }
            .eraseToAnyPublisher()
        #endif
    }

    /// The center an observer of `event` listens on: the injected one, or
    /// the event's own.
    private static func observed(_ center: NotificationCenter?, for event: Event) -> NotificationCenter {
        let center = center ?? self.center(for: event)
        #if os(macOS)
        // The Mac's memory warning exists only while the kernel's pressure
        // source runs. An observer on the default center (the app's, which
        // passes `.default` itself) starts it; a test's own center doesn't.
        if event == .memoryWarning, center === NotificationCenter.default {
            MemoryPressureRelay.start()
        }
        #endif
        return center
    }

    #if DEBUG
    /// Delivers `event` as the system would, so tests drive the observers
    /// on every platform the same way. A memory warning carries `pressure`
    /// as the Mac's relay does, or nothing, as the iPhone's does.
    static func post(_ event: Event, to center: NotificationCenter? = nil,
                     pressure: MemoryPressure? = nil) {
        (center ?? self.center(for: event)).post(name: event.name, object: nil, userInfo: pressure?.userInfo)
    }
    #endif
}

/// Held while playing or synthesizing ahead, so a hidden window's look-ahead
/// isn't throttled.
enum PlatformActivity {
    typealias Token = NSObjectProtocol

    #if os(iOS)
    /// Nothing to hold: the audio background mode keeps the process running
    /// while it plays.
    static func begin(reason: String) -> Token? {
        nil
    }

    static func end(_ token: Token?) {}
    #elseif os(macOS)
    /// User-initiated, so App Nap leaves look-ahead synthesis alone in a
    /// hidden window; idle sleep stays allowed (the audio device already
    /// holds it off while sound flows).
    static func begin(reason: String) -> Token? {
        ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
    }

    static func end(_ token: Token?) {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
    }
    #endif
}

/// Held while a book is being added, so leaving the app mid-import doesn't
/// suspend it halfway, with its copies left on disk (F036). Ended once,
/// by the add or by the system running out of time, whichever comes first.
@MainActor
final class PlatformBackgroundTask {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// Asks iOS for time to finish `name` should the app leave the screen.
    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: give it back, or iOS ends the app. Held strongly
            // until then, so the end always has its identifier.
            MainActor.assumeIsolated { self.end() }
        }
    }

    /// Whether the time asked for is still held.
    var isHeld: Bool { identifier != .invalid }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
    #elseif os(macOS)
    /// Nothing to ask for: a Mac app keeps running behind other windows.
    init(name: String) {}

    var isHeld: Bool { false }

    func end() {}
    #endif
}

/// The kernel's memory-pressure source, posted on the default center as
/// `name`, carrying its level (`PlatformLifecycle.MemoryPressure`). The
/// Mac's only memory warning (`PlatformLifecycle.Event.memoryWarning`); on
/// an iPhone it tells a `.warning` from a `.critical`, which UIKit's own
/// warning doesn't (`PlatformLifecycle.memoryPressure(in:window:)`).
enum MemoryPressureRelay {

    static let name = Notification.Name("AloudMemoryWarning")

    /// How close UIKit's own warning and the relay's level must come for the
    /// level to stand for both. Their order isn't fixed, so UIKit's waits
    /// this long for a level before it acts as critical.
    static let coalescingWindow: TimeInterval = 1

    /// Made and resumed on first use (a static's initializer runs once) and
    /// kept for the life of the process, so the handler may hold it.
    private static let source: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            guard let pressure = PlatformLifecycle.MemoryPressure(source.data) else { return }
            NotificationCenter.default.post(name: name, object: nil, userInfo: pressure.userInfo)
        }
        source.resume()
        return source
    }()

    static func start() {
        _ = source
        #if DEBUG
        isRunning = true
        #endif
    }

    #if DEBUG
    /// Whether the pressure source runs in this process.
    private(set) static var isRunning = false

    /// Delivers `pressure` as the source's handler does, to `center`.
    static func deliver(_ pressure: PlatformLifecycle.MemoryPressure, to center: NotificationCenter) {
        center.post(name: name, object: nil, userInfo: pressure.userInfo)
    }
    #endif
}

#if os(iOS)
/// Merges the relay's levels with UIKit's own warning (`memoryPressure`):
/// a level acts at once; UIKit's warning is dropped when a level came
/// within the window before it, and otherwise waits the window for one,
/// acting as critical if none comes. Fed on the main thread, where both
/// are posted.
private final class MemoryWarningCoalescer: @unchecked Sendable {

    let output = PassthroughSubject<PlatformLifecycle.MemoryPressure, Never>()
    private let window: TimeInterval
    private var lastLevel: DispatchTime?
    private var safetyNet: DispatchWorkItem?

    init(window: TimeInterval) {
        self.window = window
    }

    /// A warning: its level, or nil for UIKit's own.
    func receive(_ pressure: PlatformLifecycle.MemoryPressure?) {
        if let pressure {
            lastLevel = .now()
            safetyNet?.cancel()   // the level speaks for the warning waiting on it
            safetyNet = nil
            output.send(pressure)
            return
        }
        guard window > 0 else {
            output.send(.critical)
            return
        }
        if let lastLevel, DispatchTime.now() <= lastLevel + window { return }
        guard safetyNet == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.safetyNet = nil
            self.output.send(.critical)
        }
        safetyNet = item
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: item)
    }

    func cancel() {
        safetyNet?.cancel()
        safetyNet = nil
    }
}
#endif
