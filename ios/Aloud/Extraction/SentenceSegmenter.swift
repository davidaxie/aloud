import Foundation
import NaturalLanguage

/// One display/timing token of a sentence. Concatenating every token's `text`
/// reproduces the sentence verbatim (whitespace and punctuation preserved).
struct WordToken: Equatable {
    let text: String
    let isWord: Bool
    let weight: Double
    let isSkippable: Bool
}

/// Port of `frontend/src/lib/chunker.ts` — sentence chunking plus the
/// non-destructive word tokenizer that powers highlighting and skip-brackets.
enum SentenceSegmenter {

    /// Soft-split ceiling: sentences longer than this are broken on clauses.
    static let maxSentenceLength = 350

    // Abbreviations that commonly precede a period inside a sentence, stored
    // lowercased without the trailing dot. A boundary after one is spurious.
    private static let abbreviations: Set<String> = [
        // Titles / honorifics
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "rev", "hon",
        "gen", "col", "capt", "lt", "sgt", "gov", "sen", "rep", "pres", "supt",
        // Latin / editorial
        "eg", "ie", "etc", "vs", "viz", "al", "cf", "ca", "approx", "est", "esp",
        // Months
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        // Org / bibliographic
        "inc", "ltd", "co", "corp", "dept", "univ", "assn", "bros",
        "ref", "ed", "eds", "repr",
    ]

    // Numbering abbreviations ("No. 5", "Vol. II", "pp. 23"). They hold a
    // sentence together only when a number follows: "No." is also a whole
    // reply ('"No." "So much the worse."') and "fig" a word.
    private static let numberingAbbreviations: Set<String> = [
        "no", "nos", "vol", "pp", "fig", "figs", "eq",
    ]

    // MARK: - Sentence splitting

