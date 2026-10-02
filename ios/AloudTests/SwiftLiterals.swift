import Foundation

/// One string literal in a Swift file: where it opens and what it says.
struct SwiftLiteral: Equatable {
    /// The file's path relative to the scanned root ("" for a lone source).
    let path: String
    /// The 1-based line of the opening quote.
    let line: Int
    /// The contents as written: escapes stay as typed (`\u{2026}` is eight
    /// characters, `\"` two) and each interpolation reads "{expr}".
    let text: String
}

/// A small Swift lexer for copy lints (R25). A raw text search trips on
/// comments, doc comments and identifiers that merely mention a banned word;
/// reading only string literals keeps a lint about what users see from
/// failing on what developers write.
///
/// It knows line, doc and nested block comments; regex literals (`#/…/#`
/// and bare `/…/`, which the build enables); and every string form ("…",
/// #"…"#, """…""" and the raw multi-line kind), with interpolations nested
/// to any depth, inner strings and parentheses included.
///
/// Foundation only, so it has no XCTest or app dependency.
enum SwiftLiterals {

    /// What each `\( … )` reads as in a literal's text.
    static let interpolation = "{expr}"

    /// Every top-level literal in `source`, in order. A literal nested in an
    /// interpolation is part of its outer literal's "{expr}", never its own.
    static func literals(in source: String, path: String = "") -> [SwiftLiteral] {
        var scanner = SwiftLexer(source)
        scanner.run()
        return scanner.literals.map { SwiftLiteral(path: path, line: $0.line, text: $0.text) }
    }

    /// The literals of every file in `sources` (relative path → text, as
    /// `SourceTree.sources()` returns) whose path starts with none of
    /// `prefixes`, ordered by path then position.
    static func literals(in sources: [String: String], excluding prefixes: [String]) -> [SwiftLiteral] {
        sources.keys.sorted()
            .filter { path in !prefixes.contains { path.hasPrefix($0) } }
            .flatMap { literals(in: sources[$0] ?? "", path: $0) }
    }

    /// `source` for symbol lints: comments removed, literal text blanked
    /// (`Text("Hi \(name)")` reads `Text("\(name)")`) and regex bodies
    /// dropped. Interpolated code stays, because it is code: a symbol used
    /// only inside `"\( … )"` is still used. Newlines stay put.
    static func code(in source: String) -> String {
        var scanner = SwiftLexer(source)
        scanner.run()
        return String(scanner.code)
    }

