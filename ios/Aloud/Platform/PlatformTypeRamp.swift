import SwiftUI

// The Mac's type ramp (M5) and the reader chrome's size bands (M18). macOS
// text styles are fixed and small (.footnote and .caption are 10 pt) and
// give apps no Dynamic Type, so the Mac sets each style at a fixed size and
// grows the reader's chrome with the reader's own text size instead. The
// iPhone keeps Theme's text styles, which follow Dynamic Type. (T1)

/// How large the reader's chrome is set, in three bands of the reader's
/// text size, so a reader at 35 pt gets a player bar to match. The
/// Library, Classics and Settings stay `.standard`.
enum ChromeScale: CaseIterable, Sendable {
    /// Reader 16-21 pt: body 13, callout 12, caption 11; a 44 pt circle.
    case standard
    /// Reader 23-30 pt: body 15, callout 14, caption 13; a 52 pt circle,
    /// chips on a second row.
    case large
    /// Reader 35-40 pt: body 17, callout 16, caption 15; a 60 pt circle,
    /// chips on a second row.
    case largest

    /// The band for a reader text size in points, split halfway between
    /// neighbouring steps (21 | 23 and 30 | 35).
    init(readerPoints: CGFloat) {
        switch readerPoints {
        case ..<22: self = .standard
        case ..<32.5: self = .large
        default: self = .largest
        }
    }

    /// The band for a stored reader step.
    init(readerStep: Int) {
        self.init(readerPoints: ReaderTextSize.points(forStep: readerStep))
    }

    /// Points every style in the ramp grows by.
    var step: CGFloat {
        switch self {
        case .standard: return 0
        case .large: return 2
        case .largest: return 4
        }
    }

    /// The player bar's Play circle.
    var playCircleDiameter: CGFloat {
        switch self {
        case .standard: return 44
        case .large: return 52
        case .largest: return 60
        }
    }

    /// Whether the chips leave the transport row for a row of their own.
    var chipsOnSecondRow: Bool {
        self != .standard
    }
}

private struct ChromeScaleKey: EnvironmentKey {
    static let defaultValue = ChromeScale.standard
}

extension EnvironmentValues {
    /// The reader chrome's band, set by the reader from its text size.
    var chromeScale: ChromeScale {
        get { self[ChromeScaleKey.self] }
        set { self[ChromeScaleKey.self] = newValue }
    }
}

enum PlatformTypeRamp {

    /// The Mac's size for `style` in the `.standard` band: display serif 26,
    /// title serif 20, headline serif 15, body 13, callout 12, subhead and
    /// footnote 11, caption and eyebrow 11, numeral 28, aside serif 13.
    static func basePoints(_ style: Theme.TypeStyle) -> CGFloat {
        switch style {
        case .display:  return 26
        case .title:    return 20
        case .headline: return 15
        case .body:     return 13
        case .callout:  return 12
        case .subhead:  return 11
        case .footnote: return 11
        case .caption:  return 11
        case .eyebrow:  return 11
        case .numeral:  return 28
        case .aside:    return 13
        }
    }

    /// The Mac's size for `style` in `scale`'s band.
    static func points(_ style: Theme.TypeStyle, scale: ChromeScale) -> CGFloat {
        basePoints(style) + scale.step
    }

    /// `style` from the Mac ramp at `scale`'s band, with the weights and
    /// features of the iPhone's styles. nil on the iPhone, where
    /// `Theme.font` keeps its Dynamic Type styles.
    static func font(for style: Theme.TypeStyle, scale: ChromeScale) -> Font? {
        #if os(macOS)
        let size = points(style, scale: scale)
        let serif = Theme.serifFamilyName
        switch style {
        case .display, .title: return .custom(serif, fixedSize: size)
        case .headline: return .custom(serif, fixedSize: size).weight(.semibold)
        case .body, .callout, .footnote: return .system(size: size)
        case .subhead:  return .system(size: size, weight: .semibold)
        case .caption:  return .system(size: size, weight: .medium).monospacedDigit()
        case .eyebrow:  return .system(size: size, weight: .semibold).lowercaseSmallCaps()
        case .numeral:  return .system(size: size, weight: .bold).monospacedDigit()
        case .aside:    return .custom(serif, fixedSize: size).italic()
        }
        #else
        return nil
        #endif
    }

    /// Whether the reader's chapter line may set its title on two lines in
    /// `scale`'s band: the Largest band on the Mac (mac-ux §10.4), where the
    /// bar keeps the room (`MacPlayerBarLayout.chapterLineHeight`). Never on
    /// the iPhone, whose line wraps at the accessibility sizes instead.
    static func wrapsChapterLine(in scale: ChromeScale) -> Bool {
        #if os(macOS)
        return scale == .largest
        #else
        return false
        #endif
    }

    /// The Mac's Play glyph for a circle `diameter` across: the iPhone's
    /// proportion (its 22 pt title2 glyph in the 54 pt circle) to the whole
    /// point, so each band's circle gets its own glyph: 18, 21 and 24 pt in
    /// the 44, 52 and 60 pt circles.
    static func playGlyphPoints(diameter: CGFloat) -> CGFloat {
        (diameter * 22 / Theme.PlayCircle.diameter).rounded()
    }

    /// The Play glyph at `playGlyphPoints`, bold. nil on the iPhone, where
    /// `PlayCircleFace` keeps its Dynamic Type styles.
    static func playGlyphFont(diameter: CGFloat) -> Font? {
        #if os(macOS)
        return .system(size: playGlyphPoints(diameter: diameter), weight: .bold)
        #else
        return nil
        #endif
    }
}
