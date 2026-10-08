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

    /// P046: the reader's principal item names the author under the title,
    /// one header for VoiceOver.
    func testTheTitleBarNamesTheAuthor() throws {
        let path = "Reader/ReaderScreen.swift"
        let s = try SourceTree.sources(only: [path])
        let screen = try XCTUnwrap(s[path])
        XCTAssertTrue(screen.contains("ReaderTitleCopy.label(title: liveDocument.title, author:"),
                      "the title bar's header names the author")
        XCTAssertTrue(screen.contains("Text(author)"), "the author's line under the title")
        XCTAssertTrue(screen.contains("isAccessibilitySize"), "the title alone at the accessibility sizes")
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
        let paths = ["Reader/AppearanceSheet.swift": "Text(AppearanceCopy.title)",
                     "Settings/ListeningSheet.swift": "Text(ListeningCopy.title)"]
        let sources = try SourceTree.sources(only: Array(paths.keys))
        for (path, title) in paths {
            let text = try XCTUnwrap(sources[path])
            let start = try XCTUnwrap(text.range(of: title), path)
            let modifiers = text[start.upperBound...].prefix(400)
            let header = try XCTUnwrap(modifiers.range(of: ".accessibilityAddTraits(.isHeader)"), path)
            let block = modifiers[..<header.lowerBound]
            for needle in [".multilineTextAlignment(.center)", ".fixedSize(horizontal: false, vertical: true)",
                           ".padding(.horizontal, Theme.Space.sheetGutter)"] {
                XCTAssertTrue(block.contains(needle), "\(path): the title lacks \(needle)")
            }
        }
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
}
