import Foundation
import NaturalLanguage

/// Port of `backend/text_normalize.py` — rewrites PDF-extracted text into
/// clean, ASCII-leaning, speakable form before display and synthesis.
/// The pipeline order is load-bearing; do not reorder steps. Deliberate
/// departures from the backend: fractions and superscripts survive step 1,
/// and step 4 keeps a hyphenated split as a compound when both halves are
/// words and the joined form is not.
enum TextNormalizer {

    /// Normalize `text` for reliable pronunciation. Conservative: never invents
    /// words, and if normalization empties the string the original (trimmed)
    /// input is returned so the caller always has something to speak.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // 1. NFKC — expands ligatures (ﬁ → fi) and folds compatibility forms,
        //    except vulgar fractions and superscripts: NFKC turns "4½" into
        //    "41⁄2" and "10⁶" into "106", a different number on screen and
        //    aloud, while both voices read the originals correctly.
        var result = compatibilityFolded(text)

        // 2. Single scalar-map pass: deletions, spaces, quotes, dashes, bullets.
        // 3. The same pass strips remaining C0/C1 controls (normal whitespace
        //    kept; NEL maps to a space first, so the rest of C1 is safe to
        //    drop). A separate regex pass cost a quarter of a large book's
        //    normalization time.
        result = translate(result)

        // 4. Re-join words split by line-wrap hyphenation. The required space
        //    after the hyphen keeps genuine compounds ("well-being") intact.
        if result.contains("-") {
            let source = result
            result = result.replacing(lineWrapHyphenRegex) { match in
                let (_, letter, gap) = match.output
                // The match is only "<letter>-<gap>" (a leading `[A-Za-z]+`
                // backtracks at every letter, which was slow); both words
                // are read from the text around it, so chained wraps
                // ("house-⏎keeper-⏎ship") each see whole words.
                let head = source[..<match.range.lowerBound].reversed()
                    .prefix { $0.isASCII && $0.isLetter }
                let right = source[match.range.upperBound...]
                    .prefix { $0.isASCII && $0.isLetter }
                switch hyphenSplit(left: String(head.reversed()) + letter, gap: gap, right: right) {
                case .rejoin: return "\(letter)"
                case .compound: return "\(letter)-"
                case .asWritten: return "\(letter)-\(gap)"
                }
            }
        }

        // 5. Collapse whitespace runs to single spaces and trim the ends.
        result = collapsingWhitespace(result)

        // 6. Remove any space sitting before sentence punctuation.
        result = result.replacing(spaceBeforePunctRegex) { String($0.output.1) }

        // Safety net: never hand back an empty string.
        if result.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: - Compatibility folding

