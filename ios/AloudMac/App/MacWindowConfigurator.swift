import AppKit
import SwiftUI

/// The main window's AppKit settings, which SwiftUI has no modifier for
/// (M5): paper behind everything from the first frame, no titlebar
/// separator (the screens draw their own hairline), no tabs, a fixed
/// accessibility identifier, the 520 × 480 minimum, and (through
/// `onWindow`) the key router's tail at the end of its responder chain.
/// Placed as a zero-size background of the window's content; it acts once
/// its view joins the window. `NSWindow.identifier` stays SwiftUI's: the
/// scene finds and restores its window by it.
struct MacWindowConfigurator: NSViewRepresentable {

    /// What UI tests find the window by.
    static let accessibilityIdentifier = "aloud.window.main"
    static let minimumSize = CGSize(width: 520, height: 480)

    /// Called with the window once, after it is configured.
    var onWindow: @MainActor (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = { window in
            Self.configure(window)
            onWindow(window)
        }
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {}

    @MainActor
    static func configure(_ window: NSWindow) {
        window.setAccessibilityIdentifier(accessibilityIdentifier)
        window.backgroundColor = NSColor(Theme.bg)
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.contentMinSize = minimumSize
        #if DEBUG
        MacTestSilence.configure(window)
        #endif
    }

    /// Reports its window the first time it is placed in one.
    final class WindowAccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let onWindow else { return }
            self.onWindow = nil
            onWindow(window)
        }
    }
}

/// The window's paper as SwiftUI draws it: `Theme.bg` behind the content and
/// the toolbar, never a material. On macOS 15 the window's container
/// background is the paper too.
struct MacWindowPaper: ViewModifier {
    func body(content: Content) -> some View {
        let paper = content
            .background(Theme.bg.ignoresSafeArea())
            .toolbarBackground(Theme.bg, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        if #available(macOS 15.0, *) {
            paper.containerBackground(Theme.bg, for: .window)
        } else {
            paper
        }
    }
}
