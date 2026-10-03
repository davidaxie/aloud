#if DEBUG
import AppKit
import ObjectiveC
import SwiftUI

/// Test plumbing for a muted Mac process (testing §1.2(e), D1, D2). DEBUG
/// only: Release has none of it.
///
/// - The system alert sound is the one sound no mixer mutes, and AppKit
///   plays it for a key no responder takes (`noResponder(for:)` with
///   keyDown). Muted, that becomes a silent count, `beepAttempts`, which a
///   keyboard test reads through `debug.beeps` and expects to stay 0.
/// - `debug.identity` says which build this is and that it is muted
///   (`com.davidxie.Aloud.mac.dev|muted`); UI tests fail closed without it.
/// - `debug.focus` names the main window's first responder, for the
///   keyboard matrix's focus states.
/// - `-uitest-window-size WxH` sizes the main window's content.
@MainActor
enum MacTestSilence {

    /// keyDowns that reached the end of a responder chain: each would have
    /// beeped in an unmuted process.
    private(set) static var beepAttempts = 0 {
        didSet { MacDebugProbes.shared.beeps = beepAttempts }
    }

    private static var isInstalled = false

    /// Swaps `noResponder(for:)` for a silent counter, on `NSResponder` and
    /// on `NSWindow` and `NSApplication` (either may carry its own), so a
    /// SwiftUI window's chain is covered however it ends. Muted processes
    /// only; once.
    static func installIfMuted() {
        guard UITestHooks.muteAudio, !isInstalled else { return }
        isInstalled = true
        let selector = #selector(NSResponder.noResponder(for:))
        let block: @convention(block) (NSResponder, Selector) -> Void = { _, eventSelector in
            guard eventSelector == #selector(NSResponder.keyDown(with:)) else { return }
            MainActor.assumeIsolated { beepAttempts += 1 }
        }
        let implementation = imp_implementationWithBlock(block)
        for type in [NSResponder.self, NSWindow.self, NSApplication.self] {
            guard let method = class_getInstanceMethod(type, selector) else { continue }
            class_replaceMethod(type, selector, implementation, method_getTypeEncoding(method))
        }
    }

    /// "<bundle ID>|muted" or "<bundle ID>|audible".
    static var identity: String {
        "\(Bundle.main.bundleIdentifier ?? "")|\(UITestHooks.muteAudio ? "muted" : "audible")"
    }

    /// The main window, once: its content size under `-uitest-window-size`,
    /// and its first responder in `debug.focus` from then on.
    static func configure(_ window: NSWindow) {
        guard UITestHooks.isUITestLaunch else { return }
        if let size = UITestHooks.windowSize {
            window.setContentSize(size)
            window.center()
        }
        MacDebugProbes.shared.watch(window)
    }

    /// What `debug.focus` says for a first responder: "none", "window",
    /// "text.editable", "text.selectable", the responder's accessibility
    /// identifier when it has one, or else its class.
    static func focusDescription(_ responder: NSResponder?, in window: NSWindow?) -> String {
        guard let responder else { return "none" }
        if responder === window { return "window" }
        if let text = responder as? NSText { return text.isEditable ? "text.editable" : "text.selectable" }
        if let view = responder as? NSView, !view.accessibilityIdentifier().isEmpty {
            return view.accessibilityIdentifier()
        }
        return String(describing: type(of: responder))
    }
}

/// The probes' live values, observed by `MacDebugProbeOverlay`.
@MainActor
final class MacDebugProbes: ObservableObject {
    static let shared = MacDebugProbes()

    @Published fileprivate(set) var beeps = 0
    @Published private(set) var focus = "none"
    private var observation: NSKeyValueObservation?

    fileprivate func watch(_ window: NSWindow) {
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.focus = MacTestSilence.focusDescription(window.firstResponder, in: window)
            }
        }
    }
}

/// UI-test launches only: the Mac probes beside the shared ones (what
/// VoiceOver heard). One point each, never hit-testable.
struct MacDebugProbeOverlay: View {
    @ObservedObject private var probes = MacDebugProbes.shared

    var body: some View {
        if UITestHooks.isUITestLaunch {
            ZStack {
                probe("Identity", value: MacTestSilence.identity, identifier: "debug.identity")
                probe("Beeps", value: String(probes.beeps), identifier: "debug.beeps")
                probe("Focus", value: probes.focus, identifier: "debug.focus")
                UITestProbeOverlay()
            }
            .allowsHitTesting(false)
        }
    }

    /// The constant label keeps SwiftUI from dropping an element that has
    /// nothing visible to say.
    private func probe(_ label: String, value: String, identifier: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}
#endif
