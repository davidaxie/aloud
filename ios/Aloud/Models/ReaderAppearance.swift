import SwiftUI

/// Appearance preference: System follows the device; Light/Dark pin the scheme.
/// Persisted as a raw string; `AloudApp` resolves it beneath the UI-test
/// launch-argument override (`-uitest-force-dark` / `-uitest-force-light`),
/// so launch arguments always win.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let prefKey = "aloud.prefs.v1.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "no override" — the device setting governs.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Nine reader text sizes, 16–40 serif points, on the A−/A+ stepper. The
/// reading column's leading comes from `ReaderPageStyle`, so only the point
/// size is chosen here. The first-launch step comes from the platform
/// (`ReaderTextSizeSeed.swift`).
enum ReaderTextSize {
    static let prefKey = "aloud.prefs.v1.textSize"
    /// Nine steps on the A−/A+ stepper (R2). The first five are the old
    /// S–XXL values, so stored indices 0–4 keep meaning the same size.
    static let steps: [CGFloat] = [16, 17.5, 19, 21, 23, 26, 30, 35, 40]
    static let defaultStep = 2

    static func points(forStep step: Int) -> CGFloat {
        steps[min(max(step, 0), steps.count - 1)]
    }

    /// One step bigger or smaller from `step` (read clamped, as a stored
    /// value out of range is), nil past either end. The one step rule for
    /// the iPhone's stepper and its VoiceOver adjust, and the Mac's size
    /// commands and popover.
    static func stepped(from step: Int, bigger: Bool) -> Int? {
        let next = min(max(step, 0), steps.count - 1) + (bigger ? 1 : -1)
        return steps.indices.contains(next) ? next : nil
    }

    /// First launch only: store the seeded step. Afterwards the user's own
    /// choice on the stepper wins.
    static func seedIfNeeded(_ defaults: UserDefaults, step: Int) {
        guard defaults.object(forKey: prefKey) == nil else { return }
        defaults.set(step, forKey: prefKey)
    }
}

/// The appearance controls' copy, one place for the Aa sheet and Settings.
enum AppearanceCopy {
    static let title = "Text & appearance"
    /// The text size section's name, and the adjustable size element's label.
    static let textSize = "Text size"
    /// The System / Light / Dark control's name.
    static let appearance = "Appearance"
    /// Closes the reader's sheet, which leaves the page live behind it.
    static let done = "Done"

    /// A reader size as the stepper shows it.
    static func points(_ points: CGFloat) -> String { "\(points.formatted()) pt" }
    /// A reader size as VoiceOver says it.
    static func spokenPoints(_ points: CGFloat) -> String { "\(points.formatted()) point" }

    /// Settings' row value: the size and the scheme picked.
    static func summary(points: CGFloat, appearance: AppearancePreference) -> String {
        "\(Self.points(points)) \u{00B7} \(appearance.label)"
    }

    /// `summary` as VoiceOver says it, with no middle dot to read aloud.
    static func spokenSummary(points: CGFloat, appearance: AppearancePreference) -> String {
        "\(spokenPoints(points)), \(appearance.label) appearance"
    }
}
