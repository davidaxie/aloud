import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// System accessibility settings the shared reader honors. (R4)
enum PlatformAccessibility {
    #if os(iOS)
    /// Reduce Motion: highlights jump instead of sliding and fading.
    static var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Posted on `reduceMotionCenter` when Reduce Motion changes.
    static let reduceMotionDidChange = UIAccessibility.reduceMotionStatusDidChangeNotification

    static var reduceMotionCenter: NotificationCenter {
        .default
    }
    #elseif os(macOS)
    /// Reduce Motion, or `-uitest-reduce-motion` (tests never flip the
    /// system setting).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UITestHooks.forceReduceMotion
    }

    /// Posted on `reduceMotionCenter` when any display accommodation
    /// (Reduce Motion, Increase Contrast, Reduce Transparency) changes.
    static let reduceMotionDidChange = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification

    static var reduceMotionCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }
    #endif
}
