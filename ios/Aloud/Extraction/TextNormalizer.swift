import Foundation

/// Exact port of `backend/text_normalize.py` — rewrites PDF-extracted text into
/// clean, ASCII-leaning, speakable form before display and synthesis.
/// The pipeline order is load-bearing; do not reorder steps.
enum TextNormalizer {

    /// Normalize `text` for reliable pronunciation. Conservative: never invents
    /// words, and if normalization empties the string the original (trimmed)
    /// input is returned so the caller always has something to speak.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // 1. NFKC — expands ligatures (ﬁ → fi) and folds compatibility forms.
        var result = text.precomposedStringWithCompatibilityMapping

        // 2. Single scalar-map pass: deletions, spaces, quotes, dashes, bullets.
        result = translate(result)

        // 3. Strip remaining C0/C1 controls (normal whitespace kept; NEL was
        //    already mapped to a space above, so the C1 range is safe to drop).
        result = result.replacing(controlRegex, with: "")

        // 4. Re-join words split by line-wrap hyphenation. The required space
        //    after the hyphen keeps genuine compounds ("well-being") intact.
        result = result.replacing(lineWrapHyphenRegex) { "\($0.output.1)\($0.output.2)" }

        // 5. Collapse whitespace runs to single spaces and trim the ends.
        result = result
            .replacing(whitespaceRegex, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. Remove any space sitting before sentence punctuation.
        result = result.replacing(spaceBeforePunctRegex) { String($0.output.1) }

        // Safety net: never hand back an empty string.
        if result.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: - Scalar translation

    private static func translate(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            // Soft hyphen + zero-width family + BOM: delete.
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0xFEFF:
                continue
            // NEL, NBSP, narrow NBSP, line/para separators, en quad..hair space.
            case 0x0085, 0x00A0, 0x202F, 0x2028, 0x2029, 0x2000...0x200A:
                out.append(" ")
            // Smart single quotes.
            case 0x2018, 0x2019, 0x201A, 0x201B:
                out.append("'")
            // Smart double quotes.
            case 0x201C, 0x201D, 0x201E, 0x201F:
                out.append("\"")
            // Figure/en/em dash, horizontal bar → spaced hyphen (spoken pause).
            case 0x2012...0x2015:
                out.append(" - ")
            // Ellipsis.
            case 0x2026:
                out.append("...")
            // Bullet / list-marker glyphs: delete (whitespace collapses later).
            case 0x2022, 0x2023, 0x2043, 0x2219, 0x25CF, 0x25E6,
                 0x25AA, 0x25AB, 0x00B7, 0x2027, 0x2024:
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Regexes

    private static let controlRegex = #/[\u{00}-\u{08}\u{0E}-\u{1F}\u{7F}-\u{9F}]/#
    private static let lineWrapHyphenRegex = #/([A-Za-z])-\s+([a-z])/#
    private static let whitespaceRegex = #/\s+/#
    private static let spaceBeforePunctRegex = #/\s+([,.;:!?])/#
}
