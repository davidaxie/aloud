import Foundation
#if os(iOS)
import UIKit
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
    #endif
}
