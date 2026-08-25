import SwiftUI

@main
struct AloudApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    /// `-uitest-force-dark` / `-uitest-force-light` pin the scheme (testing
    /// only); otherwise the system setting governs.
    private static var forcedColorScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-force-dark") { return .dark }
        if args.contains("-uitest-force-light") { return .light }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.documentStore)
                .environmentObject(model.playback)
                .environmentObject(model.modelManager)
                // simctl's appearance flip is unreliable on this runtime; UI
                // tests and screenshot capture force a scheme explicitly.
                .preferredColorScheme(Self.forcedColorScheme
                    ?? AppearancePreference(rawValue: appearanceRaw)?.colorScheme)
        }
    }
}
