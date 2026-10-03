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
        /// Give back memory that can be rebuilt (the warm neural voice).
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
    /// on every platform the same way.
    static func post(_ event: Event, to center: NotificationCenter? = nil) {
        (center ?? self.center(for: event)).post(name: event.name, object: nil)
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

#if os(macOS)
/// The Mac's memory warning: the kernel's memory-pressure source, posted on
/// the default center as `PlatformLifecycle.Event.memoryWarning`.
enum MemoryPressureRelay {

    static let name = Notification.Name("AloudMemoryWarning")

    /// Made and resumed on first use (a static's initializer runs once) and
    /// kept for the life of the process.
    private static let source: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            NotificationCenter.default.post(name: name, object: nil)
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
