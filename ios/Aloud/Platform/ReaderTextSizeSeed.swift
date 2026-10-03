#if os(iOS)
import UIKit

/// The reader's first-launch text size, per platform. The iPhone follows
/// the system text size; `ReaderTextSize.seedIfNeeded` stores it once.
extension ReaderTextSize {

    /// The step a first launch stores.
    @MainActor static var platformDefaultStep: Int {
        seededStep(for: UIApplication.shared.preferredContentSizeCategory)
    }

    /// The reader's starting size follows the system text size: Large 19,
    /// AX1 26, AX3 35, AX5 40.
    static func seededStep(for category: UIContentSizeCategory) -> Int {
        switch category {
        case .extraSmall, .small: return 0
        case .medium: return 1
        case .large: return 2
        case .extraLarge: return 3
        case .extraExtraLarge, .extraExtraExtraLarge: return 4
        case .accessibilityMedium: return 5
        case .accessibilityLarge: return 6
        case .accessibilityExtraLarge: return 7
        case .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge: return 8
        default: return defaultStep
        }
    }

    /// First launch only: store the step seeded from `category`.
    static func seedIfNeeded(_ defaults: UserDefaults, category: UIContentSizeCategory) {
        seedIfNeeded(defaults, step: seededStep(for: category))
    }
}
#elseif os(macOS)
import Foundation

/// The reader's first-launch text size, per platform. macOS gives apps no
/// system text size to follow, so the Mac starts at 19 pt (step 2): about
/// 66 characters a line in the 33 em column. `ReaderTextSize.seedIfNeeded`
/// stores it once.
extension ReaderTextSize {

    /// The step a first launch stores.
    @MainActor static var platformDefaultStep: Int {
        2
    }
}
#endif
