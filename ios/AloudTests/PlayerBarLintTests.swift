import XCTest

/// Source lints for the player bar, its chapter line and Contents (R11,
/// R15, R17, R20). Reads the checkout through SourceTree; skips when the
/// test host can't see it.
final class PlayerBarLintTests: XCTestCase {

    /// The busy state is PlayCircleFace's ring (R20), and the scrub preview
    /// never names a sentence number (R17); the scrub is a jump, never a raw
    /// seek, and never a tap-to-teleport (R15, R17).
    func testPlayerBarHasNoSpinnerSentenceNumbersOrRawSeeks() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        for needle in ["ProgressView", "Sentence \\(", "seek(to:", "minimumDistance: 0"] {
            XCTAssertFalse(bar.contains(needle), "PlayerBarView.swift should not contain '\(needle)'")
        }
    }

    /// Both sleep chips speak the time left in words through the one shared
    /// label (`SleepTimer.chipSpokenLabel`, pinned by SleepTimerTests), never
    /// the m:ss countdown VoiceOver reads as numbers. The Mac's sleep menu
    /// still read "28:14, sleep timer" (H051).
    func testBothSleepChipsSpeakTheSharedLabel() throws {
        let chip = try XCTUnwrap(try SourceTree.sources(only: ["Reader/SleepChip.swift"])["Reader/SleepChip.swift"])
        let menu = try XCTUnwrap(try SourceTree.sources(in: SourceTree.macRoot,
                                                        only: ["Reader/MacSleepMenu.swift"])["Reader/MacSleepMenu.swift"])
        for (name, text) in [("SleepChip.swift", chip), ("MacSleepMenu.swift", menu)] {
            XCTAssertTrue(text.contains(".accessibilityLabel(sleepTimer.chipSpokenLabel)"),
                          "\(name) should label the chip with chipSpokenLabel")
            XCTAssertFalse(text.contains("\\(sleepTimer.chipText), sleep timer"),
                           "\(name) should not speak the countdown")
        }
    }

    /// SwiftUI resets @GestureState before onEnded runs, so a scrub release
    /// that reads `drag` there always falls back to the playhead's chapter:
    /// when the voice crossed a chapter mid-drag, the jump missed the
    /// previewed spot (R17). The release reads the span the drag's frames
    /// froze in the ScrubReleaseSpan latch instead. A gesture can't be
    /// driven from a test, so this pins the source; ScrubReleaseSpan's rules
    /// are in ReaderScrubTests.
    func testScrubReleaseNeverReadsTheResetGestureState() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        let onEnded = try XCTUnwrap(Self.closure(after: ".onEnded", in: bar), "the scrub's onEnded is gone")
        let code = Self.code(onEnded)
        let reads = try NSRegularExpression(pattern: "\\$?\\bdrag\\b")
        XCTAssertNil(reads.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                     "onEnded reads the @GestureState drag, which SwiftUI has already reset:\n\(code)")
        XCTAssertTrue(code.contains("releaseSpan"), "the release should seek in the span its drag froze")
    }

    /// The latch copies the preview's gesture state in the same `.updating`
    /// call that sets it. That state restarts at nil on every drag, so one
    /// the system cancelled (an alert, Siri, a call: no onEnded) can't lend
    /// its span to the next. Keyed by the drag's start x instead, a later
    /// drag from the same point reused the stale chapter (R17).
    func testScrubReleaseFollowsThePreviewsGestureState() throws {
        let sources = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(sources["Reader/PlayerBarView.swift"])
        let updating = try XCTUnwrap(Self.closure(after: ".updating($drag)", in: bar), "the scrub's updating is gone")
        XCTAssertTrue(Self.code(updating).contains("releaseSpan.track(state)"),
                      "each drag frame should hand its gesture state to the release:\n\(updating)")
        XCTAssertFalse(Self.code(bar).contains("startLocation"),
                       "the scrub should never tell drags apart by where they started")
    }

    /// The retry line's tap is Play, never the toggle (R11): a voice sample
    /// picked after the failure is active, so the toggle paused it and
    /// retried nothing. On the iPhone it ticks as a play (R20). Both bars.
    func testRetryLineAlwaysPlays() throws {
        let bar = try XCTUnwrap(SourceTree.sources(only: ["Reader/PlayerBarView.swift"])["Reader/PlayerBarView.swift"])
        let macSources = try SourceTree.sources(in: SourceTree.macRoot, only: ["Reader/MacPlayerBar.swift"])
        let mac = try XCTUnwrap(macSources["Reader/MacPlayerBar.swift"])
        for (name, source) in [("PlayerBarView", bar), ("MacPlayerBar", mac)] {
            XCTAssertTrue(Self.code(source).contains("onRetry: retry,"), "\(name)'s retry line should play, never toggle")
            let body = try XCTUnwrap(Self.closure(after: "func retry()", in: source), "\(name) has no retry()")
            let retry = Self.code(body)
            XCTAssertTrue(retry.contains("playback.play()"), "\(name)'s retry should play:\n\(retry)")
            XCTAssertFalse(retry.contains("togglePlayPause"), "\(name)'s retry should never toggle:\n\(retry)")
        }
        let retry = try XCTUnwrap(Self.closure(after: "func retry()", in: bar))
        XCTAssertTrue(Self.code(retry).contains("TransportHaptics.emit(.play)"))
    }

    /// A finished book's track is full (ReaderNavigation.scrubFill), the
    /// fill and the slider value both, never stopped at where the last
    /// sentence starts.
    func testAFinishedBookFillsTheScrub() throws {
        let bar = try XCTUnwrap(SourceTree.sources(only: ["Reader/PlayerBarView.swift"])["Reader/PlayerBarView.swift"])
        let code = Self.code(bar)
        XCTAssertEqual(code.components(separatedBy: "scrubFill(of:").count - 1, 2, "fill and slider value")
        XCTAssertFalse(code.contains("scrubFraction(of: drag?.target ?? playhead"))
        XCTAssertFalse(code.contains("scrubFraction(of: playhead"))
        // The Mac scrub's twin: the fill and the model's fraction.
        let macSources = try SourceTree.sources(in: SourceTree.macRoot, only: ["Reader/MacScrub.swift"])
        let mac = Self.code(try XCTUnwrap(macSources["Reader/MacScrub.swift"]))
        XCTAssertEqual(mac.components(separatedBy: "scrubFill(of:").count - 1, 2, "Mac fill and model fraction")
        XCTAssertTrue(mac.contains("isFinished: press == nil && playback.isAtEnd"), "a press shows its target")
        XCTAssertFalse(mac.contains("scrubFraction(of: shown"))
        XCTAssertFalse(mac.contains("scrubFraction(of: playhead"))
    }

    /// P004: the bar's chips and the chip above it press like controls
    /// (surface2 and a settle, ReaderChipButtonStyle), never the plain
    /// style's opacity flicker.
    func testChipsPressLikeControls() throws {
        let s = try SourceTree.sources(only: ["Reader/PlayerBarView.swift", "Reader/SleepChip.swift",
                                              "Reader/ReaderChip.swift"])
        let bar = try XCTUnwrap(s["Reader/PlayerBarView.swift"])
        let listening = Self.code(try XCTUnwrap(Self.closure(after: "private var listeningChip", in: bar)))
        XCTAssertFalse(listening.contains(".buttonStyle(.plain)"), "player.listening dims instead of pressing")
        XCTAssertTrue(listening.contains(".buttonStyle(ReaderChipButtonStyle("), listening)

        let sleep = try XCTUnwrap(s["Reader/SleepChip.swift"])
        let extend = Self.code(try XCTUnwrap(Self.closure(after: "private var extendButton", in: sleep)))
        XCTAssertFalse(extend.contains(".buttonStyle(.plain)"), "+15 min dims instead of pressing")
        XCTAssertTrue(extend.contains(".buttonStyle(ReaderChipButtonStyle(isOn: true))"), extend)
        XCTAssertTrue(Self.code(sleep).contains(".buttonStyle(ReaderChipPressStyle())"), "the sleep menu's press")

        let chip = Self.code(try XCTUnwrap(s["Reader/ReaderChip.swift"]))
        XCTAssertFalse(chip.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(chip.contains(".buttonStyle(ReaderChipButtonStyle("), "ReaderChipView presses like the bar's chips")
    }

    /// P005: a chip that can't fit says less, never in smaller type.
    func testChipLabelsNeverShrinkTheirType() throws {
        let paths = ["Reader/ReaderChipStyle.swift", "Reader/PlayerBarView.swift", "Reader/SleepChip.swift",
                     "Reader/ReaderChip.swift"]
        let s = try SourceTree.sources(only: paths)
        for path in paths {
            let text = Self.code(try XCTUnwrap(s[path], path))
            XCTAssertFalse(text.contains("minimumScaleFactor"), "\(path) shrinks a chip's type")
        }
        let bar = Self.code(try XCTUnwrap(s["Reader/PlayerBarView.swift"]))
        XCTAssertTrue(bar.contains("ListeningFormat.chipShortTitle(rate:"), "the voice chip's short form")
        XCTAssertTrue(bar.contains("ViewThatFits(in: .horizontal)"))
        let sleep = Self.code(try XCTUnwrap(s["Reader/SleepChip.swift"]))
        XCTAssertTrue(sleep.contains("ViewThatFits(in: .horizontal)") && sleep.contains("\"moon.fill\""),
                      "Chapter end and Book end fall back to the filled moon")
    }

    /// P001-P003, P006: Play's place and size come from PlayerBarLayout,
    /// the five controls carry its VoiceOver order, the chips stop at its
    /// type cap with the Large Content Viewer, and the skips are the quiet
    /// glyph style in their named font.
    func testTheTransportFollowsPlayerBarLayout() throws {
        let s = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = Self.code(try XCTUnwrap(s["Reader/PlayerBarView.swift"]))
        XCTAssertFalse(bar.contains("Spacer(minLength: Theme.Space.xs)"), "Spacers shift Play off center")
        XCTAssertTrue(bar.contains("layout.stacksTransport"))
        XCTAssertFalse(bar.contains("private var stacksTransport"), "the stacking rule lives in PlayerBarLayout")
        for control in ["listening", "back15", "play", "forward15", "sleep"] {
            XCTAssertTrue(bar.contains(".accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .\(control)))"),
                          "\(control) has no VoiceOver order")
        }
        XCTAssertTrue(bar.contains(".accessibilityElement(children: .contain)"), "the order stays inside the transport")
        XCTAssertTrue(bar.contains("HStack(spacing: layout.clusterGap)"), "breathing room beside Play")
        XCTAssertTrue(bar.contains(".buttonStyle(ReaderGlyphButtonStyle())"))
        XCTAssertTrue(bar.contains(".font(Self.skipGlyphFont)"))
        XCTAssertFalse(bar.contains(".font(.title2"), "a raw skip glyph font")
        XCTAssertTrue(bar.contains("AccentCircleButtonStyle(diameter: diameter)"))
        XCTAssertTrue(bar.contains("PlayCircleFace(state: state, diameter: diameter)"), "the ring follows the circle")
        XCTAssertEqual(bar.components(separatedBy: ".dynamicTypeSize(...PlayerBarLayout.chipTypeCap)").count - 1, 3,
                       "the voice chip, the sleep chip and the chapter line stop at the cap")
        let listening = Self.code(try XCTUnwrap(Self.closure(after: "private var listeningChip", in: bar)))
        XCTAssertTrue(listening.contains(".largeContentViewerIfAvailable"))
    }

    /// P006: the chapter line stops at the chips' cap inside the bar's
    /// height budget, so every button in that slot, the natural-voice offer
    /// row's included, shows its text large on a long press. Without it the
    /// line was unreadable at AX3 to AX5 and had no way to enlarge.
    func testTheCappedChapterLineOffersTheLargeContentViewer() throws {
        let paths = ["Reader/PlayerBarView.swift", "Reader/ReaderMessageLine.swift", "TTS/NaturalVoiceOfferRow.swift"]
        let s = try SourceTree.sources(only: paths)
        let bar = Self.code(try XCTUnwrap(s["Reader/PlayerBarView.swift"]))
        let lineCall = try XCTUnwrap(bar.components(separatedBy: "ReaderMessageLine(message:").dropFirst().first,
                                     "the bar draws the chapter line")
        // The line's own modifiers: everything before the next row.
        let lineModifiers = lineCall.components(separatedBy: "scrubTrack")[0]
        guard lineModifiers.contains(".dynamicTypeSize(...PlayerBarLayout.chipTypeCap)") else { return }

        let line = Self.code(try XCTUnwrap(s["Reader/ReaderMessageLine.swift"]))
        for button in ["private var positionLine", "private var retryLine", "private func stopReasonButton",
                       "private var backFiveMinutesButton", "private func statusLine"] {
            let body = try XCTUnwrap(Self.closure(after: button, in: line), "\(button) is gone")
            XCTAssertTrue(body.contains(".largeContentViewerIfAvailable"),
                          "\(button) is capped with no Large Content Viewer")
        }
        let buttonPattern = try NSRegularExpression(pattern: #"\bButton\s*[({]"#)
        // A named VoiceOver action (Undo jump) is written as a Button but
        // never drawn, so it needs no Large Content Viewer.
        let actions = Self.closure(after: ".accessibilityActions", in: line) ?? ""
        let buttons = buttonPattern.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
            - buttonPattern.numberOfMatches(in: actions, range: NSRange(actions.startIndex..., in: actions))
        XCTAssertEqual(buttons, 5, "the lint reads every button in the chapter line")
        XCTAssertEqual(line.components(separatedBy: ".largeContentViewerIfAvailable").count - 1, buttons,
                       "every button in the chapter line offers the Large Content Viewer")

        let offer = Self.code(try XCTUnwrap(s["TTS/NaturalVoiceOfferRow.swift"]))
        let offerText = try XCTUnwrap(Self.closure(after: "private func offerText", in: offer))
        XCTAssertTrue(offerText.contains(".largeContentViewerIfAvailable"), "the offer's line")
        let offerButtons = try XCTUnwrap(Self.closure(after: "private var buttons", in: offer))
        XCTAssertEqual(offerButtons.components(separatedBy: ".largeContentViewerIfAvailable").count - 1, 2,
                       "Download and Not now")
    }

    /// P008: the scrub's touch-down feedback is gesture state alone. It never
    /// seeks, ticks or ends; only the 8pt drag's release jumps (R17).
    func testScrubTouchFeedbackNeverSeeks() throws {
        let s = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let bar = try XCTUnwrap(s["Reader/PlayerBarView.swift"])
        let touch = Self.code(try XCTUnwrap(Self.closure(after: "private var touchDownGesture", in: bar),
                                            "the scrub's touch feedback is gone"))
        XCTAssertTrue(touch.contains("DragGesture(minimumDistance: ScrubGesture.touchDownDistance)"), touch)
        XCTAssertTrue(touch.contains(".updating($isTouchingScrub)"), touch)
        for needle in ["onEnded", "jump(", "seek", "TransportHaptics", "releaseSpan"] {
            XCTAssertFalse(touch.contains(needle), "the touch feedback should never \(needle):\n\(touch)")
        }
        let code = Self.code(bar)
        XCTAssertEqual(code.components(separatedBy: ".onEnded").count - 1, 1, "only the seek drag ends in a jump")
        XCTAssertTrue(code.contains("DragGesture(minimumDistance: ScrubGesture.minimumDistance)"))
        XCTAssertTrue(code.contains(".simultaneousGesture(touchDownGesture)"))
        XCTAssertTrue(code.contains("@GestureState private var isTouchingScrub"), "a system cancel must clear it")
    }

    /// Round 1 (R1-42, R1-44, R1-45, R1-48) in both bars: Forward 15 alone
    /// dims where it can't move; the scrub's base capsule takes the scrub
    /// track and its Increase Contrast edge under the fill; the iPhone sets
    /// the line's ink on its row's foot and the track high in its row, and
    /// hands the line Undo jump while it is offered; the Mac keeps the line
    /// centred with no Undo action (⌘Z covers it).
    func testBothBarsDimForwardEdgeTheTrackAndPlaceTheLine() throws {
        let s = try SourceTree.sources(only: ["Reader/PlayerBarView.swift"])
        let macSources = try SourceTree.sources(in: SourceTree.macRoot,
                                                only: ["Reader/MacPlayerBar.swift", "Reader/MacScrub.swift"])
        let bar = Self.code(try XCTUnwrap(s["Reader/PlayerBarView.swift"]))
        let macBar = Self.code(try XCTUnwrap(macSources["Reader/MacPlayerBar.swift"]))
        let macScrub = Self.code(try XCTUnwrap(macSources["Reader/MacScrub.swift"]))
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        for (name, source) in [("PlayerBarView", bar), ("MacPlayerBar", macBar)] {
            XCTAssertEqual(source.components(separatedBy: ".disabled(!playback.canSkipForward)").count - 1, 1,
                           "\(name): Forward 15 alone dims")
            let forward = try XCTUnwrap(source.range(of: "\"player.forward15\""), name)
            let dimmed = try XCTUnwrap(source.range(of: ".disabled(!playback.canSkipForward)"), name)
            XCTAssertLessThan(forward.lowerBound, dimmed.lowerBound, "\(name): on the forward skip")
            XCTAssertLessThan(source.distance(from: forward.upperBound, to: dimmed.lowerBound), 400,
                              "\(name): right after the forward skip")
        }
        let base = "Capsule() .fill(Theme.scrubTrack) .overlay(Capsule().strokeBorder(Theme.trackEdge, lineWidth: 1))"
        for (name, source) in [("PlayerBarView", bar), ("MacScrub", macScrub)] {
            XCTAssertTrue(compact(source).contains(base), "\(name): the base capsule alone is edged")
            XCTAssertFalse(source.contains("Capsule().fill(Theme.track)"), "\(name): the scrub has its own track")
        }

        let line = compact(try XCTUnwrap(bar.components(separatedBy: "ReaderMessageLine(message:").dropFirst().first))
        XCTAssertTrue(line.contains("rowAlignment: .bottom"), "the iPhone line sits by its scrub")
        XCTAssertTrue(line.contains("onUndoJump: playback.undoableJump != nil ? undoJump : nil"),
                      "Undo jump only while it is offered")
        // Seated by its centre, never its top edge: a press thickens the
        // line evenly and its thumb holds still under the finger.
        XCTAssertTrue(compact(bar).contains(
            ".animation(.easeOut(duration: Theme.Motion.press), value: isTouchingScrub) .modifier(ScrubLineSeat())"),
                      "the line and its thumb sit in the seat, high in their unchanged row")
        let seat = compact(try XCTUnwrap(Self.closure(after: "struct ScrubLineSeat: ViewModifier", in: bar)))
        XCTAssertTrue(seat.contains(".frame(height: ScrubThumb.pressedTrackHeight) "
                                    + ".padding(.top, PlayerBarView.trackCentre - ScrubThumb.pressedTrackHeight / 2) "
                                    + ".frame(maxHeight: .infinity, alignment: .top)"),
                      "a box as tall as the held line, centred trackCentre down the row")
        XCTAssertFalse(bar.contains(".padding(.top, Self.trackInset)"), "never pinned by its top edge")
        XCTAssertFalse(bar.contains(".frame(maxHeight: .infinity, alignment: .center)"))
        let representation = compact(try XCTUnwrap(Self.closure(after: ".accessibilityRepresentation", in: bar)))
        XCTAssertTrue(representation.contains(".accessibilityActions { if playback.undoableJump != nil {"),
                      "Position carries Undo jump while it is offered")
        let macLine = compact(try XCTUnwrap(macBar.components(separatedBy: "ReaderMessageLine(message:")
            .dropFirst().first))
        XCTAssertTrue(macLine.contains("rowAlignment: .center"), "the Mac line stays centred")
        XCTAssertTrue(macLine.contains("onUndoJump: nil"), "the Mac's Undo jump is ⌘Z")
    }

    /// R1-44: the natural-voice offer takes the chapter line's slot, so it
    /// sets its ink where the line it replaces does. The line hands the
    /// offer its `rowAlignment`, and the copy and both buttons sit on it with
    /// the line's foot lift, so a crossfade never moves the ink: centred on
    /// the iPhone's `.bottom` row, the offer sat ~9pt above the position
    /// line. Unless told, the offer stays centred, as the Mac's line is.
    func testTheOfferSetsItsInkWhereTheLineItReplacesDoes() throws {
        let s = try SourceTree.sources(only: ["Reader/ReaderMessageLine.swift", "TTS/NaturalVoiceOfferRow.swift"])
        let line = Self.code(try XCTUnwrap(s["Reader/ReaderMessageLine.swift"]))
        let row = Self.code(try XCTUnwrap(s["TTS/NaturalVoiceOfferRow.swift"]))
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        XCTAssertTrue(line.contains("NaturalVoiceOfferRow(onOpenContents: onOpenContents, rowAlignment: rowAlignment)"),
                      "the line hands the offer its alignment")
        XCTAssertTrue(row.contains("rowAlignment: VerticalAlignment = .center"), "centred unless told")
        let body = compact(row)
        XCTAssertEqual(body.components(separatedBy: ".rowInk(rowAlignment) .frame(").count - 1, 3,
                       "the copy, Download and Not now each lift their ink on the row")
        XCTAssertEqual(body.components(separatedBy: "minHeight: 44, alignment: inkAlignment)").count - 1, 3,
                       "every 44pt row seats its ink on the line's alignment")
        XCTAssertFalse(body.contains("minHeight: 44)"), "no 44pt row left centred by default")
        XCTAssertEqual(body.components(separatedBy: "HStack(alignment: rowAlignment,").count - 1, 2,
                       "the one-line row and its buttons align on it too")
    }

    /// P007: native checkmark items over the shared rule, on both apps.
    func testTheSleepMenuUsesTheSharedRuleAndNativeSelection() throws {
        let s = try SourceTree.sources(only: ["Reader/SleepChip.swift"])
        let macSources = try SourceTree.sources(in: SourceTree.macRoot, only: ["Reader/MacSleepMenu.swift"])
        let chip = Self.code(try XCTUnwrap(s["Reader/SleepChip.swift"]))
        XCTAssertTrue(chip.contains("SleepTimer.menuItems(options: sleepTimer.menuOptions, isArmed: sleepTimer.isArmed)"))
        XCTAssertTrue(chip.contains("Toggle(isOn: selection(option))"), "a native selected state")
        XCTAssertFalse(chip.contains("\"checkmark\""), "a checkmark image reads as an image, not as selected")
        XCTAssertTrue(chip.contains(".menuOrderNearestFirst()"))
        XCTAssertTrue(chip.contains("Section(SleepTimer.Copy.section)"))
        let mac = Self.code(try XCTUnwrap(macSources["Reader/MacSleepMenu.swift"]))
        XCTAssertTrue(mac.contains("SleepTimer.menuItems("), "the Mac reads the shared rule")
        XCTAssertFalse(mac.contains("static func items("), "one rule, not a Mac copy")
    }

    /// `source` without its line comments.
    private static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    /// The text of the first `{ … }` block after `marker`, braces balanced.
    private static func closure(after marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let open = source[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Contents picks are jumps (R15), so each one offers Undo jump.
    func testContentsJumpsInsteadOfSeeking() throws {
        let sources = try SourceTree.sources(only: ["Reader/ContentsSheet.swift"])
        let contents = try XCTUnwrap(sources["Reader/ContentsSheet.swift"])
        XCTAssertFalse(contents.contains("seek(to:"), "ContentsSheet.swift should jump, not seek")
        XCTAssertTrue(contents.contains("origin: .chapter"))
        XCTAssertTrue(contents.contains("origin: .searchResult"))
    }

    /// R20 removed the UIKit-generator haptics API; TransportHaptics.emit is
    /// the only way to play one.
    func testNoLegacyHapticCalls() throws {
        let sources = try SourceTree.sources()
        for needle in ["TransportHaptics.tap", "selectionChanged"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), [],
                           "'\(needle)' should be gone from ios/Aloud")
        }
    }

    /// An error is one stopped reason among six (R11): the message slot has
    /// no case of its own for it.
    func testReaderMessageHasNoPlaybackErrorCase() throws {
        let sources = try SourceTree.sources()
        let message = try XCTUnwrap(sources["Reader/ReaderMessage.swift"])
        XCTAssertFalse(message.contains("case playbackError"), "ReaderMessage keeps errors in .stopped(_:)")
        XCTAssertEqual(SourceTree.files(containing: "ReaderMessage.playbackError", in: sources), [])
    }
}
