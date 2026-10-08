import XCTest
@testable import Aloud

/// The iPhone's Classics screen against the Mac's (B7): the keyboard's
/// Search key takes the top result, the section headings are capitals that
/// VoiceOver reads as written, and the row hint says what happens, as the
/// grid cards' does, never which gesture to make.
///
/// Source reads; skips when the host can't see the checkout. The behaviour
/// itself is in BookshelfUITest and ClassicsRowAccessibilityTests.
final class ClassicsLintTests: XCTestCase {

    private static let path = "Bookshelf/BookshelfView.swift"

    /// P051: the Search key goes through the row's own path, so the play
    /// haptic and the importer's busy guard apply, and nothing happens
    /// without a result.
    func testTheSearchKeyTakesTheTopResultThroughTheRowsPath() throws {
        let s = try SourceTree.sources(only: [Self.path])
        let view = try XCTUnwrap(s[Self.path])
        let searchable = try XCTUnwrap(view.range(of: ".searchable(text: $query"))
        let submit = try XCTUnwrap(view.range(of: ".onSubmit(of: .search) { openTopResult() }"),
                                   "the Search key should open the top result")
        XCTAssertLessThan(searchable.lowerBound, submit.lowerBound, "the submit follows the search field")

        let body = try region(of: view, from: "private func openTopResult() {", length: 200)
        XCTAssertTrue(body.contains("guard let first = results?.first else { return }"),
                      "no results (or the shelves) do nothing: \(body)")
        XCTAssertTrue(body.contains("listen(to: first)"), "the tap's path, with its haptic and guard: \(body)")
    }

    /// P052: the headings draw in capitals, like the shelf's other eyebrows,
    /// and keep their written title for VoiceOver and Voice Control.
    func testSectionHeadingsAreCapitalsWithTheirTitleSpoken() throws {
        let s = try SourceTree.sources(only: [Self.path])
        let view = try XCTUnwrap(s[Self.path])
        let header = try region(of: view, from: "private func header(_ section: BookshelfSection)", length: 900)
        XCTAssertTrue(header.contains(".textCase(.uppercase)"), "the heading should be capitals: \(header)")
        XCTAssertTrue(header.contains(".accessibilityLabel(Text(section.title))"),
                      "VoiceOver keeps the written title: \(header)")
        XCTAssertTrue(header.contains(".accessibilityAddTraits(.isHeader)"))
    }

    /// P052: the side-by-side row keeps one trailing caption column of a
    /// scaled width, and the stacked layout stays at accessibility sizes.
    func testTheRowTrailsOneScaledCaptionColumn() throws {
        let s = try SourceTree.sources(only: [Self.path])
        let view = try XCTUnwrap(s[Self.path])
        XCTAssertTrue(view.contains("@ScaledMetric(relativeTo: .caption) private var statusWidth = BookshelfView.statusColumnWidth"))
        let column = try region(of: view, from: "HStack(alignment: .firstTextBaseline", length: 800)
        XCTAssertTrue(column.contains("detail(BookshelfView.rowByline(for: book))"), "the author under the title: \(column)")
        XCTAssertTrue(column.contains("Text(BookshelfView.rowStatus(for: book, rate: rate, inLibrary: inLibrary, adding: adding))"),
                      "the trailing column always holds a status: \(column)")
        XCTAssertTrue(column.contains(".font(Theme.font(.caption))"), column)
        XCTAssertTrue(column.contains(".foregroundStyle(Theme.textMuted)"), column)
        XCTAssertTrue(column.contains(".frame(width: statusWidth, alignment: .trailing)"), column)
        XCTAssertTrue(view.contains("stacked: dynamicTypeSize.isAccessibilitySize"), "the row stacks at AX sizes")
        XCTAssertTrue(view.contains(".buttonStyle(ShelfRowButtonStyle())"), "rows keep their surface2 press")
    }

    /// P053: the Classics row's hint is the grid card's, word for word, and
    /// both drop it for a finished copy.
    func testTheRowHintIsTheGridCardsHint() throws {
        let gridPath = "Library/LibraryView.swift"
        let s = try SourceTree.sources(only: [Self.path, gridPath])
        let view = try XCTUnwrap(s[Self.path])
        let grid = try XCTUnwrap(s[gridPath])
        let hint = BookshelfView.rowHint(finished: false)
        XCTAssertFalse(hint.isEmpty)
        XCTAssertEqual(BookshelfView.rowHint(finished: true), "", "a finished copy opens paused")
        XCTAssertTrue(grid.contains(".accessibilityHint(document.isFinished ? \"\" : \"\(hint)\")"),
                      "the grid card's hint should match the Classics row's")
        XCTAssertTrue(view.contains(".accessibilityHint(BookshelfView.rowHint(finished: finished))"))
        XCTAssertTrue(view.contains("finished: finishedIDs.contains(book.id)"), "the row knows its copy is finished")
    }

    /// P053: no hint in either app names a gesture. VoiceOver already says
    /// how to activate an element, and the words are wrong for Voice
    /// Control and Switch Control. B7-2: a hint is read where it is set and
    /// in the declarations it comes from, the copy tables' constants and
    /// functions included.
    func testNoHintNamesAGesture() throws {
        let s = try SourceTree.appSources()
        let scan = try Self.scanHints(in: s)
        XCTAssertGreaterThan(scan.sites, 5, "the scan should see the apps' hints")
        let tables: Set = ["contentsHint", "retryHint", "extendHint", "backFiveMinutesHint", "hintSample",
                           "hintSentence", "hint", "rowHint", "textHint", "privacyLine"]
        XCTAssertEqual(tables.subtracting(scan.declarations), [],
                       "the scan should read the declarations the hints come from")
        XCTAssertEqual(scan.offenders, [], "A hint says what happens, never which gesture makes it")
    }

