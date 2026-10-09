import SwiftUI
#if os(iOS)
import UIKit
#endif

// The system's prompt-free paste, for the Library's link row
// (`ShelfLinks.pasteControl`). Here because only the iPhone has one: the
// Mac pastes with ⌘V and never hands the row an `onPaste`.

#if os(iOS)
/// UIKit's secure paste control, dressed as one of the shelf's text links:
/// label only, a capsule in the page's own ground, accent text. It reads
/// the clipboard on the listener's tap with no Allow Paste prompt.
///
/// SwiftUI's `PasteButton` keeps its intrinsic ~34 pt height inside any
/// frame and its own white label, so it darkened its fill to grey to keep
/// that label legible and read as disabled. This control takes the frame
/// it is given (`sizeThatFits`), so its target is a full 44 pt, and its
/// colours are the sibling links' own pair (about 5.5:1).
struct PlatformPasteControl: UIViewRepresentable {
    /// Takes the pasted strings, on the main actor.
    let onPaste: ([String]) -> Void
    /// The control's accessibility identifier, set on the UIKit view.
    let identifier: String

    func makeCoordinator() -> Coordinator { Coordinator(onPaste: onPaste) }

    func makeUIView(context: Context) -> PasteControlHost {
        let host = PasteControlHost()
        install(in: host, context: context)
        return host
    }

    func updateUIView(_ host: PasteControlHost, context: Context) {
        context.coordinator.onPaste = onPaste
        // Dark mode or Increase Contrast changed: a control built with the
        // new colours replaces the old one, whose configuration is fixed
        // once it is made.
        if Look(context.environment) != context.coordinator.look {
            install(in: host, context: context)
        } else {
            host.control?.accessibilityIdentifier = identifier
        }
    }

    /// Wide enough for its label and the links' side padding, never under
    /// 44 pt either way; the control draws in the whole frame, so the
    /// target measures what the row lays out, and `ViewThatFits` sees an
    /// honest ideal width.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: PasteControlHost, context: Context) -> CGSize? {
        let i = host.control?.intrinsicContentSize ?? .zero
        return CGSize(width: min(max(i.width + 2 * Theme.Space.sm, 44), proposal.width ?? .infinity),
                      height: max(44, i.height))
    }

    /// A control for the environment's look, in place of any before it.
    private func install(in host: PasteControlHost, context: Context) {
        let look = Look(context.environment)
        context.coordinator.look = look
        let control = UIPasteControl(configuration: Self.configuration(for: look))
        control.target = context.coordinator
        control.accessibilityIdentifier = identifier
        control.accessibilityHint = PasteTextAction.controlHint
        host.show(control)
    }

    /// Label only, a capsule, the page's ground and the links' accent ink,
    /// resolved for `look` (the in-app appearance and Increase Contrast).
    static func configuration(for look: Look) -> UIPasteControl.Configuration {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = look.dark ? .dark : .light
            traits.accessibilityContrast = look.highContrast ? .high : .normal
        }
        let c = UIPasteControl.Configuration()
        c.displayMode = .labelOnly
        c.cornerStyle = .capsule
        c.baseBackgroundColor = UIColor(Theme.bg).resolvedColor(with: traits)
        c.baseForegroundColor = UIColor(Theme.accentStrong).resolvedColor(with: traits)
        return c
    }

    /// What the control's colours resolve against.
    struct Look: Equatable {
        let dark: Bool
        let highContrast: Bool

        init(_ environment: EnvironmentValues) {
            dark = environment.colorScheme == .dark
            highContrast = environment.colorSchemeContrast == .increased
        }
    }

    /// The control's target: accepts text and hands it on.
    final class Coordinator: UIResponder {
        var onPaste: ([String]) -> Void
        /// The look the current control was built for.
        var look: Look?

        init(onPaste: @escaping ([String]) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
        }

        /// Each provider's text, in order; empty ones are dropped, and a
        /// paste that found none adds nothing. Handed over on the main
        /// actor, whichever queue the providers answer on: the add
        /// publishes to the shelf.
        override func paste(itemProviders: [NSItemProvider]) {
            Task { @MainActor [weak self] in
                var strings: [String] = []
                for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
                    if let text = await Self.loadString(from: provider), !text.isEmpty {
                        strings.append(text)
                    }
                }
                guard let self, !strings.isEmpty else { return }
                self.onPaste(strings)
            }
        }

        private static func loadString(from provider: NSItemProvider) async -> String? {
            await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: (object as? NSString).map(String.init))
                }
            }
        }
    }
}

/// Holds the one paste control, pinned to its edges, so a change of look
/// can swap in a new control (`PlatformPasteControl.install`).
final class PasteControlHost: UIView {
    private(set) var control: UIPasteControl?

    func show(_ next: UIPasteControl) {
        control?.removeFromSuperview()
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        control = next
        invalidateIntrinsicContentSize()
    }
}
#else
/// The Mac pastes with ⌘V: its rows never hand over an `onPaste`, so
/// there is no control to draw.
struct PlatformPasteControl: View {
    let onPaste: ([String]) -> Void
    let identifier: String

    var body: some View { EmptyView() }
}
#endif
