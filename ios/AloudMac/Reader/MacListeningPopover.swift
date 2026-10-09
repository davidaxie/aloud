import SwiftUI

/// Voice and speed, from the player bar's voice · speed chip (M10, mac-ux
/// §3.9): a popover on paper, 340 wide, holding the shared `ListeningView`,
/// the same view as Settings' "Voice & speed" tab. The speed controls stay
/// pinned under the title and the voice list below them sizes to its
/// content, up to 560 high in all, and scrolls beyond, opening scrolled to
/// the selected voice. A voice pick re-speaks the current sentence and the popover stays
/// open; Esc or a click outside closes it, and focus returns to the chip.
struct MacListeningPopover: View {

    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 560

    /// Seeded near the default layout so the first frame barely moves.
    @State private var headerHeight: CGFloat = 44
    @State private var contentHeight: CGFloat = 320
    /// The pinned speed block, with its hairline: the presets' row and the
    /// speed track's row with their spacing and padding (no numeral below
    /// the accessibility sizes, R3-10), so the first frame barely moves.
    @State private var pinnedHeight: CGFloat = 125

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

            ListeningView(pinsSpeed: true,
                          onContentHeight: { contentHeight = $0 },
                          onPinnedHeight: { pinnedHeight = $0 })
                .frame(height: pinnedHeight
                       + Self.listHeight(content: contentHeight, header: headerHeight, pinned: pinnedHeight))
        }
        .frame(width: Self.width)
        // Paper, not the popover's material.
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
    }

    /// The voice list's height: its content, within what the cap leaves
    /// under the title and the pinned speed controls.
    static func listHeight(content: CGFloat, header: CGFloat, pinned: CGFloat = 0) -> CGFloat {
        max(min(content, maxHeight - header - pinned), 0)
    }
}
