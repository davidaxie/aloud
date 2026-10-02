import Foundation

/// Display-only typesetting for the reading column: straight quotes become
/// curly quotes, a spaced hyphen (" - ") and a double hyphen ("--") become em
/// dashes. Speech, search, caching and the content hash all keep the source
/// text; only the rendered attributed string changes.
///
/// LENGTH-PRESERVING BY CONTRACT (UTF-16). Sentence ranges, word-tint token
/// offsets and tap hit-testing are all computed from the source text, so
/// every substitution maps one UTF-16 unit to one (quotes, the hyphen of
/// " - ") or two to two ("--" → em dash + invisible word joiner).
/// `typeset` returns the source unchanged if a result ever differs in length.
enum ReaderTypography {

    static func typeset(_ text: String) -> String {
        guard text.utf16.contains(where: { $0 == quote || $0 == apostrophe || $0 == hyphen })
        else { return text }

        let source = Array(text.utf16)
        var output = source
        var index = 0
        while index < source.count {
            let unit = source[index]
            // Context comes from what is ALREADY typeset: a straight quote
            // turned into “ one step earlier (or "--" into an em dash + word
            // joiner) counts as an opener for the next mark. The source
            // itself never holds curly quotes or em dashes — TextNormalizer
            // folds them to ASCII before sentences are stored.
            let previous: UInt16? = index > 0 ? output[index - 1] : nil
            let next: UInt16? = index + 1 < source.count ? source[index + 1] : nil

            switch unit {
            case quote:
                output[index] = opensQuote(after: previous, before: next) ? leftDouble : rightDouble
            case apostrophe:
                output[index] = opensSingle(after: previous, at: index, in: source)
                    ? leftSingle : rightSingle
            case hyphen:
                if next == hyphen {
                    // Exactly two hyphens ("--"): em dash + word joiner. Runs of
                    // three or more are rules or deliberate; leave them alone.
                    let third: UInt16? = index + 2 < source.count ? source[index + 2] : nil
                    if previous != hyphen, third != hyphen {
                        output[index] = emDash
                        output[index + 1] = wordJoiner
                        index += 1
                    }
                } else if previous == space, next == space {
                    output[index] = emDash
                }
            default:
                break
            }
            index += 1
        }

        let result = String(utf16CodeUnits: output, count: output.count)
        guard result.utf16.count == source.count else { return text }
        return result
    }

    // MARK: - Context rules

    /// A quote opens when an opening context comes before it (start of
    /// text, whitespace, a bracket, a dash, another opening quote) AND a word
    /// follows it. A quote followed by whitespace, closing punctuation or the
    /// end of the sentence closes, whatever precedes it — so interrupted
    /// dialogue ("I--" / "I - ") gets a closing mark.
    private static func opensQuote(after previous: UInt16?, before next: UInt16?) -> Bool {
        guard let next, !isWhitespace(next), !closers.contains(next) else { return false }
        guard let previous else { return true }
        return isWhitespace(previous) || openers.contains(previous)
    }

    /// A single quote opens only where a double quote would AND the word it
    /// starts is not a known elision ('tis, 'em, '90s). Everything else is an
    /// apostrophe or a closing quote (’).
    private static func opensSingle(after previous: UInt16?, at index: Int,
                                    in source: [UInt16]) -> Bool {
        let next: UInt16? = index + 1 < source.count ? source[index + 1] : nil
        guard opensQuote(after: previous, before: next), let next else { return false }
        if isDigit(next) { return false }                 // '90s
        return !startsElision(source, at: index + 1)
    }

    /// Elided words that begin with an apostrophe. Matched as whole words:
    /// the elision must end at a non-letter or the end of the text, so
    /// "'em!" and "'Tis" match while "'Emma" does not.
    private static let elisions = ["tis", "twas", "twere", "em", "cause", "til", "n"]

    private static func startsElision(_ source: [UInt16], at start: Int) -> Bool {
        let tail = lowercasedPrefix(of: source, from: start, length: 7)
        for word in elisions where tail.hasPrefix(word) {
            let boundary = tail.dropFirst(word.count).first
            if boundary == nil || !(boundary!.isLetter) { return true }
        }
        return false
    }

    private static func lowercasedPrefix(of source: [UInt16], from start: Int,
                                         length: Int) -> String {
        let end = min(source.count, start + length)
        guard start < end else { return "" }
        return String(utf16CodeUnits: Array(source[start..<end]), count: end - start)
            .lowercased()
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
            || unit == 0x2009 || unit == 0x200A
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    // MARK: - Code units

    private static let quote: UInt16 = 0x22        // "
    private static let apostrophe: UInt16 = 0x27   // '
    private static let hyphen: UInt16 = 0x2D       // -
    private static let space: UInt16 = 0x20
    private static let leftDouble: UInt16 = 0x201C  // “
    private static let rightDouble: UInt16 = 0x201D // ”
    private static let leftSingle: UInt16 = 0x2018  // ‘
    private static let rightSingle: UInt16 = 0x2019 // ’
    private static let emDash: UInt16 = 0x2014      // —
    private static let wordJoiner: UInt16 = 0x2060  // invisible, zero width

    /// Opening context: brackets, dashes (incl. the word joiner that follows
    /// a typeset "--"), and opening quotes.
    private static let openers: Set<UInt16> = [
        0x28, 0x5B, 0x7B,                      // ( [ {
        hyphen, 0x2013, emDash, wordJoiner,    // - – — ⁠
        leftDouble, leftSingle,
    ]

    /// Characters that never follow an opening quote. Quote marks are not
    /// here: in `"'You` and `.'"` the mark before decides (opener vs not).
    private static let closers: Set<UInt16> = [
        0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F,    // , . ; : ! ?
        0x29, 0x5D, 0x7D,                      // ) ] }
    ]
}