    /// B7-2: a gesture written into a hint table, or into a function that
    /// returns a hint, is caught though the call site holds no literal; a
    /// table's other constants are left alone.
    func testTheHintScanReadsTheTablesHintsComeFrom() throws {
        let sources = [
            "Copy.swift": """
            enum PasteCopy {
                static let open = "Tap to open"
                static let label = "Tap"
                static func closing(_ soon: Bool) -> String {
                    if soon { return "Swipe down to close" }
                    return ""
                }
            }
            """,
            "Chip.swift": """
            enum Chip {
                case paste
                var hint: String {
                    switch self {
                    case .paste: return "Click to paste"
                    }
                }
            }
            """,
            "View.swift": """
            struct PasteView: View {
                var body: some View {
                    Text("Paste").accessibilityHint(PasteCopy.open)
                    Text("Close").accessibilityHint(PasteCopy.closing(true))
                    Text("Chip").accessibilityHint(chip.hint)
                }
            }
            """,
        ]
        let scan = try Self.scanHints(in: sources)
        XCTAssertEqual(scan.sites, 3)
        XCTAssertEqual(scan.offenders, ["Chip.swift:5 \u{00AB}Click to paste\u{00BB}",
                                        "Copy.swift:2 \u{00AB}Tap to open\u{00BB}",
                                        "Copy.swift:5 \u{00AB}Swipe down to close\u{00BB}"])
    }

    /// What `scanHints` found: the literals naming a gesture, the hint sites
    /// seen, and the names of the declarations read as hints.
    struct HintScan {
        var offenders: [String] = []
        var sites = 0
        var declarations: Set<String> = []
    }

    /// Reads every hint in `sources` (path to text). A hint site is a
    /// `.accessibilityHint(` call or a UIKit hint assignment; a hint
    /// declaration is any let, var or func named for a hint, or a member a
    /// site reads through a type (`Copy.name`, `Self.name`). Literals on a
    /// site's line or inside a hint declaration must name no gesture at all;
    /// every other literal must not say double-tap.
    static func scanHints(in sources: [String: String]) throws -> HintScan {
        let gesture = try NSRegularExpression(
            pattern: #"(?i)\b(double[- ]?)?(tap(s|ped|ping)?|click(s|ed|ing)?)\b|\bswip(e|es|ed|ing)\b"#)
        let doubleTap = try NSRegularExpression(pattern: #"(?i)\bdouble[- ]?tap"#)
        let site = try NSRegularExpression(pattern: #"\.accessibilityHint\(|\baccessibilityHint(Text)?\s*=(?!=)"#)
        let member = try NSRegularExpression(pattern: #"\b[A-Z]\w*\.([a-z_]\w*)"#)
        let declaration = try NSRegularExpression(pattern: #"\b(let|var|func)\s+([A-Za-z_]\w*)"#)
        let hintName = try NSRegularExpression(pattern: #"[Hh]int"#)
        func first(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }

        var scan = HintScan()
        // Comments dropped and literal text blanked, lines kept in place.
        let code = sources.mapValues { SwiftLiterals.code(in: $0).components(separatedBy: "\n") }

        // The sites, and the members they read through a type.
        var siteLines: [String: Set<Int>] = [:]
        var referenced: Set<String> = []
        for (path, lines) in code {
            for (index, line) in lines.enumerated() {
                guard let found = first(site, line), let range = Range(found.range, in: line) else { continue }
                siteLines[path, default: []].insert(index + 1)
                scan.sites += 1
                let argument = String(line[range.upperBound...])
                for match in member.matches(in: argument, range: NSRange(argument.startIndex..., in: argument)) {
                    referenced.insert(group(match, 1, argument))
                }
            }
        }

        // The declarations hints come from: the declaring line, a body in
        // braces (a function's may open a few lines down), or a constant
        // whose value continues on the next line.
        var tableLines: [String: Set<Int>] = [:]
        for (path, lines) in code {
            for (index, line) in lines.enumerated() {
                guard let found = first(declaration, line) else { continue }
                let name = group(found, 2, line)
                guard referenced.contains(name) || first(hintName, name) != nil else { continue }
                scan.declarations.insert(name)
                var last = index
                let isFunc = group(found, 1, line) == "func"
                if let open = (index..<min(index + (isFunc ? 6 : 1), lines.count))
                    .first(where: { lines[$0].contains("{") }) {
                    var depth = 0
                    for end in open..<lines.count {
                        depth += lines[end].filter { $0 == "{" }.count - lines[end].filter { $0 == "}" }.count
                        last = end
                        if depth <= 0 { break }
                    }
                } else if line.trimmingCharacters(in: .whitespaces).hasSuffix("="), index + 1 < lines.count {
                    last = index + 1
                }
                tableLines[path, default: []].formUnion((index + 1)...(last + 1))
            }
        }

        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            let hinted = siteLines[path, default: []].union(tableLines[path, default: []])
            for literal in SwiftLiterals.literals(in: source, path: path) {
                let text = SwiftLiterals.unescaped(literal.text)
                if first(hinted.contains(literal.line) ? gesture : doubleTap, text) != nil {
                    scan.offenders.append("\(path):\(literal.line) \u{00AB}\(text)\u{00BB}")
                }
            }
        }
        return scan
    }

    // MARK: - Helpers

    private func region(of source: String, from start: String, length: Int) throws -> Substring {
        let found = try XCTUnwrap(source.range(of: start), "missing \(start)")
        return source[found.lowerBound...].prefix(length)
    }
}
