import SwiftUI

@main
struct AloudApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.documentStore)
                .environmentObject(model.playback)
                .environmentObject(model.modelManager)
                // simctl's appearance flip is unreliable on this runtime; UI
                // tests and screenshot capture force a scheme explicitly
                // (DEBUG builds only — the hook is a no-op in Release).
                .preferredColorScheme(UITestHooks.forcedColorScheme
                    ?? AppearancePreference(rawValue: appearanceRaw)?.colorScheme)
        }
    }
}
