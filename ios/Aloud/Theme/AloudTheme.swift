import SwiftUI
import UIKit

/// Semantic design tokens. Views consume these exclusively — never raw colors.
/// Single-hue discipline ("Bronze", hue ~35°): the accent family is aged brass
/// on sepia paper, and every neutral is a hue-tinted warm gray. No gradients.
enum Theme {

    // MARK: Surfaces

    static let bg = dynamic(light: bgLight, dark: bgDark)
    /// `bg` as a STATIC sRGB color, already resolved for `scheme`. Use it
    /// where SwiftUI hands a color to UIKit chrome: `.toolbarBackground`
    /// resolves a trait-driven color (the UIColor-provider `bg`, and the
    /// asset-catalog copy too) in the bar's own traits, which stay LIGHT
    /// under an in-app Dark override while the phone is in Light — a cream
    /// bar that SwiftUI then gives light-mode content (dark title, light
    /// pills). The caller reads `colorScheme` from its environment (which
    /// does carry the override), passes it here, and pins the bar with
    /// `.toolbarColorScheme(_:for:)` so its content matches.
    static func bgResolved(for scheme: ColorScheme) -> Color {
        let rgb = scheme == .dark ? bgDark : bgLight
        return Color(.sRGB,
                     red: Double((rgb >> 16) & 0xFF) / 255,
                     green: Double((rgb >> 8) & 0xFF) / 255,
                     blue: Double(rgb & 0xFF) / 255,
                     opacity: 1)
    }
    /// The paper's two values, shared by `bg` and `bgResolved(for:)` (the
    /// LaunchBackground color set repeats them for the launch screen).
    private static let bgLight: UInt32 = 0xFBF8F2
    private static let bgDark: UInt32 = 0x14100A
    static let bgTint = dynamic(light: 0xF3EDE1, dark: 0x1C1710)
    static let surface = dynamic(light: 0xFEFCF8, dark: 0x1A150E)
    static let surface2 = dynamic(light: 0xF6F0E5, dark: 0x231D13)

    // MARK: Text

    // Every text tier clears WCAG AA (4.5:1) on every surface above — bg,
    // bgTint, surface, surface2 — in both modes: text ≥ 13:1, textMuted
    // ≥ 5.6:1, textFaint ≥ 4.6:1. Hierarchy comes from size and weight, not
    // from dropping below legibility.
    static let text = dynamic(light: 0x261D10, dark: 0xF1E9DA)
    /// Increase Contrast raises secondary text to ≥ 7:1 on the solid grounds.
    static let textMuted = dynamic(light: 0x6A5B45, dark: 0xA99A7C,
                                   highContrast: (0x5A4A34, 0xC2B497))
    /// Tertiary text on SOLID grounds only — never on `accentSoft` (use
    /// `textMuted` there).
    static let textFaint = dynamic(light: 0x77694E, dark: 0x93856A)

    // MARK: Lines

    static let line = dynamic(light: 0xE9E1D0, dark: 0x2B2417)
    static let lineStrong = dynamic(light: 0xD7CBB1, dark: 0x3E3423)

    // MARK: Accent family (one hue only)

    /// Icon-only fills (Play, the Continue circle), progress, the margin
    /// mark, rules and toggles. NEVER text, and never the ground behind a
    /// text label (3.80:1 light) — use `accentStrong` for those.
    static let accent = dynamic(light: 0xA87434, dark: 0xC99A5B)
    /// Accent text and links, fills that carry a text label (a `bg` label on
    /// it is 5.50:1), and the word underline.
    static let accentStrong = dynamic(light: 0x8A5B22, dark: 0xE0B478)
    static let accentSoft = dynamic(light: 0xA87434, dark: 0xC99A5B,
                                    lightAlpha: 0.12, darkAlpha: 0.20)
    /// Sentence fill, drawn beneath the text: findable at a glance against
    /// the page (1.35:1 light, 1.66:1 dark) while body text on it stays
    /// ≥ 9.4:1. Increase Contrast raises it to 34%.
    static let highlightBg = dynamic(light: 0xA87434, dark: 0xC99A5B,
                                     lightAlpha: 0.26, darkAlpha: 0.28,
                                     highContrastAlpha: 0.34)

    // MARK: Elevation ink (R3)

