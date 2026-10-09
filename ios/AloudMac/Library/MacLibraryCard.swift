import SwiftUI

/// One book in the Library grid: the shared card (the 2:3 cover, the serif
/// title, the author and the listening line) as a button. One click opens
/// the book and plays it (R4); Return or Space does the same for a card
/// with keyboard focus. Hover draws a Theme.bgTint plate behind it and
/// nothing moves. Right-click gives Open, Rename…, Mark as Finished and
/// Delete…; Edit ▸ Rename Book…, Mark as Finished and Delete Book… (⌘⌫)
/// act on a focused card's book, so the keyboard reaches all three (L014);
/// VoiceOver gets the same three management actions under the iPhone's
/// names (R12g).
struct MacLibraryCard: View {
    let document: LibraryDocument
    let rate: Double
    let coverWidth: CGFloat
    let onOpen: () -> Void
    let perform: (DocumentAction) -> Void

    var body: some View {
        Button(action: onOpen) {
            DocumentCardView(document: document, rate: rate)
                .frame(width: coverWidth, alignment: .leading)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.md, outset: MacGridMetrics.plateOutset))
        // A focused button takes Space; Return opens it too (mac-ux §3.2).
        .onKeyPress(.return) {
            onOpen()
            return .handled
        }
        // A Finished book opens paused at its end, so it promises nothing.
        .accessibilityHint(document.isFinished ? "" : "Opens and starts reading aloud")
        .accessibilityInputLabels(DocumentCardView.inputLabels(for: document))
        .accessibilityIdentifier("library.card")
        .accessibilityActions {
            MacDocumentActions(document: document, perform: perform)
        }
        .contextMenu {
            MacDocumentMenu(document: document, onOpen: onOpen, perform: perform)
        }
        .macBookCommands(for: document, perform: perform)
    }
}

extension View {
    /// Edit ▸ Rename Book…, Mark as Finished and Delete Book… (⌘⌫) act on
    /// the book whose card has keyboard focus, a grid card or the Continue
    /// card alike. Mark as Finished only while the book has something left
    /// to mark, and Mark as Unfinished in its place once it is Finished, as
    /// its context menu offers them.
    func macBookCommands(for document: LibraryDocument,
                         perform: @escaping (DocumentAction) -> Void) -> some View {
        let available = DocumentAction.available(for: document)
        let markFinished: (() -> Void)? = available.contains(.markFinished)
            ? { perform(.markFinished) } : nil
        let markUnfinished: (() -> Void)? = available.contains(.markUnfinished)
            ? { perform(.markUnfinished) } : nil
        return focusedValue(\.macRenameBook) { perform(.rename) }
            .focusedValue(\.macMarkFinished, markFinished)
            .focusedValue(\.macMarkUnfinished, markUnfinished)
            .focusedValue(\.macDeleteBook) { perform(.delete) }
    }
}

// MARK: - Menu

extension DocumentAction {
    /// The Mac's menu wording of `title`: Apple's title case, with an
    /// ellipsis where the item asks something before it acts.
    var menuTitle: String {
        switch self {
        case .rename: return "Rename\u{2026}"
        // The shared title, already in Apple's title case: the iPhone's card
        // menu, this one and the menu bar (`MacMenuCopy`) agree.
        case .markFinished, .markUnfinished: return title
        case .delete: return "Delete\u{2026}"
        }
    }
}

/// A book's context menu, on a grid card and the Continue card alike: Open,
/// then, while that open would start the voice, the open that doesn't
/// (R4-10, as the iPhone's card menu offers it), then the shared
/// `DocumentAction` list, with Delete… set apart.
struct MacDocumentMenu: View {
    let document: LibraryDocument
    let onOpen: () -> Void
    let perform: (DocumentAction) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    /// Observed here rather than read through the model, so the silent open
    /// comes and goes as the voice starts and stops: the library itself
    /// observes only which book is open.
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        Button("Open", action: onOpen)
        if playback.opensPlaying(document) {
            Button(OpenMenuItem.silentTitle) {
                // The library's own open, less the autoplay request.
                model.continuePlayback.readerOpens(document.id)
                router.open(document, autoplay: false)
            }
        }
        ForEach(DocumentAction.available(for: document), id: \.self) { action in
            if action == .delete { Divider() }
            Button(action.menuTitle, role: action.role) { perform(action) }
        }
    }
}

/// A book's VoiceOver actions, on a grid card and the Continue card alike:
/// the shared `DocumentAction` list under the iPhone's names (R12g). No
/// Open: the card's own press opens it. The menu's wording is
/// `MacDocumentMenu`'s alone (J018).
struct MacDocumentActions: View {
    let document: LibraryDocument
    let perform: (DocumentAction) -> Void

    var body: some View {
        ForEach(DocumentAction.available(for: document), id: \.self) { action in
            Button(action.title) { perform(action) }
        }
    }
}

// MARK: - Hover plate

/// The Mac's hover for a card or a row: a Theme.bgTint plate fades in
/// behind the label over Motion.press, reaching `outset` past it, and a
/// press deepens it to surface2. No lift, no shadow, no scale: hover never
/// moves layout. The whole label is the click target, and the system draws
/// the focus ring under keyboard navigation.
struct MacHoverPlateStyle: ButtonStyle {
    var radius: CGFloat
    var outset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        Plated(configuration: configuration, radius: radius, outset: outset)
    }

    private struct Plated: View {
        let configuration: Configuration
        let radius: CGFloat
        let outset: CGFloat

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(configuration.isPressed ? Theme.surface2 : Theme.bgTint)
                        .padding(-outset)
                        .opacity(isHovered || configuration.isPressed ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: Theme.Motion.press), value: isHovered)
                .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
        }
    }
}

/// The same plate behind a view that isn't itself one button (the Continue
/// card holds two).
struct MacHoverPlate: ViewModifier {
    var radius: CGFloat
    var outset: CGFloat = 0

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.bgTint)
                    .padding(-outset)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: Theme.Motion.press), value: isHovered)
    }
}
