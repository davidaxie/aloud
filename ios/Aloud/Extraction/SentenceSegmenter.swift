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
        "no", "nos", "vol", "pp", "fig", "figs", "eq", "ref", "ed", "eds", "repr",
    ]

    // MARK: - Sentence splitting

    /// Split a paragraph into trimmed, non-empty sentences. Uses NLTokenizer,
    /// then repairs boundaries that fell on abbreviations, initials,
    /// initialisms, or bare list markers.
    static func splitIntoSentences(_ text: String) -> [String] {
        let normalized = text
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let raw = rawSplit(normalized)

        var merged: [String] = []
        var i = 0
        while i < raw.count {
            var piece = raw[i]
            while i < raw.count - 1 && endsWithAbbreviation(piece) {
                i += 1
                // Preserve a single space across the undone boundary.
                piece = piece.replacing(#/\s+$/#, with: "")
                    + " "
                    + raw[i].replacing(#/^\s+/#, with: "")
            }
            let cleaned = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { merged.append(cleaned) }
            i += 1
        }
        return merged
    }

    private static func rawSplit(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let segment = String(text[range])
            if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(segment)
            }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    /// Should the boundary at the end of `seg` be merged into the next segment?
    private static func endsWithAbbreviation(_ seg: String) -> Bool {
        let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare list / enumeration marker like "1." or "2)" left dangling.
        if trimmed.wholeMatch(of: #/\(?\d+[.)]/#) != nil { return true }

        guard let last = trimmed.split(whereSeparator: \.isWhitespace).last else { return false }
        let lastToken = String(last)
        // Single initial ("J.") or initialism ("U.S.", "e.g.", "a.m.").
        if lastToken.wholeMatch(of: #/[A-Za-z]\./#) != nil { return true }
        if lastToken.wholeMatch(of: #/(?:[A-Za-z]\.){2,}/#) != nil { return true }

        // Known abbreviation word (strip trailing dot, ignore edge punctuation).
        let bare = lastToken
            .replacing(#/[.,;:!?)"'\]]+$/#, with: "")
            .replacing(#/^[("'\[]+/#, with: "")
            .lowercased()
        return abbreviations.contains(bare)
    }

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

    /// Rough syllable estimate used to weight relative spoken duration.
    static func estimatedSyllables(_ word: String) -> Int {
        let s = word.lowercased().filter { ("a"..."z").contains($0) }
        guard !s.isEmpty else { return 0 }
        var count = s.matches(of: #/[aeiouy]+/#).count
        // Discount a silent final "e" but keep "-le" endings; never drop the
        // only vowel.
        if count > 1 && s.hasSuffix("e") && !s.hasSuffix("le") { count -= 1 }
        return max(1, count)
    }

    /// Extra pause weight from trailing punctuation; multiple marks accumulate.
    private static func trailingPauseWeight(_ token: String) -> Double {
        guard let match = token.firstMatch(of: #/[.,;:!?…—–-]+$/#) else { return 0 }
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

    /// Split a sentence into display tokens. Non-destructive: concatenating
    /// every token's `text` reproduces the input verbatim. `isSkippable` is
    /// true when the whole token lies inside a bracketed span, or when the
    /// token is a standalone footnote marker (†, ‡, *).
    static func tokenizeSentence(_ text: String) -> [WordToken] {
        let chars = Array(text)
        let inside = bracketMask(text)
        var tokens: [WordToken] = []
        var i = 0
        while i < chars.count {
            let isSpace = chars[i].isWhitespace
            var j = i
            while j < chars.count && chars[j].isWhitespace == isSpace { j += 1 }
            let raw = String(chars[i..<j])

            var skippable = true
            for k in i..<j where !inside[k] {
                skippable = false
                break
            }

            if isSpace {
                tokens.append(WordToken(text: raw, isWord: false, weight: 0, isSkippable: skippable))
            } else {
                // Inline reference markers standing alone ("†", "*", "‡", "**")
                // are unspoken citations too.
                if !skippable, raw.wholeMatch(of: #/[†‡*]+/#) != nil {
                    skippable = true
                }
                let isWord = raw.unicodeScalars.contains {
                    ("A"..."Z").contains(Character($0))
                        || ("a"..."z").contains(Character($0))
                        || ("0"..."9").contains(Character($0))
                }
                tokens.append(WordToken(text: raw,
                                        isWord: isWord,
                                        weight: tokenWeight(raw),
                                        isSkippable: skippable))
            }
            i = j
        }
        return tokens
    }

    /// The text to actually synthesize. With `skipBrackets` off the input is
    /// returned verbatim; with it on, bracketed tokens and standalone footnote
    /// markers are dropped and the surviving whitespace tidied so no doubled
    /// spaces or floating punctuation remain. A sentence that skipping would
    /// silence entirely (e.g. one wrapped whole in parentheses) is spoken in
    /// full instead.
    static func spokenText(_ text: String, skipBrackets: Bool) -> String {
        guard skipBrackets else { return text }
        var out = ""
        for token in tokenizeSentence(text) where !token.isSkippable {
            out += token.text
        }
        let cleaned = out
            .replacing(#/\s+/#, with: " ")
            .replacing(#/\s+([,.;:!?…)\]}])/#) { String($0.output.1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Never skip a sentence into silence: fall back to the original.
        return cleaned.isEmpty ? text : cleaned
    }
}
