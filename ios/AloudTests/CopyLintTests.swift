import XCTest

/// R25's CI string lint: one vocabulary and one duration format, checked on
/// what people can read. Literal rules read string literals through the
/// SwiftLiterals lexer, so a comment or a dotted identifier never trips them
/// (only `isCopy` literals count unless a rule says otherwise); symbol rules
/// read `SwiftLiterals.code(in:)`, which has comments and literal text
/// removed. Needles match the literal with its escapes resolved, so copy is
/// caught however it was typed.
///
/// Written against the final copy of all five Phase 4 slices (contracts §8).
/// Pure source reads; skips when the host can't see the checkout. A failure
/// lists each offender as `path:line «text»`.
final class CopyLintTests: XCTestCase {

    /// Extraction's literals are parsing tables, never shown; App/UITest*
    /// is DEBUG-only launch plumbing.
    private static let excludedPrefixes = ["Extraction/", "App/UITest"]

    /// The one duration format (ListeningEstimate): a number or an
    /// interpolation glued to an abbreviated unit, a number or an
    /// interpolation before a spelled-out unit (with at most one word
    /// between, as in "15 more minutes"), or a printf clock.
    private static let durationPatterns = [
        #"(\d|\})\s?(h|hr|hrs|min|mins)\b"#,
        #"(\d|\})(\s\w+)?\s(minutes?|hours?)\b"#,
        #"%\d*d:%"#,
    ]

    private static let durationSymbols = [
        "DateComponentsFormatter", ".formatted(.time(", "Duration.seconds(", ".formatted(.units(",
    ]

    /// The one file that may spell a device or a gesture.
    private static let deviceCopyHome = "Platform/DeviceNoun.swift"

    /// "iPhone", "iOS", "tap" and "swipe" as words, in any case and any
    /// tense ("Double-tap", "tapped", "Swiping"), never inside another word
    /// ("Tape", "Kiosk").
    private static let deviceWords = [
        #"(?i)\biphones?\b"#, #"(?i)\bios\b"#, #"(?i)\btap(s|ped|ping)?\b"#, #"(?i)\bswip(e|es|ed|ing)\b"#,
    ]

    // MARK: - Add

