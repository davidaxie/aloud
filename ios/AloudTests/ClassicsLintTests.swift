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
    /// Control and Switch Control.
    func testNoHintNamesAGesture() throws {
        let s = try SourceTree.appSources()
        let gesture = try NSRegularExpression(
            pattern: #"(?i)\b(double[- ]?)?(tap(s|ped|ping)?|click(s|ed|ing)?)\b|\bswip(e|es|ed|ing)\b"#)
        let doubleTap = try NSRegularExpression(pattern: #"(?i)\bdouble[- ]?tap"#)
        func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        var offenders: [String] = []
        var hintCount = 0
        for (path, source) in s.sorted(by: { $0.key < $1.key }) {
            let lines = source.components(separatedBy: "\n")
            let hintLines = Set(lines.indices.filter { lines[$0].contains(".accessibilityHint(") }.map { $0 + 1 })
            hintCount += hintLines.count
            for literal in SwiftLiterals.literals(in: source, path: path) {
                let text = SwiftLiterals.unescaped(literal.text)
                if hintLines.contains(literal.line) ? matches(gesture, text) : matches(doubleTap, text) {
                    offenders.append("\(path):\(literal.line) \u{00AB}\(text)\u{00BB}")
                }
            }
        }
        XCTAssertGreaterThan(hintCount, 5, "the scan should see the apps' hints")
        XCTAssertEqual(offenders, [], "A hint says what happens, never which gesture makes it")
    }

    // MARK: - Helpers

    private func region(of source: String, from start: String, length: Int) throws -> Substring {
        let found = try XCTUnwrap(source.range(of: start), "missing \(start)")
        return source[found.lowerBound...].prefix(length)
    }
}
