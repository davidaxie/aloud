import AppKit
import SwiftUI
import XCTest
@testable import Aloud

/// The Mac player bar's layout and focus budget (M9, mac-ux §3.7): a column
/// that matches the reading column (480-640 pt), the chips on a second row
/// below a 560 pt column or in the larger chrome bands, and at most nine
/// focusable controls below the text, ten while the natural-voice offer
/// shows. The bands (M18, mac-ux §10.4): the bar follows the reader's text
/// size, the shared chapter line and Play glyph with it, and fits the
/// 520 × 480 window at 40 pt. Plus the sleep chip's
/// menu: the most recent choice first, Off only while armed, in the chip's
/// sentence case. Pure layout, no window; text is measured with AppKit's
/// own metrics, and the shared chapter line as SwiftUI sets it, through
/// `NSHostingView`.
@MainActor
final class MacPlayerBarTests: XCTestCase {

    // MARK: - Column

    func testTheColumnMatchesTheReadingColumn() {
        XCTAssertEqual(MacPlayerBarLayout.columnWidth(forBarWidth: 1000), 640, "capped at the widest measure")
        XCTAssertEqual(MacPlayerBarLayout.columnWidth(forBarWidth: 520), 480,
                       "the minimum window less its gutters is the narrowest column")
        XCTAssertEqual(MacPlayerBarLayout.columnWidth(forBarWidth: 600), 560)
        for width in stride(from: CGFloat(520), through: 2560, by: 10) {
            let column = MacPlayerBarLayout.columnWidth(forBarWidth: width)
            XCTAssertTrue((MacPlayerBarLayout.minColumnWidth...MacPlayerBarLayout.maxColumnWidth).contains(column),
                          "\(width) pt: column \(column)")
        }
    }

    // MARK: - Rows

    func testTwoRowsBelowA560PointColumn() {
        let narrow = MacPlayerBarLayout(barWidth: 599, scale: .standard)
        XCTAssertLessThan(narrow.columnWidth, 560)
        XCTAssertTrue(narrow.chipsOnSecondRow)
        XCTAssertEqual(narrow.transportRows, [[.back15, .play, .forward15], [.listening, .sleep]],
                       "the transport stays whole; the two chips take the row under it")

        let atBreak = MacPlayerBarLayout(barWidth: 600, scale: .standard)
        XCTAssertEqual(atBreak.columnWidth, 560)
        XCTAssertFalse(atBreak.chipsOnSecondRow, "a 560 pt column keeps one row")
        XCTAssertEqual(atBreak.transportRows, [[.listening, .back15, .play, .forward15, .sleep]])

        XCTAssertTrue(MacPlayerBarLayout(barWidth: 520, scale: .standard).chipsOnSecondRow)
        XCTAssertFalse(MacPlayerBarLayout(barWidth: 1000, scale: .standard).chipsOnSecondRow)
    }

    /// M18: from a 23 pt reader the chrome is larger, and the chips move to
    /// their own row even in a wide window.
    func testTheLargerChromeBandsUseTwoRowsAtAnyWidth() {
        for scale in [ChromeScale.large, .largest] {
            XCTAssertTrue(MacPlayerBarLayout(barWidth: 1400, scale: scale).chipsOnSecondRow, "\(scale)")
        }
        XCTAssertTrue(MacPlayerBarLayout(barWidth: 1400, scale: ChromeScale(readerStep: 4)).chipsOnSecondRow,
                      "23 pt is the first large step")
        XCTAssertFalse(MacPlayerBarLayout(barWidth: 1400, scale: ChromeScale(readerStep: 3)).chipsOnSecondRow,
                       "21 pt keeps one row")
    }

    func testEveryRowDrawsTheSameFiveTransportControls() {
        for width in [CGFloat(520), 599, 600, 1000] {
            for scale in ChromeScale.allCases {
                let rows = MacPlayerBarLayout(barWidth: width, scale: scale).transportRows
                XCTAssertEqual(Set(rows.flatMap { $0 }), [.listening, .back15, .play, .forward15, .sleep])
                XCTAssertEqual(rows.flatMap { $0 }.count, 5, "no control drawn twice")
            }
        }
    }

