import SwiftUI

/// The reader toolbar's Aa popover (mac-ux §3.11): the shared Mac text and
/// appearance view on paper, 300 wide, under its title. Esc or a click
/// outside closes it, and focus returns to Aa.
struct MacAppearancePopover: View {

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(AppearanceCopy.title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("appearance.title")
            MacTextAppearanceView()
        }
        .padding(Theme.Space.lg)
        .frame(width: Self.width)
        // Paper, not the popover's material.
        .background(Theme.surface)
        .presentationBackground(Theme.surface)
    }
}