    /// Split a paragraph into trimmed, non-empty sentences. Uses NLTokenizer,
    /// then repairs boundaries that fell on abbreviations, initials,
    /// initialisms, or bare list markers, inside a bracketed span, or before
    /// a fragment of closing punctuation.
    static func splitIntoSentences(_ text: String) -> [String] {
        let normalized = text
            .replacing(whitespaceRunRegex, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let raw = rawSplit(normalized)
        let lastClosers = lastCloserOffsets(in: normalized)

        var merged: [String] = []
        var i = 0
        while i < raw.count {
            let start = raw[i].lowerBound
            while i < raw.count - 1 {
                let next = normalized[raw[i + 1]]
                if endsWithAbbreviation(normalized[start..<raw[i].upperBound], before: next)
                    || isClosingFragment(next) {
                    i += 1
                } else if let closer = bracketCloser(in: normalized, from: start,
                                                     through: i, segments: raw,
                                                     lastClosers: lastClosers) {
                    i = closer
                } else {
                    break
                }
            }
            // Slicing the paragraph (rather than re-joining pieces) keeps the
            // text across an undone boundary exactly as written: "_word._"
            // must not gain a space before its closing underscore.
            let cleaned = normalized[start..<raw[i].upperBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { merged.append(cleaned) }
            i += 1
        }
        return merged
    }

    /// One tokenizer for every paragraph: allocating an NLTokenizer per call
    /// dominated the time to add a large book. NLTokenizer is not
    /// thread-safe, so its use is serialized.
    private static let sentenceTokenizer = NLTokenizer(unit: .sentence)
    private static let sentenceTokenizerLock = NSLock()

    /// NLTokenizer's sentence ranges in `text`, whitespace-only ones dropped.
    private static func rawSplit(_ text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        do {
            sentenceTokenizerLock.lock()
            defer { sentenceTokenizerLock.unlock() }
            let tokenizer = sentenceTokenizer
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                out.append(range)
                return true
            }
        }
        if out.count > 1 {
            for j in 1..<out.count {
                if let boundary = gluedTailEnd(after: out[j - 1], in: out[j], of: text) {
                    out[j - 1] = out[j - 1].lowerBound..<boundary
                    out[j] = boundary..<out[j].upperBound
                }
            }
        }
        out.removeAll { !text[$0].contains(where: { !$0.isWhitespace }) }
        return out.isEmpty ? [text.startIndex..<text.endIndex] : out
    }

    /// Where the boundary between two NLTokenizer segments belongs when it
    /// fell inside a word, or nil to leave it. Marks glued to a sentence end
    /// belong to that sentence: NLTokenizer cuts "_Hush._ She slept." after
    /// the period (leaving "_ She slept."), and "Somerville.[344] This" inside
    /// the footnote reference (leaving "344] This").
    private static func gluedTailEnd(after previous: Range<String.Index>,
                                     in segment: Range<String.Index>,
                                     of text: String) -> String.Index? {
        guard previous.upperBound == segment.lowerBound,
              let last = text[previous].last, !last.isWhitespace else { return nil }
        var end = segment.lowerBound

        // A bracket opened in the sentence's last word and closed within the
        // next segment's first word.
        let lastWord = text[previous].split(whereSeparator: \.isWhitespace).last ?? ""
        var unclosed: [Character] = []
        for character in lastWord {
            if let closer = closerFor[character] {
                unclosed.append(closer)
            } else if character == unclosed.last {
                unclosed.removeLast()
            }
        }
        var closedBracket = false
        if let closer = unclosed.last {
            var cursor = segment.lowerBound
            while cursor < segment.upperBound, !text[cursor].isWhitespace {
                let character = text[cursor]
                cursor = text.index(after: cursor)
                if character == closer {
                    end = cursor
                    closedBracket = true
                    break
                }
            }
        }

        // Then any closing marks ("_", "_]", "\"", ".").
        while end < segment.upperBound, closingFragmentCharacters.contains(text[end]) {
            end = text.index(after: end)
        }
        guard end > segment.lowerBound else { return nil }
        // A bare run of marks must end the word: the "'" of "'Tis" stays put.
        if !closedBracket, end < segment.upperBound, !text[end].isWhitespace { return nil }
        return end
    }

    private static let closerFor: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// Should the boundary between `piece` and the segment `next` be undone?
    private static func endsWithAbbreviation(_ piece: Substring, before next: Substring) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare list / enumeration marker like "1." or "2)" left dangling.
        if trimmed.wholeMatch(of: listMarkerRegex) != nil { return true }

        guard let last = trimmed.split(whereSeparator: \.isWhitespace).last else { return false }
        let lastToken = String(last)
        // Single initial ("J.") or initialism ("U.S.", "e.g.", "a.m."). A
        // bare "I." is the pronoun ending a sentence ("So did I."), never an
        // initial.
        if lastToken.wholeMatch(of: singleInitialRegex) != nil { return lastToken != "I." }
        if lastToken.wholeMatch(of: initialismRegex) != nil { return true }

        // Known abbreviation word (strip trailing dot, ignore edge punctuation,
        // Gutenberg's italic underscores included: "_etc._").
        let bare = lastToken
            .replacing(trailingEdgePunctRegex, with: "")
            .replacing(leadingEdgePunctRegex, with: "")
            .lowercased()
        if numberingAbbreviations.contains(bare) {
            return startsWithNumber(next, loneIIsPronoun: bare == "no" || bare == "nos")
        }
        return abbreviations.contains(bare)
    }

    /// Does `segment` open with a number, arabic ("5", "23-27") or roman
    /// ("II", "xiv")? After "No." a lone "I" is usually the pronoun
    /// ('"No." I shook my head') and counts as a numeral only with
    /// punctuation ("No. I,"); after "Vol.", "pp.", "Fig." or "Eq." it is
    /// always the numeral ("Vol. I By Mary J. Holmes").
    private static func startsWithNumber(_ segment: Substring, loneIIsPronoun: Bool) -> Bool {
        guard let token = segment.split(whereSeparator: \.isWhitespace).first,
              let first = token.first else { return false }
        if first.isNumber { return true }
        let letters = token.prefix(while: \.isLetter)
        guard !letters.isEmpty,
              letters.allSatisfy({ "IVXLCDM".contains($0) })
                || letters.allSatisfy({ "ivxlcdm".contains($0) }) else { return false }
        if loneIIsPronoun, letters == "I" || letters == "i" {
            guard let after = token.dropFirst().first else { return false }
            return ".,;:)".contains(after)
        }
        return true
    }

    /// Characters that can trail a sentence end: closing brackets and quotes,
    /// Gutenberg's italic underscore, stray terminal punctuation, and
    /// superscript-digit footnote markers. NLTokenizer cuts "childhood.¹ It
    /// was" before the "¹", which would open the next sentence (and be read
    /// "one it was").
    private static let closingFragmentCharacters: Set<Character> = [
        "_", ")", "]", "}", "\"", "'", ".", "!", "?", ",", ";", ":",
        "\u{00B9}", "\u{00B2}", "\u{00B3}", "\u{2070}", "\u{2074}", "\u{2075}",
        "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}",
    ]