    /// The one shadow/scrim ink: the palette's 36° hue, darker than `bg` in
    /// dark mode (Theme.text would turn cream there and LIGHTEN the scrim).
    static let shadowInk = dynamic(light: 0x261D10, dark: 0x0A0805)

    // MARK: Typography (R2)

    /// The named text styles (R2's ten plus R21's aside). Every one scales
    /// with Dynamic Type (serif styles through `relativeTo:`, sans styles are
    /// system text styles), so no view sets a point size. Pair `.eyebrow`
    /// with `.eyebrowTracking()`.
    enum TypeStyle: CaseIterable {
        /// Serif 28, relative to .largeTitle — the wordmark, big titles.
        case display
        /// Serif 22, relative to .title2 — sheet and screen titles.
        case title
        /// Serif 17 semibold, relative to .headline — card and row titles.
        case headline
        /// SF 16 (.callout) — body chrome.
        case body
        /// SF 15 (.subheadline) — secondary lines, buttons.
        case callout
        /// SF 13 semibold (.footnote) — chips, emphasized small labels.
        case subhead
        /// SF 13 (.footnote) — captions under rows, notes.
        case footnote
        /// SF 12 medium, tabular digits (.caption) — readouts, durations.
        case caption
        /// SF 12 semibold small caps (.caption) — section eyebrows. Not
        /// .caption2: it never drops below 11pt, so it doesn't follow the
        /// smaller text sizes, which the Dynamic Type audit reports.
        case eyebrow
        /// SF bold, tabular digits (.largeTitle) — the speed readout.
        case numeral
        /// Serif 15 italic, relative to .footnote — the privacy line.
        case aside
    }

    static func font(_ style: TypeStyle) -> Font {
        switch style {
        case .display:  return .custom(serifFamilyName, size: 28, relativeTo: .largeTitle)
        case .title:    return .custom(serifFamilyName, size: 22, relativeTo: .title2)
        case .headline: return .custom(serifFamilyName, size: 17, relativeTo: .headline).weight(.semibold)
        case .body:     return .callout
        case .callout:  return .subheadline
        case .subhead:  return .footnote.weight(.semibold)
        case .footnote: return .footnote
        case .caption:  return .caption.weight(.medium).monospacedDigit()
        case .eyebrow:  return .caption.weight(.semibold).lowercaseSmallCaps()
        case .numeral:  return .largeTitle.weight(.bold).monospacedDigit()
        case .aside:    return .custom(serifFamilyName, size: 15, relativeTo: .footnote).italic()
        }
    }

