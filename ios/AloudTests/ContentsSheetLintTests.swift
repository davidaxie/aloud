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
    private static let entryPath = "Reader/ChapterLineContentsEntry.swift"

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
        // R2-19: one stop over a chapter list at either height; the detent
        // reaches the toggle alone.
        XCTAssertTrue(sheet.contains("PlaceHistory.collapsedCount(hasChapterList: navigation.hasChapterList,"))
        XCTAssertFalse(sheet.contains("collapsedCount(atHalfHeight:"), "raising the sheet adds no stops")
        // The rows shown and the toggle read the same height and size.
        let section = try region(of: sheet, from: "private func placesSection(", to: "/// Places kept above the toggle")
        XCTAssertTrue(section.contains("expanded: showsEarlierPlaces, collapsedCount: collapsed)"), section)
        XCTAssertTrue(section.contains("PlaceHistory.offersEarlier(total: rows.count, hasChapterList: navigation.hasChapterList, "
                                       + "expanded: showsEarlierPlaces, atHalfHeight: detent == .medium, "
                                       + "accessibilitySize: dynamicTypeSize.isAccessibilitySize)"),
                      "the toggle waits for the sheet to grow: \(section)")
        XCTAssertEqual(occurrences(of: "accessibilitySize: dynamicTypeSize.isAccessibilitySize", in: sheet), 2)
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
        // Any edit forgets the remembered search, so a reopening never
        // brings back a query the field no longer holds.
        XCTAssertTrue(changed.contains("pickedSentence = nil searchMemory.forget() scheduleSearch(for: newValue)"), changed)
        XCTAssertFalse(changed.contains("isBlank"), "not only a blank field forgets: \(changed)")
        // The shared memory is read on the main actor, never as a default
        // argument (a Swift 6 error).
        XCTAssertTrue(sheet.contains("private var searchMemory: ContentsSearchMemory { .shared }"))
        XCTAssertFalse(sheet.contains("searchMemory: ContentsSearchMemory = .shared"))
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
        let s = try SourceTree.sources(only: [Self.linePath, Self.seamPath, Self.entryPath])
        let line = try XCTUnwrap(s[Self.linePath])
        let seam = try XCTUnwrap(s[Self.seamPath])
        let entrySource = try XCTUnwrap(s[Self.entryPath])
        let seamCode = SwiftLiterals.code(in: seam).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(seamCode.contains("#if os(iOS) static let chapterLineOffersSearch = true"), seamCode)
        XCTAssertTrue(seamCode.contains("#elseif os(macOS) static let chapterLineOffersSearch = false"), seamCode)

        XCTAssertTrue(line.contains(".modifier(ChapterLineContentsEntry(onOpenContents: onOpenContents, offersSearchAction: true))"),
                      "the position line offers the search")
        XCTAssertTrue(line.contains(".modifier(ChapterLineContentsEntry(onOpenContents: onOpenContents, offersSearchAction: false))"),
                      "the error line keeps Contents in its menu")
        // The entry lives in its own file, so the player bar's count of the
        // line's buttons (each with the Large Content Viewer) stays its own.
        XCTAssertFalse(line.contains("struct ChapterLineContentsEntry"))
        XCTAssertFalse(line.contains(".contextMenu"), "the line's menu comes only through the entry")
        let entry = try region(of: entrySource, from: "struct ChapterLineContentsEntry: ViewModifier",
                               to: "private func searchThisBook()")
        for needle in ["if PlatformContentsEntry.chapterLineOffersSearch {", ".contextMenu {",
                       "Button(ContentsSearch.title, systemImage: \"list.bullet\", action: onOpenContents)",
                       "Button(ContentsSearch.searchMenuItem, systemImage: \"magnifyingglass\", action: searchThisBook)",
                       ".accessibilityActions {", "@Environment(\\.dynamicTypeSize) private var dynamicTypeSize",
                       "if Self.offersMenu(dynamicTypeSize: dynamicTypeSize) {",
                       "!dynamicTypeSize.isAccessibilitySize"] {
            XCTAssertTrue(entry.contains(needle), "the entry should contain '\(needle)': \(entry)")
        }
        // The VoiceOver action comes before the size check, so it stays at
        // every size; only the long-press menu steps aside for the viewer.
        let actions = try XCTUnwrap(entry.range(of: ".accessibilityActions {"))
        let sizeCheck = try XCTUnwrap(entry.range(of: "if Self.offersMenu(dynamicTypeSize: dynamicTypeSize) {"))
        let menu = try XCTUnwrap(entry.range(of: ".contextMenu {"))
        XCTAssertLessThan(actions.lowerBound, sizeCheck.lowerBound, entry)
        XCTAssertLessThan(sizeCheck.lowerBound, menu.lowerBound, entry)
        let search = try region(of: entrySource, from: "private func searchThisBook()", to: "onOpenContents()")
        XCTAssertTrue(search.contains("ContentsSearchMemory.shared.requestSearchFocus()"))
        // The protected Voice Control names stay, the visible title first.
        let labels = try region(of: line, from: "static func positionInputLabels(", to: "/// The title, and Back 5 min")
        XCTAssertTrue(labels.contains("[Text(title), Text(\"Contents\")]"), labels)
        XCTAssertTrue(labels.contains("PlatformContentsEntry.chapterLineOffersSearch ? [Text(ContentsSearch.searchInputLabel)] : []"))
        XCTAssertTrue(line.contains("private static let contentsHint = \"Opens contents and search\""))
    }

    // MARK: - Critique round 1

    /// R1-23: the placeholder is drawn in textFaint (4.73:1 light, 4.62:1
    /// dark on surface2), not the system's grey; the title argument stays,
    /// so VoiceOver still hears the field's name.
    func testTheSearchPlaceholderMeetsAA() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let field = try region(of: sheet, from: "TextField(ContentsSearch.searchPrompt, text: $query,",
                               to: ".focused($fieldFocused)")
        XCTAssertTrue(field.contains("prompt: Text(ContentsSearch.searchPrompt).foregroundStyle(Theme."), field)
        XCTAssertTrue(field.contains("foregroundStyle(Theme.textFaint)"), field)
    }

    /// R1-21: the sheet opens on the current chapter unless the newest stop
    /// is in another chapter (`PlaceHistory.opensOnCurrentChapter`), never
    /// at the top merely because the book has places.
    func testContentsOpensOnTheCurrentChapterAfterAListen() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let list = try region(of: sheet, from: "private var chapterList: some View", to: "private func chapterRows(")
        XCTAssertTrue(list.contains("if PlaceHistory.opensOnCurrentChapter(newestStop: placeRows.first?.sentence,"), list)
        XCTAssertTrue(list.contains("scrollToCurrent(proxy)"), list)
        XCTAssertFalse(list.contains("if placeRows.isEmpty { scrollToCurrent(proxy) }"), "places alone kept it at the top")
    }

    /// R1-24: a place row draws its snippet (`PlaceRow.snippet`); VoiceOver
    /// keeps the row's sentence label.
    func testAPlaceRowDrawsItsSnippet() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let label = try region(of: sheet, from: "private struct ContentsPlaceLabel: View", to: "// MARK: - Result label")
        XCTAssertTrue(label.contains("Text(row.snippet)"), label)
        XCTAssertFalse(label.contains("Text(row.text)"), label)
        XCTAssertTrue(label.contains(".lineLimit(isAccessibilitySize ? 4 : (compact ? 1 : 2))"), "P024's line limits stay")
        XCTAssertTrue(sheet.contains(".accessibilityLabel(row.accessibilityLabel)"))
    }

    /// R2-17: Contents closes from its header at any height, and in a
    /// search-only book with the keyboard up; its keyboard and detent
    /// rules and its scrim stay.
    func testContentsClosesFromItsHeader() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let body = try region(of: sheet, from: "var body: some View {", to: ".onAppear { opened() }")
        XCTAssertTrue(body.contains("SheetHeader(title: ContentsSearch.title, titleIdentifier: \"contents.title\", "
                                    + "closeIdentifier: \"contents.close\", grabberGap: Theme.Space.md)"), body)
        XCTAssertTrue(body.contains(".sheetChrome(hasList ? [.medium, .large] : [.large], selection: $detent)"), body)
        XCTAssertTrue(body.contains("if focused { detent = .large }"), body)
        XCTAssertTrue(body.contains("if newDetent != .large { fieldFocused = false }"), body)
        XCTAssertFalse(body.contains("backgroundInteraction"), "the scrim stays")
    }
}
