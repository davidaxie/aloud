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
}
