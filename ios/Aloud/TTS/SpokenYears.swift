import Foundation

/// How the Kokoro voice should say four-digit years. Its espeak-ng fallback
/// reads "1915" as "nineteen hundred fifteen"; people say "nineteen fifteen".
///
/// Spoken text only: applied to the string handed to sherpa-onnx, never to
/// the stored, displayed or searched text, so sentence ids, the word
/// highlight (laid out over display tokens) and Contents search ("1915"
/// still finds 1915) are untouched.
///
/// Conservative by construction: a number is rewritten only when it is a
/// standalone run of four ASCII digits in 1100...2099. Money, percentages,
/// decimals, thousands groups, times, fractions, signed numbers, phone-style
/// groups and digits glued to letters are left exactly as written, as are
/// 1000...1099 and anything from 2100. Output words are joined by spaces, not
/// hyphens: every one is in the bundled Kokoro lexicons, "twenty-five" is not.
enum SpokenYears {

    /// `text` with its years spelled the way they are said. `british` reads
    /// 2001...2009 as "two thousand and five".
    static func apply(to text: String, british: Bool = false) -> String {
        guard text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return text }
        let s = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count + 32)
        var i = 0
        while i < s.count {
            // Only the first digit of a run that nothing word-like precedes.
            guard isDigit(s[i]), i == 0 || !(s[i - 1].isLetter || s[i - 1].isNumber) else {
                out.append(s[i]); i += 1; continue
            }
            let a = run(s, i)
            if let r = range(s, a, british: british) {
                out += r.text; i = r.end; continue
            }
            if let spoken = single(s, a, british: british) {
                out += spoken; i = a.end
            } else {
                out += String(s[a.start..<a.digitsEnd]); i = a.digitsEnd
            }
        }
        return out
    }

    // MARK: - Words

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven",
                               "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                               "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty",
                               "sixty", "seventy", "eighty", "ninety"]

    /// 0...99 in words.
    private static func words(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        return n % 10 == 0 ? tens[n / 10] : tens[n / 10] + " " + ones[n % 10]
    }

    /// The two digits after the century: "oh five", "fifteen"; nil for 00.
    private static func tail(_ r: Int) -> String? {
        if r == 0 { return nil }
        return r < 10 ? "oh " + ones[r] : words(r)
    }

    /// 1100...2099 as said: "nineteen fifteen", "nineteen hundred",
    /// "nineteen oh five", "two thousand five", "twenty twenty five".
    static func year(_ n: Int, british: Bool = false) -> String {
        if (2000...2009).contains(n) {
            let r = n - 2000
            return r == 0 ? "two thousand" : "two thousand " + (british ? "and " : "") + ones[r]
        }
        return words(n / 100) + (tail(n % 100).map { " " + $0 } ?? " hundred")
    }

    /// "nineteen twenty" → "nineteen twenties"; "… hundred" → "… hundreds".
    private static func decade(_ spoken: String) -> String {
        spoken.hasSuffix("y") ? String(spoken.dropLast()) + "ies" : spoken + "s"
    }

    // MARK: - Scanning

    private struct Run {
        let start: Int, digitsEnd: Int
        let value: Int, length: Int
        enum Suffix { case none, s, apostropheS }
        let suffix: Suffix
        /// After the suffix.
        let end: Int
    }

    private static func run(_ s: [Character], _ i: Int) -> Run {
        var j = i
        var value = 0
        while j < s.count, isDigit(s[j]) {
            value = j - i < 9 ? value * 10 + Int(s[j].asciiValue! - 48) : Int.max
            j += 1
        }
        func boundary(_ k: Int) -> Bool { k == s.count || !(s[k].isLetter || s[k].isNumber) }
        var suffix = Run.Suffix.none, end = j
        if j < s.count, s[j] == "s", boundary(j + 1) {
            suffix = .s; end = j + 1
        } else if j + 1 < s.count, s[j] == "'" || s[j] == "\u{2019}", s[j + 1] == "s", boundary(j + 2) {
            suffix = .apostropheS; end = j + 2
        }
        return Run(start: i, digitsEnd: j, value: value, length: j - i, suffix: suffix, end: end)
    }

    private static func isDigit(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return v >= 48 && v <= 57
    }

    private static func inRange(_ n: Int) -> Bool { (1100...2099).contains(n) }

    /// Nothing before the run turns it into money, a signed number, the far
    /// end of a group ("555-1915", "3.1915", "12:1915", "3/1915"), a bare
    /// decimal (".1250") or an issue number. A hyphen after a letter is a
    /// prefix: "mid-1920s"; a dot after one an abbreviation: "c.1250".
    private static func leftOK(_ s: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let p = s[i - 1]
        if "$£€¥₹#+−±@&".contains(p) { return false }
        if isHyphen(p) { return i >= 2 && s[i - 2].isLetter }
        if p == "." { return i >= 2 && s[i - 2].isLetter }
        if ",:/×".contains(p), i >= 2, isDigit(s[i - 2]) { return false }
        return true
    }

    /// ASCII "-" and the Unicode hyphens NFKC leaves (U+2010, U+2011).
    private static func isHyphen(_ c: Character) -> Bool {
        c == "-" || c == "\u{2010}" || c == "\u{2011}"
    }

    /// Superscript digits: footnote marks ("1915¹").
    private static func isSuperscript(_ c: Character) -> Bool {
        "\u{B9}\u{B2}\u{B3}\u{2070}\u{2074}\u{2075}\u{2076}\u{2077}\u{2078}\u{2079}".contains(c)
    }

    /// Nothing after the digits makes them a percentage, a decimal or a
    /// thousands group, a time, a fraction ("1250½"), degrees, or part of a
    /// word. A superscript footnote mark ("1915¹") may follow.
    private static func rightOK(_ s: [Character], _ j: Int) -> Bool {
        guard j < s.count else { return true }
        let c = s[j]
        if c.isLetter || (c.isNumber && !isSuperscript(c)) || "%‰°".contains(c) { return false }
        if ".,:/×".contains(c), j + 1 < s.count, isDigit(s[j + 1]) { return false }
        let rest = String(s[j..<min(s.count, j + 12)]).drop(while: { $0 == " " }).lowercased()
        return !(rest.hasPrefix("%") || rest.hasPrefix("percent") || rest.hasPrefix("per cent"))
    }

    // MARK: - One number

    private static func single(_ s: [Character], _ a: Run, british: Bool) -> String? {
        guard a.length == 4, inRange(a.value), leftOK(s, a.start) else { return nil }
        let spoken = year(a.value, british: british)
        switch a.suffix {
        case .s:
            return a.value % 10 == 0 ? decade(spoken) : nil      // "1920s"; "1915s" stays
        case .apostropheS:
            return a.value % 10 == 0 ? decade(spoken) : spoken + "'s"
        case .none:
            guard rightOK(s, a.digitsEnd),
                  !isCount(s, start: a.start, end: a.digitsEnd, round: a.value % 100 == 0) else { return nil }
            return spoken
        }
    }

    /// "1507 tons", "1350-1400 years": a count, left to the engine. Round
    /// hundreds read the same either way ("fifteen hundred soldiers").
    private static func isCount(_ s: [Character], start: Int, end: Int, round: Bool) -> Bool {
        !round && countNouns.contains(nextWord(s, end)) && !yearCues.contains(previousWord(s, start))
    }

    /// A non-round number before one of these is a count ("1350 years
    /// before", "1269 metres"), left to the engine's own reading, unless
    /// `yearCues` says otherwise ("In 1915 men…"). Round hundreds read the
    /// same either way ("fifteen hundred soldiers"). TextNormalizer reads a
    /// dash after a year before one as a clause break ("1915—20 years").
    static let countNouns: Set<String> = [
        "men", "women", "people", "persons", "soldiers", "troops", "horses", "ships", "guns",
        "prisoners", "inhabitants", "souls", "copies", "pages", "lines", "verses", "words",
        "miles", "mile", "yards", "yard", "feet", "foot", "ft", "metres", "meters", "metre",
        "meter", "km", "kilometres", "kilometers", "acres", "tons", "tonnes", "pounds", "lbs",
        "lb", "dollars", "francs", "livres", "ducats", "guineas", "rupees", "crowns", "years",
        "square", "sq", "cubic", "degrees", "kg", "kilograms", "grams", "ounces", "inches", "leagues",
        "fathoms", "hectares", "gallons", "children", "families", "houses", "households", "votes",
        "deaths", "casualties", "volumes", "books", "head",
    ]

    private static let yearCues: Set<String> = [
        "in", "year", "since", "until", "till", "circa", "c", "ca", "ad", "anno",
        "summer", "winter", "spring", "autumn", "fall",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// The lowercased letters after exactly one space, or "".
    private static func nextWord(_ s: [Character], _ j: Int) -> String {
        guard j < s.count, s[j] == " " else { return "" }
        var k = j + 1
        while k < s.count, s[k].isLetter { k += 1 }
        return String(s[(j + 1)..<k]).lowercased()
    }

    /// The word before `i` (skipping spaces and an opening bracket or
    /// quote), dots dropped: "A.D." → "ad".
    private static func previousWord(_ s: [Character], _ i: Int) -> String {
        var j = i
        while j > 0, " (\"'[".contains(s[j - 1]) { j -= 1 }
        var k = j
        while k > 0, s[k - 1].isLetter || s[k - 1] == "." { k -= 1 }
        return String(s[k..<j]).replacingOccurrences(of: ".", with: "").lowercased()
    }

    // MARK: - Ranges

    /// The index of the digit after a dash at `k`, allowing one space on
    /// either side of it, and whether a space was there; nil when there's
    /// no such dash.
    private static func dashThenDigit(_ s: [Character], _ k: Int) -> (digit: Int, spaced: Bool)? {
        var d = k
        if d < s.count, s[d] == " " { d += 1 }
        guard d + 1 < s.count, isHyphen(s[d]) else { return nil }
        var e = d + 1
        if e < s.count, s[e] == " " { e += 1 }
        guard e < s.count, isDigit(s[e]) else { return nil }
        return (e, d > k || e > d + 1)
    }

    /// "1914-1918", "1914 - 18", "1862-3", "1920s-1930s", "1920s-30s" → "… to …". Any
    /// other number-dash-number group ("2015-03-14", "1050 - 1150",
    /// "1874-5-6-7") is returned untouched as a whole, so its far end is
    /// never read as a year on its own.
    private static func range(_ s: [Character], _ a: Run, british: Bool) -> (text: String, end: Int)? {
        guard a.suffix != .apostropheS, let dash = dashThenDigit(s, a.end) else { return nil }
        let b = run(s, dash.digit)
        // "1874-5-6-7", "1914 - 1918 - 1939" (en dashes, normalized): a
        // chain is never a range, and stays untouched to its last number.
        // Only the same dash continues it: in "1-25 - 1469-94" the spaced
        // one separates two groups.
        var groupEnd = b.end
        while let next = dashThenDigit(s, groupEnd), next.spaced == dash.spaced {
            groupEnd = run(s, next.digit).end
        }
        let chained = groupEnd != b.end
        let untouched = (text: String(s[a.start..<groupEnd]), end: groupEnd)
        guard a.length == 4, inRange(a.value), leftOK(s, a.start), !chained,
              b.suffix == a.suffix, rightOK(s, b.suffix == .none ? b.digitsEnd : b.end)
        else { return untouched }
        if a.suffix == .none,
           isCount(s, start: a.start, end: b.digitsEnd, round: a.value % 100 == 0 && b.value % 100 == 0) {
            return untouched
        }

        switch (b.length, a.suffix) {
        case (4, _):
            guard inRange(b.value), b.value > a.value else { return untouched }
            if a.suffix == .s {
                guard a.value % 10 == 0, b.value % 10 == 0 else { return untouched }
                return (decade(year(a.value, british: british)) + " to "
                        + decade(year(b.value, british: british)), b.end)
            }
            return (year(a.value, british: british) + " to " + year(b.value, british: british), b.end)
        case (2, .none):
            let full = a.value - a.value % 100 + b.value
            guard full > a.value, let t = tail(b.value) else { return untouched }
            let end = (2000...2009).contains(a.value) ? year(full, british: british) : t
            return (year(a.value, british: british) + " to " + end, b.end)
        case (2, .s):
            // "1920s-30s" → "nineteen twenties to thirties".
            let full = a.value - a.value % 100 + b.value
            guard a.value % 10 == 0, b.value % 10 == 0, full > a.value else { return untouched }
            let end = (2000...2009).contains(a.value) ? decade(year(full, british: british)) : decade(words(b.value))
            return (decade(year(a.value, british: british)) + " to " + end, b.end)
        case (1, .none):
            let full = a.value - a.value % 10 + b.value
            guard full > a.value, !(2000...2009).contains(full), let t = tail(full % 100)
            else { return untouched }
            return (year(a.value, british: british) + " to " + t, b.end)
        default:
            return untouched
        }
    }
}