    /// NFKC, leaving vulgar fractions and superscripts as they are.
    private static func compatibilityFolded(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: keepsCompatibilityForm) else {
            return s.precomposedStringWithCompatibilityMapping
        }
        var out = ""
        var run = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if keepsCompatibilityForm(scalar) {
                out += String(run).precomposedStringWithCompatibilityMapping
                run.removeAll()
                out.unicodeScalars.append(scalar)
            } else {
                run.append(scalar)
            }
        }
        return out + String(run).precomposedStringWithCompatibilityMapping
    }

    /// ¹ ² ³, the superscripts and super-signs block, and the vulgar fractions.
    private static func keepsCompatibilityForm(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00B2, 0x00B3, 0x00B9, 0x00BC...0x00BE,
             0x2070...0x207F, 0x2150...0x215F, 0x2189:
            return true
        default:
            return false
        }
    }

    // MARK: - Hyphenation

    private enum HyphenSplit { case rejoin, compound, asWritten }

    /// What to make of one "inter- national" / "inter-⏎national" split.
    /// Gutenberg text wraps real compounds at their hyphen ("public-⏎house",
    /// "sixty-⏎fourth"), and a suspended hyphen ("first- and second-class")
    /// is no wrap at all, so the hyphen is kept only when both halves are
    /// words and the joined form is not. Everything else is re-joined: a
    /// typesetter's syllable split usually leaves one half that is no word
    /// ("hon-⏎our", "mor-⏎row"), and a split name has two ("Archi-⏎medes").
    /// A kept compound loses its line break; a same-line split is left as
    /// written.
    private static func hyphenSplit(left: String, gap: Substring, right: Substring) -> HyphenSplit {
        // No word list on this system: re-join as before.
        guard let wordList else { return .rejoin }
        let keep: HyphenSplit = gap.contains(where: \.isNewline) ? .compound : .asWritten
        if suspendedHyphenFollowers.contains(right) { return keep }

        wordListLock.lock()
        defer { wordListLock.unlock() }
        func isWord(_ s: String) -> Bool { isKnownWord(s.lowercased(), in: wordList) }
        if isWord(left + right) || !(isWord(left) && isWord(String(right))) { return .rejoin }
        return keep
    }

    /// Is lowercase `word` in the list, directly, as its American spelling,
    /// or as one of the few common words the list lacks?
    private static func isKnownWord(_ word: String, in list: NLEmbedding) -> Bool {
        if list.contains(word) || wordsMissingFromList.contains(word) { return true }
        return americanSpellings(of: word).contains(where: list.contains)
    }

    /// The word list is American: "honour", "realise" and "travelling" are
    /// missing while "honor", "realize" and "traveling" are present. These
    /// respellings are tried only for a word the list lacks.
    private static func americanSpellings(of word: String) -> [String] {
        var out: [String] = []
        if word.contains("our") { out.append(word.replacingOccurrences(of: "our", with: "or")) }
        for (british, american) in britishSuffixes where word.hasSuffix(british) {
            out.append(String(word.dropLast(british.count)) + american)
        }
        return out
    }

    private static let britishSuffixes: [(String, String)] = [
        ("ise", "ize"), ("ised", "ized"), ("ises", "izes"), ("ising", "izing"),
        ("iser", "izer"), ("isers", "izers"), ("isation", "ization"), ("isations", "izations"),
        ("yse", "yze"), ("ysed", "yzed"), ("ysing", "yzing"),
        ("lling", "ling"), ("lled", "led"), ("ller", "ler"), ("llers", "lers"),
        ("tre", "ter"), ("tres", "ters"), ("ence", "ense"),
    ]

    /// Common words absent from the OS list whose halves are both words, so
    /// a split of them would otherwise keep its hyphen ("can-⏎not").
    private static let wordsMissingFromList: Set<String> = ["cannot"]

    /// After a hyphen these words mark a suspended compound ("two- or
    /// three-day"), even where the halves happen to spell a word ("tenor").
    private static let suspendedHyphenFollowers: Set<Substring> = ["and", "or", "nor"]

    /// The OS's built-in English word embedding, used only as an on-device
    /// word list (lowercase, American spelling, about 57k words). nil when
    /// unavailable.
    private static let wordList = NLEmbedding.wordEmbedding(for: .english)
    private static let wordListLock = NSLock()

    // MARK: - Scalar translation

    private static func translate(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        // A ZWNJ or ZWJ waits for the scalar after it (see `keepsJoiner`).
        var joiner: (scalar: Unicode.Scalar, before: Unicode.Scalar?)?
        for scalar in s.unicodeScalars {
            if let pending = joiner {
                if keepsJoiner(before: pending.before, after: scalar) { out.unicodeScalars.append(pending.scalar) }
                joiner = nil
            }
            switch scalar.value {
            // Soft hyphen + zero-width space + BOM: delete.
            case 0x00AD, 0x200B, 0xFEFF:
                continue
            // Zero-width non-joiner and joiner: delete, but where they shape
            // the text.
            case 0x200C, 0x200D:
                joiner = (scalar, out.unicodeScalars.last)
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
            // After a number an em dash or bar is a spaced double hyphen, the
            // ASCII em dash: "In 1915—20 years later" is a clause break, not
            // the range "1915–20", and SpokenYears reads only a single
            // hyphen as "to". Both display as an em dash.
            case 0x2014, 0x2015:
                let previous = out.unicodeScalars.reversed().first { $0 != " " }
                out.append(previous.map { (0x30...0x39).contains($0.value) } == true ? " -- " : " - ")
            case 0x2012, 0x2013:
                out.append(" - ")
            // Ellipsis.
            case 0x2026:
                out.append("...")
            // Bullet / list-marker glyphs: delete (whitespace collapses later).
            case 0x2022, 0x2023, 0x2043, 0x2219, 0x25CF, 0x25E6,
                 0x25AA, 0x25AB, 0x00B7, 0x2027, 0x2024:
                continue
            // Remaining C0/C1 controls (tab, LF, VT, FF, CR and NEL excepted).
            case 0x00...0x08, 0x0E...0x1F, 0x7F...0x84, 0x86...0x9F:
                continue
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        if let pending = joiner, keepsJoiner(before: pending.before, after: nil) {
            out.unicodeScalars.append(pending.scalar)
        }
        return out
    }

    /// ZWJ and ZWNJ beside an emoji or a letter of a non-Latin script are
    /// spelling: they join "👩‍💻" into one emoji and keep Persian "می‌خواهم"
    /// and Devanagari half forms as written. Between Latin letters they are
    /// leftovers of ligature breaking in PDFs, and go. Search folds a query
    /// by the same rule.
    static func keepsJoiner(before: Unicode.Scalar?, after: Unicode.Scalar?) -> Bool {
        func shapes(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar, scalar.value > 0x7F else { return false }
            let properties = scalar.properties
            if scalar.value == 0xFE0F || properties.isEmojiPresentation || properties.isEmojiModifier
                || (properties.isEmoji && scalar.value > 0x2000) {
                return true
            }
            switch scalar.value {
            case ..<0x0370, 0x1E00...0x1EFF: return false   // Latin, IPA and their diacritics
            default:
                switch properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .nonspacingMark, .spacingMark, .enclosingMark:
                    return true
                default:
                    return false
                }
            }
        }
        return shapes(before) || shapes(after)
    }

    /// Whitespace runs → one space, ends trimmed. Same result as replacing
    /// `\s+` and trimming, without a regex match per space.
    private static func collapsingWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var pendingSpace = false
        for character in s {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Regexes

    private static let lineWrapHyphenRegex = #/([A-Za-z])-(\s+)(?=[a-z])/#
    private static let spaceBeforePunctRegex = #/\s+([,.;:!?])/#
}
