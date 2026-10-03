import SwiftUI
#if os(iOS)
import UIKit
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
    /// Views read `@Environment(\.displayScale)` instead.
    static var hairline: CGFloat {
        1 / max(UIScreen.main.scale, 1)
    }
}
#endif
