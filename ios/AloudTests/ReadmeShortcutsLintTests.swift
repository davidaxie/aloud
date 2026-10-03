import Foundation
import XCTest

/// README's keyboard table, held to the one keyboard table (mac-prd M20).
/// The rows between README's `shortcuts:begin` and `shortcuts:end` markers
/// are every `MacCommand` with a key, in the enum's order, each with:
/// - the key as the menus spell it (`MacShortcut.symbol`: "⇧⌘O", "Space"),
///   read through MacShortcutKey's and MacModifiers' own spellings;
/// - the title at rest (`MacCommand.title`, a `MacMenuCopy` string);
/// - the menu it sits in (`MacCommand.menu`).
/// Change a key, a title or a command in AloudMac/Commands/MacShortcuts.swift
/// and this fails until README says the same; the failure prints the rows.
/// README's relative links are checked too, so the airplane check and the
/// legacy notes can't move out from under it, and so is M20's other lint:
/// nothing in ios/ reaches into the legacy web app.
///
/// iOS suite only: the Mac bundle excludes every *LintTests file.
final class ReadmeShortcutsLintTests: XCTestCase {

    /// The checkout's root: ios/'s parent.
    static let checkoutRoot = SourceTree.iosRoot.deletingLastPathComponent()

    static let readme = checkoutRoot.appendingPathComponent("README.md", isDirectory: false)

    private static let shortcutsPath = SourceTree.macPrefix + "Commands/MacShortcuts.swift"

    /// The opening marker may carry a note after it; the closing one can't.
    static let beginMarker = "<!-- shortcuts:begin"
    static let endMarker = "<!-- shortcuts:end -->"
    static let header = ["Keys", "Command", "Menu"]

    /// The markdown files whose relative links must resolve, from the root.
    private static let linkedDocuments = ["README.md", "docs/legacy-web-app.md"]

    // MARK: - The table

    func testTheReadmeTableIsTheKeyboardTable() throws {
        let expected = try Self.sourceRows(in: try Self.shortcutsSource())
        XCTAssertGreaterThan(expected.count, 20, "the reader finds the table's keys")
        let listed = try Self.readmeRows(in: try Self.text(of: Self.readme))

        let missing = expected.filter { !listed.contains($0) }.map(\.markdown)
        let extra = listed.filter { !expected.contains($0) }.map(\.markdown)
        XCTAssertEqual(missing, [], "README's table lacks these MacShortcuts rows")
        XCTAssertEqual(extra, [], "README's table has rows MacShortcuts doesn't")
        XCTAssertEqual(listed.map(\.markdown), expected.map(\.markdown),
                       "README's table, in MacShortcuts' order, should read:\n" + Self.markdown(of: expected))
    }