/// How roman numerals that number a chapter are said. espeak-ng reads "XI"
/// letter by letter and a lone "I" as the pronoun, so a heading came out as
/// a string of letter names.
///
/// Spoken text only, like `SpokenYears`: display text, sentence ranges,
/// `contentHash`, word timing and clip-cache keys never see it. Numerals are
/// recognised by the matcher the chapter list uses (`DocContent.romanNumeral`),
/// so real words built from roman letters stay words.
enum SpokenNumerals {

    /// The heading word a bare chapter numeral is said with (spoken copy).
    static let chapterWord = "Chapter"

    /// Headings that number what follows.
    private static let keywordNumeral =
        #/\b((?i:chapter|book|part|volume|stave|act|scene|canto|letter))(\h+)([IVXLCDMivxlcdm]+)\b/#

    /// The keyword rule, for Kokoro (an English-only voice): a roman numeral
    /// after a heading word becomes its cardinal, the heading word and the
    /// punctuation kept as written. A lone letter must be I, V or X after a
    /// capitalized heading word, with no lowercase word straight after it,
    /// so the pronoun after "book" and lettered parts stay letters.
    /// Lowercase numerals stop below 400, so short words spelled with roman
    /// letters stay words.
    static func apply(to text: String) -> String {
        text.replacing(keywordNumeral) { match in
            let (whole, keyword, gap, numeral) = match.output
            guard let value = numeralValue(numeral) else { return String(whole) }
            if numeral.count == 1 {
                guard "IVX".contains(numeral), keyword.first?.isUppercase == true else { return String(whole) }
                let rest = text[match.range.upperBound...].drop { $0 == " " || $0 == "\u{00A0}" }
                if let next = rest.first, next.isLowercase { return String(whole) }
            }
            return String(keyword) + String(gap) + cardinal(value)
        }
    }

