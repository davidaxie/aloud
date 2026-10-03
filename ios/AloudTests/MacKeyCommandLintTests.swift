import Foundation
import XCTest

/// M11's one keyboard table, held in source (testing §4.3). The table is
/// `MacCommand` in AloudMac/Commands/MacShortcuts.swift; the iOS suite
/// can't import the Mac module, so it reads the files:
/// - no plain key (Space, ←, →, [, ]) ever becomes a menu key equivalent:
///   AloudCommands binds keys only from the table, and only when the key
///   isn't plain, so `MacKeyRouter` keeps them and a search field still
///   types them;
/// - every command's title comes from the copy table (`MacMenuCopy`), and
///   every command has a tooltip name;
/// - every command of Aloud's own has its menu item;
/// - the UI tests' `MacKey` presses exactly the table's keys, so the
///   keyboard matrix tests what the menus bind.
///
/// iOS suite only: the Mac bundle excludes every *LintTests file.
final class MacKeyCommandLintTests: XCTestCase {

    private static let shortcutsPath = "Commands/MacShortcuts.swift"
    private static let commandsPath = "Commands/AloudCommands.swift"

    /// Built by AppKit or SwiftUI, not by AloudCommands (`MacCommand.isSystem`).
    private static let systemCommands: Set<String> = ["settings", "fullScreen", "minimize", "hide", "quit"]

    /// Commands whose menu entry isn't a plain `item(_:)`: the Sleep Timer
    /// submenu and the Appearance picker, each titled from the copy table.
    private static let submenus = ["sleepTimer": "Menu(MacMenuCopy.sleepTimer)",
                                   "appearance": "Picker(MacMenuCopy.appearance"]

    /// Keys `MacKey` holds for moving focus, which no command owns.
    private static let focusKeys: Set<String> = ["escape", "pageUp", "pageDown", "home", "end", "tab", "shiftTab",
                                                 "returnKey", "down"]

    /// `MacKey` names Show/Hide Contents for what it does to the window.
    private static let keyAliases = ["contents": "toggleContents"]

    /// Each takes the window from the test: never pressed, so not in `MacKey`.
    private static let unpressed: Set<String> = ["fullScreen", "minimize", "hide", "quit"]

    // MARK: - Plain keys stay off the menus

    func testNoPlainKeyBecomesAMenuKeyEquivalent() throws {
        let source = try Self.mac(Self.commandsPath)
        let code = SwiftLiterals.code(in: source)
        let calls = Self.calls(of: ".keyboardShortcut(", in: code)
        XCTAssertFalse(calls.isEmpty, "the menus bind their ⌘ keys here")
        for call in calls {
            XCTAssertEqual(call.arguments.replacingOccurrences(of: " ", with: ""),
                           "shortcut.key.keyEquivalent,modifiers:shortcut.modifiers.eventModifiers",
                           "a key equivalent comes from the table, never typed in place")
            XCTAssertTrue(call.condition?.contains("!shortcut.isPlain") == true,
                          "a key equivalent is bound only for a key that isn't plain, got '\(call.condition ?? "none")'")
        }
        XCTAssertFalse(code.replacingOccurrences(of: " ", with: "").contains("modifiers:[]"),
                       "no modifier-free binding in the menus")
    }