    /// M20: the native apps stand alone. No string in either app's code,
    /// and no line of the project spec or ios/'s scripts, names the legacy
    /// web app's folders or its server. Doc comments may still say what a
    /// file was ported from.
    func testNothingInIOSReachesIntoTheLegacyWebApp() throws {
        let literals = SwiftLiterals.literals(in: try SourceTree.appSources(), excluding: [])
        XCTAssertGreaterThan(literals.count, 100, "the reader finds the apps' strings")
        let reaching = literals.filter { literal in Self.legacyNeedles.contains { literal.text.contains($0) } }
            .map { "\($0.path):\($0.line) \($0.text)" }
        XCTAssertEqual(reaching, [], "the apps reach into the legacy web app")

        let ios = SourceTree.iosRoot
        let scripts = try FileManager.default.contentsOfDirectory(atPath: ios.path).filter { $0.hasSuffix(".sh") }
            + FileManager.default.contentsOfDirectory(atPath: ios.appendingPathComponent("tools").path)
            .filter { $0.hasSuffix(".sh") }.map { "tools/" + $0 }
        XCTAssertTrue(scripts.contains("xcb.sh") && scripts.contains("tools/fetch_kokoro_model.sh"),
                      "the reader finds ios/'s scripts")
        for file in ["project.yml"] + scripts.sorted() {
            let lines = try Self.text(of: ios.appendingPathComponent(file)).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                // A shell or YAML comment may mention them; code may not.
                let code = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    ? "" : line.components(separatedBy: " #")[0]
                for needle in Self.legacyNeedles where code.contains(needle) {
                    XCTFail("ios/\(file):\(index + 1) names '\(needle)': \(line)")
                }
            }
        }
    }

    /// The legacy web app's folders and its two local servers.
    static let legacyNeedles = ["backend/", "frontend/", "extension/", "native_app", "localhost:8000",
                                "localhost:5173"]

    func testTheReadmeLinksReachTheirFiles() throws {
        var checked = 0
        for document in Self.linkedDocuments {
            let url = Self.checkoutRoot.appendingPathComponent(document)
            let base = url.deletingLastPathComponent()
            for target in Self.relativeLinks(in: try Self.text(of: url)) {
                let path = target.components(separatedBy: "#")[0]
                let resolved = base.appendingPathComponent(path).standardizedFileURL.path
                XCTAssertTrue(FileManager.default.fileExists(atPath: resolved),
                              "\(document) links \(target), which isn't in the checkout")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 2, "the reader finds the links")
        XCTAssertTrue(Self.relativeLinks(in: try Self.text(of: Self.readme)).contains("./docs/mac-airplane-check.md"),
                      "README links the airplane check")
    }

    // MARK: - The readers, on fixed text

    /// The readers run on text of their own, so a lint that finds nothing
    /// to compare can't pass by accident.
    func testKeysAreSpelledAsTheMenusSpellThem() {
        let spelling = Spelling(namedKeys: ["space": "Space", "leftArrow": "←", "rightArrow": "→", "delete": "⌫"],
                                modifiers: [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")])
        let cases = [
            #"MacShortcut(key: .character("o"), modifiers: [.shift, .command])"#: "⇧⌘O",
            #"MacShortcut(key: .character("s"), modifiers: [.command, .control])"#: "⌃⌘S",
            #"MacShortcut(key: .leftArrow, modifiers: .command)"#: "⌘←",
            #"MacShortcut(key: .delete, modifiers: .command)"#: "⌘⌫",
            #"MacShortcut(key: .character("]"))"#: "]",
            #"MacShortcut(key: .space)"#: "Space",
        ]
        for (expression, keys) in cases {
            XCTAssertEqual(MacKeyCommandLintTests.Binding(shortcut: expression).flatMap(spelling.keys(for:)), keys,
                           expression)
        }
        XCTAssertNil(MacKeyCommandLintTests.Binding(shortcut: #"MacShortcut(key: .tab)"#).flatMap(spelling.keys(for:)),
                     "a key the source can't spell is no row")
    }

    func testCopyLiteralsReadAsTheyShow() {
        XCTAssertEqual(Self.unescaped(#"Find\u{2026}"#), "Find…")
        XCTAssertEqual(Self.unescaped(#"Say \"hi\" \\ now"#), #"Say "hi" \ now"#)
        XCTAssertNil(Self.unescaped(#"Hi \(name)"#), "an interpolated title has no fixed text")
        let copy = Self.copyStrings(in: #"""
            enum MacMenuCopy {
                static let find = "Find\u{2026}"
                static let all: Set<String> = [find]
            }
            """#)
        XCTAssertEqual(copy, ["find": "Find…"])
    }

    func testTheTableReaderTakesOnlyTheMarkedTable() throws {
        let readme = """
            | Key | Action |
            |---|---|
            | `Space` | Play / pause |

            <!-- shortcuts:begin (a note) -->
            | Keys | Command | Menu |
            |---|:--|---|
            | `⇧⌘O` | Add a Classic… | File |
            |  `Space`  |  Play  |  Playback  |
            <!-- shortcuts:end -->
            """
        XCTAssertEqual(try Self.readmeRows(in: readme),
                       [Row(keys: "⇧⌘O", title: "Add a Classic…", menu: "File"),
                        Row(keys: "Space", title: "Play", menu: "Playback")])

        let renamed = readme.replacingOccurrences(of: "| Keys | Command | Menu |", with: "| Key | Command | Menu |")
        XCTAssertThrowsError(try Self.readmeRows(in: renamed), "the columns are fixed")
        let bare = readme.replacingOccurrences(of: "`⇧⌘O`", with: "⇧⌘O")
        XCTAssertThrowsError(try Self.readmeRows(in: bare), "keys are code spans")
        XCTAssertThrowsError(try Self.readmeRows(in: "| Keys | Command | Menu |"), "no markers, no table")
    }

    // MARK: - Rows

    /// One row of the table: "⇧⌘O", "Add a Classic…", "File".
    struct Row: Equatable {
        let keys: String
        let title: String
        let menu: String

        var markdown: String { "| `\(keys)` | \(title) | \(menu) |" }
    }

    /// The table as README carries it: header, separator, rows.
    static func markdown(of rows: [Row]) -> String {
        (["| " + header.joined(separator: " | ") + " |", "|---|---|---|"] + rows.map(\.markdown))
            .joined(separator: "\n")
    }

    /// Why README's table can't be read.
    struct TableError: Error, CustomStringConvertible {
        let description: String
    }

    /// The rows between the markers. The header must be `header`, the
    /// second line a separator, and each key cell one code span.
    static func readmeRows(in text: String) throws -> [Row] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix(beginMarker) }),
              let end = lines[begin...].firstIndex(where: { $0 == endMarker }) else {
            throw TableError(description: "README has no '\(beginMarker) -->' … '\(endMarker)' pair")
        }
        let table = lines[(begin + 1)..<end].filter { !$0.isEmpty }
        guard table.count >= 2, cells(of: table[table.startIndex]) == header else {
            throw TableError(description: "the table's header should be | \(header.joined(separator: " | ")) |")
        }
        let separator = cells(of: table[table.startIndex + 1])
        guard separator.count == header.count,
              separator.allSatisfy({ cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }) else {
            throw TableError(description: "the header's next line should be |---|---|---|")
        }
        return try table.dropFirst(2).map { line in
            let cells = cells(of: line)
            guard cells.count == header.count else {
                throw TableError(description: "'\(line)' isn't a \(header.count)-cell row")
            }
            let keys = cells[0]
            guard keys.count > 2, keys.hasPrefix("`"), keys.hasSuffix("`") else {
                throw TableError(description: "the keys in '\(line)' should be one code span, like `⌘O`")
            }
            return Row(keys: String(keys.dropFirst().dropLast()), title: cells[1], menu: cells[2])
        }
    }

    /// "| a | b |" → ["a", "b"]; anything else → [].
    static func cells(of line: String) -> [String] {
        guard line.count > 1, line.hasPrefix("|"), line.hasSuffix("|") else { return [] }
        return line.dropFirst().dropLast().components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The table MacShortcuts.swift implies: each `MacCommand` case with a
    /// key, in order.
    static func sourceRows(in source: String) throws -> [Row] {
        let code = SwiftLiterals.code(in: source)
        let commands = try MacKeyCommandLintTests.commandCases(in: source)
        let spelling = try Spelling(source: source)
        let shortcuts = MacKeyCommandLintTests.switchCases(
            in: try XCTUnwrap(MacKeyCommandLintTests.body(of: "var shortcut: MacShortcut? {", in: source),
                              "MacCommand.shortcut"))
        let titles = MacKeyCommandLintTests.switchCases(
            in: try XCTUnwrap(MacKeyCommandLintTests.body(of: "var title: String {", in: code), "MacCommand.title"))
        let menus = MacKeyCommandLintTests.switchCases(
            in: try XCTUnwrap(MacKeyCommandLintTests.body(of: "var menu: MacMenu {", in: code), "MacCommand.menu"))
        let copy = copyStrings(in: source)

        var rows: [Row] = []
        for command in commands {
            let expression = try XCTUnwrap(shortcuts[command], ".\(command) has no shortcut clause")
            if expression == "nil" { continue }
            let binding = try XCTUnwrap(MacKeyCommandLintTests.Binding(shortcut: expression),
                                        "can't read .\(command)'s key: \(expression)")
            let keys = try XCTUnwrap(spelling.keys(for: binding),
                                     ".\(command)'s key \(binding.key) \(binding.modifiers.sorted()) has no spelling")
            let title = try XCTUnwrap(titles[command], ".\(command) has no title")
            XCTAssertTrue(title.hasPrefix("MacMenuCopy."), ".\(command)'s title '\(title)' isn't from the copy table")
            let name = String(title.dropFirst("MacMenuCopy.".count))
            let text = try XCTUnwrap(copy[name], "MacMenuCopy.\(name) is a plain string literal")
            let menu = try XCTUnwrap(menus[command], ".\(command) has no menu")
            XCTAssertTrue(menu.hasPrefix("."), ".\(command)'s menu '\(menu)' is a MacMenu case")
            rows.append(Row(keys: keys, title: text, menu: String(menu.dropFirst()).capitalized))
        }
        return rows
    }

    // MARK: - Spelling a key

    /// How MacShortcuts.swift spells a key: `MacShortcutKey.symbol`'s named
    /// keys ("space" → "Space"), a character upper-cased, and
    /// `MacModifiers.symbol`'s modifiers in their order ("⌃⌥⇧⌘").
    struct Spelling {
        let namedKeys: [String: String]
        let modifiers: [(name: String, symbol: String)]

        /// "⇧⌘O" for `.character("o")` with [.shift, .command]; nil for a key
        /// or a modifier the source doesn't spell.
        func keys(for binding: MacKeyCommandLintTests.Binding) -> String? {
            let key: String?
            if binding.key.hasPrefix("char:") {
                key = String(binding.key.dropFirst("char:".count)).uppercased()
            } else {
                key = namedKeys[binding.key]
            }
            guard let key, binding.modifiers.isSubset(of: Set(modifiers.map(\.name))) else { return nil }
            return modifiers.filter { binding.modifiers.contains($0.name) }.map(\.symbol).joined() + key
        }

        init(namedKeys: [String: String], modifiers: [(name: String, symbol: String)]) {
            self.namedKeys = namedKeys
            self.modifiers = modifiers
        }

        /// Read from the two `symbol` properties.
        init(source: String) throws {
            let keyType = try XCTUnwrap(MacKeyCommandLintTests.body(of: "enum MacShortcutKey: Hashable, Sendable {",
                                                                    in: source), "enum MacShortcutKey")
            let keySymbol = try XCTUnwrap(MacKeyCommandLintTests.body(of: "var symbol: String {", in: keyType),
                                          "MacShortcutKey.symbol")
            XCTAssertTrue(keySymbol.contains("return String(character).uppercased()"),
                          "MacShortcutKey.symbol spells a character another way; teach this lint")
            var named: [String: String] = [:]
            for (name, expression) in MacKeyCommandLintTests.switchCases(in: keySymbol) {
                guard expression.count > 1, expression.hasPrefix("\""), expression.hasSuffix("\""),
                      let text = ReadmeShortcutsLintTests.unescaped(String(expression.dropFirst().dropLast())) else {
                    XCTFail("MacShortcutKey.symbol's .\(name) isn't a plain literal: \(expression)")
                    continue
                }
                named[name] = text
            }

            let modifierType = try XCTUnwrap(
                MacKeyCommandLintTests.body(of: "struct MacModifiers: OptionSet, Hashable, Sendable {", in: source),
                "struct MacModifiers")
            let modifierSymbol = try XCTUnwrap(MacKeyCommandLintTests.body(of: "var symbol: String {", in: modifierType),
                                               "MacModifiers.symbol")
            let regex = try NSRegularExpression(pattern: #"contains\(\.(\w+)\)\s*\?\s*"([^"\\]+)""#)
            let range = NSRange(modifierSymbol.startIndex..., in: modifierSymbol)
            let modifiers: [(name: String, symbol: String)] = regex.matches(in: modifierSymbol, range: range).compactMap {
                guard let name = Range($0.range(at: 1), in: modifierSymbol),
                      let symbol = Range($0.range(at: 2), in: modifierSymbol) else { return nil }
                return (String(modifierSymbol[name]), String(modifierSymbol[symbol]))
            }
            XCTAssertEqual(modifiers.count, 4, "MacModifiers.symbol spells ⌃, ⌥, ⇧ and ⌘")
            self.init(namedKeys: named, modifiers: modifiers)
        }
    }

    // MARK: - Reading the files

    /// `MacMenuCopy`'s `static let name = "…"` strings, as they show.
    /// Members of other types come before `enum MacMenuCopy {`, so they're
    /// never read.
    static func copyStrings(in source: String) -> [String: String] {
        guard let start = source.range(of: "enum MacMenuCopy {"),
              let regex = try? NSRegularExpression(pattern: #"static let (\w+) = "((?:[^"\\\n]|\\.)*)""#) else { return [:] }
        let tail = String(source[start.upperBound...])
        var strings: [String: String] = [:]
        for match in regex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
            guard let name = Range(match.range(at: 1), in: tail), let literal = Range(match.range(at: 2), in: tail),
                  let text = unescaped(String(tail[literal])) else { continue }
            strings[String(tail[name])] = text
        }
        return strings
    }

    /// A literal's text as it shows: `\u{2026}` → "…", `\"` → `"`. nil for
    /// an interpolation or an escape this doesn't know.
    static func unescaped(_ literal: String) -> String? {
        var text = ""
        var index = literal.startIndex
        while index < literal.endIndex {
            let character = literal[index]
            index = literal.index(after: index)
            guard character == "\\" else {
                text.append(character)
                continue
            }
            guard index < literal.endIndex else { return nil }
            let escape = literal[index]
            index = literal.index(after: index)
            switch escape {
            case "\"", "\\", "'": text.append(escape)
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "u":
                guard index < literal.endIndex, literal[index] == "{",
                      let close = literal[index...].firstIndex(of: "}"),
                      let value = UInt32(literal[literal.index(after: index)..<close], radix: 16),
                      let scalar = Unicode.Scalar(value) else { return nil }
                text.unicodeScalars.append(scalar)
                index = literal.index(after: close)
            default: return nil
            }
        }
        return text
    }

    /// The targets of a markdown file's `[text](target)` links that point
    /// into the checkout: no scheme, not just an anchor.
    static func relativeLinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let target = String(text[range])
            return target.contains("://") || target.hasPrefix("#") || target.hasPrefix("mailto:") ? nil : target
        }
    }

    private static func shortcutsSource() throws -> String {
        let sources = try SourceTree.appSources(platforms: [.macOS])
        return try XCTUnwrap(sources[shortcutsPath], shortcutsPath)
    }

    /// A file of the checkout's. It skips where the checkout can't be read,
    /// like every source lint (SourceTreeReachabilityTests fails there), but
    /// a file missing beside a readable ios/ fails.
    private static func text(of url: URL) throws -> String {
        try SourceTree.requireCheckoutAccess()
        guard SourceTree.exists(SourceTree.appRoot) else { throw XCTSkip("Can't read the checkout from this test host") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
