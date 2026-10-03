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

    /// Layout-only hyphenation (no soft hyphens are inserted into the text).
    static let hyphenationFactor: Float = 0.25

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