    /// No Mac view binds Space, an arrow or a bracket as a button's key: the
    /// router owns them (Esc, the cancel action, is the import overlay's).
    func testNoMacViewBindsAPlainKey() throws {
        let sources = try SourceTree.appSources(platforms: [.macOS])
        let regex = try NSRegularExpression(pattern: #"\.keyboardShortcut\(\s*(\.space|\.leftArrow|\.rightArrow|"\[|"\]|" ")"#)
        let offenders = sources.filter { _, text in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.map(\.key).sorted()
        XCTAssertEqual(offenders, [], "a plain key bound as a shortcut takes it from search fields")
    }

    // MARK: - Titles and menu items

    func testEveryCommandHasACopyTableTitleAndATooltipName() throws {
        // Comments out, literal text blanked: a quote in a doc comment can't
        // throw the brace matching off.
        let source = SwiftLiterals.code(in: try Self.mac(Self.shortcutsPath))
        let commands = try Self.commandCases(in: source)
        XCTAssertGreaterThan(commands.count, 20, "the reader finds the table")

        let titleBody = try XCTUnwrap(Self.body(of: "var title: String {", in: source), "MacCommand.title")
        let titles = Self.switchCases(in: titleBody)
        let copy = try XCTUnwrap(Self.body(of: "enum MacMenuCopy {", in: source), "MacMenuCopy")
        let allStart = try XCTUnwrap(copy.range(of: "static let all: Set<String> = ["), "MacMenuCopy.all")
        let allTail = copy[allStart.upperBound...]
        let allEnd = try XCTUnwrap(allTail.range(of: "]"), "MacMenuCopy.all's end")
        let listed = Set(allTail[..<allEnd.lowerBound].components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })

        for command in commands {
            guard let title = titles[command] else {
                XCTFail(".\(command) has no title")
                continue
            }
            guard title.hasPrefix("MacMenuCopy.") else {
                XCTFail(".\(command)'s title '\(title)' isn't from the copy table")
                continue
            }
            let name = String(title.dropFirst("MacMenuCopy.".count))
            XCTAssertTrue(copy.contains("static let \(name) = \""), "MacMenuCopy.\(name) is a copy-table string")
            XCTAssertTrue(listed.contains(name), "MacMenuCopy.all lists \(name)")
        }
        XCTAssertEqual(Set(titles.keys), Set(commands), "one title per command, no strays")

        let helpBody = try XCTUnwrap(Self.body(of: "static func label(for command: MacCommand) -> String {", in: source),
                                     "MacMenuCopy.Help.label(for:)")
        XCTAssertEqual(Set(Self.switchCases(in: helpBody).keys), Set(commands), "every command has a tooltip name")
    }

    func testEveryCommandOfAloudsOwnHasAMenuItem() throws {
        let commands = try Self.commandCases(in: try Self.mac(Self.shortcutsPath))
        let menus = SwiftLiterals.code(in: try Self.mac(Self.commandsPath))
        for command in commands where !Self.systemCommands.contains(command) {
            if let entry = Self.submenus[command] {
                XCTAssertTrue(menus.contains(entry), ".\(command)'s menu is \(entry)…")
            } else {
                XCTAssertTrue(menus.contains("item(.\(command))"), ".\(command) has a menu item")
            }
        }
        for command in Self.systemCommands {
            XCTAssertFalse(menus.contains("item(.\(command))"), "AppKit builds .\(command)'s item; a second would clash")
        }
    }

    // MARK: - The tests press the table's keys

    func testTheUITestKeysAreTheTablesKeys() throws {
        let shortcuts = try Self.mac(Self.shortcutsPath)
        let shortcutBody = try XCTUnwrap(Self.body(of: "var shortcut: MacShortcut? {", in: shortcuts),
                                         "MacCommand.shortcut")
        var table: [String: Binding] = [:]
        for (command, expression) in Self.switchCases(in: shortcutBody) where expression != "nil" {
            table[command] = try XCTUnwrap(Binding(shortcut: expression), "can't read .\(command): \(expression)")
        }
        XCTAssertGreaterThan(table.count, 15, "the reader finds the table's keys")

        let helpers = try Self.macUITest("XCUIHelpers.swift")
        let keyBody = try XCTUnwrap(Self.body(of: "var key: String {", in: helpers), "MacKey.key")
        let modifierBody = try XCTUnwrap(Self.body(of: "var modifiers: XCUIElement.KeyModifierFlags {", in: helpers),
                                         "MacKey.modifiers")
        let keys = Self.switchCases(in: keyBody)
        let modifiers = Self.switchCases(in: modifierBody)
        XCTAssertEqual(Set(keys.keys), Set(modifiers.keys), "every MacKey has a key and modifiers")

        var pressed: Set<String> = []
        for (name, keyExpression) in keys where !Self.focusKeys.contains(name) {
            let command = Self.keyAliases[name] ?? name
            pressed.insert(command)
            guard let binding = table[command] else {
                XCTFail("MacKey.\(name) has no command with a key in the table")
                continue
            }
            XCTAssertEqual(Binding.key(fromTest: keyExpression), binding.key, "MacKey.\(name)'s key")
            XCTAssertEqual(Binding.modifiers(in: modifiers[name] ?? ""), binding.modifiers, "MacKey.\(name)'s modifiers")
        }
        XCTAssertEqual(Set(table.keys).subtracting(pressed), Self.unpressed,
                       "every key the menus bind is one the matrix can press")
    }

    // MARK: - Reading the files

    /// A key and its modifiers, normalized across the app's and the test's
    /// spellings: "space", "leftArrow", "delete" or "char:j"; {"command", …}.
    struct Binding: Equatable {
        let key: String
        let modifiers: Set<String>

        /// `MacShortcut(key: .character("o"), modifiers: [.shift, .command])`.
        init?(shortcut expression: String) {
            guard let key = Self.firstMatch(#"key:\s*\.(\w+)(?:\("(.)"\))?"#, in: expression) else { return nil }
            self.key = key[0] == "character" ? "char:" + key[1] : key[0]
            let modifiers = Self.firstMatch(#"modifiers:\s*(\[[^\]]*\]|\.\w+)"#, in: expression)?[0] ?? "[]"
            self.modifiers = Self.modifiers(in: modifiers)
        }

        /// `XCUIKeyboardKey.leftArrow.rawValue` or `"]"`.
        static func key(fromTest expression: String) -> String {
            if let name = firstMatch(#"XCUIKeyboardKey\.(\w+)"#, in: expression) { return name[0] }
            if let character = firstMatch(#"^"(.)"$"#, in: expression) { return "char:" + character[0] }
            return expression
        }

        /// `.command`, `[.control, .command]` or `[]`.
        static func modifiers(in expression: String) -> Set<String> {
            let regex = try? NSRegularExpression(pattern: #"\.(\w+)"#)
            let range = NSRange(expression.startIndex..., in: expression)
            return Set((regex?.matches(in: expression, range: range) ?? []).compactMap {
                Range($0.range(at: 1), in: expression).map { String(expression[$0]) }
            })
        }

        /// The capture groups of `pattern`'s first match ("" for one that
        /// didn't take part).
        private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func mac(_ path: String) throws -> String {
        let sources = try SourceTree.appSources(platforms: [.macOS])
        return try XCTUnwrap(sources[SourceTree.macPrefix + path], "AloudMac/\(path)")
    }

    private static func macUITest(_ path: String) throws -> String {
        guard SourceTree.exists(SourceTree.macUITestsRoot) else { throw XCTSkip("AloudMacUITests not created yet") }
        return try XCTUnwrap(try SourceTree.sources(in: SourceTree.macUITestsRoot, only: [path])[path], path)
    }

    /// `enum MacCommand`'s cases, in order.
    static func commandCases(in source: String) throws -> [String] {
        let body = try XCTUnwrap(body(of: "enum MacCommand: String, CaseIterable, Sendable {", in: source),
                                 "enum MacCommand")
        let code = SwiftLiterals.code(in: body)
        // The cases come before the first member.
        let head = code.components(separatedBy: "\n").prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("var ") || trimmed.hasPrefix("static ") || trimmed.hasPrefix("func ")
                     || trimmed.hasPrefix("///"))
        }
        return head.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .flatMap { $0.dropFirst("case ".count).components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text between the braces that open at the end of `signature`.
    /// Braces inside string literals are skipped.
    static func body(of signature: String, in source: String) -> String? {
        guard let start = source.range(of: signature) else { return nil }
        var depth = 1
        var inString = false
        var previous: Character = " "
        var index = start.upperBound
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(source[start.upperBound..<index]) }
                }
            }
            previous = character
            index = source.index(after: index)
        }
        return nil
    }

    /// A switch's `case .a, .b: return X` clauses (a clause may wrap lines
    /// before its colon), as name → X.
    static func switchCases(in body: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"case\s+((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*return\s+([^\n]+)"#)
        else { return [:] }
        var cases: [String: String] = [:]
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let names = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body)
            else { continue }
            let expression = String(body[value]).trimmingCharacters(in: .whitespaces)
            for name in body[names].components(separatedBy: ",") {
                cases[name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["."])] = expression
            }
        }
        return cases
    }

    /// Each call of `opener` (".keyboardShortcut("): its argument text, and
    /// the condition of the nearest `if` above it on the lines before.
    static func calls(of opener: String, in code: String) -> [(arguments: String, condition: String?)] {
        var found: [(arguments: String, condition: String?)] = []
        var searchFrom = code.startIndex
        while let range = code.range(of: opener, range: searchFrom..<code.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" { depth -= 1 }
                if depth > 0 { index = code.index(after: index) }
            }
            let arguments = String(code[range.upperBound..<index])
            let before = code[code.startIndex..<range.lowerBound].components(separatedBy: "\n").suffix(4)
            let condition = before.reversed().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("if ") }
            found.append((arguments, condition?.trimmingCharacters(in: .whitespaces)))
            searchFrom = index < code.endIndex ? code.index(after: index) : code.endIndex
        }
        return found
    }
}
