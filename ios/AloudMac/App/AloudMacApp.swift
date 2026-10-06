import AppKit
import SwiftUI

/// The Mac app's entry point. A scene builder can't branch on the process,
/// so the choice is made here, before any scene exists: a hosted unit-test
/// process runs `MacTestHostApp` (no window, no Dock icon), and every other
/// launch runs `AloudMacApp`.
@main
@MainActor
enum AloudMacLaunch {
    static func main() {
        if MacHostProcess.isHostedUnitTest {
            MacTestHostApp.main()
        } else {
            AloudMacApp.main()
        }
    }
}

/// Aloud on the Mac: one window (Library, Classics and the reader in one
/// navigation stack) and the Settings window, over the shared core. Owns the
/// one `AppModel`, as the iPhone's `AloudApp` does; the delegate owns the
/// Mac-only parts (UI state, menus, keys, appearance).
struct AloudMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    // The shared instance: an App Intent may have built it before any scene.
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Aloud", id: MacMainWindow.id) {
            MacMainWindow(delegate: delegate)
                .aloudEnvironment(model)
                .environment(delegate.ui)
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { AloudCommands(state: delegate.commandState) }

        Settings {
            MacSettingsView()
                .aloudEnvironment(model)
                .environment(delegate.ui)
        }
    }
}

/// The main window's content: the root view on paper at the 520 × 480
/// minimum, with the window's AppKit settings, and (UI-test launches only)
/// the debug probes.
struct MacMainWindow: View {
    static let id = "main"

    let delegate: MacAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MacRootView()
            .frame(minWidth: MacWindowConfigurator.minimumSize.width,
                   minHeight: MacWindowConfigurator.minimumSize.height)
            .modifier(MacWindowPaper())
            .background(MacWindowConfigurator { window in
                // A Dock click with the window closed reopens it (M5).
                let openWindow = openWindow
                delegate.mainWindowAppeared(window) { openWindow(id: Self.id) }
            })
            #if DEBUG
            .overlay(alignment: .bottomTrailing) { MacDebugProbeOverlay() }
            #endif
    }
}

/// What a hosted unit-test process runs (testing §1.2(f)): the test bundle
/// needs a live app to load into, and nothing else. No window ever opens, and
/// the accessory policy keeps the app out of the Dock and the app switcher,
/// so a test run never takes the desktop. It builds no `AppModel`, so the
/// launch touches no library; a test that needs the model builds its own.
struct MacTestHostApp: App {
    @NSApplicationDelegateAdaptor(MacTestHostDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Sets the accessory policy before launch finishes, and again after it, in
/// case the scene machinery set its own in between.
@MainActor
final class MacTestHostDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Which kind of process this is. Not a test hook: it holds in every
/// configuration, so even a Release-hosted run could never open the window.
enum MacHostProcess {

    /// XCTest is loaded into this process, and no UI test launched it.
    static var isHostedUnitTest: Bool {
        isHostedUnitTest(isUITestLaunch: UITestHooks.isUITestLaunch,
                         environment: ProcessInfo.processInfo.environment,
                         xcTestLoaded: NSClassFromString("XCTestCase") != nil)
    }

    /// The rule, pure. A UI test launches the app as a separate process with
    /// a `-uitest-` argument and wants the real window; a hosted unit test
    /// loads XCTest into the app itself (or names its configuration file).
    static func isHostedUnitTest(isUITestLaunch: Bool, environment: [String: String],
                                 xcTestLoaded: Bool) -> Bool {
        guard !isUITestLaunch else { return false }
        return xcTestLoaded || environment["XCTestConfigurationFilePath"] != nil
    }
}

extension View {
    /// The shared core's observable objects, as the iPhone's root injects
    /// them, so the shared views read them the same way on both apps.
    func aloudEnvironment(_ model: AppModel) -> some View {
        environmentObject(model)
            .environmentObject(model.documentStore)
            .environmentObject(model.playback)
            .environmentObject(model.sleepTimer)
            .environmentObject(model.modelManager)
            .environmentObject(model.router)
            .environmentObject(model.importer)
            .environmentObject(model.naturalVoiceOffer)
            // "Where you stopped" in Contents.
            .environment(\.placeHistory, model.placeHistory)
    }
}