    /// The row holding Play fits its circle; 56 at the default band.
    func testTheTransportRowFitsThePlayCircle() {
        XCTAssertEqual(MacPlayerBarLayout.transportRowHeight(for: [.back15, .play, .forward15], scale: .standard), 56)
        for scale in ChromeScale.allCases {
            XCTAssertGreaterThan(MacPlayerBarLayout.transportRowHeight(for: [.play], scale: scale),
                                 scale.playCircleDiameter)
        }
        XCTAssertGreaterThanOrEqual(MacPlayerBarLayout.transportRowHeight(for: [.listening, .sleep], scale: .standard),
                                    MacPlayerBarLayout.chipHeight)
    }

    // MARK: - Focus budget

    /// Every message the chapter line can hold.
    private static let messages: [ReaderMessage?] = [nil]
        + StopReason.allCases.map { .stopped($0) }
        + [.notice(.fellBackToSystem), .notice(.coolingDown), .naturalVoiceOffer,
           .downloadProgress(0.4), .downloadWaiting(NaturalVoiceCopy.waitingForWiFi), .preparingVoice]

    private static let chips: [ReaderChip?] = [nil, .undoJump, .moreClassics, .followVoice(.up)]

    /// At rest (no chip), whatever the line says, both layouts.
    func testAtMostNineFocusableControlsAtRest() {
        for width in [CGFloat(520), 1000] {
            let layout = MacPlayerBarLayout(barWidth: width, scale: .standard)
            for message in Self.messages {
                let controls = layout.focusableControls(message: message, chip: nil)
                XCTAssertLessThanOrEqual(controls.count, MacPlayerBarLayout.focusBudget, "\(String(describing: message))")
                XCTAssertEqual(Set(controls).count, controls.count, "no control counted twice")
            }
        }
        XCTAssertEqual(MacPlayerBarLayout(barWidth: 1000, scale: .standard)
                        .focusableControls(message: nil, chip: nil).count, 7,
                       "the quiet bar: line, scrub and the five transport controls")
    }

    /// The budget while the natural-voice offer shows: its Download and Not
    /// now are one control more than a line's one inline action, and the
    /// offer shows once, after 60 s of listening, so the bar may hold one
    /// more then.
    private static let offerFocusBudget = MacPlayerBarLayout.focusBudget + 1

    /// With the chip slot's one chip: still within budget for every line
    /// with at most one inline action (mac-ux §3.7's count), both layouts.
    /// A sleep stop under a chip fills it exactly.
    func testAtMostNineFocusableControlsWithTheOneChip() {
        for width in [CGFloat(520), 1000] {
            let layout = MacPlayerBarLayout(barWidth: width, scale: .standard)
            for message in Self.messages where message != .naturalVoiceOffer {
                for chip in Self.chips {
                    XCTAssertLessThanOrEqual(layout.focusableControls(message: message, chip: chip).count,
                                             MacPlayerBarLayout.focusBudget,
                                             "\(width) pt: \(String(describing: message)) with \(String(describing: chip))")
                }
            }
        }
        XCTAssertEqual(MacPlayerBarLayout(barWidth: 1000, scale: .standard)
                        .focusableControls(message: .stopped(.sleepTimer), chip: .undoJump).count,
                       MacPlayerBarLayout.focusBudget)
    }

