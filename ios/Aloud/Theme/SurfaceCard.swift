import SwiftUI

/// The app's one card (R4-27): surface ground, a continuous `Radius.lg`
/// corner and a 1 pt border, the corner of the Continue card, the download
/// card and the Aa sheet's groups. Settings' groups and the Licenses cards
/// draw it. What the card holds is clipped to its corner, so a pressed
/// row's highlight never squares it off.
struct SurfaceCard: ViewModifier {

    static let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: Self.shape)
            .clipShape(Self.shape)
            .overlay(Self.shape.strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
    }
}

extension View {
    /// Draws the view as a card (`SurfaceCard`).
    func surfaceCard() -> some View {
        modifier(SurfaceCard())
    }
}

/// The rule between two rows of a card: the border's weight and colour,
/// inset to the rows' text, so it reads as quietly as the card's edge.
struct SurfaceCardSeparator: View {

    var inset: CGFloat = Theme.Space.md

    var body: some View {
        Rectangle()
            .fill(Theme.Stroke.borderColor)
            .frame(height: Theme.Stroke.borderWidth)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A card row's press (R4-27): the row's whole width fills with surface2,
/// the unselected chips' fill, where a system list row drew its own grey.
/// No fade and no scale: the row stays put under the finger.
struct SurfaceCardRowStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Color.clear)
    }
}
