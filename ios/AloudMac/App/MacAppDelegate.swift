import AppKit
import SwiftUI

/// The Mac app's AppKit side, and the owner of its Mac-only parts: the
/// window's UI state, the menu bar's model, the key router and the
/// appearance (contracts §6).
///
/// - Closing the window keeps the book playing; a Dock click brings the
///   window back (M5).
/// - Finder's Open With and a drop on the Dock icon reach the window's
///   `onOpenURL`. This delegate leaves `application(_:open:)` to SwiftUI,
///   which delivers an event's files there one at a time, back to back;
///   the Library's intake gathers them into one batch (one file opens and
///   plays, several are all added and none opens). A UI test's
///   `-uitest-open <path>` is replayed through that same entry once the
///   window is up.
/// - The Dock icon's menu repeats the loaded book's Play/Pause and skips
///   (`MacDockMenu`, M13).
/// - No window tabs, so no Show Tab Bar.
/// - Quitting needs nothing here: the shared `willTerminate` observers
///   (AppModel's, the store's) anchor the place, flush progress and clear
///   the live-session marker, on both apps.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    /// The window's UI state, for the app's lifetime: the commands and the
    /// views read the same flags.
    let ui = MacUIState()

    /// The menus' model over the one `AppModel`. Built on first use, so the
    /// shared graph is made by the scene, as on the iPhone.
    /// A command that acts in the main window brings it back first.
    lazy var commandState: MacCommandState = {
        var actions = MacCommandActions(model: AppModel.shared, ui: ui)
        actions.showMainWindow = { [unowned self] in self.showMainWindow() }
        return MacCommandState(actions: actions)
    }()

    /// Space, the arrows and the brackets, before any menu sees them.
    private(set) lazy var keyRouter = MacKeyRouter { [unowned self] command in
        self.commandState.actions.perform(command)
    }

    /// The Dock icon's menu, over the Playback menu's actions. Kept here:
    /// its items target it.
    private lazy var dockMenu = MacDockMenu(actions: commandState.actions)

    private let appearance = MacAppearance()

    /// Reopens the main window. The window's content hands it over when it
    /// first appears; SwiftUI's `openWindow` exists only inside the scene.
    private(set) var openMainWindow: (() -> Void)?
    /// The main window, once configured.
    private(set) weak var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        MacTestSilence.installIfMuted()
        #endif
        // Before the first text field: no text menu offers Speech.
        MacFieldEditor.install()
        // Before the first window, so its first frame is the chosen paper.
        appearance.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyRouter.install()
        MacMenuPruner.removeSpeech()
        // Again once SwiftUI has finished building the menu bar.
        DispatchQueue.main.async { MacMenuPruner.removeSpeech() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The loaded book's title, Play or Pause and the two skips; nil with
    /// no book, so only the system's items show (M13, phase 4).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu.menu()
    }

    /// A Dock click brings the main window back however it went away: closed
    /// (reopened through the scene, even with Settings still up) or
    /// minimized (restored). With it on screen, AppKit's own reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow, mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
            return false
        }
        if let mainWindow, mainWindow.isVisible { return true }
        guard let openMainWindow else { return true }
        openMainWindow()
        return false
    }

    /// The main window on screen and in front, however it went away, for a
    /// menu command that acts in it (Add from Files…, Find, Back…).
    func showMainWindow() {
        if let mainWindow, mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        } else if let mainWindow, mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// The main window is on screen: it can be reopened from here on, and a
    /// UI test's `-uitest-open` file arrives now, as Finder's would.
    func mainWindowAppeared(_ window: NSWindow, reopen: @escaping () -> Void) {
        mainWindow = window
        openMainWindow = reopen
        keyRouter.ensureTail(on: window)
        // The menu bar is complete by now; a late Speech item goes too.
        MacMenuPruner.removeSpeech()
        guard !didReplayTestOpen, let url = UITestHooks.openPath else { return }
        didReplayTestOpen = true
        DispatchQueue.main.async { Self.open([url]) }
    }

    private var didReplayTestOpen = false

    /// Files to open, by the app's own Open With entry (SwiftUI's delegate,
    /// which hands them to `onOpenURL`); if that entry is missing, the same
    /// steps `onOpenURL` takes (the bare Library, then the window's intake,
    /// the files already together, so several still open none).
    static func open(_ urls: [URL]) {
        let entry = NSApp.delegate
        if let entry, entry.responds(to: #selector(NSApplicationDelegate.application(_:open:))) {
            entry.application?(NSApp, open: urls)
            return
        }
        admitWithoutEntry(urls, router: AppModel.shared.router, intake: MacFileIntake.shared)
    }

    /// `open`'s fallback. Only files Aloud can add clear the window, as
    /// `MacRootView.receiveOpened` does: with none, the reader and any
    /// Rename or Delete stay as they were, rather than the window clearing
    /// for files the intake then drops. Static, so the tests take the same
    /// steps.
    static func admitWithoutEntry(_ urls: [URL], router: LibraryRouter, intake: MacFileIntake) {
        let files = urls.filter { $0.isFileURL && MacFileIntake.isAddable($0) }
        guard !files.isEmpty else { return }
        router.clearForOpenIn()
        intake.admit(files)
    }
}

/// The Edit menu's Speech submenu would read the selection aloud through the
/// system synthesizer, on the speakers, past the muted engine (M11, testing
/// §1.3). The commands remove
/// the text-editing group that carries it; this is the backstop, for a
/// Speech item AppKit adds on its own. Text views' right-click menus go
/// through it too (`MacFieldEditor`).
@MainActor
enum MacMenuPruner {
    static let speechActions: Set<String> = ["startSpeaking:", "stopSpeaking:"]

    static func removeSpeech() {
        removeSpeech(from: NSApp.mainMenu)
    }

    /// Removes each Speech item, and a submenu holding nothing else (the
    /// Speech ▸ submenu itself). A menu that also holds other items keeps
    /// them: Speech items sitting directly in Edit never take Edit with them.
    static func removeSpeech(from menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items.reversed() {
            if let submenu = item.submenu {
                if isSpeechOnly(submenu) {
                    menu.removeItem(item)
                } else {
                    removeSpeech(from: submenu)
                }
            } else if isSpeech(item) {
                menu.removeItem(item)
            }
        }
    }

    private static func isSpeech(_ item: NSMenuItem) -> Bool {
        item.action.map { speechActions.contains(NSStringFromSelector($0)) } ?? false
    }

    /// At least one Speech item, and nothing but Speech items and separators.
    static func isSpeechOnly(_ menu: NSMenu) -> Bool {
        let items = menu.items.filter { !$0.isSeparatorItem }
        return !items.isEmpty && items.allSatisfy(isSpeech)
    }
}