    /// The decided rule: nine at rest, ten while the offer shows. The offer
    /// alone keeps to nine; under any one chip it makes exactly ten, never
    /// more.
    func testTheOfferShowingAllowsOneMoreControl() {
        XCTAssertEqual(MacPlayerBarLayout.focusBudget, 9)
        XCTAssertEqual(Self.offerFocusBudget, 10)
        for width in [CGFloat(520), 1000] {
            let layout = MacPlayerBarLayout(barWidth: width, scale: .standard)
            XCTAssertEqual(layout.focusableControls(message: .naturalVoiceOffer, chip: nil).count,
                           MacPlayerBarLayout.focusBudget, "\(width) pt: the offer with no chip")
            for chip in Self.chips.compactMap({ $0 }) {
                let controls = layout.focusableControls(message: .naturalVoiceOffer, chip: chip)
                XCTAssertEqual(controls.count, Self.offerFocusBudget, "\(width) pt: the offer with \(chip)")
                XCTAssertEqual(Set(controls).count, controls.count, "no control counted twice")
            }
        }
    }

    func testTheSleepStopAddsBackFiveMinutesAndTheOfferItsTwoButtons() {
        XCTAssertEqual(MacPlayerBarLayout.messageControls(nil), [.chapterLine])
        XCTAssertEqual(MacPlayerBarLayout.messageControls(.stopped(.sleepTimer)), [.chapterLine, .backFiveMinutes])
        XCTAssertEqual(MacPlayerBarLayout.messageControls(.stopped(.playbackError)), [.chapterLine],
                       "Try again is the line itself")
        XCTAssertEqual(MacPlayerBarLayout.messageControls(.naturalVoiceOffer),
                       [.chapterLine, .offerDownload, .offerNotNow])
    }

    /// mac-ux §10.1's reader order: chip slot, chapter line, scrub, voice ·
    /// speed, back 15, play, forward 15, sleep, in either layout.
    func testTheFocusOrderIsTheStatedOrderInBothLayouts() {
        let expected: [MacPlayerBarLayout.Control] = [.chip, .chapterLine, .scrub,
                                                      .listening, .back15, .play, .forward15, .sleep]
        for width in [CGFloat(520), 1000] {
            XCTAssertEqual(MacPlayerBarLayout(barWidth: width, scale: .standard)
                            .focusableControls(message: nil, chip: .undoJump), expected, "\(width) pt")
        }
    }

    // MARK: - Bands (M18)

    /// The reader's nine sizes and the band each one sets the bar in.
    private static let sizeBands: [(points: CGFloat, scale: ChromeScale)] = [
        (16, .standard), (17.5, .standard), (19, .standard), (21, .standard),
        (23, .large), (26, .large), (30, .large),
        (35, .largest), (40, .largest),
    ]

    /// Every reader step picks its band: body / callout / caption 13 / 12 /
    /// 11 at 16-21 pt, 15 / 14 / 13 at 23-30, 17 / 16 / 15 at 35-40, and
    /// the bar drawn at that step is the band's bar.
    func testEachReaderSizeStepSetsTheBarsBand() {
        XCTAssertEqual(Self.sizeBands.map(\.points), ReaderTextSize.steps, "every step of the Aa stepper and ⌘+ / ⌘−")
        let type: [ChromeScale: [CGFloat]] = [.standard: [13, 12, 11], .large: [15, 14, 13], .largest: [17, 16, 15]]
        for (step, expected) in Self.sizeBands.enumerated() {
            let scale = ChromeScale(readerStep: step)
            XCTAssertEqual(scale, expected.scale, "\(expected.points) pt")
            XCTAssertEqual([.body, .callout, .caption].map { PlatformTypeRamp.points($0, scale: scale) },
                           type[expected.scale], "\(expected.points) pt")
            let layout = MacPlayerBarLayout(barWidth: 1400, scale: scale)
            XCTAssertEqual(layout.scale, expected.scale, "\(expected.points) pt")
            XCTAssertEqual(layout.chipsOnSecondRow, expected.scale != .standard,
                           "\(expected.points) pt: the chips leave the transport row from 23 pt")
        }
    }

