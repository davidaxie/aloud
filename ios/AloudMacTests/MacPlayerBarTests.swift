import SwiftUI
import XCTest
@testable import Aloud

/// The Mac player bar's layout and focus budget (M9, mac-ux §3.7): a column
/// that matches the reading column (480-640 pt), the chips on a second row
/// below a 560 pt column or in the larger chrome bands, and at most nine
/// focusable controls below the text, ten while the natural-voice offer
/// shows. Plus the sleep chip's menu: the most recent choice first, Off
/// only while armed, in the chip's sentence case. Pure layout, no window.
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
           .downloadProgress(0.4), .downloadWaiting, .preparingVoice]

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
