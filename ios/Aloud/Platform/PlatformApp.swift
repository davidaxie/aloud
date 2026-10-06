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

        /// The level `notification` carries. One that carries none (the
        /// iPhone's single `didReceiveMemoryWarning`) is critical, which is
        /// what that warning has always meant here: a paused engine is
        /// freed too.
        init(of notification: Notification) {
            let raw = notification.userInfo?[Self.userInfoKey] as? String
            self = raw.flatMap(Self.init(rawValue:)) ?? .critical
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

#if os(macOS)
/// The Mac's memory warning: the kernel's memory-pressure source, posted on
/// the default center as `PlatformLifecycle.Event.memoryWarning` carrying
/// its level (`PlatformLifecycle.MemoryPressure`).
enum MemoryPressureRelay {

    static let name = Notification.Name("AloudMemoryWarning")

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
    #endif
}
#endif
