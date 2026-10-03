import CoreGraphics
#if os(iOS)
import UIKit
#endif

// The reader's font faces and rule images, built the same way on each
// platform. (R2)

#if os(iOS)
extension PlatformFont {
    /// The installed face called `name`, or nil.
    static func named(_ name: String, size: CGFloat) -> PlatformFont? {
        UIFont(name: name, size: size)
    }

    static func exists(named name: String) -> Bool {
        UIFont(name: name, size: 17) != nil
    }
}

/// Faces derived from a font through its descriptor, so they stay in its
/// family.
enum PlatformFontTraits {
    /// The family's bold face, or nil when it has none.
    static func bold(_ font: PlatformFont) -> PlatformFont? {
        adding(.traitBold, to: font)
    }

    /// The family's italic face, or nil when it has none.
    static func italic(_ font: PlatformFont) -> PlatformFont? {
        adding(.traitItalic, to: font)
    }

    /// Lowercase set in small caps; numerals and capitals stay full size.
    static func smallCaps(_ font: PlatformFont) -> PlatformFont {
        let features: [[UIFontDescriptor.FeatureKey: Int]] = [[
            .type: kLowerCaseType,
            .selector: kLowerCaseSmallCapsSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func adding(_ trait: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont? {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(trait))
        else { return nil }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

enum PlatformRuleImage {
    /// A solid rule for a text attachment. `color` is already resolved for
    /// the appearance (the reader rebuilds when it flips); `scale` is the
    /// display's, at least 1.
    static func make(size: CGSize, color: PlatformColor, scale: CGFloat) -> PlatformImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

enum PlatformLegibility {
    /// The system Bold Text setting, as these traits carry it.
    static func isBold(_ traits: UITraitCollection) -> Bool {
        traits.legibilityWeight == .bold
    }
}
#endif