    /// A segment of nothing but closing punctuation ("_", "_]", ")", "\"")
    /// that NLTokenizer cut off the sentence it ends ("_Hush._" splits after
    /// the period). Left alone it becomes a sentence of its own.
    private static func isClosingFragment(_ segment: Substring) -> Bool {
        var sawMark = false
        for character in segment where !character.isWhitespace {
            guard closingFragmentCharacters.contains(character) else { return false }
            sawMark = true
        }
        return sawMark
    }

    /// If the piece from `start` through `segments[i]` leaves a bracket open
    /// and a later segment closes it, that segment's index. NLTokenizer
    /// ignores brackets, so "[Illustration: The ship. It sank.]" would split
    /// into two pieces with a dangling bracket each, which skip-brackets
    /// (deciding per sentence) could not drop. Openers with no closer of
    /// their type later in the paragraph are ignored, as in `bracketMask`.
    ///
    /// Lengths count from the piece's own start, not from the opener. A
    /// merge that keeps the piece within the soft-split length is made. One
    /// that makes it longer is made only when soft-splitting the merged
    /// piece would still keep the whole bracketed span in one chunk (a
    /// short "(p. 810)" in a long sentence): otherwise the span is cut
    /// anyway, and the merge would only trade a natural sentence boundary
    /// for a clause cut. A piece is never grown past `longestBracketPiece`,
    /// which also bounds each call's scan.
    private static func bracketCloser(in text: String,
                                      from start: String.Index,
                                      through i: Int,
                                      segments: [Range<String.Index>],
                                      lastClosers: [Int]) -> Int? {
        // Brackets are ASCII, so scanning UTF-8 bytes is exact; lengths are
        // UTF-8 too, which only makes the length caps stricter.
        let base = text.utf8
        func utf8Offset(_ index: String.Index) -> Int {
            base.distance(from: base.startIndex, to: index)
        }
        /// End of the piece if it ran through `segments[j]`, trailing space
        /// excluded (pieces are trimmed).
        func pieceEnd(through j: Int) -> String.Index {
            var end = segments[j].upperBound
            while end > start, text[text.index(before: end)].isWhitespace {
                end = text.index(before: end)
            }
            return end
        }
        let pieceStart = utf8Offset(start)
        guard utf8Offset(pieceEnd(through: i)) - pieceStart <= longestBracketPiece else { return nil }

        var depth = [0, 0, 0]
        var openedAt = [0, 0, 0]   // where each type's outermost span began
        var offset = pieceStart
        func consume(_ byte: UInt8) {
            if let k = bracketOpeners.firstIndex(of: byte) {
                if depth[k] == 0 { openedAt[k] = offset }
                depth[k] += 1
            } else if let k = bracketClosers.firstIndex(of: byte), depth[k] > 0 {
                depth[k] -= 1
            }
            offset += 1
        }
        for byte in text[start..<segments[i].upperBound].utf8 { consume(byte) }
        guard depth.contains(where: { $0 > 0 }) else { return nil }

        // `offset` is now where the rest of the paragraph begins.
        let tracked = (0..<3).filter { depth[$0] > 0 && lastClosers[$0] >= offset }
        guard let spanStart = tracked.map({ openedAt[$0] }).min() else { return nil }

        for j in (i + 1)..<segments.count {
            let end = pieceEnd(through: j)
            let length = utf8Offset(end) - pieceStart
            if length > longestBracketPiece { return nil }
            offset = utf8Offset(segments[j].lowerBound)
            for byte in text[segments[j]].utf8 {
                consume(byte)
                // A span longer than one chunk is cut by soft-splitting anyway.
                if offset - spanStart > maxSentenceLength { return nil }
                guard tracked.allSatisfy({ depth[$0] == 0 }) else { continue }
                if length <= maxSentenceLength { return j }
                let span = base.index(base.startIndex, offsetBy: spanStart)
                    ..< base.index(base.startIndex, offsetBy: offset)
                let chunks = softSplitLongSentence(String(text[start..<end]))
                return chunks.contains { $0.contains(text[span]) } ? j : nil
            }
        }
        return nil
    }

    /// The longest piece (UTF-8 bytes) a bracket merge may build.
    private static let longestBracketPiece = 4 * maxSentenceLength