    /// True when `text` could be something a person reads: it has a letter
    /// (outside "{expr}" and escapes) and is not a dotted identifier
    /// (`library.card`, `play.fill`, `aloud.prefs.v1.rate`,
    /// `chapters.row.{expr}`), a URL, or a "-"-prefixed launch argument.
    static func isCopy(_ text: String) -> Bool {
        let readable = unescaped(text).replacingOccurrences(of: interpolation, with: "")
        guard readable.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return false }
        return !matches(dottedIdentifier, text) && !matches(url, text) && !matches(launchArgument, text)
    }

    /// `text` with Swift's escapes resolved (`\u{2026}` → "…", `\"` → `"`,
    /// `\n` → newline), so a needle matches however the copy was typed.
    /// "{expr}" placeholders stay.
    static func unescaped(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else {
                out.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            switch next {
            case "n": out.append("\n"); index += 2
            case "t": out.append("\t"); index += 2
            case "r": out.append("\r"); index += 2
            case "0": out.append("\0"); index += 2
            case "u":
                // \u{1F600}: up to 8 hex digits in braces.
                if index + 2 < scalars.count, scalars[index + 2] == "{",
                   let close = scalars[(index + 3)...].firstIndex(of: "}"),
                   let value = UInt32(String(String.UnicodeScalarView(scalars[(index + 3)..<close])), radix: 16),
                   let decoded = Unicode.Scalar(value) {
                    out.append(decoded)
                    index = close + 1
                } else {
                    out.append(next)
                    index += 2
                }
            default:
                // \" \' \\ and a line continuation's newline: the character itself.
                out.append(next)
                index += 2
            }
        }
        return String(out)
    }

    // MARK: - Classifiers

    private static let dottedIdentifier = regex(#"^[A-Za-z0-9_{}()-]+(\.[A-Za-z0-9_{}()-]+)+$"#)
    private static let url = regex(#"^[A-Za-z][A-Za-z0-9+.-]*://\S+$"#)
    private static let launchArgument = regex(#"^-{1,2}[A-Za-z][A-Za-z0-9_.-]*$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants above; one that fails to compile is a
        // bug in this file, caught by SwiftLiteralsTests.
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Bad pattern \(pattern)")
        }
        return regex
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The scanner behind `SwiftLiterals`: one pass that records top-level
/// literals and builds the code view at the same time.
private struct SwiftLexer {

    private(set) var literals: [(line: Int, text: String)] = []
    private(set) var code = String.UnicodeScalarView()

    private let chars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    /// The last non-blank character of code, which tells a bare regex's
    /// opening `/` (where an operand starts) from division.
    private var lastSignificant: Unicode.Scalar?

    init(_ source: String) {
        chars = Array(source.unicodeScalars)
    }

    mutating func run() {
        scanCode(insideInterpolation: false)
    }

    // MARK: Code

    /// Code to the end of the source or, inside an interpolation, up to and
    /// including the `)` that closes it (consumed, not emitted).
    private mutating func scanCode(insideInterpolation: Bool) {
        var depth = 0
        while index < chars.count {
            let char = chars[index]
            if char == "/", peek(1) == "/" { skipLineComment(); continue }
            if char == "/", peek(1) == "*" { skipBlockComment(); continue }
            if char == "/", startsBareRegex() { skipBareRegex(); continue }
            if char == "#" || char == "\"" {
                let hashes = countHashes()
                if peek(hashes) == "\"" {
                    let opening = line
                    let text = scanString(hashes: hashes)
                    // An inner string is part of its outer literal's "{expr}".
                    if !insideInterpolation { literals.append((opening, text)) }
                    continue
                }
                if hashes > 0, peek(hashes) == "/" { skipRegex(hashes: hashes); continue }
            }
            if insideInterpolation {
                if char == "(" { depth += 1 }
                if char == ")" {
                    if depth == 0 { advance(); return }
                    depth -= 1
                }
            }
            emit(advance())
        }
    }

    private mutating func skipLineComment() {
        // The newline itself is code, so lines still line up.
        while index < chars.count, chars[index] != "\n" { index += 1 }
    }

    /// `/* … */`, nested to any depth, as Swift allows.
    private mutating func skipBlockComment() {
        var depth = 0
        while index < chars.count {
            if matches("/*") { depth += 1; index += 2; continue }
            if matches("*/") {
                depth -= 1
                index += 2
                if depth == 0 { break }
                continue
            }
            skip()
        }
        // Keeps `a/**/b` from reading as `ab`.
        code.append(" ")
    }

    // MARK: Strings

    /// One string literal of any form, opening at `index` with `hashes`
    /// leading `#`. Returns its text as written, with "{expr}" for each
    /// interpolation; the code view keeps the delimiters and the
    /// interpolated code, and blanks the rest.
    private mutating func scanString(hashes: Int) -> String {
        let fence = String(repeating: "#", count: hashes)
        index += hashes
        let multiline = matches("\"\"\"")
        let quote = multiline ? "\"\"\"" : "\""
        index += quote.unicodeScalars.count
        emit(fence + quote)

        let closer = quote + fence
        // In a raw string only a backslash followed by the same number of
        // hashes escapes or interpolates; a bare one is just a character.
        let escape = "\\" + fence
        var text = String.UnicodeScalarView()
        while index < chars.count {
            if matches(closer) { index += closer.unicodeScalars.count; break }
            let char = chars[index]
            // An unterminated single-line literal stops at its line's end
            // instead of swallowing the rest of the file.
            if char == "\n", !multiline { break }
            if matches(escape) {
                index += escape.unicodeScalars.count
                if peek() == "(" {
                    advance()
                    text.append(contentsOf: SwiftLiterals.interpolation.unicodeScalars)
                    emit(escape + "(")
                    scanCode(insideInterpolation: true)
                    emit(")")
                } else {
                    text.append(contentsOf: escape.unicodeScalars)
                    if index < chars.count { text.append(chars[index]); skip() }
                }
                continue
            }
            text.append(char)
            skip()
        }
        emit(closer)
        let written = String(text)
        return multiline ? Self.dedented(written) : written
    }

    /// A multi-line literal's value: the line break after the opening
    /// delimiter and the closing delimiter's line are not content, and the
    /// closing delimiter's indentation is every line's margin.
    private static func dedented(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        guard lines.count >= 2 else { return raw }
        lines.removeFirst()
        let margin = lines.removeLast()
        guard margin.allSatisfy({ $0 == " " || $0 == "\t" }) else { return raw }
        return lines
            .map { $0.hasPrefix(margin) ? String($0.dropFirst(margin.count)) : $0 }
            .joined(separator: "\n")
    }

    // MARK: Regex literals

    /// `#/…/#` (or with more hashes): skipped whole, since a quote in a
    /// pattern is not a string.
    private mutating func skipRegex(hashes: Int) {
        let fence = String(repeating: "#", count: hashes)
        index += hashes + 1
        emit(fence + "/")
        let closer = "/" + fence
        while index < chars.count {
            if matches(closer) { index += closer.unicodeScalars.count; break }
            if chars[index] == "\\" { skip() }
            if index < chars.count { skip() }
        }
        emit("/" + fence)
    }

    /// A bare `/…/` regex opens where an operand must start (after `=`, `(`,
    /// `,`, `:`, `[`, `{` or `;`), is not followed by a space, and closes on
    /// the same line. Division (`a / b`) never follows one of those.
    private func startsBareRegex() -> Bool {
        guard let next = peek(1), !next.properties.isWhitespace,
              let last = lastSignificant, "=(,:[{;".unicodeScalars.contains(last) else { return false }
        var at = index + 1
        while at < chars.count, chars[at] != "\n" {
            if chars[at] == "\\" {
                // An escaped line break would carry the pattern onto the next line.
                guard at + 1 < chars.count, chars[at + 1] != "\n" else { return false }
                at += 2
                continue
            }
            if chars[at] == "/" { return true }
            at += 1
        }
        return false
    }

    private mutating func skipBareRegex() {
        index += 1
        emit("/")
        while index < chars.count, chars[index] != "/" {
            if chars[index] == "\\" { index += 1 }
            index += 1
        }
        index = min(index + 1, chars.count)
        emit("/")
    }

    // MARK: Primitives

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let at = index + offset
        return at < chars.count ? chars[at] : nil
    }

    private func countHashes() -> Int {
        var count = 0
        while peek(count) == "#" { count += 1 }
        return count
    }

    /// Whether the source continues with `text` at `index`.
    private func matches(_ text: String) -> Bool {
        var at = index
        for scalar in text.unicodeScalars {
            guard at < chars.count, chars[at] == scalar else { return false }
            at += 1
        }
        return true
    }

    /// Consumes one character, counting lines.
    @discardableResult
    private mutating func advance() -> Unicode.Scalar {
        let char = chars[index]
        index += 1
        if char == "\n" { line += 1 }
        return char
    }

    /// Consumes a character the code view blanks, keeping a newline.
    private mutating func skip() {
        if advance() == "\n" { code.append("\n") }
    }

    private mutating func emit(_ char: Unicode.Scalar) {
        code.append(char)
        if !char.properties.isWhitespace { lastSignificant = char }
    }

    private mutating func emit(_ text: String) {
        text.unicodeScalars.forEach { emit($0) }
    }
}
