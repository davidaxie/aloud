import Combine
import Foundation
#if os(iOS)
import UIKit
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
        #endif
    }

    #if os(iOS)
    /// Where `event` is posted when the caller doesn't inject a center.
    static func center(for event: Event) -> NotificationCenter {
        .default
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
        (center ?? self.center(for: event)).addObserver(forName: event.name, object: nil,
                                                        queue: queue, using: block)
    }

    /// The same event as a Combine publisher, for the observers that keep
    /// their subscriptions in a cancellable set.
    static func publisher(for event: Event,
                          in center: NotificationCenter? = nil) -> NotificationCenter.Publisher {
        (center ?? self.center(for: event)).publisher(for: event.name)
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
    #endif
}
