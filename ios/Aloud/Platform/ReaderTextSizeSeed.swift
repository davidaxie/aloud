#if os(iOS)
import UIKit

/// The reader's first-launch text size, per platform. The iPhone follows
/// the system text size; `ReaderTextSize.seedIfNeeded` stores it once, and
/// until the listener picks a size of their own it keeps following
/// (`followSystemIfUnchosen`).
extension ReaderTextSize {

    /// The step a first launch stores.
    @MainActor static var platformDefaultStep: Int {
        seededStep(for: UIApplication.shared.preferredContentSizeCategory)
    }

    /// Where the step the size was last seeded at is kept, beside the size
    /// itself: while the two agree, the listener never chose a size.
    static let seededKey = "aloud.prefs.v1.textSizeSeeded"

    /// The key a first launch's seed is recorded under.
    static var platformSeedKey: String? { seededKey }

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

    /// First launch only: store the step seeded from `category`, and the
    /// seed beside it.
    static func seedIfNeeded(_ defaults: UserDefaults, category: UIContentSizeCategory) {
        seedIfNeeded(defaults, step: seededStep(for: category), seedKey: seededKey)
    }

    /// The page follows the system text size (`category`) until the
    /// listener picks a size. The stepper, the VoiceOver adjust and the
    /// pinch write only the size, so a size moved off its seed is theirs
    /// and is never overwritten. An install from before the seed was
    /// recorded starts following once its size matches the system's; one
    /// whose size differs keeps it.
    static func followSystemIfUnchosen(_ defaults: UserDefaults, category: UIContentSizeCategory) {
        guard defaults.object(forKey: prefKey) != nil else { return }
        let target = seededStep(for: category)
        let stored = defaults.integer(forKey: prefKey)
        guard defaults.object(forKey: seededKey) != nil else {
            if stored == target { defaults.set(target, forKey: seededKey) }
            return
        }
        guard stored == defaults.integer(forKey: seededKey), stored != target else { return }
        defaults.set(target, forKey: seededKey)
        defaults.set(target, forKey: prefKey)
    }

    /// `followSystemIfUnchosen` at the system text size now: at launch, for
    /// a change made while Aloud was closed, and on each live change.
    @MainActor static func followSystemIfUnchosen(_ defaults: UserDefaults) {
        followSystemIfUnchosen(defaults, category: UIApplication.shared.preferredContentSizeCategory)
    }

    /// Posted when the system text size changes.
    static var systemTextSizeDidChange: Notification.Name? {
        UIContentSizeCategory.didChangeNotification
    }
}

extension PlatformAccessibility {
    /// VoiceOver or Switch Control is running: an offer on screen (Undo
    /// jump) stays up long enough to be reached (R1-39).
    @MainActor static var assistiveTechRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    /// A new Undo jump offer is announced once (R1-39), so a VoiceOver
    /// listener knows there is a place to go back to.
    static let announcesUndoOffer = true
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

    /// The Mac records no seed: there is no system size to follow.
    static var platformSeedKey: String? { nil }

    /// Nothing to follow on the Mac.
    @MainActor static func followSystemIfUnchosen(_ defaults: UserDefaults) {}

    /// The Mac has no system text size.
    static var systemTextSizeDidChange: Notification.Name? { nil }
}

extension PlatformAccessibility {
    /// R1-39 is the iPhone's. The Mac's Undo jump offer keeps its 10 s
    /// with VoiceOver or Switch Control on, since Command-Z and the Edit
    /// menu take it from anywhere: the offer reads no assistive tech here.
    @MainActor static var assistiveTechRunning: Bool {
        false
    }

    /// The Mac says nothing new when an Undo jump offer opens: its chip
    /// slot and the Edit menu show it, as before R1-39.
    static let announcesUndoOffer = false
}
#endif
