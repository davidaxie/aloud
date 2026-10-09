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
        XCTAssertEqual(occurrences(of: "accessibilitySize: dynamicTypeSize.isAccessibilitySize", in: sheet), 3,
                       "the rows shown, the toggle and the book's time left (R4-29) read the same size")
        let place = try region(of: sheet, from: "private func placeRow(", to: "/// An eyebrow over a run of rows")
        XCTAssertTrue(place.contains(".padding(.vertical, Theme.Space.xs)"), "place rows pad 8pt: \(place)")
        XCTAssertTrue(place.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(place.contains("ContentsPlaceLabel(row: row, compact: detent == .medium)"))
        let label = try region(of: sheet, from: "private struct ContentsPlaceLabel", to: "// MARK: - Result label")
        XCTAssertTrue(label.contains(".lineLimit(isAccessibilitySize ? 4 : (compact ? 1 : 2))"), label)
        XCTAssertTrue(label.contains(".font(Theme.font(row.isCurrent ? .subhead : .footnote))"),
                      "the current place's detail line is semibold: \(label)")
        XCTAssertTrue(label.contains("Text(row.snippet) .font(Theme.excerpt())"),
                      "the snippet is the book's words, in the reading serif (R3-13): \(label)")
    }

    // MARK: - P025: picks play

    func testPicksPlayThroughTheSharedJump() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        XCTAssertFalse(sheet.contains("playback.jump("), "every pick goes through ContentsSearch.jumpAndPlay")
        let pick = try region(of: sheet, from: "private func pick(", to: "// MARK: - Field")
        for needle in ["let started = ContentsSearch.jumpAndPlay(playback, to: sentence, origin: origin)",
                       "TransportHaptics.emit(started ? .play : .place)", "dismiss()"] {
            XCTAssertTrue(pick.contains(needle), "a pick should contain '\(needle)': \(pick)")
        }
        // One haptic per pick, after the jump that decides it: play when it
        // started the book, the place tick while the book reads on.
        XCTAssertEqual(pick.components(separatedBy: "TransportHaptics.emit").count - 1, 1, pick)
        let jump = try XCTUnwrap(pick.range(of: "jumpAndPlay("), pick)
        let haptic = try XCTUnwrap(pick.range(of: "TransportHaptics.emit"), pick)
        XCTAssertLessThan(jump.lowerBound, haptic.lowerBound, "the jump decides the haptic")
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
        for needle in ["let listAsked = searchMemory.consumeListRequest()",
                       "listAsked ? nil : searchMemory.restore(for: playback.document?.id, "
                       + "playhead: playback.currentSentence, navigation: navigation, now: Date())",
                       "searchMemory.consumeSearchFocus()",
                       "detent = .large", "startSearch(now: restored.query)", "fieldFocused = true"] {
            XCTAssertTrue(opened.contains(needle), "opening should contain '\(needle)': \(opened)")
        }
        XCTAssertFalse(opened.contains("searchMemory.restore(for: playback.document?.id)"),
                       "the restore reads the playhead and the clock (R3-14): \(opened)")
        XCTAssertFalse(opened.contains("searchMemory.forget()"), "asking for the list keeps the search: \(opened)")
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

    /// R3-14: picking a chapter or a place is moving on another way, so it
    /// forgets the search before the jump; a result's pick remembers it.
    func testAChapterOrPlacePickForgetsTheSearch() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let chapter = try region(of: sheet, from: "private func chapterRow(", to: "} label: {")
        XCTAssertTrue(chapter.contains("searchMemory.forget() pick(chapter.startSentence, origin: .chapter)"), chapter)
        let place = try region(of: sheet, from: "private func placeRow(", to: "} label: {")
        XCTAssertTrue(place.contains("searchMemory.forget() pick(row.sentence, origin: .chapter)"), place)
        let result = try region(of: sheet, from: "private func resultRow(", to: "} label: {")
        XCTAssertFalse(result.contains("forget()"), "a result's pick remembers: \(result)")
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
                       "Button(ContentsSearch.title, systemImage: \"list.bullet\", action: openList)",
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
        // R3-14: the menu's Contents opens on the chapters, keeping the search.
        let list = try region(of: entrySource, from: "private func openList()", to: "onOpenContents()")
        XCTAssertTrue(list.contains("ContentsSearchMemory.shared.requestList()"), list)
        XCTAssertFalse(list.contains("forget()"), list)
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
        // R4-32: the label without ", current"; the trait says it.
        XCTAssertTrue(sheet.contains(".accessibilityLabel(row.rowLabel)"))
        // R3-13: the snippet in the reading serif and the reader's colour;
        // the detail line stays in the sans footnote, faint.
        XCTAssertTrue(label.contains("Text(row.snippet) .font(Theme.excerpt()) .foregroundStyle(Theme.text)"), label)
        XCTAssertEqual(occurrences(of: "Theme.font(.body)", in: label), 0, "no sans quote: \(label)")
        XCTAssertTrue(label.contains(".foregroundStyle(Theme.textFaint)"), label)
    }

    /// R3-13: a result's sentence is set in the reading serif, its hit still
    /// tinted (underlined without colour, never bolded), its chapter in the
    /// sans footnote. The AX-aware line limits and the lead stay.
    func testAResultQuotesTheBookInTheReadingSerif() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let label = try region(of: sheet, from: "struct ContentsResultLabel: View", to: "static func emphasized(")
        for needle in ["Self.emphasized(snippet, underlined: differentiateWithoutColor) .font(Theme.excerpt())",
                       ".lineLimit(isAccessibilitySize ? 5 : 3)",
                       "leadLimit: ContentsSearch.leadLimit(for: dynamicTypeSize)",
                       "Text(location) .font(Theme.font(.footnote)) .foregroundStyle(Theme.textFaint)"] {
            XCTAssertTrue(label.contains(needle), "the result label should contain '\(needle)': \(label)")
        }
        XCTAssertEqual(occurrences(of: "Theme.font(.body)", in: label), 0, "no sans quote: \(label)")
        let emphasis = try region(of: sheet, from: "static func emphasized(", to: "\n}")
        XCTAssertTrue(emphasis.contains("foregroundColor(Theme.accentStrong)"), emphasis)
        XCTAssertFalse(emphasis.contains("weight") || emphasis.contains("bold"), "never a weight change: \(emphasis)")
    }

    /// R2-17: Contents closes from its header at any height, and in a
    /// search-only book with the keyboard up; its keyboard and detent
    /// rules and its scrim stay.
    func testContentsClosesFromItsHeader() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let body = try region(of: sheet, from: "var body: some View {", to: ".onAppear { opened() }")
        // R4-30: no gap of its own, so the title sits at the other sheets'
        // height; the field sits md under the header.
        XCTAssertTrue(body.contains("SheetHeader(title: ContentsSearch.title, titleIdentifier: \"contents.title\", "
                                    + "closeIdentifier: \"contents.close\")"), body)
        XCTAssertFalse(body.contains("grabberGap"), body)
        XCTAssertTrue(body.contains("} .zIndex(1) .padding(.bottom, Theme.Space.md)"), body)
        XCTAssertTrue(body.contains(".sheetChrome(hasList ? [.medium, .large] : [.large], selection: $detent)"), body)
        XCTAssertTrue(body.contains("if focused { detent = .large }"), body)
        XCTAssertTrue(body.contains("if newDetent != .large { fieldFocused = false }"), body)
        XCTAssertFalse(body.contains("backgroundInteraction"), "the scrim stays")

        let grabberPath = "Theme/SheetGrabber.swift"
        let g = try SourceTree.sources(only: [grabberPath]).mapValues(SwiftLiterals.code(in:))
        let grabber = try XCTUnwrap(g[grabberPath])
        XCTAssertFalse(grabber.contains("grabberGap"), "one grabber gap for every sheet")
        let header = try region(of: grabber, from: "struct SheetHeader: View", to: "private var titleText")
        XCTAssertTrue(header.contains("VStack(spacing: Theme.Space.xs) { SheetGrabber()"), header)
    }

    // MARK: - Round 4

    /// R4-29: the whole book's time left under the title, from the shared
    /// helper, over the list only; spoken spelled out; wrapping.
    func testTheBookLeftLineShowsOverTheListOnly() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let body = try region(of: sheet, from: "var body: some View {", to: ".onAppear { opened() }")
        XCTAssertTrue(body.contains("if showsBookLeftLine, let minutes = bookMinutesLeft { bookLeftLine(minutes) }"), body)
        let estimate = try region(of: sheet, from: "private var bookMinutesLeft: Int? {", to: "/// One caption line")
        XCTAssertTrue(estimate.contains("navigation.bookMinutesLeft(at: playback.currentSentence, rate: playback.rate, "
                                        + "isFinished: playback.isAtEnd)"), estimate)
        let line = try region(of: sheet, from: "private func bookLeftLine(_ minutes: Int)", to: "// MARK: - Opening")
        for needle in ["Text(ContentsSearch.bookLeftCaption(minutes: minutes))",
                       ".font(Theme.font(.caption))", ".foregroundStyle(Theme.textMuted)",
                       ".multilineTextAlignment(.center)", ".fixedSize(horizontal: false, vertical: true)",
                       ".accessibilityLabel(ContentsSearch.bookLeftSpoken(minutes: minutes))",
                       ".accessibilityIdentifier(\"contents.bookLeft\")"] {
            XCTAssertTrue(line.contains(needle), "the line should contain '\(needle)': \(line)")
        }
        XCTAssertFalse(line.contains(".lineLimit("), "it wraps at the accessibility sizes")
    }

    /// R4-29 against P024: the line adds a caption's height over the
    /// field, so at half height on the shortest screens, over a stop, it
    /// waits for the sheet to grow, as the earlier-stops toggle does, and
    /// the first chapter still starts above the fold. The sheet's own
    /// height decides it; the rule itself is in ContentsPlaybackRound4Tests.
    func testTheBookLeftLineWaitsForTheSheetOnTheShortestScreens() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let shows = try region(of: sheet, from: "private var showsBookLeftLine: Bool {", to: "/// One caption line")
        XCTAssertTrue(shows.contains("ContentsSearch.showsBookLeft(query: query) && "
                                     + "PlaceHistory.showsBookLeft(hasChapterList: navigation.hasChapterList, "
                                     + "hasStops: !placeRows.isEmpty, atHalfHeight: detent == .medium, "
                                     + "shortSheet: shortSheet, accessibilitySize: dynamicTypeSize.isAccessibilitySize)"),
                      shows)
        let body = try region(of: sheet, from: "var body: some View {", to: ".onAppear { opened() }")
        XCTAssertTrue(body.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) "
                                    + ".onGeometryChange(for: Bool.self) { PlaceHistory.isShortSheet(height: "
                                    + "Double($0.size.height)) } action: { shortSheet = $0 }"),
                      "the whole sheet's height, which its detent sets, not its content's: \(body)")
    }

    /// R4-31: the field takes the Classics field's capsule, on surface2.
    func testTheSearchFieldIsACapsule() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let field = try region(of: sheet, from: "private var fieldBox: some View {", to: "// MARK: - Chapters")
        XCTAssertTrue(field.contains(".background(Theme.surface2, in: Capsule(style: .continuous))"), field)
        XCTAssertTrue(field.contains(".overlay(Capsule(style: .continuous) .strokeBorder(Theme.Stroke.borderColor, "
                                     + "lineWidth: Theme.Stroke.borderWidth))"), field)
        XCTAssertFalse(field.contains("RoundedRectangle"), field)
        XCTAssertTrue(field.contains(".frame(minHeight: 44)"), field)
        XCTAssertTrue(field.contains(".foregroundStyle(Theme.textFaint)"), "the faint magnifier and prompt stay")
        XCTAssertFalse(sheet.contains(".searchable("), "the sheet keeps its own keyboard and detent rules")
    }

    /// R4-32: both row kinds say "selected" through the trait alone, and
    /// under Bold Text the current chapter keeps a mark that isn't weight.
    func testCurrentRowsSayTheirStateOnceAndKeepAMarkUnderBoldText() throws {
        let s = try SourceTree.sources(only: [Self.sheetPath])
        let sheet = try XCTUnwrap(s[Self.sheetPath])
        let chapter = try region(of: sheet, from: "private func chapterRow(", to: "// MARK: - Where you stopped")
        XCTAssertTrue(chapter.contains(".accessibilityLabel(ContentsSearch.chapterRowLabel(title: title, "
                                       + "minutes: minutes))"), chapter)
        XCTAssertFalse(chapter.contains("chapterAccessibilityLabel"), chapter)
        XCTAssertTrue(chapter.contains(".accessibilityAddTraits(isCurrent ? .isSelected : [])"), chapter)
        XCTAssertTrue(chapter.contains(".frame(width: currentMarkerWidth)"), chapter)
        let place = try region(of: sheet, from: "private func placeRow(", to: "/// An eyebrow over")
        XCTAssertTrue(place.contains(".accessibilityLabel(row.rowLabel)"), place)
        XCTAssertTrue(place.contains(".accessibilityAddTraits(row.isCurrent ? .isSelected : [])"), place)
        let result = try region(of: sheet, from: "private func resultRow(", to: "private func emptyState(")
        XCTAssertTrue(result.contains(".frame(width: currentMarkerWidth)"), "the restored pick's bar matches")

        XCTAssertTrue(sheet.contains("ContentsChapterLabel.markerWidth(boldText: legibilityWeight == .bold "
                                     + "|| Theme.BoldText.shared.isOn)"))
        let label = try region(of: sheet, from: "struct ContentsChapterLabel: View", to: "// MARK: - Place label")
        XCTAssertTrue(label.contains("@Environment(\\.legibilityWeight) private var legibilityWeight"), label)
        XCTAssertTrue(label.contains(".foregroundStyle(Self.titleColor(isCurrent: isCurrent, isCompleted: isCompleted, "
                                     + "boldText: legibilityWeight == .bold || Theme.BoldText.shared.isOn))"), label)
        XCTAssertTrue(label.contains("if isCurrent && boldText { return Theme.accentStrong }"), label)
        XCTAssertFalse(label.contains("accentSoft)"), "never a fill the faint time can't sit on")
    }

    /// R4-33: the iPhone's session claims and releases on one serial
    /// queue, the claim off the main actor, so a release always lands
    /// before a later claim; the graph stays on the main actor.
    func testTheSessionClaimsAndReleasesOnOneQueue() throws {
        let path = "Playback/AudioSessionManager.swift"
        let s = try SourceTree.sources(only: [path]).mapValues(SwiftLiterals.code(in:))
        let source = try XCTUnwrap(s[path])
        XCTAssertEqual(occurrences(of: "DispatchQueue(label:", in: source), 1, "one queue")
        let activate = try region(of: source, from: "func activate() throws {", to: "func deactivate(")
        XCTAssertTrue(activate.contains("try Self.sessionQueue.sync {"), activate)
        let deactivate = try region(of: source, from: "func deactivate(notifyingOthers: Bool) {", to: "func claim()")
        XCTAssertTrue(deactivate.contains("Self.sessionQueue.async {"), deactivate)
        let claim = try region(of: source, from: "func claim() async throws {", to: "func bindOutput(")
        XCTAssertTrue(claim.contains("Self.sessionQueue.async {"), claim)
        XCTAssertTrue(claim.contains("throw AudioOutputHeldElsewhere()"), claim)
        XCTAssertTrue(source.contains("extension AudioSessionManager: AudioOutputClaiming {}"))

        let controllerPath = "Playback/PlaybackController.swift"
        let c = try SourceTree.sources(only: [controllerPath])
        let controller = try XCTUnwrap(c[controllerPath])
        let start = try region(of: controller, from: "private func startAudioHardware() throws {",
                               to: "private static let audioStartSignposter")
        for needle in ["audioOutput.bindOutput(of: audioEngine)", "audioEngine.prepare()", "try audioEngine.start()",
                       "beginInterval(\"engineStart\")", "beginInterval(\"activate\")"] {
            XCTAssertTrue(start.contains(needle), "the hardware start keeps '\(needle)': \(start)")
        }
        let begin = try region(of: controller, from: "private func beginClaim(", to: "private func awaitPendingClaim(")
        XCTAssertTrue(begin.contains("beginInterval(\"activate\")"), "the claim keeps its signpost: \(begin)")
    }
}
