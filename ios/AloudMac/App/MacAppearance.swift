import AppKit
import Combine
import SwiftUI

/// System / Light / Dark, app-wide (M5): the shared `AppearancePreference`
/// becomes `NSApp.appearance`, so menus, popovers, alerts and the Settings
/// window match the paper, not only the SwiftUI content. A UI test's
/// `-uitest-force-light` / `-uitest-force-dark` wins over the preference.
@MainActor
final class MacAppearance {
    private var subscription: AnyCancellable?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Applies the stored choice now (before the first window, so the first
    /// frame is already the right paper) and again whenever it changes: the
    /// Aa popover, Settings and the View menu all write the one preference.
    func start() {
        apply()
        subscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.apply() } }
    }

    private func apply() {
        let name = Self.appearanceName(for: stored, forced: UITestHooks.forcedColorScheme)
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }

    private var stored: AppearancePreference {
        defaults.string(forKey: AppearancePreference.prefKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// nil follows the system; Aqua and Dark Aqua pin it. Increase Contrast
    /// still reaches the tokens through the system setting either way.
    nonisolated static func appearanceName(for preference: AppearancePreference,
                                           forced: ColorScheme?) -> NSAppearance.Name? {
        switch forced ?? preference.colorScheme {
        case .light?: return .aqua
        case .dark?: return .darkAqua
        case nil: return nil
        @unknown default: return nil
        }
    }
}