    /// The Play circle grows a step per band (44, 52, 60), and its row,
    /// the chips and the skips grow with it.
    func testThePlayCircleAndTheControlsGrowWithTheBand() {
        let table: [(ChromeScale, circle: CGFloat, playRow: CGFloat, chip: CGFloat, chipRow: CGFloat, skip: CGFloat)] = [
            (.standard, 44, 56, 28, 44, 32),
            (.large, 52, 64, 32, 48, 36),
            (.largest, 60, 72, 36, 52, 40),
        ]
        XCTAssertEqual(table.map(\.0), ChromeScale.allCases)
        for (scale, circle, playRow, chip, chipRow, skip) in table {
            XCTAssertEqual(scale.playCircleDiameter, circle, "\(scale)")
            XCTAssertEqual(MacPlayerBarLayout.transportRowHeight(for: [.back15, .play, .forward15], scale: scale),
                           playRow, "\(scale)")
            XCTAssertEqual(MacPlayerBarLayout.chipHeight(for: scale), chip, "\(scale)")
            XCTAssertEqual(MacPlayerBarLayout.transportRowHeight(for: [.listening, .sleep], scale: scale),
                           chipRow, "\(scale)")
            XCTAssertEqual(MacPlayerBarLayout.glyphHit(for: scale), skip, "\(scale)")
            XCTAssertGreaterThanOrEqual(MacPlayerBarLayout.chipHeight(for: scale), MacPlayerBarLayout.chipHeight,
                                        "never under the HIG's 28 pt")
            // The busy ring sits outside the circle; its row holds it too,
            // so buffering never draws over the scrub or the chips' row.
            let ring = circle + 2 * (Theme.PlayCircle.arcGap + Theme.PlayCircle.arcWidth)
            XCTAssertGreaterThanOrEqual(playRow, ring, "\(scale): the busy ring fits its row")
        }
        XCTAssertEqual(MacPlayerBarLayout.chipHeight(for: .standard), MacPlayerBarLayout.chipHeight)
        XCTAssertEqual(MacPlayerBarLayout.glyphHit(for: .standard), MacPlayerBarLayout.glyphHit)
        let circles = ChromeScale.allCases.map(\.playCircleDiameter)
        XCTAssertEqual(circles, circles.sorted(), "the circle only grows")
        XCTAssertEqual(Set(circles).count, circles.count, "each band a larger circle")
    }

    /// The whole bar in each band fits the minimum window: at most half of
    /// its 480 pt height, so the page keeps the other half, in one row or
    /// two, at every width from the 520 pt minimum. 144 pt in one row at
    /// the standard band.
    func testTheBarsHeightInEveryBandFitsTheMinimumWindow() {
        let minimum = MacWindowConfigurator.minimumSize
        XCTAssertEqual(minimum, CGSize(width: 520, height: 480))
        for width in [minimum.width, 599, 600, 1000, 1400] {
            var previous: CGFloat = 0
            for scale in ChromeScale.allCases {
                let layout = MacPlayerBarLayout(barWidth: width, scale: scale)
                XCTAssertLessThanOrEqual(layout.height, minimum.height / 2, "\(width) pt, \(scale): \(layout.height)")
                XCTAssertGreaterThanOrEqual(layout.height, previous, "\(width) pt, \(scale): a larger band never shrinks it")
                previous = layout.height
            }
        }
        XCTAssertEqual(MacPlayerBarLayout(barWidth: 1000, scale: .standard).height,
                       Theme.Space.xs + 44 + MacScrub.rowHeight + 56 + Theme.Space.sm,
                       "insets, the chapter line, the scrub and one transport row")
        XCTAssertEqual(MacPlayerBarLayout(barWidth: 1000, scale: .standard).height, 144)
        XCTAssertEqual(MacPlayerBarLayout(barWidth: minimum.width, scale: .standard).height, 144 + 44,
                       "the chips' own row below 560 pt")
        XCTAssertEqual(MacPlayerBarLayout(barWidth: 1400, scale: .large).height,
                       MacPlayerBarLayout(barWidth: minimum.width, scale: .large).height,
                       "a larger band is two rows at any width")
    }

