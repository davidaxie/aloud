import Foundation

/// The book-page typesetting rules for the reading column, as pure values so
/// unit tests can pin them. Everything here is layout-only: no rule inserts,
/// removes or reorders a character of sentence text, so sentence ranges,
/// word-tint offsets and the content hash are untouched.
struct ReaderPageStyle {

    let fontSize: CGFloat

    // MARK: Body

    /// Leading tightens as the type grows: 1.60 at 16pt down to 1.50 at 23pt
    /// and above, linear between the table's points.
    static let leadingTable: [(size: CGFloat, multiple: CGFloat)] = [
        (16, 1.60), (17.5, 1.58), (19, 1.55), (21, 1.52), (23, 1.50),
    ]

    var lineHeightMultiple: CGFloat {
        let table = Self.leadingTable
        if fontSize <= table[0].size { return table[0].multiple }
        for (low, high) in zip(table, table.dropFirst()) where fontSize <= high.size {
            let t = (fontSize - low.size) / (high.size - low.size)
            return low.multiple + (high.multiple - low.multiple) * t
        }
        return table[table.count - 1].multiple
    }

    var lineHeight: CGFloat { (fontSize * lineHeightMultiple).rounded() }

    /// Book paragraphs: a first-line indent and a small gap, ragged right.
    var firstLineIndent: CGFloat { (fontSize * 1.1).rounded() }
    var paragraphGap: CGFloat { (fontSize * 0.45).rounded() }

    /// The indent in a column `columnWidth` points wide: 1.1 em in a column
    /// of `wideColumnEms` or more; narrower, never more than 6% of the
    /// measure, so a phone column at the largest sizes (9-10 em) doesn't
    /// open every paragraph with a 44 pt hole.
    func firstLineIndent(columnWidth: CGFloat) -> CGFloat {
        guard fontSize > 0, columnWidth / fontSize < Self.wideColumnEms else { return firstLineIndent }
        return min(firstLineIndent, (columnWidth * Self.narrowIndentShare).rounded(.down))
    }

    /// The most of a column's width a first-line indent takes.
    static let narrowIndentShare: CGFloat = 0.06

    /// Layout-only hyphenation (no soft hyphens are inserted into the text),
    /// in a column of `wideColumnEms` or more.
    static let hyphenationFactor: Float = 0.25
    /// Hyphenation in a column of `narrowColumnEms` or fewer: a few words a
    /// line rag deeply unless long words may break.
    static let narrowHyphenationFactor: Float = 0.6
    /// From this measure up, the wide setting (factor and indent). The
    /// iPhone's default column on every supported phone (19 pt in 327 pt on
    /// a 375 pt phone, 17.2 em; in 354 pt on a 402 pt one, 18.6 em) and
    /// every Mac column at its normal sizes sit above it, so they keep the
    /// book's usual setting.
    static let wideColumnEms: CGFloat = 17
    static let narrowColumnEms: CGFloat = 12

    /// Hyphenation for a column `emsPerLine` ems wide: `hyphenationFactor`
    /// at `wideColumnEms` or more, rising linearly to
    /// `narrowHyphenationFactor` at `narrowColumnEms` or fewer.
    static func hyphenationFactor(emsPerLine: CGFloat) -> Float {
        guard emsPerLine.isFinite, emsPerLine < wideColumnEms else { return hyphenationFactor }
        guard emsPerLine > narrowColumnEms else { return narrowHyphenationFactor }
        let t = Float((wideColumnEms - emsPerLine) / (wideColumnEms - narrowColumnEms))
        return hyphenationFactor + (narrowHyphenationFactor - hyphenationFactor) * t
    }

    /// The body's measure-dependent setting.
    struct BodySetting: Equatable {
        let firstLineIndent: CGFloat
        let hyphenationFactor: Float
    }

    /// The setting for a column `columnWidth` points wide; nil (a host that
    /// doesn't know its measure yet) is the wide setting.
    func body(columnWidth: CGFloat?) -> BodySetting {
        guard let columnWidth, columnWidth > 0, fontSize > 0 else {
            return BodySetting(firstLineIndent: firstLineIndent, hyphenationFactor: Self.hyphenationFactor)
        }
        return BodySetting(firstLineIndent: firstLineIndent(columnWidth: columnWidth),
                           hyphenationFactor: Self.hyphenationFactor(emsPerLine: columnWidth / fontSize))
    }

    // MARK: Chapter openings

    var openingSpaceAbove: CGFloat { (fontSize * 3).rounded() }
    var headingSize: CGFloat { (fontSize * 1.2).rounded() }
    static let headingKern: CGFloat = 1.5
    var headingToRule: CGFloat { (fontSize * 0.8).rounded() }
    var ruleToText: CGFloat { (fontSize * 1.6).rounded() }
    static let ruleSize = CGSize(width: 24, height: 1.5)
    /// Words of the opening paragraph set in small caps.
    static let openingSmallCapsWords = 3

    // MARK: Colophon (R24)

    /// The colophon's last line, its listening time: a step below the
    /// body, like a caption.
    var colophonDetailSize: CGFloat { (fontSize * 0.85).rounded() }

    // MARK: PDF page marks

    static let pageRuleSize = CGSize(width: 32, height: 1)

    // MARK: Which headings get an opening

    /// Chapter openings only for books that really are chaptered: at least
    /// three detected headings, and never two openings within five
    /// paragraphs (a heading that close is dropped back to body text).
    static func openingParagraphs(candidates: [Int], minimumCount: Int = 3,
                                  minimumGap: Int = 5) -> Set<Int> {
        guard candidates.count >= minimumCount else { return [] }
        var kept: [Int] = []
        for index in candidates.sorted() {
            if let last = kept.last, index - last < minimumGap { continue }
            kept.append(index)
        }
        return Set(kept)
    }

    // MARK: Fonts

    /// The reading serif. `bold` (the system Bold Text setting, i.e.
    /// `legibilityWeight == .bold`) swaps in the family's bold face, derived
    /// through the descriptor's bold trait; a family without one keeps its
    /// regular face.
    static func serif(size: CGFloat, bold: Bool = false) -> PlatformFont {
        let regular = PlatformFont.named(Theme.serifFamilyName, size: size) ?? .systemFont(ofSize: size)
        guard bold else { return regular }
        return PlatformFontTraits.bold(regular) ?? regular
    }

    /// The serif's italic (Iowan Old Style Italic, or Bold Italic under Bold
    /// Text; Georgia Italic where Iowan is missing), for R24's colophon
    /// heading.
    /// Derived through the descriptor's italic trait, like `serif`'s bold;
    /// a family without an italic keeps its upright face.
    static func italicSerif(size: CGFloat, bold: Bool = false) -> PlatformFont {
        let upright = serif(size: size, bold: bold)
        return PlatformFontTraits.italic(upright) ?? upright
    }

    /// Serif with lowercase set in small caps (numerals and capitals stay
    /// full size, so "Chapter IV" keeps its numeral).
    static func smallCapsSerif(size: CGFloat, bold: Bool = false) -> PlatformFont {
        PlatformFontTraits.smallCaps(serif(size: size, bold: bold))
    }

    /// UTF-16 length of the first `count` words of `text`, including the
    /// whitespace between them (for the opening small-caps run).
    static func utf16LengthOfFirstWords(_ text: String, count: Int) -> Int {
        var words = 0
        var inWord = false
        var length = 0
        for scalar in text.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSpace, inWord {
                inWord = false
                if words == count { return length }
            } else if !isSpace, !inWord {
                inWord = true
                words += 1
            }
            length += String(scalar).utf16.count
        }
        return length
    }
}
