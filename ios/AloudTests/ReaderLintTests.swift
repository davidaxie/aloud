import XCTest

/// Source lints for the reader (R11, R12a/e, R15, R16 and the iOS 26 glass
/// rule): the old follow machinery, the floating chip and the value probe
/// stay gone.
final class ReaderLintTests: XCTestCase {

    private func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Lines that aren't comments. Some screens explain in a comment why
    /// they avoid a modifier, so modifier lints read code only.
    private func codeLines(_ text: String) -> [Substring] {
        lines(text).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    func testTheOldFollowAndChipAreGone() throws {
        let app = try SourceTree.sources()
        for needle in ["riseTransition", "idleReturn", "Return to playhead", "scrolledAway"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: app), [], "'\(needle)' is gone (R16)")
        }
        XCTAssertEqual(SourceTree.files(containing: "autoScroll", in: app), ["App/AppModel.swift"],
                       "only the V4 migration still names the removed pref")
    }

    func testTheReaderScreenHasOneChipSlotMagicTapAndAnIdentifierProbe() throws {
        let screen = try XCTUnwrap(try SourceTree.sources(only: ["Reader/ReaderScreen.swift"])["Reader/ReaderScreen.swift"])
        let file = ["Reader/ReaderScreen.swift": screen]
        XCTAssertEqual(SourceTree.occurrences(of: "ReaderChipView(", in: file), 1, "one chip slot (R11)")
        XCTAssertTrue(screen.contains(".accessibilityAction(.magicTap"), "magic tap plays and pauses (R12b)")
        XCTAssertTrue(screen.contains("reader.sentence.\\("), "the playhead lives in the probe's identifier (R12e)")
        XCTAssertFalse(screen.contains("accessibilityIdentifier(\"reader.sentence\")"), "the value probe is gone")
    }

    /// R16: calm follow's band ends at the player bar's top edge, measured
    /// against the text's bottom. The bar's height alone leaves out the
    /// home-indicator strip it paints over, so the band ran behind the bar.
    func testTheBandEndsAtThePlayerBarsTopEdge() throws {
        let screen = try XCTUnwrap(try SourceTree.sources(only: ["Reader/ReaderScreen.swift"])["Reader/ReaderScreen.swift"])
        XCTAssertTrue(screen.contains("obscuredBottom: FollowBand.obscuredBottom("),
                      "the text view gets the bar's reach, not its height")
        XCTAssertFalse(codeLines(screen).contains { $0.contains("size.height") },
                       "no bar height measured on its own")
    }

    /// R3-01 repair: the text's bottom edge, and its twin in the window, are
    /// read on the text view before its `.ignoresSafeArea(edges: .bottom)`.
    /// The ignore places the text down to the window's bottom, but its own
    /// frame stays the safe area's, which ends at the bar's top: read after
    /// it, the band's edges came in level on every open, the bar never
    /// counted, and a reopened finished book never placed its colophon.
    func testTheTextsBottomIsReadOnTheTextInsideItsIgnore() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        let text = try XCTUnwrap(screen.range(of: "ReaderTextView("), "the text view")
        let rest = text.upperBound..<screen.endIndex
        let ignore = try XCTUnwrap(screen.range(of: ".ignoresSafeArea(edges: .bottom)", range: rest), "the text's ignore")
        for reading in ["textBottom = maxY", "textBottomInWindow = maxY"] {
            let at = try XCTUnwrap(screen.range(of: reading, range: rest), reading)
            XCTAssertLessThan(at.lowerBound, ignore.lowerBound, "\(reading) is read on the text, inside its ignore")
        }
        XCTAssertTrue(screen.contains("bandMeasured: FollowBand.isMeasured(textMaxY: textBottom, chromeMinY: barTop)"),
                      "the colophon waits on the same edges")
    }

    /// P046: the reader's principal item names the author under the title,
    /// one header for VoiceOver.
    func testTheTitleBarNamesTheAuthor() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        XCTAssertTrue(screen.contains("ReaderTitleCopy.label(title: liveDocument.title, author:"),
                      "the title bar's header names the author")
        XCTAssertTrue(screen.contains("Text(author)"), "the author's line under the title")
        // R1-20: the author at every size, the block capped where the bar
        // caps its text, and the title centred like every other screen's.
        XCTAssertTrue(screen.contains(".dynamicTypeSize(...DynamicTypeSize.xxLarge)"),
                      "the title block is capped at xxLarge, where both lines fit")
        XCTAssertFalse(screen.contains("isAccessibilitySize"), "the author shows at the accessibility sizes too")
        XCTAssertFalse(screen.contains(".toolbarRole("), "no role that moves the title to the leading side")
        XCTAssertTrue(screen.contains(".sharedBackgroundVisibility(.hidden)"), "no glass capsule behind the title")
    }

    /// R1-13: the sentence menu lifts a snapshot of the sentence's lines,
    /// never the text view, which would hide the whole column behind it.
    func testTheSentenceMenuLiftsASnapshot() throws {
        let path = "Reader/ReaderTextView.swift"
        let s = try SourceTree.sources(only: [path])
        let view = try XCTUnwrap(s[path])
        XCTAssertFalse(view.contains("UITargetedPreview(view: textView"), "lifting the text view blanks the page")
        XCTAssertTrue(view.contains("resizableSnapshotView(from: union"), "a snapshot of the lines on screen")
        XCTAssertTrue(view.contains("UIPreviewTarget(container: textView"))
    }

    /// R1-14: the Aa sheet's dismissal lives in the column's tap, not in
    /// `tapSentence`, which VoiceOver's Play from here and the menu share.
    func testATapWithTheSheetUpOnlyClosesIt() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        XCTAssertTrue(screen.contains("onDismissTap: showAppearanceSheet ? { showAppearanceSheet = false } : nil"))
        let tap = try XCTUnwrap(screen.range(of: "private func tapSentence("))
        let body = screen[tap.lowerBound...].prefix(200)
        XCTAssertFalse(body.contains("showAppearanceSheet"), String(body))
    }

    /// R1-16: opening a book starts its audio before chapters and labels
    /// are derived, and derives them off the main thread.
    func testOpeningABookStartsAudioFirst() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        let start = try XCTUnwrap(screen.range(of: "private func load() async"))
        let load = String(screen[start.lowerBound...])
        let order = ["content = loaded", "playback.load(document:", "UITestHooks.seekText",
                     "playback.startAutoplay()", "Task.detached(priority: .userInitiated)",
                     "navigation = derived.value", "store.noteOpened"]
        let offsets = try order.map { try XCTUnwrap(load.range(of: $0), $0).lowerBound }
        XCTAssertEqual(offsets, offsets.sorted(), "audio first, then navigation, then the store")
        XCTAssertTrue(load.contains("BudgetSignposts.live.begin(.readerOpen)"))
    }

    /// P050: the reader's type comes from the theme's tokens: no raw
    /// `.font(.title)` anywhere in the reader. The failure state offers a
    /// way back and keeps its icon out of VoiceOver's order.
    func testTheReaderUsesTheTypeTokens() throws {
        let s = try SourceTree.sources()
        for (path, text) in s where path.hasPrefix("Reader/") {
            for line in codeLines(text) {
                // A raw system style, not the theme's token (Theme.font(.title)).
                let raw = line.replacingOccurrences(of: "Theme.font(.title)", with: "")
                XCTAssertFalse(raw.contains(".font(.title)"), "\(path): \(line)")
            }
        }
        let screen = try XCTUnwrap(s["Reader/ReaderScreen.swift"])
        XCTAssertTrue(screen.contains("reader.backToLibrary"))
        XCTAssertTrue(screen.contains("router.popToRoot()"))
        XCTAssertTrue(screen.contains("ReaderFailureCopy.backToLibrary"))
    }

    /// iOS 26: a hard scroll edge on a pushed screen turns the bar's glass
    /// buttons light in dark mode.
    func testNoHardScrollEdges() throws {
        let app = try SourceTree.sources()
        for (path, text) in app {
            for line in codeLines(text) {
                XCTAssertFalse(line.contains("scrollEdgeEffectStyle(.hard"), "\(path): \(line)")
                XCTAssertFalse(line.contains("topEdgeEffect.style = .hard"), "\(path): \(line)")
            }
        }
    }

    /// R12e: no accessibility value carries a sentence index.
    func testNoAccessibilityValueMentionsASentence() throws {
        let app = try SourceTree.sources()
        for (path, text) in app {
            for line in lines(text) where line.contains(".accessibilityValue(") {
                XCTAssertFalse(line.lowercased().contains("sentence"), "\(path): \(line)")
            }
        }
    }

    /// A control whose glyph is capped below the accessibility sizes shows
    /// it large on a long press (the A- and A+ steppers in the Aa sheet).
    func testCappedControlsInTheAppearanceSheetOfferTheLargeContentViewer() throws {
        let path = "Reader/AppearanceSheet.swift"
        let code = codeLines(try XCTUnwrap(try SourceTree.sources(only: [path])[path]))
        let caps = code.indices.filter { code[$0].contains(".dynamicTypeSize(...") }
        XCTAssertFalse(caps.isEmpty)
        for cap in caps {
            let after = code[cap..<min(cap + 4, code.endIndex)]
            XCTAssertTrue(after.contains { $0.contains(".largeContentViewerIfAvailable") },
                          "\(path): \(code[cap].trimmingCharacters(in: .whitespaces)) has no Large Content Viewer")
        }
    }

    /// The navigation bar caps its text size, so every control the reader
    /// puts in it opts in to the Large Content Viewer, as its title does:
    /// the Aa button was left out (H053).
    func testTheReadersBarControlsOfferTheLargeContentViewer() throws {
        let path = "Reader/ReaderScreen.swift"
        let code = codeLines(try XCTUnwrap(try SourceTree.sources(only: [path])[path]))
        let items = code.indices.filter { code[$0].contains("ToolbarItem(placement:") }
        XCTAssertFalse(items.isEmpty, "the lint reads the reader's bar items")
        for item in items {
            let body = code[item..<min(item + 20, code.endIndex)]
            let end = body.firstIndex { $0.contains("ToolbarItem(") && $0 != code[item] } ?? body.endIndex
            XCTAssertTrue(body[..<end].contains { $0.contains(".accessibilityShowsLargeContentViewer") },
                          "\(path): \(code[item].trimmingCharacters(in: .whitespaces)) has no Large Content Viewer")
        }
    }

    /// The player bar's capped transport (Back 15, Forward 15 and Play)
    /// shows its glyph large on a long press too (F099). The scrub preview
    /// is a floating label, not a control, so it is left alone.
    func testCappedTransportControlsOfferTheLargeContentViewer() throws {
        let path = "Reader/PlayerBarView.swift"
        let code = codeLines(try XCTUnwrap(try SourceTree.sources(only: [path])[path]))
        var checked: Set<String> = []
        for cap in code.indices where code[cap].contains(".dynamicTypeSize(...") {
            let owner = code[...cap].last { $0.contains("func ") || $0.contains("var ") } ?? ""
            guard let name = ["skipButton", "playButton"].first(where: { owner.contains($0) }) else { continue }
            checked.insert(name)
            let after = code[cap..<min(cap + 4, code.endIndex)]
            XCTAssertTrue(after.contains { $0.contains(".largeContentViewerIfAvailable") },
                          "\(path): \(name)'s cap has no Large Content Viewer")
        }
        XCTAssertEqual(checked, ["skipButton", "playButton"], "the lint reads both capped controls")
    }

    /// The Aa sample previews the column, which ignores Dynamic Type: the
    /// reader serif is a fixed size, never one that scales with .body.
    func testTheReaderSerifIsAFixedSize() throws {
        let path = "Theme/AloudTheme.swift"
        let theme = try XCTUnwrap(try SourceTree.sources(only: [path])[path])
        let start = try XCTUnwrap(theme.range(of: "static func readerSerif("))
        let body = theme[start.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(body.contains("Font.custom(serifFamilyName, fixedSize: size)"), String(body))
    }

    /// J029: the Aa sheet's pinned title keeps the sheet gutter and wraps
    /// centered at the accessibility sizes, as the Voice & speed sheet's
    /// does: bare, it ran to the edges and wrapped "Text &" to the left.
    func testTheSheetTitlesWrapCenteredInsideTheGutters() throws {
        // Both sheets draw their title through the shared SheetHeader
        // (SettingsHomeLintTests checks they do), so the rule lives there.
        let path = "Theme/SheetGrabber.swift"
        let sources = try SourceTree.sources(only: [path])
        let chrome = try XCTUnwrap(sources[path])
        let start = try XCTUnwrap(chrome.range(of: "private var titleText: some View {"), path)
        let block = chrome[start.upperBound...].prefix(400)
        for needle in ["Text(title)", ".multilineTextAlignment(.center)",
                       ".fixedSize(horizontal: false, vertical: true)"] {
            XCTAssertTrue(block.contains(needle), "SheetHeader's title lacks \(needle)")
        }
        let header = try XCTUnwrap(chrome.range(of: "struct SheetHeader: View {"), path)
        let body = chrome[header.upperBound..<start.lowerBound]
        XCTAssertEqual(body.components(separatedBy: "titleText\n").count - 1, 2, "one title in each layout")
        XCTAssertTrue(body.contains(".padding(.horizontal, Theme.Space.sheetGutter)\n"),
                      "inside the gutters with the close on its own row")
        XCTAssertTrue(body.contains(".padding(.horizontal, Theme.Space.sheetGutter + Theme.SheetTarget.minimum)"),
                      "clear of the close beside it")
    }

    /// J027: under Bold Text the stepper's serif A glyphs set in the
    /// column's own bold face (`ReaderPageStyle.serif(size:bold:)`), not the
    /// regular one.
    func testTheStepperGlyphsFollowBoldText() throws {
        let path = "Reader/AppearanceSheet.swift"
        let s = try SourceTree.sources(only: [path])
        let sheet = try XCTUnwrap(s[path])
        let glyph = try XCTUnwrap(sheet.range(of: "Text(verbatim: \"A\")"))
        let following = sheet[glyph.upperBound...].prefix(300)
        XCTAssertTrue(following.contains("weight: legibilityWeight == .bold ? .bold : .regular"), String(following))
        XCTAssertTrue(sheet.contains("@Environment(\\.legibilityWeight) private var legibilityWeight"))
    }

    func testUITestsReadThePlayheadThroughTheHelpers() throws {
        let uiTests = try SourceTree.sources(in: SourceTree.uiTestsRoot)
        XCTAssertEqual(SourceTree.occurrences(of: "[\"reader.sentence\"]", in: uiTests), 0,
                       "the value probe is gone; use currentSentence(_:) or waitForSentence(_:in:timeout:)")
    }

    /// F040 and F041 on the Mac, as on the iPhone's sheet: a result's
    /// footnote is `searchLocation` (none in a chapterless book), and a
    /// landed search is announced against the count before it.
    func testTheMacContentsSearchNamesNoFakeChapterAndIsAnnounced() throws {
        let file = "Reader/MacContentsPanel.swift"
        let panel = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot, only: [file])[file])
        let code = codeLines(panel).joined(separator: "\n")
        XCTAssertTrue(code.contains("navigation.searchLocation(ofSentence: match.sentenceID"))
        XCTAssertFalse(code.contains("navigation.location(ofSentence: match.sentenceID"))
        XCTAssertTrue(code.contains("let location: String?"))
        XCTAssertTrue(code.contains("if let location {"))

        let captured = try XCTUnwrap(code.range(of: "let previousCount: Int? = searchedQuery == nil ? nil : results.count"),
                                     "the count before the search lands")
        let landed = try XCTUnwrap(code.range(of: "results = found"))
        let announced = try XCTUnwrap(code.range(of: "ContentsSearch.announceResults(count: found.count, query: trimmed,"))
        XCTAssertLessThan(captured.lowerBound, landed.lowerBound, "previousCount is taken before results change")
        XCTAssertLessThan(landed.lowerBound, announced.lowerBound)
        XCTAssertTrue(code.contains("previousCount: previousCount, muted: playback.isOutputMuted)"))
    }

    /// The Mac Contents panel says the row a remap left unheard, and focus
    /// coming back to the list says one it missed while away (I013). Focus
    /// can't be driven from a test, so this pins the source; the rule is in
    /// MacContentsPlacesTests. Here because Mac-hosted tests can't read the
    /// checkout.
    func testTheMacContentsPanelSaysTheRowARemapLeftUnheard() throws {
        let path = "Reader/MacContentsPanel.swift"
        let sources = try SourceTree.sources(in: SourceTree.macRoot, only: [path])
        let panel = try XCTUnwrap(sources[path])
        let onChange = try XCTUnwrap(panel.range(of: ".onChange(of: listLayout)"))
        let body = panel[onChange.upperBound...].prefix(600)
        XCTAssertTrue(body.contains("MacContents.remapIsUnheard("))
        XCTAssertTrue(body.contains("announceCursor(currentMode)"))
        XCTAssertTrue(panel.contains("} else if cursorUnheard {"))
    }

    /// A scan that lands while the Mac panel's list holds the keyboard
    /// moves its cursor onto what landed and says it, or hands the keyboard
    /// back to the field (L024). Focus can't be driven from a test, so this
    /// pins the landing; the rule is in MacContentsPanelTests. Here because
    /// Mac-hosted tests can't read the checkout.
    func testTheMacContentsSearchMovesAListCursorOntoWhatLanded() throws {
        let path = "Reader/MacContentsPanel.swift"
        let sources = try SourceTree.sources(in: SourceTree.macRoot, only: [path])
        let panel = codeLines(try XCTUnwrap(sources[path])).joined(separator: "\n")
        let landed = try XCTUnwrap(panel.range(of: "results = found"))
        let after = panel[landed.upperBound...].prefix(1_200)
        XCTAssertTrue(after.contains("MacContents.cursorAfterScan(listFocused: isListFocused, found: found.count)"))
        XCTAssertTrue(after.contains("announceCursor(.results)"))
        XCTAssertTrue(after.contains("focusField()"))
    }

    /// "Where you stopped" rows are keyed by their place, never their
    /// position, on both apps: a stop recorded while Contents is open
    /// slides the rows down with their own elements, so VoiceOver stays on
    /// the place it read and a double-tap plays that one (L026). Here
    /// because Mac-hosted tests can't read the checkout.
    func testPlaceRowsAreKeyedByTheirPlaceOnBothApps() throws {
        let sheetPath = "Reader/ContentsSheet.swift"
        let sheets = try SourceTree.sources(only: [sheetPath])
        let sheet = codeLines(try XCTUnwrap(sheets[sheetPath])).joined(separator: "\n")
        XCTAssertTrue(sheet.contains("ForEach(Array(rows.prefix(visible)), id: \\.sentence)"))
        XCTAssertFalse(sheet.contains("ForEach(Array(rows.prefix(visible))) {"), "never keyed by position")

        let panelPath = "Reader/MacContentsPanel.swift"
        let panels = try SourceTree.sources(in: SourceTree.macRoot, only: [panelPath])
        let panel = codeLines(try XCTUnwrap(panels[panelPath])).joined(separator: "\n")
        XCTAssertTrue(panel.contains("ForEach(Array(rows.prefix(list.placeCount)), id: \\.sentence)"))
        XCTAssertTrue(panel.contains(".id(MacContents.PlaceKey(sentence: row.sentence))"))
        XCTAssertFalse(panel.contains(".id(row.index)"), "no place row takes its position as its identity")
        XCTAssertTrue(panel.contains("proxy.scrollTo(MacContents.PlaceKey(sentence: rows[index].sentence))"),
                      "the keyboard's cursor still scrolls to a place")
    }

    /// The page's own Look Up event reaches the coordinator, which drops
    /// the click's play (J022). Only AppKit's Look Up counts, never a Force
    /// Click's pressure alone: with Look Up set to a three-finger tap (or
    /// off), a deep click shows no definition, so it must still play
    /// (K025). The event can't be built in a test, so this pins the
    /// override; the rule is in ReaderColumnViewTests. Here because
    /// Mac-hosted tests can't read the checkout.
    func testTheMacPageHearsLookUpNeverPressureAlone() throws {
        let path = "Reader/ReaderNSTextView.swift"
        let pages = try SourceTree.sources(in: SourceTree.macRoot, only: [path])
        let page = try XCTUnwrap(pages[path])
        let code = codeLines(page).joined(separator: "\n")
        XCTAssertNil(code.range(of: "func pressureChange("), "a deep click is not a Look Up")
        XCTAssertNil(code.range(of: "event.stage"), "no pressure stage stands in for Look Up")
        let quickLook = try XCTUnwrap(code.range(of: "override func quickLook(with event: NSEvent) {"))
        XCTAssertTrue(code[quickLook.upperBound...].prefix(120).contains("onLookUpGesture?()"))
        let column = "Reader/ReaderColumnView.swift"
        let columns = try SourceTree.sources(in: SourceTree.macRoot, only: [column])
        let coordinator = try XCTUnwrap(columns[column])
        XCTAssertTrue(coordinator.contains("textView.onLookUpGesture = { [weak self] in self?.lookUpGestureArrived() }"))
    }

    /// Aloud coming to the front speaks a stop it held while behind another
    /// app (J026): the app delegate's activation, since a Mac window on
    /// screen never changes scene phase. The rule is in MacPlatformTests.
    func testTheMacAppSpeaksAHeldStopWhenItComesForward() throws {
        let path = "App/MacAppDelegate.swift"
        let delegate = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot, only: [path])[path])
        let code = codeLines(delegate).joined(separator: "\n")
        let hook = try XCTUnwrap(code.range(of: "func applicationDidBecomeActive(_ notification: Notification) {"))
        XCTAssertTrue(code[hook.upperBound...].prefix(120).contains("Self.announceHeldStop(of: AppModel.shared.playback)"))
    }

    /// The Mac's A− and A+ draw their own glyph style, whose limit reads as
    /// one (J028); the transport's style rests a tint step from disabled.
    /// The contrast is measured in MacThemeTests.
    func testTheMacTextSizeStepperUsesItsOwnGlyphStyle() throws {
        let path = "Reader/MacTextAppearanceView.swift"
        let view = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot, only: [path])[path])
        let code = codeLines(view).joined(separator: "\n")
        XCTAssertTrue(code.contains(".buttonStyle(MacTextStepButtonStyle())"))
        XCTAssertFalse(code.contains(".buttonStyle(MacGlyphButtonStyle())"))
    }

    // MARK: - Critique round 3

    /// R3-13 on the Mac: the panel's place snippets and results are set in
    /// the reading serif (`Theme.excerpt(scale:)`), as on the iPhone. The
    /// current place keeps its snippet as set and marks its detail line
    /// semibold; a hit is tinted `accentStrong`, never semibold. The fonts
    /// are measured in MacContentsPanelTests. Here because Mac-hosted tests
    /// can't read the checkout.
    func testTheMacContentsQuotesTheBookInTheReadingSerif() throws {
        let placesPath = "Reader/MacContentsPlaces.swift"
        let panelPath = "Reader/MacContentsPanel.swift"
        let s = try SourceTree.sources(in: SourceTree.macRoot, only: [placesPath, panelPath])
        let places = codeLines(try XCTUnwrap(s[placesPath])).joined(separator: "\n")
        let panel = codeLines(try XCTUnwrap(s[panelPath])).joined(separator: "\n")

        let place = try XCTUnwrap(places.range(of: "struct MacContentsPlaceLabel: View {"))
        let placeBody = places[place.upperBound...].prefix(900)
        XCTAssertTrue(placeBody.contains(".font(Theme.font(row.isCurrent ? .subhead : .footnote, scale: scale))"),
                      String(placeBody))
        XCTAssertTrue(placeBody.contains(".font(Theme.excerpt(scale: scale))"), String(placeBody))
        XCTAssertFalse(placeBody.contains(".semibold"), "the snippet keeps one weight: \(String(placeBody))")

        let result = try XCTUnwrap(panel.range(of: "struct MacContentsResultLabel: View {"))
        // The whole struct, to its closing brace at column 0.
        let resultEnd = try XCTUnwrap(panel.range(of: "\n}", range: result.upperBound..<panel.endIndex))
        let resultBody = panel[result.upperBound..<resultEnd.lowerBound]
        XCTAssertTrue(resultBody.contains(".font(Theme.excerpt(scale: scale))"), String(resultBody))
        XCTAssertTrue(resultBody.contains("Text(snippet.hit).foregroundColor(Theme.accentStrong)"), String(resultBody))
        // With no weight change the tint was the hit's only cue: under
        // Differentiate Without Color it is underlined too, as on the
        // iPhone (P032).
        XCTAssertTrue(resultBody.contains("accessibilityDifferentiateWithoutColor"), String(resultBody))
        XCTAssertTrue(resultBody.contains("Self.emphasized(snippet, underlined: differentiateWithoutColor)"),
                      String(resultBody))
        XCTAssertTrue(resultBody.contains(".underline(underlined, color: Theme.accentStrong)"), String(resultBody))
        XCTAssertFalse(resultBody.contains(".semibold"), "the hit is tinted, not bolded: \(String(resultBody))")
        XCTAssertFalse(resultBody.contains("Theme.font(.body"), "no sans quote: \(String(resultBody))")
    }

    /// R3-15: the Play circle, its busy ring and the Continue card's echo
    /// of it fill with `accentFill`, which Increase Contrast deepens; the
    /// pressed circle keeps `accentStrong`. The contrast is measured in
    /// ThemeTokenContrastTests.
    func testThePlayCirclesFillWithAccentFill() throws {
        let theme = "Theme/AloudTheme.swift"
        let face = "Reader/PlayCircleFace.swift"
        let card = "Library/ContinueListeningCard.swift"
        let s = try SourceTree.sources(only: [theme, face, card])
        let themeCode = codeLines(try XCTUnwrap(s[theme])).joined(separator: "\n")
        let faceCode = codeLines(try XCTUnwrap(s[face])).joined(separator: "\n")
        let cardCode = codeLines(try XCTUnwrap(s[card])).joined(separator: "\n")
        XCTAssertTrue(themeCode.contains("Circle().fill(isPressed ? Theme.accentStrong : Theme.accentFill)"))
        let ring = try XCTUnwrap(faceCode.range(of: "private struct BusyRing: View {"))
        let ringBody = faceCode[ring.upperBound...].prefix(1_500)
        XCTAssertEqual(ringBody.components(separatedBy: ".stroke(Theme.accentFill").count - 1, 2,
                       "both rings match their circle: \(String(ringBody))")
        XCTAssertFalse(ringBody.contains(".stroke(Theme.accent,"), String(ringBody))
        let glyph = try XCTUnwrap(cardCode.range(of: "struct PlayCircleGlyph: View {"))
        XCTAssertTrue(cardCode[glyph.upperBound...].prefix(200).contains(".fill(Theme.accentFill)"))
    }

    // MARK: - Round 4 chrome

    /// The Aa button's `ToolbarItem` body in ReaderScreen.
    private func appearanceItem(in screen: String) throws -> String {
        let start = try XCTUnwrap(screen.range(of: "ToolbarItem(placement: .topBarTrailing) {"), "Aa's bar item")
        return String(screen[start.upperBound...].prefix(1500))
    }

    /// R4-07: Aa lets the bar size its platter (44 pt from iOS 26, as the
    /// back circle), through BarItemTarget, and keeps no 44 pt frame of its
    /// own; it stays a bare Text. BarItemTarget keeps the frame before
    /// iOS 26, where nothing else gives the glyph a 44 pt target, and is
    /// nothing on the Mac.
    func testAaLetsTheBarSizeItsPlatter() throws {
        let files = ["Reader/ReaderScreen.swift", "Platform/BarItemTarget.swift"]
        let s = try SourceTree.sources(only: files)
        let screen = try XCTUnwrap(s[files[0]])
        let item = try appearanceItem(in: screen)
        let label = try XCTUnwrap(item.range(of: "Text(\"Aa\")"), item)
        let face = String(item[label.lowerBound...].prefix(400))
        XCTAssertTrue(face.contains(".modifier(BarItemTarget())"), face)
        XCTAssertFalse(face.contains("minWidth: 44"), face)
        XCTAssertFalse(face.contains(".contentShape(Rectangle())"), face)
        let target = try XCTUnwrap(s[files[1]])
        let code = codeLines(target).joined(separator: "\n")
        let ios = try XCTUnwrap(code.range(of: "#if os(iOS)"), code)
        let available = try XCTUnwrap(code.range(of: "if #available(iOS 26, *) {"), code)
        let frame = try XCTUnwrap(code.range(of: ".frame(minWidth: 44, minHeight: 44)"), code)
        let otherwise = try XCTUnwrap(code.range(of: "#else"), code)
        XCTAssertLessThan(ios.lowerBound, available.lowerBound, code)
        XCTAssertLessThan(available.lowerBound, frame.lowerBound, "the frame is the pre-26 branch: \(code)")
        XCTAssertLessThan(frame.lowerBound, otherwise.lowerBound, "the Mac draws no frame: \(code)")
        XCTAssertTrue(code.contains(".contentShape(Rectangle())"), code)
    }

    /// R4-08: Aa toggles its non-modal sheet and reads as selected while it
    /// is up; leaving the reader (Back, the edge swipe) closes it. The
    /// system back button stays the system's.
    func testAaTogglesItsSheetAndTheSheetLeavesWithTheReader() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        let item = try appearanceItem(in: screen)
        // The press haptic first, then the toggle (TransportHaptics).
        XCTAssertTrue(item.contains("Button {\n                    TransportHaptics.emit(.press)\n"
                                    + "                    showAppearanceSheet.toggle()\n                } label: {"), item)
        XCTAssertFalse(item.contains("showAppearanceSheet = true"), item)
        XCTAssertTrue(item.contains(".accessibilityAddTraits(showAppearanceSheet ? .isSelected : [])"), item)
        let disappear = try XCTUnwrap(MacKeyCommandLintTests.body(of: ".onDisappear {", in: screen), "the reader's onDisappear")
        XCTAssertTrue(disappear.contains("BudgetSignposts.live.end(&openSignpost, gaveUp: true)"), disappear)
        XCTAssertTrue(disappear.contains("showAppearanceSheet = false"), disappear)
        XCTAssertFalse(screen.contains("navigationBarBackButtonHidden"), "no custom Back")
    }

    /// R4-06: the way back to the colophon is Follow aimed at it, on both
    /// apps: the iPhone bumps the follow request, the Mac calls its follow
    /// action and tooltips the chip's hint.
    func testBackToTheEndRoutesLikeFollow() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        let handle = try XCTUnwrap(MacKeyCommandLintTests.body(of: "private func handle(_ chip: ReaderChip) {", in: screen))
        XCTAssertTrue(handle.contains("case .followVoice, .theEnd:\n            TransportHaptics.emit(.press)\n"
                                      + "            followChipTaps &+= 1"), handle)
        let macPath = "Reader/MacChipSlot.swift"
        let mac = try SourceTree.sources(in: SourceTree.macRoot, only: [macPath])
        let slot = try XCTUnwrap(mac[macPath])
        XCTAssertTrue(slot.contains("case .followVoice, .theEnd: onFollowVoice()"), slot)
        XCTAssertTrue(slot.contains("case .moreClassics, .theEnd: return chip.hint"), slot)
    }
}
