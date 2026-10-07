import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The color and font types the shared theme and reader name, and the one
// way a token resolves for light, dark and Increase Contrast. (R1, R5)

#if os(iOS)
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont

extension PlatformColor {
    /// A color that resolves per appearance: `dark` for Dark Mode,
    /// `highContrast` for Increase Contrast.
    static func dynamic(_ resolve: @escaping (_ dark: Bool, _ highContrast: Bool) -> PlatformColor) -> Color {
        Color(uiColor: UIColor { trait in
            resolve(trait.userInterfaceStyle == .dark, trait.accessibilityContrast == .high)
        })
    }
}

enum PlatformScreen {
    /// One physical pixel on the main screen, for code with no view to ask.
    /// Views use `hairlineHeight()`, which reads `displayScale`.
    static var hairline: CGFloat {
        1 / max(UIScreen.main.scale, 1)
    }
}
#elseif os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont

extension PlatformColor {
    /// A color that resolves per appearance: `dark` for Dark Mode,
    /// `highContrast` for Increase Contrast. AppKit asks the provider again
    /// whenever the drawing appearance changes, so `NSApp.appearance` and
    /// the system settings both reach it.
    static func dynamic(_ resolve: @escaping (_ dark: Bool, _ highContrast: Bool) -> PlatformColor) -> Color {
        Color(nsColor: dynamicColor(resolve))
    }

    /// `dynamic`'s color before SwiftUI wraps it, for AppKit callers.
    static func dynamicColor(_ resolve: @escaping (_ dark: Bool, _ highContrast: Bool) -> PlatformColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let look = look(matching: appearance.bestMatch(from: lookNames))
            return resolve(look.dark, look.highContrast)
        }
    }

    /// The four looks a token tells apart. Increase Contrast reaches an
    /// appearance only as a best match: `NSAppearance(named:)` hands back
    /// plain Aqua or Dark Aqua for the two high-contrast names.
    static let lookNames: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// What a best match among `lookNames` means for a token. No match
    /// reads as light, as an unspecified trait does on the iPhone.
    static func look(matching name: NSAppearance.Name?) -> (dark: Bool, highContrast: Bool) {
        (dark: name == .darkAqua || name == .accessibilityHighContrastDarkAqua,
         highContrast: name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua)
    }
}

enum PlatformScreen {
    /// One physical pixel on the main screen, for code with no view to ask.
    /// Views use `hairlineHeight()`, which reads `displayScale` (it follows the
    /// window's screen). Retina when no screen is attached.
    static var hairline: CGFloat {
        1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1)
    }
}
#endif

extension PlatformScreen {
    /// One physical pixel at `scale`, a view's `displayScale`.
    static func hairline(scale: CGFloat) -> CGFloat {
        1 / max(scale, 1)
    }
}

extension View {
    /// Sizes a rule one physical pixel tall on the screen it is drawn on.
    /// `displayScale` follows the window's screen and redraws the rule when
    /// it moves; the main screen's (`PlatformScreen.hairline`) may be the
    /// other display of a Mac with a Retina and a 1x one.
    func hairlineHeight() -> some View {
        modifier(HairlineHeight())
    }
}

private struct HairlineHeight: ViewModifier {
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.frame(height: PlatformScreen.hairline(scale: displayScale))
    }
}

/// A capsule's hairline border, one physical pixel on the screen it is
/// drawn on (`hairlineHeight()`).
struct HairlineCapsuleBorder: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Capsule().strokeBorder(Theme.Stroke.hairlineColor, lineWidth: PlatformScreen.hairline(scale: displayScale))
    }
}