    func testAddIsTheOnlyAddVerb() throws {
        let tree = try Tree()
        let verbs = [#"(?i)\bimport(s|ed|ing)?\b"#, #"(?i)\bupload"#]
        let retired = ["Add to", "Add a document", "Add something"]
        let hits = tree.copy.filter { literal in
            let text = literal.readable
            return verbs.contains { Self.matches($0, text) } || retired.contains { text.contains($0) }
        }
        assertNone(hits, "'Add' is the only add verb, with no object (R25)")
    }

    // MARK: - Retired copy

    func testRetiredCopyStaysGone() throws {
        let tree = try Tree()
        let retired = ["Soon", "Couldn't import", "Couldn\u{2019}t import", "classics included",
                       "Browse the Classics", "Under a min", "in this book", "\u{2248}"]
        assertNone(tree.copy.filter { literal in retired.contains { literal.readable.contains($0) } },
                   "Retired copy is back")
        // "≈ " glued to a phrase has no letter of its own, so it is checked
        // in every literal: it is never part of an identifier.
        assertNone(tree.literals.filter { $0.readable.contains("\u{2248}") }, "Estimates never say '≈'")

        // The screen is Classics and the voice is the natural voice; the code
        // names never reach a sentence. (A lone word, like a resource folder
        // name, is not a sentence.)
        let codeNames = [#"(?i)\bbookshelf\b"#, #"(?i)\bneural voice\b"#]
        let sentences = tree.copy.filter { literal in
            literal.readable.contains(" ") && codeNames.contains { Self.matches($0, literal.readable) }
        }
        assertNone(sentences, "Copy says Classics and natural voice, never bookshelf or neural voice")
    }

    // MARK: - Privacy

    func testOnePrivacyLine() throws {
        let tree = try Tree()
        let line = "Everything stays on your device."

        let users = tree.sources.keys.filter { tree.code(of: $0).contains("PrivacyCopy.line") }.sorted()
        XCTAssertEqual(users, ["Library/EmptyLibraryView.swift", "Settings/SettingsView.swift"],
                       "The privacy line shows in the empty state and the Settings footer only")

        let spelled = tree.literals.filter { $0.readable == line }
        XCTAssertEqual(spelled.map(\.path), ["Library/EmptyLibraryView.swift"],
                       "PrivacyCopy.line is spelled once:\n" + Self.located(spelled))

        // R1-10: one voice for the promise, the serif aside, wherever it
        // shows on either app.
        let mac = SourceTree.exists(SourceTree.macRoot) ? try SourceTree.sources(in: SourceTree.macRoot) : [:]
        let prefixed = Dictionary(uniqueKeysWithValues: mac.map { (SourceTree.macPrefix + $0.key, $0.value) })
        let shown = tree.sources.merging(prefixed) { first, _ in first }
            .filter { $0.value.contains("Text(PrivacyCopy.line)") }
        XCTAssertGreaterThanOrEqual(shown.count, 3, "the empty Library, Settings and the Mac's: \(shown.keys.sorted())")
        for (path, text) in shown {
            var rest = text[...]
            while let use = rest.range(of: "Text(PrivacyCopy.line)") {
                let after = rest[use.upperBound...]
                let next = after.range(of: "Text(")?.lowerBound ?? after.endIndex
                XCTAssertTrue(after[..<next].contains(".font(Theme.font(.aside))"),
                              "\(path): the privacy line is set in the aside: \(String(after.prefix(160)))")
                rest = after
            }
        }

        let echoes = ["stays on your device", "on this device only", "entirely offline",
                      "everything offline", "All offline"]
        let restated = tree.literals.filter { literal in
            literal.readable != line && echoes.contains { literal.readable.localizedCaseInsensitiveContains($0) }
        }
        assertNone(restated, "No second privacy promise")

        let offline = tree.copy.filter { literal in
            Self.matches(#"(?i)\boffline\b"#, literal.readable) && literal.path != "TTS/NaturalVoiceOffer.swift"
        }
        assertNone(offline, "'offline' appears only in the natural-voice offer's 'works offline'")
    }

    // MARK: - Durations

    func testOneDurationFormat() throws {
        // The rules' reach, on text as the lexer gives it (an interpolation
        // reads "{expr}"): a spelled-out unit after a literal number counts
        // too, so "Add 15 minutes" can't drift from what "+15 min" adds.
        for spelled in ["Add 15 minutes", "Keeps playing for 15 more minutes", "Sleep in 1 hour",
                        "{expr} minutes left", "+15 min", "1 hr 12 min", "%d:%02d"] {
            XCTAssertTrue(Self.isDuration(spelled), "the lint misses \(spelled)")
        }
        for prose in ["Sleep timer", "End of chapter", "Chapter 12", "Back to the start"] {
            XCTAssertFalse(Self.isDuration(prose), "the lint flags \(prose)")
        }

        let tree = try Tree()
        // ListeningEstimate is the format. App Intents metadata must be a
        // compile-time literal ("15 minutes"), so those files are exempt too.
        let allowed = Set(["Models/ListeningEstimate.swift"]
                          + tree.sources.keys.filter { tree.code(of: $0).contains("import AppIntents") })

        let formatted = tree.copy.filter { literal in
            !allowed.contains(literal.path) && Self.isDuration(literal.readable)
        }
        assertNone(formatted, "Durations go through ListeningEstimate ('1 hr 12 min')")

        let formatters = tree.sources.keys.sorted().filter { !allowed.contains($0) }.flatMap { path in
            Self.durationSymbols.filter { tree.code(of: path).contains($0) }.map { "\(path): \($0)" }
        }
        XCTAssertEqual(formatters, [], "Only ListeningEstimate formats a duration")
    }

    func testPlayerBarAndListeningDoNoDurationMath() throws {
        let tree = try Tree()
        XCTAssertNil(tree.sources["Settings/SpeedSheet.swift"], "SpeedSheet stays deleted")

        for path in ["Reader/PlayerBarView.swift", "Settings/ListeningView.swift"] {
            // Missing would pass every check below without reading anything.
            guard tree.sources[path] != nil else {
                XCTFail("\(path) moved; point this lint at its new home")
                continue
            }
            let code = tree.code(of: path)
            for math in ["String(format:", "/ 60", "% 60", ".formatted("] {
                XCTAssertFalse(code.contains(math), "\(path) formats a number itself: \(math)")
            }
            assertNone(tree.copy.filter { $0.path == path && Self.isDuration($0.readable) },
                       "\(path) spells a duration itself")
        }
    }

    // MARK: - Cards

    func testCardsShowNoPercent() throws {
        let tree = try Tree()
        let cardPercents = ["0% \u{00B7}", "% \u{00B7}", "%,"]
        assertNone(tree.literals.filter { literal in cardPercents.contains { literal.readable.contains($0) } },
                   "A card never leads with a percent (R25)")

        let users = tree.sources.keys.filter { tree.code(of: $0).contains("progressPercent") }.sorted()
        XCTAssertEqual(users, [], "progressPercent stays deleted")

        // Download and import progress are the only percents left.
        let percentFiles: Set<String> = ["TTS/NaturalVoiceOffer.swift", "Import/DocumentImporter.swift"]
        assertNone(tree.literals.filter { $0.text.contains("}%") && !percentFiles.contains($0.path) },
                   "Only download and import progress show a percent")
    }

    // MARK: - Preparing

    func testOneWordForAnAddInProgress() throws {
        let tree = try Tree()
        // An add in progress is "Adding"; "Preparing" means the voice only.
        let preparing = tree.copy.filter { $0.text.contains("Preparing") }
        XCTAssertEqual(preparing.map { "\($0.path) \($0.readable)" },
                       ["Settings/ListeningView.swift Preparing voice\u{2026}"],
                       "'Preparing' is reserved for 'Preparing voice…':\n" + Self.located(preparing))
    }

    // MARK: - Device words

    /// C1 (contracts §7, S0-K): nothing the Mac compiles names the iPhone,
    /// its system or a touch gesture. Such a line is spelled whole in
    /// `DeviceCopy`, or names the device through `DeviceNoun`, both in
    /// Platform/DeviceNoun.swift. The iOS-only files in `MacExclusions` keep
    /// their own words.
    func testMacCompiledCopyNamesNoIPhoneOrGesture() throws {
        for spelled in ["Playback stopped \u{00B7} tap to try again", "Double-tap to listen", "Tapped twice",
                        "Swipe up for more", "Stopped when iOS closed Aloud", "on this iPhone", "iPhone's storage"] {
            XCTAssertTrue(Self.namesTheDevice(spelled), "the lint misses \(spelled)")
        }
        for neutral in ["Playback stopped", "Try again", "Taper", "Tape", "Kiosk", "Biography",
                        "Opens and starts reading aloud", "Paused \u{00B7} your Mac went to sleep"] {
            XCTAssertFalse(Self.namesTheDevice(neutral), "the lint flags \(neutral)")
        }

        // ios/Aloud minus the exclusions, plus ios/AloudMac once it exists.
        let compiled = try SourceTree.macCompiledSources(excluding: MacExclusions.projectExcludes)
        XCTAssertNil(compiled["Bookshelf/BookshelfView.swift"], "the scan drops the iOS-only files")
        let named = SwiftLiterals.literals(in: compiled, excluding: Self.excludedPrefixes).filter { literal in
            SwiftLiterals.isCopy(literal.text) && Self.namesTheDevice(literal.readable)
        }
        assertNone(named.filter { $0.path != Self.deviceCopyHome },
                   "A line that names the iPhone, iOS, a tap or a swipe lives in \(Self.deviceCopyHome)")
        // The scan reads the device's own lines, so an empty result above
        // means something.
        XCTAssertFalse(named.filter { $0.path == Self.deviceCopyHome }.isEmpty,
                       "\(Self.deviceCopyHome) should spell the iPhone's words")
    }

    // MARK: - Book, not document

    /// R1-11: what people read calls a book a book, on both apps. The one
    /// exception is the open error's guess at a scanned document, which is
    /// what such a file is.
    func testCopySaysBookNotDocument() throws {
        let tree = try Tree()
        let macSources = SourceTree.exists(SourceTree.macRoot) ? try SourceTree.sources(in: SourceTree.macRoot) : [:]
        let mac = SwiftLiterals.literals(in: macSources, excluding: []).filter { SwiftLiterals.isCopy($0.text) }
        let allowed = "scanned document"
        let hits = (tree.copy + mac).filter { literal in
            let text = literal.readable.replacingOccurrences(of: allowed, with: "")
            return Self.matches(#"(?i)\bdocuments?\b"#, text)
        }
        assertNone(hits, "Copy says book, not document")
        XCTAssertTrue(Self.matches(#"(?i)\bdocuments?\b"#, "Couldn't open this document"), "the pattern bites")
        XCTAssertFalse(Self.matches(#"(?i)\bdocuments?\b"#, "documentation"), "only the word")
    }

    // MARK: - The page's marks

    /// A typewriter apostrophe between two letters, or a "(c)" for ©.
    private static let typewriterMarks = [#"[A-Za-z]'[A-Za-z]"#, #"\(c\)"#]

    /// Calls whose text only developers read: logs, asserts and test skips.
    private static let diagnosticCall =
        #"(?<![A-Za-z0-9_])(log|logger|os_log|NSLog|print|debugPrint|assert|assertionFailure|precondition|preconditionFailure|fatalError|XCTSkip|XCTFail)\s*[.(]"#

    /// R2-33: what people read sets the page's marks, ’ and © (as the page
    /// sets ’ and “ ”), never a typewriter apostrophe between letters or a
    /// "(c)", on both apps. Text handed to a log, an assert or an XCTSkip
    /// is for developers and keeps its plain marks; the licence texts are
    /// resources, not Swift, so the lexer never reads them. Each offender
    /// is listed as path:line.
    func testCopySetsTheTypographersMarks() throws {
        for typed in ["Couldn't play Emma", "Aloud's own mixes", "Copyright (c) Microsoft"] {
            XCTAssertTrue(Self.hasTypewriterMark(typed), "the lint misses \(typed)")
        }
        for set in ["Couldn\u{2019}t play Emma", "Copyright \u{00A9} Microsoft", "Text in ( ), [ ] and { }",
                    "\u{201C}Emma\u{201D}", "'Emma'", "(contents)"] {
            XCTAssertFalse(Self.hasTypewriterMark(set), "the lint flags \(set)")
        }
        let probe = "func f() {\n    log.error(\"it doesn't decode\")\n    precondition(ok,\n                 \"a controller's mixer\")\n    let s = \"Can't\"\n}\n"
        let probeCode = SwiftLiterals.code(in: probe).components(separatedBy: "\n")
        let probed = SwiftLiterals.literals(in: probe, path: "probe").map { Self.isDiagnostic($0, codeLines: probeCode) }
        XCTAssertEqual(probed, [true, true, false], "logs and asserts are skipped, copy is read")

        let tree = try Tree()
        let macSources = SourceTree.exists(SourceTree.macRoot) ? try SourceTree.sources(in: SourceTree.macRoot) : [:]
        let mac = Dictionary(uniqueKeysWithValues: macSources.map { (SourceTree.macPrefix + $0.key, $0.value) })
        let sources = tree.sources.merging(mac) { first, _ in first }
        let codeLines = sources.mapValues { SwiftLiterals.code(in: $0).components(separatedBy: "\n") }
        let macCopy = SwiftLiterals.literals(in: mac, excluding: Self.excludedPrefixes.map { SourceTree.macPrefix + $0 })
            .filter { SwiftLiterals.isCopy($0.text) }
        let hits = (tree.copy + macCopy).filter { literal in
            Self.hasTypewriterMark(literal.readable) && !Self.isDiagnostic(literal, codeLines: codeLines[literal.path] ?? [])
        }
        assertNone(hits, "Copy sets \u{2019} and \u{00A9}, not ' and (c)")
    }

    /// R2-33, R8: a toggle's subtitle is an aside, set as the Read asides
    /// line is: no full stop.
    func testToggleSubtitlesEndWithoutAFullStop() throws {
        let tree = try Tree()
        let macSources = SourceTree.exists(SourceTree.macRoot) ? try SourceTree.sources(in: SourceTree.macRoot) : [:]
        let mac = Dictionary(uniqueKeysWithValues: macSources.map { (SourceTree.macPrefix + $0.key, $0.value) })
        let declaration = try NSRegularExpression(pattern: #"static\s+let\s+(\w*Subtitle)\s*(:\s*String\s*)?=\s*"$"#)
        var found: [String: String] = [:]
        for (path, text) in tree.sources.merging(mac, uniquingKeysWith: { first, _ in first }) {
            let lines = text.components(separatedBy: "\n")
            for literal in SwiftLiterals.literals(in: text, path: path) where lines.indices.contains(literal.line - 1) {
                let line = lines[literal.line - 1]
                guard let opening = line.range(of: "\"") else { continue }
                let head = String(line[..<opening.upperBound])
                let range = NSRange(head.startIndex..., in: head)
                guard let match = declaration.firstMatch(in: head, range: range),
                      let name = Range(match.range(at: 1), in: head) else { continue }
                found["\(path) \(head[name])"] = literal.readable
            }
        }
        XCTAssertTrue(found.keys.contains { $0.hasSuffix(" wordHighlightSubtitle") }, "the scan reads \(found.keys.sorted())")
        XCTAssertTrue(found.keys.contains { $0.hasSuffix(" readAsidesSubtitle") }, "the scan reads \(found.keys.sorted())")
        for (name, subtitle) in found.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(subtitle.hasSuffix("."), "\(name) ends with a full stop: \(subtitle)")
        }
    }

    // MARK: - Helpers

    /// The app's sources and their literals, read once per test.
    private struct Tree {
        let sources: [String: String]
        let literals: [SwiftLiteral]
        let copy: [SwiftLiteral]
        private let codes: [String: String]

        /// Throws XCTSkip (through SourceTree) when the checkout is unreadable.
        init() throws {
            sources = try SourceTree.sources()
            literals = SwiftLiterals.literals(in: sources, excluding: CopyLintTests.excludedPrefixes)
            copy = literals.filter { SwiftLiterals.isCopy($0.text) }
            codes = sources.mapValues(SwiftLiterals.code(in:))
        }

        func code(of path: String) -> String { codes[path] ?? "" }
    }

    private static func isDuration(_ text: String) -> Bool {
        durationPatterns.contains { matches($0, text) }
    }

    private static func namesTheDevice(_ text: String) -> Bool {
        deviceWords.contains { matches($0, text) }
    }

    private static func hasTypewriterMark(_ text: String) -> Bool {
        typewriterMarks.contains { matches($0, text) }
    }

    /// Whether `literal` is handed to a log, an assert or a test skip: its
    /// own line names the call, or it continues a call opened on a line
    /// above (up to eight back) and that statement names it. `codeLines`
    /// is the file as `SwiftLiterals.code(in:)` gives it, split on
    /// newlines, so parentheses in comments and literals never count.
    private static func isDiagnostic(_ literal: SwiftLiteral, codeLines: [String]) -> Bool {
        let index = literal.line - 1
        guard codeLines.indices.contains(index) else { return false }
        var start = index
        var depth = 0
        for above in stride(from: index - 1, through: max(0, index - 8), by: -1) {
            let line = codeLines[above]
            depth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            if depth > 0 {
                start = above
                break
            }
        }
        return matches(diagnosticCall, codeLines[start...index].joined(separator: "\n"))
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Bad lint pattern \(pattern)")
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func located(_ literals: [SwiftLiteral]) -> String {
        literals.map { "\($0.path):\($0.line) \u{00AB}\($0.text)\u{00BB}" }.joined(separator: "\n")
    }

    private func assertNone(_ hits: [SwiftLiteral], _ rule: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hits.isEmpty, "\(rule):\n" + Self.located(hits), file: file, line: line)
    }
}

private extension SwiftLiteral {
    /// The text with escapes resolved, for needles and patterns.
    var readable: String { SwiftLiterals.unescaped(text) }
}
