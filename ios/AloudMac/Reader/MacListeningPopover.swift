import SwiftUI

/// Voice and speed, from the player bar's voice · speed chip (M10, mac-ux
/// §3.9): a popover on paper, 340 wide, holding the shared `ListeningView`,
/// the same view as Settings' "Voice & speed" tab. It sizes to its content
/// up to 560 high and scrolls beyond, opening scrolled to the selected
/// voice. A voice pick re-speaks the current sentence and the popover stays
/// open; Esc or a click outside closes it, and focus returns to the chip.
struct MacListeningPopover: View {

    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 560

    /// Seeded near the default layout so the first frame barely moves.
    @State private var headerHeight: CGFloat = 44
    @State private var contentHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the list: the title never scrolls away.
            Text(ListeningCopy.title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("listening.title")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    headerHeight = height
                }

            ListeningView(onContentHeight: { contentHeight = $0 })
                .frame(height: Self.listHeight(content: contentHeight, header: headerHeight))
        }
        .frame(width: Self.width)
        // Paper, not the popover's material.
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
    }

    /// The list's height: its content, within what the cap leaves under
    /// the title.
    static func listHeight(content: CGFloat, header: CGFloat) -> CGFloat {
        max(min(content, maxHeight - header), 0)
    }
}
