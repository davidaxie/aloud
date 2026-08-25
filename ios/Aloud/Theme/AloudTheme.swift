import SwiftUI
import UIKit

/// Semantic design tokens. Views consume these exclusively — never raw colors.
/// Single-hue discipline ("Bronze", hue ~35°): the accent family is aged brass
/// on sepia paper, and every neutral is a hue-tinted warm gray. No gradients.
enum Theme {

    // MARK: Surfaces

    static let bg = dynamic(light: 0xFBF8F2, dark: 0x14100A)
    static let bgTint = dynamic(light: 0xF3EDE1, dark: 0x1C1710)
    static let surface = dynamic(light: 0xFEFCF8, dark: 0x1A150E)
    static let surface2 = dynamic(light: 0xF6F0E5, dark: 0x231D13)

    // MARK: Text

    static let text = dynamic(light: 0x261D10, dark: 0xF1E9DA)
    static let textMuted = dynamic(light: 0x7B6A50, dark: 0xA99A7C)
    static let textFaint = dynamic(light: 0xAB9C7E, dark: 0x6F6450)

    // MARK: Lines

    static let line = dynamic(light: 0xE9E1D0, dark: 0x2B2417)
    static let lineStrong = dynamic(light: 0xD7CBB1, dark: 0x3E3423)

    // MARK: Accent family (one hue only)

    static let accent = dynamic(light: 0xA87434, dark: 0xC99A5B)
    static let accentStrong = dynamic(light: 0x8A5B22, dark: 0xE0B478)
    static let accentSoft = dynamic(light: 0xA87434, dark: 0xC99A5B,
                                    lightAlpha: 0.12, darkAlpha: 0.20)
    static let highlightBg = dynamic(light: 0xA87434, dark: 0xC99A5B,
                                     lightAlpha: 0.16, darkAlpha: 0.17)
    static let highlightText = dynamic(light: 0x261D10, dark: 0xF6EFDF)

    // MARK: Typography

    /// Reading typeface: Iowan Old Style (ships with iOS), Georgia fallback.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(serifFamilyName, size: size).weight(weight)
    }

    /// UI chrome typeface: system (SF Pro).
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let serifFamilyName: String = {
        UIFont(name: "Iowan Old Style", size: 17) != nil ? "Iowan Old Style" : "Georgia"
    }()

    // MARK: Radii

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 26
    }

    // MARK: Private

    private static func dynamic(light: UInt32, dark: UInt32,
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: dark, alpha: darkAlpha)
                : UIColor(rgb: light, alpha: lightAlpha)
        })
    }
}

/// Solid accent circle (floating +, play). Darkens to `accentStrong` while
/// pressed and settles with a slight scale — no opacity flash.
struct AccentCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(configuration.isPressed ? Theme.accentStrong : Theme.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Solid accent capsule (primary text actions, e.g. empty-state Import).
struct AccentCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(configuration.isPressed ? Theme.accentStrong : Theme.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}
