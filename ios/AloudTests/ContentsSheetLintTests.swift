import XCTest

/// The iPhone's Contents sheet as the parity batch left it (P024-P033),
/// held in source where a hosted test can't reach: the sheet's view glue,
/// the chapter line's ways in, and the seam that keeps those off the Mac.
/// The rules themselves are unit-tested (PlaceHistoryRulesTests,
/// ContentsResultSnippetTests, ScrubAccessibilityTests).
final class ContentsSheetLintTests: XCTestCase {

    private static let sheetPath = "Reader/ContentsSheet.swift"
    private static let linePath = "Reader/ReaderMessageLine.swift"
    private static let seamPath = "Platform/PlatformContentsEntry.swift"

    /// The text from `start` up to (not including) the first `end` after
    /// it, whitespace collapsed so a reformat doesn't trip the lint.
    private func region(of source: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(source.range(of: start), "no '\(start)'")
        let to = try XCTUnwrap(source.range(of: end, range: from.upperBound..<source.endIndex),
                               "no '\(end)' after '\(start)'")
        return source[from.lowerBound..<to.lowerBound]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - P026: rows press

    func testEveryRowPressesToSurface2() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        XCTAssertFalse(sheet.contains(".buttonStyle(.plain)"), "Contents rows press to surface2, never plain")
        // Chapter, place, the earlier-stops toggle and result rows.
        XCTAssertEqual(occurrences(of: ".buttonStyle(ContentsRowButtonStyle())", in: sheet), 4)
        let style = try region(of: sheet, from: "private struct ContentsRowButtonStyle", to: "// MARK: - Chapter label")
        for needle in ["configuration.isPressed ? Theme.surface2 : Color.clear",
                       ".animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)"] {
            XCTAssertTrue(style.contains(needle), "the press style should contain '\(needle)': \(style)")
        }
        XCTAssertFalse(style.contains("scaleEffect"), "rows never scale on press")
    }

    // MARK: - P027, P028: chapter titles

