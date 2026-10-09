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

    /// Control edges (chips, the stepper card, capsules) reach the 3:1
    /// non-text minimum on every solid ground under Increase Contrast.
    func testIncreaseContrastTakesEdgesToThreeToOne() {
        for appearance in Appearance.all where appearance.highContrast {
            for edge in [("line", Theme.line), ("lineStrong", Theme.lineStrong)] {
                for ground in Self.solidGrounds {
                    let ratio = contrast(edge.1, on: ground.color, appearance)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(edge.0) on \(ground.name), \(appearance): "
                                                + String(format: "%.2f:1", ratio))
                }
            }
        }
    }

    /// A selected option (an Appearance segment, a speed preset) differed
    /// from its neighbours only by a 12% `accentSoft` tint, 1.14:1 (H056).
    /// Its edge (`Stroke.selectedColor`, `accentStrong`) is drawn in every
    /// appearance now, not only under Increase Contrast (R1-46), and
    /// reaches 3:1 on every solid ground and on the fill itself.
    func testTheSelectedOptionIsAlwaysEdged() {
        for appearance in Appearance.all {
            XCTAssertEqual(resolve(Theme.Stroke.selectedColor, appearance).alpha, 1, accuracy: 0.001,
                           "the edge is opaque, \(appearance)")
            for ground in Self.solidGrounds {
                let onGround = contrast(Theme.Stroke.selectedColor, on: ground.color, appearance)
                XCTAssertGreaterThanOrEqual(onGround, 3, "selected edge on \(ground.name), \(appearance): "
                                            + String(format: "%.2f:1", onGround))
                let onFill = contrast(Theme.Stroke.selectedColor, on: Theme.accentSoft, over: ground.color, appearance)
                XCTAssertGreaterThanOrEqual(onFill, 3, "selected edge on accentSoft over \(ground.name), \(appearance): "
                                            + String(format: "%.2f:1", onFill))
            }
        }
    }

    // MARK: Scrub track (R1-45)

    /// The scrub's fill stays the 3:1 non-text minimum on its own track in
    /// every appearance (light is `track`, already 3.10:1).
    func testTheScrubFillStaysThreeToOneOnTheScrubTrack() {
        for appearance in Appearance.all {
            let ratio = contrast(Theme.accent, on: Theme.scrubTrack, appearance)
            XCTAssertGreaterThanOrEqual(ratio, 3, "accent on scrubTrack, \(appearance): "
                                        + String(format: "%.2f:1", ratio))
        }
    }

    /// In dark mode the unfilled scrub reads on the bar's surface at 0%
    /// (`track` there was 1.15:1, so the line vanished), with and without
    /// Increase Contrast.
    func testTheDarkScrubTrackReadsOnTheBar() {
        for appearance in Appearance.all where appearance.dark {
            let ratio = contrast(Theme.scrubTrack, on: Theme.surface, appearance)
            XCTAssertGreaterThanOrEqual(ratio, 1.5, "scrubTrack on surface, \(appearance): "
                                        + String(format: "%.2f:1", ratio))
            XCTAssertGreaterThan(ratio, contrast(Theme.track, on: Theme.surface, appearance),
                                 "lifted from track, \(appearance)")
        }
    }

    /// The scrub track's edge is clear by default and, under Increase
    /// Contrast, a 3:1 boundary on the grounds the bars sit on.
    func testIncreaseContrastEdgesTheScrubTrack() {
        for appearance in Appearance.all {
            guard appearance.highContrast else {
                XCTAssertEqual(resolve(Theme.trackEdge, appearance).alpha, 0, accuracy: 0.001, "\(appearance)")
                continue
            }
            for ground in [("surface", Theme.surface), ("bg", Theme.bg), ("bgTint", Theme.bgTint)] {
                let ratio = contrast(Theme.trackEdge, on: ground.1, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 3, "trackEdge on \(ground.0), \(appearance): "
                                            + String(format: "%.2f:1", ratio))
            }
        }
    }

    /// P041: Voice & speed and Text & appearance are pushed on the Settings
    /// root's bgTint. Their text tiers clear AA there (the solid-ground
    /// test), a voice row's 3 pt selection bar and a toggle's track keep the
    /// 3:1 non-text minimum, and the selected speed preset, drawn over
    /// surface2 on that page (its tint over bgTint alone is 4.41:1 in
    /// light), and the selected scheme segment clear AA.
    func testTheSettingsGroundKeepsItsSelectionsLegible() {
        for appearance in Appearance.all {
            let bar = contrast(Theme.accent, on: Theme.bgTint, appearance)
            XCTAssertGreaterThanOrEqual(bar, 3, "accent on bgTint, \(appearance): " + String(format: "%.2f:1", bar))
            let preset = contrast(Theme.accentStrong, on: Theme.accentSoft, over: Theme.surface2, appearance)
            XCTAssertGreaterThanOrEqual(preset, 4.5, "accentStrong on accentSoft over surface2, \(appearance): "
                                        + String(format: "%.2f:1", preset))
            for text in Self.textColors {
                let ratio = contrast(text.color, on: Theme.bgTint, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text.name) on bgTint, \(appearance): "
                                            + String(format: "%.2f:1", ratio))
            }
        }
    }

    /// A progress fill (`accent`) stays the 3:1 non-text minimum on its
    /// track in every appearance: the scrubs, cover progress, the download
    /// and import bars. On the Increase Contrast `line` it was 1.00:1.
    func testProgressFillStaysThreeToOneOnItsTrack() {
        for appearance in Appearance.all {
            let ratio = contrast(Theme.accent, on: Theme.track, appearance)
            XCTAssertGreaterThanOrEqual(ratio, 3, "accent on track, \(appearance): "
                                        + String(format: "%.2f:1", ratio))
        }
    }

    /// The disabled Download capsule's faint label on the track: Increase
    /// Contrast only raises it (on the Increase Contrast `line` it fell from
    /// 4.12:1 to 1.62:1), and it never drops under 4:1.
    func testTheDisabledDownloadLabelStaysLegibleOnTheTrack() {
        for dark in [false, true] {
            let normal = Appearance(dark: dark, highContrast: false)
            let high = Appearance(dark: dark, highContrast: true)
            let (before, after) = (contrast(Theme.textFaint, on: Theme.track, normal),
                                   contrast(Theme.textFaint, on: Theme.track, high))
            XCTAssertGreaterThanOrEqual(before, 4, "textFaint on track, \(normal): " + String(format: "%.2f:1", before))
            XCTAssertGreaterThan(after, before, "textFaint on track, \(high): " + String(format: "%.2f:1", after))
        }
    }

    /// Increase Contrast never lowers a ratio it is meant to raise: the
    /// word underline on the (darker) sentence fill, and the faint tier.
    func testIncreaseContrastNeverLowersTheUnderlineOrTheFaintTier() {
        func underline(_ appearance: Appearance) -> CGFloat {
            contrast(Theme.accentStrong, on: Theme.highlightBg, over: Theme.bg, appearance)
        }
        for dark in [false, true] {
            let normal = Appearance(dark: dark, highContrast: false)
            let high = Appearance(dark: dark, highContrast: true)
            XCTAssertGreaterThanOrEqual(underline(high), underline(normal),
                                        "the word underline on the sentence fill, \(high)")
            for ground in Self.solidGrounds {
                XCTAssertGreaterThan(contrast(Theme.textFaint, on: ground.color, high),
                                     contrast(Theme.textFaint, on: ground.color, normal),
                                     "textFaint on \(ground.name), \(high)")
                XCTAssertLessThan(contrast(Theme.textFaint, on: ground.color, high),
                                  contrast(Theme.textMuted, on: ground.color, high),
                                  "textFaint stays a tier under textMuted on \(ground.name), \(high)")
            }
        }
    }

    // MARK: Disabled glyph (R2-24)

    /// A disabled transport glyph (Forward 15 at a book's end) reads as
    /// dimmed beside the enabled `textMuted` glyph, ≥ 2.5:1 from it once
    /// both sit on the bar's `surface`, and stays visible, ≥ 1.5:1 on
    /// `surface` and `surface2`, in light, dark and both Increase Contrast
    /// modes. `textFaint` was 1.23-1.35:1 from `textMuted`. An inactive
    /// control, so it is never in `textColors` and has no 4.5:1 floor.
    func testADisabledGlyphIsVisiblyDimmedYetVisible() {
        for appearance in Appearance.all {
            let apart = contrast(Theme.textMuted, on: Theme.glyphDisabled, over: Theme.surface, appearance)
            XCTAssertGreaterThanOrEqual(apart, 2.5, "glyphDisabled from textMuted, \(appearance): "
                                        + String(format: "%.2f:1", apart))
            let faintApart = contrast(Theme.textMuted, on: Theme.textFaint, over: Theme.surface, appearance)
            XCTAssertGreaterThan(apart, faintApart, "dimmer than textFaint read, \(appearance)")
            for ground in [("surface", Theme.surface), ("surface2", Theme.surface2)] {
                let ratio = contrast(Theme.glyphDisabled, on: ground.1, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 1.5, "glyphDisabled on \(ground.0), \(appearance): "
                                            + String(format: "%.2f:1", ratio))
            }
        }
        XCTAssertFalse(Self.textColors.contains { $0.name == "glyphDisabled" }, "never a text color")
    }
}
