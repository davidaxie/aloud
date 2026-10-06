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

    /// The Aa sample previews the column, which ignores Dynamic Type: the
    /// reader serif is a fixed size, never one that scales with .body.
    func testTheReaderSerifIsAFixedSize() throws {
        let path = "Theme/AloudTheme.swift"
        let theme = try XCTUnwrap(try SourceTree.sources(only: [path])[path])
        let start = try XCTUnwrap(theme.range(of: "static func readerSerif("))
        let body = theme[start.upperBound...].prefix { $0 != "}" }
        XCTAssertTrue(body.contains("Font.custom(serifFamilyName, fixedSize: size)"), String(body))
    }

    func testUITestsReadThePlayheadThroughTheHelpers() throws {
        let uiTests = try SourceTree.sources(in: SourceTree.uiTestsRoot)
        XCTAssertEqual(SourceTree.occurrences(of: "[\"reader.sentence\"]", in: uiTests), 0,
                       "the value probe is gone; use currentSentence(_:) or waitForSentence(_:in:timeout:)")
    }
}