    func testChapterTitlesAreRegularWithTheCurrentOneSemiboldOnTwoLines() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let label = try region(of: sheet, from: "struct ContentsChapterLabel: View", to: "// MARK: - Place label")
        for needle in [".font(Theme.rowTitle(emphasized: isCurrent))",
                       "HStack(alignment: .firstTextBaseline", ".lineLimit(2)", ".lineLimit(3)",
                       "dynamicTypeSize.isAccessibilitySize"] {
            XCTAssertTrue(label.contains(needle), "the chapter label should contain '\(needle)'")
        }
        XCTAssertFalse(label.contains("Theme.font(.headline)"), "a chapter title is not a semibold headline")
        XCTAssertTrue(sheet.contains(".frame(minHeight: 52)"), "chapter rows keep their 52pt minimum")
        let row = try region(of: sheet, from: "private func chapterRow(", to: "// MARK: - Where you stopped")
        XCTAssertTrue(row.contains("isCurrent: isCurrent"))
        XCTAssertTrue(row.contains(".accessibilityAddTraits(isCurrent ? .isSelected : [])"))
    }

    // MARK: - P024: half height

    func testHalfHeightKeepsOneStopAndTighterRows() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        XCTAssertTrue(sheet.contains("PlaceHistory.collapsedCount(atHalfHeight: detent == .medium,"))
        XCTAssertEqual(occurrences(of: "collapsedCount: collapsed", in: sheet), 2,
                       "the rows shown and the toggle count from the same number")
        let place = try region(of: sheet, from: "private func placeRow(", to: "/// An eyebrow over a run of rows")
        XCTAssertTrue(place.contains(".padding(.vertical, Theme.Space.xs)"), "place rows pad 8pt: \(place)")
        XCTAssertTrue(place.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(place.contains("ContentsPlaceLabel(row: row, compact: detent == .medium)"))
        let label = try region(of: sheet, from: "private struct ContentsPlaceLabel", to: "// MARK: - Result label")
        XCTAssertTrue(label.contains(".lineLimit(isAccessibilitySize ? 4 : (compact ? 1 : 2))"), label)
        XCTAssertTrue(label.contains(".font(Theme.font(row.isCurrent ? .subhead : .footnote))"),
                      "the current place's detail line is semibold: \(label)")
    }

    // MARK: - P025: picks play

    func testPicksPlayThroughTheSharedJump() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        XCTAssertFalse(sheet.contains("playback.jump("), "every pick goes through ContentsSearch.jumpAndPlay")
        let pick = try region(of: sheet, from: "private func pick(", to: "// MARK: - Field")
        for needle in ["ContentsSearch.jumpAndPlay(playback, to: sentence, origin: origin)",
                       "TransportHaptics.emit(.play)", "dismiss()"] {
            XCTAssertTrue(pick.contains(needle), "a pick should contain '\(needle)': \(pick)")
        }
        for origin in ["pick(chapter.startSentence, origin: .chapter)", "pick(row.sentence, origin: .chapter)",
                       "pick(match.sentenceID, origin: .searchResult)"] {
            XCTAssertTrue(sheet.contains(origin), "missing '\(origin)'")
        }
        XCTAssertEqual(occurrences(of: ".accessibilityHint(ContentsSearch.playsFromHereHint)", in: sheet), 3,
                       "chapter, place and result rows say they play")
    }

    // MARK: - P029, P030, P031: search

    func testTheSearchKeyScansNowAndDropsTheKeyboard() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let submit = try region(of: sheet, from: ".onSubmit {", to: ".autocorrectionDisabled()")
        for needle in ["debounceTask?.cancel()", "startSearch(now: query)", "fieldFocused = false"] {
            XCTAssertTrue(submit.contains(needle), "the Search key should '\(needle)': \(submit)")
        }
        XCTAssertFalse(submit.contains("pick("), "the Search key never jumps to the top hit")
        let now = try region(of: sheet, from: "private func scheduleSearch(", to: "let scan = Task.detached")
        XCTAssertTrue(now.contains("if !immediately {"), "a submitted scan skips the debounce: \(now)")
    }

    func testCancelAndTheEmptyStatesLetTheKeyboardGo() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let field = try region(of: sheet, from: "private var searchField: some View", to: "private var fieldBox")
        for needle in ["if fieldFocused {", "Button(action: cancelSearch)", "ContentsSearch.cancelSearch",
                       ".font(Theme.font(.callout))", ".foregroundStyle(Theme.accentStrong)",
                       ".frame(minWidth: 44, minHeight: 44)", "\"search.cancel\""] {
            XCTAssertTrue(field.contains(needle), "Cancel should contain '\(needle)': \(field)")
        }
        let cancel = try region(of: sheet, from: "private func cancelSearch()", to: "private func pick(")
        for needle in ["query = \"\"", "searchMemory.forget()", "fieldFocused = false"] {
            XCTAssertTrue(cancel.contains(needle), "Cancel should '\(needle)': \(cancel)")
        }
        // The explicit 44pt clear button stays (protected).
        XCTAssertTrue(sheet.contains("\"search.clear\""))
        let area = try region(of: sheet, from: "private var contentArea: some View", to: "// MARK: - Opening")
        XCTAssertFalse(area.contains("Spacer("), "a blank state is a scroll view, not a spacer: \(area)")
        let blank = try region(of: sheet, from: "private func keyboardDismissingArea", to: "// MARK: - Debounced scan")
        XCTAssertTrue(blank.contains(".scrollDismissesKeyboard(.immediately)"), blank)
        let empty = try region(of: sheet, from: "private func emptyState(", to: "/// Where the list would be")
        XCTAssertTrue(empty.contains("keyboardDismissingArea"), empty)
    }

    func testAPickedResultsSearchIsRemembered() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let result = try region(of: sheet, from: "private func resultRow(", to: "private func emptyState(")
        for needle in ["searchMemory.remember(query: query, pickedSentence: match.sentenceID, in: playback.document?.id)",
                       ".accessibilityAddTraits(isPicked ? .isSelected : [])", ".id(match.id)"] {
            XCTAssertTrue(result.contains(needle), "a result row should contain '\(needle)'")
        }
        let opened = try region(of: sheet, from: "private func opened()", to: "private func queryChanged(")
        for needle in ["searchMemory.restore(for: playback.document?.id)", "searchMemory.consumeSearchFocus()",
                       "detent = .large", "startSearch(now: restored.query)", "fieldFocused = true"] {
            XCTAssertTrue(opened.contains(needle), "opening should contain '\(needle)': \(opened)")
        }
        let changed = try region(of: sheet, from: "private func queryChanged(", to: "private func cancelSearch()")
        XCTAssertTrue(changed.contains("if ContentsSearchMemory.isBlank(newValue) { searchMemory.forget() }"))
    }

    // MARK: - P032

    func testTheHitIsUnderlinedWithoutColor() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        XCTAssertTrue(sheet.contains("@Environment(\\.accessibilityDifferentiateWithoutColor)"))
        XCTAssertTrue(sheet.contains("Self.emphasized(snippet, underlined: differentiateWithoutColor)"))
        XCTAssertTrue(sheet.contains(".underline(underlined, color: Theme.accentStrong)"))
    }

    // MARK: - P033: the chapter line's ways in

    func testTheChapterLineOffersSearchOnTheIPhoneOnly() throws {
        let s = try SourceTree.sources(only: [Self.linePath, Self.seamPath])
        let line = try XCTUnwrap(s[Self.linePath])
        let seam = try XCTUnwrap(s[Self.seamPath])
        let seamCode = SwiftLiterals.code(in: seam).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(seamCode.contains("#if os(iOS) static let chapterLineOffersSearch = true"), seamCode)
        XCTAssertTrue(seamCode.contains("#elseif os(macOS) static let chapterLineOffersSearch = false"), seamCode)

        XCTAssertTrue(line.contains(".modifier(ContentsEntry(onOpenContents: onOpenContents, offersSearchAction: true))"),
                      "the position line offers the search")
        XCTAssertTrue(line.contains(".modifier(ContentsEntry(onOpenContents: onOpenContents, offersSearchAction: false))"),
                      "the error line keeps Contents in its menu")
        let entry = try region(of: line, from: "private struct ContentsEntry: ViewModifier", to: "private func searchThisBook()")
        for needle in ["if PlatformContentsEntry.chapterLineOffersSearch {", ".contextMenu {",
                       "Button(ContentsSearch.title, systemImage: \"list.bullet\", action: onOpenContents)",
                       "Button(ContentsSearch.searchPrompt, systemImage: \"magnifyingglass\", action: searchThisBook)",
                       ".accessibilityActions {"] {
            XCTAssertTrue(entry.contains(needle), "the entry should contain '\(needle)': \(entry)")
        }
        let search = try region(of: line, from: "private func searchThisBook()", to: "onOpenContents()")
        XCTAssertTrue(search.contains("ContentsSearchMemory.shared.requestSearchFocus()"))
        // The protected Voice Control names stay, the visible title first.
        let labels = try region(of: line, from: "static func positionInputLabels(", to: "/// The title, and Back 5 min")
        XCTAssertTrue(labels.contains("[Text(title), Text(\"Contents\")]"), labels)
        XCTAssertTrue(labels.contains("PlatformContentsEntry.chapterLineOffersSearch ? [Text(ContentsSearch.searchInputLabel)] : []"))
        XCTAssertTrue(line.contains("private static let contentsHint = \"Opens contents and search\""))
    }
}