    /// The bare-heading rule, for Kokoro and an English System voice: a
    /// sentence that is nothing but a numeral (a trailing period allowed).
    /// Opening a chapter it is said as one, the way Contents shows it;
    /// elsewhere a roman numeral of two or more letters in one case and
    /// below 400 (section numbers, not a word spelled in roman letters) is
    /// said as its cardinal. A lone letter that opens nothing and an arabic
    /// number are left as they are.
    static func bareHeading(_ text: String, opensChapter: Bool) -> String {
        var core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if core.hasSuffix("."), !core.hasSuffix("..") { core.removeLast() }
        guard DocContent.isBareNumeral(core) else { return text }
        if opensChapter {
            guard let value = Int(core) ?? romanValue(core) else { return text }
            return chapterWord + " " + cardinal(value)
        }
        guard core.count > 1, let value = numeralValue(Substring(core)), value < 400 else { return text }
        return cardinal(value)
    }

    /// A roman numeral in one case: any value in capitals, below 400 in
    /// lowercase. nil for anything else.
    private static func numeralValue(_ numeral: Substring) -> Int? {
        let upper = numeral.uppercased()
        if numeral != Substring(upper) {
            guard numeral == Substring(numeral.lowercased()), !upper.contains(where: { "DM".contains($0) })
            else { return nil }
        }
        return romanValue(upper)
    }

    /// The value of a well-formed roman numeral, any case; nil otherwise.
    static func romanValue(_ numeral: String) -> Int? {
        let upper = numeral.uppercased()
        guard !upper.isEmpty, upper.wholeMatch(of: DocContent.romanNumeral) != nil else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0, largest = 0
        for letter in upper.reversed() {
            guard let value = values[letter] else { return nil }
            if value < largest { total -= value } else { total += value; largest = value }
        }
        return total
    }

    /// `value` in American English words, joined by spaces as `SpokenYears`
    /// joins its words: "eleven", "twenty one", "one hundred four".
    static func cardinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return words.replacingOccurrences(of: "-", with: " ")
    }
}
