import SwiftUI

/// A book on the shelf pressed under a finger: a surface2 plate behind it,
/// reaching `outset` past it on every side, and the book a touch smaller,
/// eased over `Motion.press`. At rest nothing is drawn. The plate is a
/// background pulled out by negative padding, so it takes no layout and
/// nothing beside the card moves; no opacity changes, so the cover never
/// dims. Under Reduce Motion the plate shows without the scale, and so
/// does a card with `scales` off: the Continue card, whose play circle is
/// placed from outside the button and would stay full size over a body
/// shrinking under it. The iPhone's answer to the Mac's hover plate
/// (`MacHoverPlateStyle`), which the Mac keeps (`shelfCardPressStyle()`).
struct ShelfPlateButtonStyle: ButtonStyle {
    var radius: CGFloat = Theme.Radius.md
    var outset: CGFloat = Theme.Space.xs
    /// Whether the pressed book draws a touch smaller; off, the plate alone.
    var scales = true

    /// How small a pressed book draws.
    static let pressedScale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        Plated(isPressed: configuration.isPressed, radius: radius, outset: outset, scales: scales) {
            configuration.label
        }
    }

    /// The pressed and resting faces, apart from the gesture, so a test can
    /// build either one.
    struct Plated<Label: View>: View {
        let isPressed: Bool
        let radius: CGFloat
        let outset: CGFloat
        let scales: Bool
        private let label: Label

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        init(isPressed: Bool, radius: CGFloat = Theme.Radius.md, outset: CGFloat = Theme.Space.xs,
             scales: Bool = true, @ViewBuilder label: () -> Label) {
            self.isPressed = isPressed
            self.radius = radius
            self.outset = outset
            self.scales = scales
            self.label = label()
        }

        var body: some View {
            label
                .scaleEffect(ShelfPlateButtonStyle.scale(isPressed: isPressed && scales,
                                                         reduceMotion: reduceMotion))
                .background {
                    if ShelfPlateButtonStyle.drawsPlate(isPressed: isPressed) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Theme.surface2)
                            .padding(-outset)
                            .accessibilityHidden(true)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.press), value: isPressed)
        }
    }

    /// The plate shows only while pressed.
    static func drawsPlate(isPressed: Bool) -> Bool { isPressed }

    /// A pressed book draws at `pressedScale`, except under Reduce Motion.
    static func scale(isPressed: Bool, reduceMotion: Bool) -> CGFloat {
        isPressed && !reduceMotion ? pressedScale : 1
    }
}