    private static let bracketOpeners: [UInt8] = [UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{")]
    private static let bracketClosers: [UInt8] = [UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}")]

    /// UTF-8 offset of the last ")", "]" and "}" in `text` (-1 when there is
    /// none), in `bracketClosers` order. Found once per paragraph, so
    /// `bracketCloser` never rescans the rest of the paragraph at each
    /// boundary (which made one huge paragraph quadratic).
    private static func lastCloserOffsets(in text: String) -> [Int] {
        var last = [-1, -1, -1]
        var offset = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: ")"): last[0] = offset
            case UInt8(ascii: "]"): last[1] = offset
            case UInt8(ascii: "}"): last[2] = offset
            default: break
            }
            offset += 1
        }
        return last
    }

    // Built once: a regex literal rebuilds its program on every evaluation,
    // and these run per paragraph or per boundary.
    private static let listMarkerRegex = #/\(?\d+[.)]/#
    private static let singleInitialRegex = #/[A-Za-z]\./#
    private static let initialismRegex = #/(?:[A-Za-z]\.){2,}/#
    private static let trailingEdgePunctRegex = #/[.,;:!?)"'\]_]+$/#
    private static let leadingEdgePunctRegex = #/^[("'\[_]+/#

    // MARK: - Soft split

    /// Break an over-long sentence on clause boundaries (then spaces, then a
    /// hard cut as a last resort) so one TTS request never gets a giant blob.
    static func softSplitLongSentence(_ sentence: String,
                                      maxLen: Int = maxSentenceLength) -> [String] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= maxLen { return s.isEmpty ? [] : [s] }

        let chars = Array(s)
        let clause: Set<Character> = [",", ";", ":", ")", "—", "–"]

        // Candidate cut points: the index just past clause punctuation + whitespace.
        var breaks: [Int] = []
        var i = 0
        while i < chars.count {
            if clause.contains(chars[i]) {
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j > i + 1 { breaks.append(j) }
                i = j
            } else {
                i += 1
            }
        }

        var chunks: [String] = []
        var start = 0
        while chars.count - start > maxLen {
            // Furthest clause break that still fits inside [start, start+maxLen].
            var cut = -1
            for b in breaks {
                if b <= start { continue }
                if b - start <= maxLen { cut = b } else { break }
            }
            if cut <= start {
                // Fall back to the last space that fits, else hard cut.
                var space = -1
                var k = min(start + maxLen, chars.count - 1)
                while k > start {
                    if chars[k] == " " { space = k; break }
                    k -= 1
                }
                cut = space > start ? space + 1 : start + maxLen
            }
            let chunk = String(chars[start..<cut]).trimmingCharacters(in: .whitespaces)
            if !chunk.isEmpty { chunks.append(chunk) }
            start = cut
        }
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// Full paragraph → chunk pipeline: sentence-split, then soft-split any
    /// over-long sentence.
    static func chunkParagraph(_ text: String,
                               maxLen: Int = maxSentenceLength) -> [String] {
        splitIntoSentences(text).flatMap { softSplitLongSentence($0, maxLen: maxLen) }
    }

    // MARK: - Word tokenization

    // Hot-path regexes, built once. Regex literals construct a fresh Regex
    // program on every evaluation, and these run per token (or per sentence)
    // on the playback schedule chain.
    private static let vowelRunRegex = #/[aeiouy]+/#
    private static let trailingPunctRegex = #/[.,;:!?…—–-]+$/#
    /// Standalone daggers are unspoken footnote markers. Asterisks are
    /// deliberately NOT here: a free-standing "*" is ambiguous — it can be
    /// multiplication ("2 * 3"), an emphasis marker, or a scene break
    /// ("* * *") — so only the unambiguous marks are dropped. A sentence
    /// that is nothing but a scene break is silenced by `isSeparatorRow`.
    private static let footnoteMarkerRegex = #/[†‡]+/#
    private static let whitespaceRunRegex = #/\s+/#
    private static let spaceBeforePunctRegex = #/\s+([,.;:!?…)\]}])/#

    /// Rough syllable estimate used to weight relative spoken duration.
    static func estimatedSyllables(_ word: String) -> Int {
        let s = word.lowercased().filter { ("a"..."z").contains($0) }
        guard !s.isEmpty else { return 0 }
        var count = s.matches(of: vowelRunRegex).count
        // Discount a silent final "e" but keep "-le" endings; never drop the
        // only vowel.
        if count > 1 && s.hasSuffix("e") && !s.hasSuffix("le") { count -= 1 }
        return max(1, count)
    }

    /// Extra pause weight from trailing punctuation; multiple marks accumulate.
    private static func trailingPauseWeight(_ token: String) -> Double {
        guard let match = token.firstMatch(of: trailingPunctRegex) else { return 0 }
        var extra = 0.0
        for ch in match.output {
            switch ch {
            case ".", "!", "?", "…": extra += 1.5
            case ",", ";", ":": extra += 0.5
            default: extra += 0.4 // dashes/hyphens — a brief break
            }
        }
        return extra
    }

    private static func tokenWeight(_ token: String) -> Double {
        Double(max(1, estimatedSyllables(token))) + trailingPauseWeight(token)
    }

    /// Per-character mask marking which characters fall inside a bracketed span
    /// (bracket characters included). Independent per-type depth counters;
    /// an opener is honoured only when a closer of its type exists somewhere in
    /// the sentence, and stray closers are ignored.
    static func bracketMask(_ text: String) -> [Bool] {
        let chars = Array(text)
        var inside = [Bool](repeating: false, count: chars.count)
        let hasClose: [Character: Bool] = [
            "(": chars.contains(")"),
            "[": chars.contains("]"),
            "{": chars.contains("}"),
        ]
        var pd = 0, sd = 0, cd = 0
        for (i, c) in chars.enumerated() {
            if (c == "(" || c == "[" || c == "{"), hasClose[c] == true {
                if c == "(" { pd += 1 } else if c == "[" { sd += 1 } else { cd += 1 }
                inside[i] = true
            } else if c == ")" && pd > 0 {
                inside[i] = true
                pd -= 1
            } else if c == "]" && sd > 0 {
                inside[i] = true
                sd -= 1
            } else if c == "}" && cd > 0 {
                inside[i] = true
                cd -= 1
            } else {
                inside[i] = pd > 0 || sd > 0 || cd > 0
            }
        }
        return inside
    }

    /// Per-character mask of the bracket spans that skipping REMOVES. A span
    /// from `bracketMask` is removable only when it is not glued to a word
    /// character (letter/digit) on either side: "item(s)" and
    /// "word(aside)more" stay intact, while "Result (see fig. 2), holds."
    /// drops the span but keeps the comma, and "as predicted [12]." drops
    /// the citation but keeps the period.
    static func skipMask(_ text: String) -> [Bool] {
        let chars = Array(text)
        let inside = bracketMask(text)
        var mask = [Bool](repeating: false, count: chars.count)
        var i = 0
        while i < chars.count {
            guard inside[i] else { i += 1; continue }
            var j = i
            while j < chars.count, inside[j] { j += 1 }
            let gluedBefore = i > 0 && isWordCharacter(chars[i - 1])
            let gluedAfter = j < chars.count && isWordCharacter(chars[j])
            if !gluedBefore && !gluedAfter {
                for k in i..<j { mask[k] = true }
            }
            i = j
        }
        return mask
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Split a sentence into display tokens. Non-destructive: concatenating
    /// every token's `text` reproduces the input verbatim. Runs of
    /// non-whitespace are additionally split where `skipMask` flips, so
    /// punctuation glued to a bracket closer ("2),", "[12].") becomes its own
    /// token and survives skipping. `isSkippable` marks removable bracket
    /// spans and standalone dagger footnote markers. A separator row's
    /// tokens weigh nothing: it plays as silence, so no word is timed or lit.
    static func tokenizeSentence(_ text: String) -> [WordToken] {
        let key = text as NSString
        if let hit = tokenCache.object(forKey: key) { return hit.tokens }

        let chars = Array(text)
        let mask = skipMask(text)
        let silentRow = isSeparatorRow(text)
        var tokens: [WordToken] = []
        var i = 0
        while i < chars.count {
            let isSpace = chars[i].isWhitespace
            let masked = mask[i]
            var j = i
            while j < chars.count, chars[j].isWhitespace == isSpace, mask[j] == masked { j += 1 }
            let raw = String(chars[i..<j])
            var skippable = masked

            if isSpace {
                tokens.append(WordToken(text: raw, isWord: false, weight: 0, isSkippable: skippable))
            } else {
                // Inline reference markers standing alone ("†", "‡", "††")
                // are unspoken citations too (see `footnoteMarkerRegex` for
                // why "*" is not one of them).
                if !skippable, raw.wholeMatch(of: footnoteMarkerRegex) != nil {
                    skippable = true
                }
                let isWord = raw.unicodeScalars.contains {
                    ("A"..."Z").contains(Character($0))
                        || ("a"..."z").contains(Character($0))
                        || ("0"..."9").contains(Character($0))
                }
                tokens.append(WordToken(text: raw,
                                        isWord: isWord,
                                        weight: silentRow ? 0 : tokenWeight(raw),
                                        isSkippable: skippable))
            }
            i = j
        }

        // A clause mark orphaned at the sentence start by a dropped leading
        // span ("(However), we left." → "we left.") is dropped with it.
        if let first = tokens.firstIndex(where: { !$0.isSkippable && $0.weight > 0 }),
           tokens[..<first].contains(where: \.isSkippable),
           tokens[first].text.allSatisfy({ ",;:".contains($0) }) {
            let t = tokens[first]
            tokens[first] = WordToken(text: t.text, isWord: t.isWord,
                                      weight: t.weight, isSkippable: true)
        }

        tokenCache.setObject(TokenBox(tokens), forKey: key)
        return tokens
    }

    /// Single source of truth for whether a token is present in the audio
    /// `spokenText` synthesizes. `WordTimingEstimator` consults the same
    /// predicate, so word windows always describe the actual clip.
    static func isSpoken(_ token: WordToken, skipBrackets: Bool) -> Bool {
        !(skipBrackets && token.isSkippable)
    }

    /// A scene break or rule: no letters or digits, and every other
    /// character one repeated glyph ("* * * * *", "*****", "-----",
    /// "• • •"). Kokoro's espeak fallback reads such symbols by name
    /// ("asterisk asterisk asterisk"), so the row is shown but never spoken.
    /// Mixed marks ("† *") are not a row.
    static func isSeparatorRow<S: StringProtocol>(_ text: S) -> Bool {
        var glyph: Character?
        for character in text where !character.isWhitespace {
            if character.isLetter || character.isNumber { return false }
            if let seen = glyph, seen != character { return false }
            glyph = character
        }
        return glyph != nil
    }

    /// The text to actually synthesize. With `skipBrackets` off the input is
    /// returned verbatim; with it on, removable bracket spans and standalone
    /// dagger markers are dropped and the survivors tidied: whitespace
    /// collapsed, no space left before punctuation, no orphaned leading
    /// comma. A sentence that skipping silences entirely (a bare citation
    /// "[12]", an "[Illustration: …]" line, a whole-sentence aside) returns
    /// "" — the playback layer schedules a short silence for it and moves
    /// on, so it is never read aloud. A separator row returns "" either way.
    static func spokenText(_ text: String, skipBrackets: Bool) -> String {
        // Decided at playback, not extraction, so scene breaks in books
        // already on the shelf go quiet without shifting a sentence index.
        if isSeparatorRow(text) { return "" }
        guard skipBrackets else { return text }
        let key = text as NSString
        if let hit = spokenCache.object(forKey: key) { return hit as String }
        let spoken = spokenText(tokens: tokenizeSentence(text), skipBrackets: true)
        spokenCache.setObject(spoken as NSString, forKey: key)
        return spoken
    }

    /// `spokenText` over pre-tokenized input (tokens must reproduce the
    /// sentence verbatim when joined, as `tokenizeSentence` guarantees).
    static func spokenText(tokens: [WordToken], skipBrackets: Bool) -> String {
        let verbatim = tokens.map(\.text).joined()
        if isSeparatorRow(verbatim) { return "" }
        guard skipBrackets else { return verbatim }
        var out = ""
        for token in tokens where isSpoken(token, skipBrackets: true) {
            out += token.text
        }
        return out
            .replacing(whitespaceRunRegex, with: " ")
            .replacing(spaceBeforePunctRegex) { String($0.output.1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Memoization

    /// Tokenization output for one sentence, boxed for NSCache.
    private final class TokenBox {
        let tokens: [WordToken]
        init(_ tokens: [WordToken]) { self.tokens = tokens }
    }

    /// One sentence is tokenized on several independent paths per playback
    /// step — synthesis text (`topUpSchedule`/`cuePrefetch`), word-timing
    /// windows, and the reader's word ranges — so both stages are memoized
    /// behind small content-keyed caches. NSCache is thread-safe and sheds
    /// under memory pressure; keying by the full text (not sentence index)
    /// means stale entries are impossible across documents.
    private static let tokenCache: NSCache<NSString, TokenBox> = {
        let cache = NSCache<NSString, TokenBox>()
        cache.countLimit = 256
        return cache
    }()

    private static let spokenCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()
}
