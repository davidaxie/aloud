import SwiftUI
import UIKit

@main
struct AloudApp: App {
    // The shared instance: an App Intent may have built it before any scene.
    @StateObject private var model = AppModel.shared
    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.documentStore)
                .environmentObject(model.playback)
                .environmentObject(model.sleepTimer)
                .environmentObject(model.modelManager)
                .environmentObject(model.router)
                .environmentObject(model.importer)
                .environmentObject(model.naturalVoiceOffer)
                // The app's one haptic player (R20). At the root, so it keeps
                // playing while a sheet is up.
                .playsTransportHaptics()
                // simctl's appearance flip is unreliable on this runtime; UI
                // tests and screenshot capture force a scheme explicitly
                // (DEBUG builds only — the hook is a no-op in Release).
                .preferredColorScheme(effectiveScheme)
                // preferredColorScheme restyles SwiftUI content only; UIKit
                // chrome (navigation bars, their titles and backgrounds,
                // menus) follows the WINDOW's style. Without this, choosing
                // Dark while the phone is in Light left light bars over a
                // dark page (a cream reader bar, an invisible Settings title).
                .onAppear { WindowAppearance.apply(effectiveScheme) }
                .onChange(of: appearanceRaw) { WindowAppearance.apply(effectiveScheme) }
        }
    }

    private var effectiveScheme: ColorScheme? {
        UITestHooks.forcedColorScheme ?? AppearancePreference(rawValue: appearanceRaw)?.colorScheme
    }
}

/// Mirrors the in-app appearance override onto every UIKit window, so system
/// chrome resolves dynamic colors in the same scheme as the SwiftUI content.
enum WindowAppearance {
    @MainActor
    static func apply(_ scheme: ColorScheme?) {
        let style: UIUserInterfaceStyle
        switch scheme {
        case .dark?: style = .dark
        case .light?: style = .light
        default: style = .unspecified
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