    /// At 40 pt the chapter line may wrap (mac-ux §10.4): the bar keeps room
    /// for its title on two lines over its detail. In the other bands one
    /// line of the band's type fits the shared line's 44 pt row.
    func testTheChapterLineHasRoomToWrapAtTheLargestBand() {
        for scale in ChromeScale.allCases {
            XCTAssertLessThanOrEqual(MacPlayerBarLayout.lineHeight(.subhead, scale: scale),
                                     MacPlayerBarLayout.chapterLineMinHeight, "\(scale): one line fits")
        }
        XCTAssertEqual(MacPlayerBarLayout.chapterLineHeight(for: .standard), 44)
        XCTAssertEqual(MacPlayerBarLayout.chapterLineHeight(for: .large), 44)
        let wrapped = 2 * MacPlayerBarLayout.lineHeight(.subhead, scale: .largest) + Theme.Space.xxs
            + MacPlayerBarLayout.lineHeight(.footnote, scale: .largest)
        XCTAssertGreaterThanOrEqual(MacPlayerBarLayout.chapterLineHeight(for: .largest), wrapped)
        XCTAssertGreaterThan(MacPlayerBarLayout.chapterLineHeight(for: .largest), MacPlayerBarLayout.chapterLineMinHeight,
                             "two lines and a detail need more than the one-line row")
    }

    /// The shared chapter line reads the band: its title 11, 13 and 15 pt
    /// semibold, its detail and every message 11, 13 and 15 pt, and only
    /// the Largest band stacks the title over the detail.
    func testTheChapterLineSetsEachBandsType() {
        let table: [(ChromeScale, points: CGFloat)] = [(.standard, 11), (.large, 13), (.largest, 15)]
        XCTAssertEqual(table.map(\.0), ChromeScale.allCases)
        for (scale, points) in table {
            XCTAssertEqual(ReaderMessageLine.titleFont(scale), .system(size: points, weight: .semibold), "\(scale)")
            XCTAssertEqual(ReaderMessageLine.detailFont(scale), .system(size: points), "\(scale)")
            XCTAssertEqual(ReaderMessageLine.stacksPosition(dynamicTypeSize: .large, scale: scale), scale == .largest,
                           "\(scale)")
        }
    }

    /// The line as the bar draws it, in the narrowest column, with a title
    /// far too long for one line: the one 44 pt row in the Default and Large
    /// bands (the title truncates), and in the Largest band the title on
    /// exactly two lines over its detail, with the bar still inside half the
    /// minimum window. SwiftUI sets a 15 pt line 19 pt high where
    /// `MacPlayerBarLayout.lineHeight` counts AppKit's 18, so the line is
    /// 61 pt against the bar's 58: expected to fail until MacPlayerBar.swift
    /// measures SwiftUI's line (strict, so the fix flags this for removal).
    func testTheChapterLineWrapsOnlyInTheLargestBandWithinTheBarsRoom() {
        let position = ReaderPositionLine(
            kind: .chapter(number: 24, count: 61),
            title: "Chapter XXIV. In Which the Travellers, Having Crossed the Frozen Sea, Come at Last to the Northern Shore",
            minutesLeft: 8)
        for scale in ChromeScale.allCases {
            let height = measuredChapterLineHeight(position, scale: scale)
            guard scale == .largest else {
                XCTAssertEqual(height, MacPlayerBarLayout.chapterLineMinHeight, accuracy: 0.5, "\(scale): one line")
                continue
            }
            let stacked = 2 * measuredLineHeight(ReaderMessageLine.titleFont(scale)) + Theme.Space.xxs
                + measuredLineHeight(ReaderMessageLine.detailFont(scale))
            XCTAssertGreaterThan(height, MacPlayerBarLayout.chapterLineMinHeight, "the title wraps")
            XCTAssertEqual(height, stacked, accuracy: 0.5, "two title lines over the detail, no more")
            let minimum = MacWindowConfigurator.minimumSize
            let bar = MacPlayerBarLayout(barWidth: minimum.width, scale: scale)
            XCTAssertLessThanOrEqual(bar.height - MacPlayerBarLayout.chapterLineHeight(for: scale) + height,
                                     minimum.height / 2, "the bar, with the line as drawn, in half the window")
            XCTAssertLessThanOrEqual(height, MacPlayerBarLayout.chapterLineHeight(for: scale) + 0.5,
                                     "inside the bar's room for it")
        }
    }

