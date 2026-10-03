import SwiftUI
import UIKit
import XCTest
@testable import Aloud

/// The theme's text colors stay legible on every ground they are set on
/// (WCAG AA, 4.5:1) in light, dark and Increase Contrast, and Increase
/// Contrast lifts `textMuted` to 7:1 on the solid grounds. Each token is
/// resolved the way the app resolves it, as a `PlatformColor` under the
/// appearance's traits; translucent grounds are composited over the ground
/// beneath them first.
final class ThemeTokenContrastTests: XCTestCase {

    private struct Appearance: CustomStringConvertible {
        let dark: Bool
        let highContrast: Bool

        static let all = [false, true].flatMap { highContrast in
            [false, true].map { Appearance(dark: $0, highContrast: highContrast) }
        }

        var description: String {
            (dark ? "dark" : "light") + (highContrast ? " + Increase Contrast" : "")
        }
    }

    /// Gamma-encoded sRGB components, as the color draws.
    private struct RGBA {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0

        /// `self` drawn over an opaque `ground` (source-over, in sRGB).
        func over(_ ground: RGBA) -> RGBA {
            func mix(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat { top * alpha + bottom * (1 - alpha) }
            return RGBA(red: mix(red, ground.red), green: mix(green, ground.green),
                        blue: mix(blue, ground.blue), alpha: 1)
        }

        /// WCAG relative luminance.
        var luminance: CGFloat {
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    private func resolve(_ token: Color, _ appearance: Appearance) -> RGBA {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.dark ? .dark : .light
            traits.accessibilityContrast = appearance.highContrast ? .high : .normal
        }
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        PlatformColor(token).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The contrast of `text` on `ground`, where `ground` may be translucent
    /// over `beneath` (an opaque token).
    private func contrast(_ text: Color, on ground: Color, over beneath: Color? = nil,
                          _ appearance: Appearance) -> CGFloat {
        var bottom = resolve(ground, appearance)
        if let beneath { bottom = bottom.over(resolve(beneath, appearance)) }
        let top = resolve(text, appearance).over(bottom)
        let (lighter, darker) = (max(top.luminance, bottom.luminance), min(top.luminance, bottom.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static let solidGrounds: [(name: String, color: Color)] = [
        ("bg", Theme.bg), ("bgTint", Theme.bgTint), ("surface", Theme.surface), ("surface2", Theme.surface2),
    ]

    /// Every color text is set in on a solid ground.
    private static let textColors: [(name: String, color: Color)] = [
        ("text", Theme.text), ("textMuted", Theme.textMuted), ("textFaint", Theme.textFaint),
        ("accentStrong", Theme.accentStrong),
    ]

    // MARK: Resolution

    /// The resolver really sees each appearance (otherwise every ratio
    /// below would be the light one four times).
    func testTokensResolvePerAppearance() {
        func hex(_ c: RGBA) -> UInt32 {
            [c.red, c.green, c.blue].reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
        }
        let light = Appearance(dark: false, highContrast: false)
        let dark = Appearance(dark: true, highContrast: false)
        let lightHigh = Appearance(dark: false, highContrast: true)
        let darkHigh = Appearance(dark: true, highContrast: true)

        XCTAssertEqual(hex(resolve(Theme.bg, light)), 0xFBF8F2)
        XCTAssertEqual(hex(resolve(Theme.bg, dark)), 0x14100A)
        XCTAssertEqual(hex(resolve(Theme.bg, darkHigh)), 0x14100A)
        XCTAssertEqual(hex(resolve(Theme.textMuted, light)), 0x6A5B45)
        XCTAssertEqual(hex(resolve(Theme.textMuted, dark)), 0xA99A7C)
        XCTAssertEqual(hex(resolve(Theme.textMuted, lightHigh)), 0x5A4A34)
        XCTAssertEqual(hex(resolve(Theme.textMuted, darkHigh)), 0xC2B497)
        XCTAssertEqual(resolve(Theme.highlightBg, light).alpha, 0.26, accuracy: 0.001)
        XCTAssertEqual(resolve(Theme.highlightBg, dark).alpha, 0.28, accuracy: 0.001)
        XCTAssertEqual(resolve(Theme.highlightBg, lightHigh).alpha, 0.34, accuracy: 0.001)
        XCTAssertEqual(resolve(Theme.accentSoft, darkHigh).alpha, 0.20, accuracy: 0.001)
    }

    // MARK: AA everywhere

    func testTextColorsClearAAOnEverySolidGround() {
        for appearance in Appearance.all {
            for text in Self.textColors {
                for ground in Self.solidGrounds {
                    let ratio = contrast(text.color, on: ground.color, appearance)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text.name) on \(ground.name), \(appearance): "
                                                + String(format: "%.2f:1", ratio))
                }
            }
        }
    }

    /// Text on the tinted and filled grounds, each where the app sets it.
    func testTextOnTintedAndFilledGroundsClearsAA() {
        let pairs: [(name: String, text: Color, ground: Color, beneath: Color?)] = [
            // A filled button's label (the download card).
            ("bg on accentStrong", Theme.bg, Theme.accentStrong, nil),
            // The reader's sentence fill on the page.
            ("text on highlightBg over bg", Theme.text, Theme.highlightBg, Theme.bg),
            // The cover's tonal ground.
            ("textMuted on accentSoft over surface", Theme.textMuted, Theme.accentSoft, Theme.surface),
            // Selected chips: Listening and the player bar sit on surface,
            // the Appearance sheet's segments on surface2.
            ("accentStrong on accentSoft over surface", Theme.accentStrong, Theme.accentSoft, Theme.surface),
            ("accentStrong on accentSoft over surface2", Theme.accentStrong, Theme.accentSoft, Theme.surface2),
        ]
        for appearance in Appearance.all {
            for pair in pairs {
                let ratio = contrast(pair.text, on: pair.ground, over: pair.beneath, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(pair.name), \(appearance): "
                                            + String(format: "%.2f:1", ratio))
            }
        }
    }

    // MARK: Increase Contrast

    func testIncreaseContrastLiftsTextMutedToSevenToOne() {
        for appearance in Appearance.all where appearance.highContrast {
            for ground in Self.solidGrounds {
                let ratio = contrast(Theme.textMuted, on: ground.color, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 7, "textMuted on \(ground.name), \(appearance): "
                                            + String(format: "%.2f:1", ratio))
            }
        }
    }
}