    /// Serif at the reader's own size (the reading column sizes itself from
    /// the Aa stepper, which is seeded from the system text size).
    static func readerSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(serifFamilyName, size: size).weight(weight)
    }

    static let serifFamilyName: String = {
        UIFont(name: "Iowan Old Style", size: 17) != nil ? "Iowan Old Style" : "Georgia"
    }()

    // MARK: Spacing (R3)

    /// The only spacing values: 4/8/12/16/20/24/32/48.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Screen gutter (lists, library) and sheet/reader gutter.
        static let screenGutter: CGFloat = 20
        static let sheetGutter: CGFloat = 24
    }

    // MARK: Strokes (R3)

    enum Stroke {
        /// One physical pixel of `lineStrong`: dividers, the top-edge rule.
        static var hairlineWidth: CGFloat { 1 / max(UIScreen.main.scale, 1) }
        static let hairlineColor = Theme.lineStrong
        /// 1pt of `line`: card and chip borders.
        static let borderWidth: CGFloat = 1
        static let borderColor = Theme.line
    }

    // MARK: Elevation (R3)

    enum Elevation {
        /// Floating cards only (the import overlay card).
        static let raisedInk = Theme.dynamic(light: 0x261D10, dark: 0x0A0805,
                                             lightAlpha: 0.14, darkAlpha: 0.60)
        static let raisedRadius: CGFloat = 16
        static let raisedY: CGFloat = 6
        /// Modal scrims: lowers the shelf's luminance in both modes.
        static let scrim = Theme.dynamic(light: 0x261D10, dark: 0x0A0805,
                                         lightAlpha: 0.32, darkAlpha: 0.55)
    }

    // MARK: Motion (R20)

    enum Motion {
        static let press: Double = 0.12
        static let message: Double = 0.2
        static let crossfade: Double = 0.2
        /// The play/pause glyph swap: it grows from `glyphFromScale` as it
        /// fades in (opacity only under Reduce Motion).
        static let glyph: Double = 0.18
        static let glyphFromScale: CGFloat = 0.6
        /// One full turn of the buffering arc.
        static let arcTurn: Double = 1.0
        /// One full cycle of the buffering pulse that replaces the arc under
        /// Reduce Motion.
        static let pulse: Double = 1.2
        /// How far a chip or message rises as it fades in.
        static let rise: CGFloat = 8
        /// R24's colophon fade-in at the end of a book: opacity only, so it
        /// holds under Reduce Motion.
        static let colophon: Double = 0.6
    }

    // MARK: Play circle (R20)

    /// The accent Play circle and its busy ring. The ring sits `arcGap`
    /// outside the circle, so it never covers the glyph.
    enum PlayCircle {
        static let diameter: CGFloat = 54
        /// The Continue card's circle: still a full 44pt target.
        static let compactDiameter: CGFloat = 44
        static let arcWidth: CGFloat = 2
        static let arcGap: CGFloat = 2
        /// The arc's length, as a fraction of the ring.
        static let arcSweep: CGFloat = 0.28
        /// The glyph dims while the ring shows, so busy never reads as ready.
        static let busyGlyphOpacity: Double = 0.4
        /// The pulse's dimmest point: the ring never vanishes.
        static let pulseFloor: Double = 0.3
    }

    // MARK: Radii

    /// Continuous corners only.
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
    }

    // MARK: Private

    fileprivate static func dynamic(light: UInt32, dark: UInt32,
                                    lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
                                    highContrastAlpha: CGFloat? = nil,
                                    highContrast: (light: UInt32, dark: UInt32)? = nil) -> Color {
        Color(uiColor: UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let isHighContrast = trait.accessibilityContrast == .high
            var alpha = isDark ? darkAlpha : lightAlpha
            if isHighContrast, let highContrastAlpha { alpha = highContrastAlpha }
            var rgb = isDark ? dark : light
            if isHighContrast, let highContrast { rgb = isDark ? highContrast.dark : highContrast.light }
            return UIColor(rgb: rgb, alpha: alpha)
        })
    }
}

extension View {
    /// The eyebrow style's tracking (+0.8), paired with `Theme.font(.eyebrow)`.
    func eyebrowTracking() -> some View { tracking(0.8) }

    /// Floating-card elevation in shadow ink (never `Theme.text`).
    func raisedElevation() -> some View {
        shadow(color: Theme.Elevation.raisedInk,
               radius: Theme.Elevation.raisedRadius, y: Theme.Elevation.raisedY)
    }

    /// The one transition for chips and messages entering and leaving: a
    /// short rise with a fade, or the fade alone under Reduce Motion. The
    /// caller still supplies the animation.
    func messageTransition() -> some View { modifier(MessageTransition()) }

    /// A number that rolls its digits when `value` changes (a plain
    /// crossfade under Reduce Motion), so a readout never just snaps.
    func numericReadout(_ value: Double) -> some View { modifier(NumericReadout(value: value)) }
}

// MARK: - Motion styles (R20)

/// The app's only movement vocabulary. Every insertion that moves goes
/// through here, so Reduce Motion is honored in one place: each style
/// collapses to `.opacity` when it is on.
enum MotionStyle: Equatable {
    case opacity, rise, pop

    /// Chips and messages.
    static func message(reduceMotion: Bool) -> MotionStyle { reduceMotion ? .opacity : .rise }
    /// The play/pause glyph swap.
    static func glyph(reduceMotion: Bool) -> MotionStyle { reduceMotion ? .opacity : .pop }

    var transition: AnyTransition {
        switch self {
        case .opacity: return .opacity
        case .rise:    return .opacity.combined(with: .offset(y: Theme.Motion.rise))
        case .pop:     return .opacity.combined(with: .scale(scale: Theme.Motion.glyphFromScale))
        }
    }
}

private struct MessageTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(MotionStyle.message(reduceMotion: reduceMotion).transition)
    }
}

private struct NumericReadout: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText(value: value))
            .animation(.easeOut(duration: Theme.Motion.message), value: value)
    }
}

/// Solid accent circle (Play). Darkens to `accentStrong` while
/// pressed and settles with a slight scale — no opacity flash.
struct AccentCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = Theme.PlayCircle.diameter

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(configuration.isPressed ? Theme.accentStrong : Theme.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
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