    /// One line of `font` as SwiftUI sets it.
    private func measuredLineHeight(_ font: Font) -> CGFloat {
        NSHostingView(rootView: Text("Ag").font(font)).fittingSize.height
    }

    /// The natural-voice offer that takes the line's place reads the band
    /// too: its one-line form widens with each band, and in the narrowest
    /// column it stays the one 44 pt row. Its own defaults and directory,
    /// network tasks off; nothing downloads.
    func testTheOfferRowFollowsTheBandInOneRow() throws {
        let suite = "aloud.tests.macPlayerBarOffer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPlayerBarTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = FixedNetworkPath(isExpensiveOrConstrained: false)
        let manager = ModelManager(pathSource: path, installDirectory: directory, defaults: defaults,
                                   freeSpace: { 2_000_000_000 }, hasher: { _ in "" })
        manager.startsNetworkTasks = false
        manager.announce = { _ in }
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: true, now: { 0 },
                                      pathSource: path, watchesDownloadPath: false)
        func row(_ scale: ChromeScale) -> some View {
            NaturalVoiceOfferRow(onOpenContents: {})
                .environmentObject(offer)
                .environmentObject(manager)
                .environment(\.chromeScale, scale)
        }
        let widths = ChromeScale.allCases.map { NSHostingView(rootView: row($0)).fittingSize.width }
        XCTAssertEqual(widths, widths.sorted(), "\(widths)")
        XCTAssertEqual(Set(widths).count, widths.count, "each band sets it larger: \(widths)")
        for scale in ChromeScale.allCases {
            let height = NSHostingView(rootView: row(scale).frame(width: MacPlayerBarLayout.minColumnWidth))
                .fittingSize.height
            XCTAssertEqual(height, MacPlayerBarLayout.chapterLineMinHeight, accuracy: 0.5, "\(scale): one row")
        }
    }

    /// The shared line's height in a bar at the minimum column, with
    /// `scale` in its environment as `MacReaderScreen` sets it.
    private func measuredChapterLineHeight(_ position: ReaderPositionLine, scale: ChromeScale) -> CGFloat {
        let line = ReaderMessageLine(message: nil, position: position,
                                     onOpenContents: {}, onRetry: {}, onBackFiveMinutes: {})
            .environment(\.chromeScale, scale)
            .frame(width: MacPlayerBarLayout.minColumnWidth + 2 * Theme.Space.screenGutter)
        return NSHostingView(rootView: line).fittingSize.height
    }

    /// The Play glyph is sized from its circle (the iPhone's 22 pt in 54):
    /// 18, 21 and 24 pt bold in the 44, 52 and 60 pt circles, where the
    /// system's text styles gave 44 and 52 the same glyph. Every glyph the
    /// circle shows sits inside it.
    func testThePlayGlyphGrowsWithEachBandsCircle() throws {
        let table: [(ChromeScale, points: CGFloat)] = [(.standard, 18), (.large, 21), (.largest, 24)]
        XCTAssertEqual(table.map(\.0), ChromeScale.allCases)
        var previous: CGFloat = 0
        for (scale, points) in table {
            let diameter = scale.playCircleDiameter
            XCTAssertEqual(PlatformTypeRamp.playGlyphPoints(diameter: diameter), points, "\(scale)")
            XCTAssertEqual(PlayCircleFace.glyphFont(diameter: diameter), .system(size: points, weight: .bold), "\(scale)")
            XCTAssertGreaterThan(points, previous, "\(scale): a larger circle, a larger glyph")
            previous = points
            let config = NSImage.SymbolConfiguration(pointSize: points, weight: .bold)
            for glyph in [PlayButtonState.Glyph.play, .pause, .retry, .listenAgain] {
                let size = try XCTUnwrap(NSImage(systemSymbolName: glyph.rawValue, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)?.size, glyph.rawValue)
                XCTAssertLessThanOrEqual(max(size.width, size.height), diameter / CGFloat(2).squareRoot(),
                                         "\(scale): \(glyph.rawValue) inside the circle, corners and all")
            }
        }
        XCTAssertNotEqual(PlayCircleFace.glyphFont(diameter: ChromeScale.standard.playCircleDiameter),
                          PlayCircleFace.glyphFont(diameter: ChromeScale.large.playCircleDiameter))
    }

    /// Nothing clips at 40 pt in the narrowest window, nor in one row at
    /// the 560 pt break: the cluster fits the column, the widest chip
    /// labels fit their side, each label fits its chip's height, and the
    /// skip glyphs fit their hit regions.
    func testNothingClipsAtFortyPointsInTheMinimumWindow() {
        let listening = "Samantha · " + ListeningFormat.rate(2.25)
        let sleepLabels = [SleepTimer.Copy.chapterEnd, SleepTimer.Copy.bookEnd, SleepTimer.Copy.extendChip, "28:14"]
        let cases: [(barWidth: CGFloat, scale: ChromeScale)] = [
            (520, .standard), (600, .standard), (520, .large), (520, .largest), (1400, .largest),
        ]
        for (barWidth, scale) in cases {
            let layout = MacPlayerBarLayout(barWidth: barWidth, scale: scale)
            let label = "\(barWidth) pt, \(scale)"
            XCTAssertLessThanOrEqual(MacPlayerBarLayout.transportClusterWidth(for: scale), layout.columnWidth, label)
            for text in [listening] + sleepLabels {
                XCTAssertLessThanOrEqual(chipWidth(text, scale: scale), layout.chipSideWidth, "\(label): \(text)")
            }
            XCTAssertLessThanOrEqual(MacPlayerBarLayout.lineHeight(.subhead, scale: scale),
                                     MacPlayerBarLayout.chipHeight(for: scale), label)
            for symbol in ["gobackward.15", "goforward.15"] {
                guard let glyph = glyphSize(symbol, scale: scale) else {
                    XCTFail("\(symbol) is a system symbol")
                    continue
                }
                let hit = MacPlayerBarLayout.glyphHit(for: scale)
                XCTAssertLessThanOrEqual(max(glyph.width, glyph.height), hit, "\(label): \(symbol)")
            }
        }
        // The chip slot's one chip, glyph and title, centered over the
        // narrowest column.
        for chip in [ReaderChip.undoJump, .moreClassics, .followVoice(.up)] {
            let glyph = glyphSize(chip.systemImage, scale: .largest, style: .subhead)?.width ?? .infinity
            XCTAssertLessThanOrEqual(chipWidth(chip.title, scale: .largest) + Theme.Space.xs + glyph,
                                     MacPlayerBarLayout.minColumnWidth, chip.title)
        }
    }

    /// The bands move nothing in or out of the keyboard's way: nine at rest
    /// and ten with the offer under a chip, in the same order, at every band
    /// and width.
    func testTheFocusBudgetHoldsInEveryBand() {
        let expected: [MacPlayerBarLayout.Control] = [.chip, .chapterLine, .scrub,
                                                      .listening, .back15, .play, .forward15, .sleep]
        for scale in ChromeScale.allCases {
            for width in [CGFloat(520), 599, 600, 1000, 1400] {
                let layout = MacPlayerBarLayout(barWidth: width, scale: scale)
                let label = "\(width) pt, \(scale)"
                for message in Self.messages {
                    for chip in Self.chips {
                        let controls = layout.focusableControls(message: message, chip: chip)
                        let budget = message == .naturalVoiceOffer && chip != nil
                            ? Self.offerFocusBudget : MacPlayerBarLayout.focusBudget
                        XCTAssertLessThanOrEqual(controls.count, budget,
                                                 "\(label): \(String(describing: message)) with \(String(describing: chip))")
                        XCTAssertEqual(Set(controls).count, controls.count, "\(label): no control counted twice")
                    }
                }
                XCTAssertEqual(layout.focusableControls(message: nil, chip: nil).count, 7, label)
                XCTAssertEqual(layout.focusableControls(message: nil, chip: .undoJump), expected, label)
            }
        }
    }

    /// A smaller band gives the page back its foot: the chip slot's reach
    /// is measured afresh from the new band's chip; with no chip seen yet,
    /// nothing is covered still.
    func testABandChangeMeasuresTheChipReachAfresh() {
        XCTAssertEqual(MacReaderScreen.chipReach(previous: 0, bandChangedTo: .largest), 0)
        let largest = MacReaderScreen.chipReach(previous: 0, slotHeight: MacPlayerBarLayout.chipHeight(for: .largest))
        XCTAssertEqual(largest, 36 + Theme.Space.sm)
        for scale in ChromeScale.allCases {
            XCTAssertEqual(MacReaderScreen.chipReach(previous: largest, bandChangedTo: scale),
                           MacPlayerBarLayout.chipHeight(for: scale) + Theme.Space.sm, "\(scale)")
        }
        XCTAssertLessThan(MacReaderScreen.chipReach(previous: largest, bandChangedTo: .standard), largest)
    }

    /// A chip's width for `text`: the band's subhead (semibold, as the
    /// chip sets it) and the capsule's 12 pt sides.
    private func chipWidth(_ text: String, scale: ChromeScale) -> CGFloat {
        let font = NSFont.systemFont(ofSize: PlatformTypeRamp.points(.subhead, scale: scale), weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 2 * Theme.Space.sm
    }

    /// An SF Symbol at `style`'s size in `scale`'s band, large, as the skips
    /// draw it.
    private func glyphSize(_ name: String, scale: ChromeScale, style: Theme.TypeStyle = .body) -> CGSize? {
        let config = NSImage.SymbolConfiguration(pointSize: PlatformTypeRamp.points(style, scale: scale),
                                                 weight: .regular, scale: style == .body ? .large : .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)?.size
    }

    // MARK: - Sleep menu

    func testTheSleepMenuListsTheMostRecentFirstAndOffOnlyWhileArmed() {
        let options = SleepTimer.orderedOptions(lastUsed: .minutes(30), minuteChoices: SleepTimer.standardMinuteChoices)
        let off = MacSleepMenu.items(options: options, isArmed: false)
        XCTAssertEqual(off.choices, [.minutes(30), .minutes(15), .minutes(45), .minutes(60), .endOfChapter])
        XCTAssertFalse(off.showsOff, "Off shows only while a timer is armed")

        let armed = MacSleepMenu.items(options: options, isArmed: true)
        XCTAssertEqual(armed.choices, off.choices, "Off never joins the choices")
        XCTAssertTrue(armed.showsOff)
    }

    func testTheSleepMenuSpeaksTheChipsSentenceCase() {
        XCTAssertEqual(MacSleepMenu.title(for: .minutes(15), endsAtChapter: true), "15 min")
        XCTAssertEqual(MacSleepMenu.title(for: .minutes(60), endsAtChapter: true), "1 hr")
        XCTAssertEqual(MacSleepMenu.title(for: .endOfChapter, endsAtChapter: true), "End of chapter")
        XCTAssertEqual(MacSleepMenu.title(for: .endOfChapter, endsAtChapter: false), "End of book")
        XCTAssertEqual(MacSleepMenu.title(for: .off, endsAtChapter: true), "Off")
    }
}
