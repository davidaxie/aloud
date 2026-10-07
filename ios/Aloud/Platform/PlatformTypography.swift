import CoreGraphics
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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

    /// The Bold Text setting now, for chrome that has no traits to hand
    /// (`Theme.BoldText`).
    static var isBoldTextOn: Bool { UIAccessibility.isBoldTextEnabled }

    /// Posted on the default center when Bold Text changes.
    static let boldTextDidChange: Notification.Name? = UIAccessibility.boldTextStatusDidChangeNotification
}
#elseif os(macOS)
extension PlatformFont {
    /// The installed face called `name`, or nil.
    static func named(_ name: String, size: CGFloat) -> PlatformFont? {
        NSFont(name: name, size: size)
    }

    static func exists(named name: String) -> Bool {
        NSFont(name: name, size: 17) != nil
    }
}

/// Faces derived from a font through its descriptor, so they stay in its
/// family.
enum PlatformFontTraits {
    /// The family's bold face, or nil when it has none.
    static func bold(_ font: PlatformFont) -> PlatformFont? {
        adding(.bold, to: font)
    }

    /// The family's italic face, or nil when it has none.
    static func italic(_ font: PlatformFont) -> PlatformFont? {
        adding(.italic, to: font)
    }

    /// Lowercase set in small caps; numerals and capitals stay full size.
    static func smallCaps(_ font: PlatformFont) -> PlatformFont {
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kLowerCaseType,
            .selectorIdentifier: kLowerCaseSmallCapsSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        // AppKit's init can fail where UIKit's can't; the face stays as it was.
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// AppKit always hands back a descriptor, and matching may land on the
    /// regular face, so the derived face must carry the trait to count.
    private static func adding(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont? {
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(trait))
        guard let derived = NSFont(descriptor: descriptor, size: font.pointSize),
              derived.fontDescriptor.symbolicTraits.contains(trait)
        else { return nil }
        return derived
    }
}

enum PlatformRuleImage {
    /// A solid rule for a text attachment. `color` is already resolved for
    /// the appearance (the reader rebuilds when it flips). AppKit runs the
    /// drawing handler at each backing store's own scale, so `scale` has
    /// nothing to set here.
    static func make(size: CGSize, color: PlatformColor, scale: CGFloat) -> PlatformImage {
        NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }
}

enum PlatformLegibility {
    /// macOS has no Bold Text setting, so the column is always regular.
    static func isBold(_ appearance: NSAppearance) -> Bool {
        false
    }

    static var isBoldTextOn: Bool { false }

    static let boldTextDidChange: Notification.Name? = nil
}
#endif
