import XCTest
@testable import Aloud

/// R11/R15/R16/R24/R4-06: one chip slot, undo over the end of the book over
/// follow, with fixed copy, icons, identifiers and Voice Control names. At
/// the end the chip offers the next book while the colophon shows, and the
/// way back to it once the page is scrolled away.
final class ReaderChipTests: XCTestCase {

    private static let allChips: [ReaderChip] = [.undoJump, .moreClassics, .theEnd(.up), .theEnd(.down),
                                                 .followVoice(.up), .followVoice(.down)]

    func testResolveShowsAtMostOneChipAndUndoWins() {
        let directions: [ReaderFollowDirection?] = [nil, .up, .down]
        for canUndo in [false, true] {
            for offscreen in directions {
                for atEnd in [false, true] {
                    let chip = ReaderChip.resolve(canUndoJump: canUndo, voiceOffscreen: offscreen, isAtEnd: atEnd)
                    let context = "undo \(canUndo), offscreen \(String(describing: offscreen)), at end \(atEnd)"
                    switch (canUndo, atEnd, offscreen) {
                    case (true, _, _):
                        XCTAssertEqual(chip, .undoJump, "undo beats everything: \(context)")
                    case (false, true, nil):
                        // At the end and following, the colophon is on screen.
                        XCTAssertEqual(chip, .moreClassics, "the end, the colophon showing: \(context)")
                    case (false, true, let direction?):
                        // R4-06: the end beats follow, and leads back to the
                        // colophon while the page is away from it.
                        XCTAssertEqual(chip, .theEnd(direction), "the end, scrolled away: \(context)")
                    case (false, false, nil):
                        XCTAssertNil(chip, context)
                    case (false, false, let direction?):
                        XCTAssertEqual(chip, .followVoice(direction), context)
                    }
                }
            }
        }
    }

    /// Callers that predate R24 (ReaderMessageTests) never see More classics.
    func testIsAtEndDefaultsToFalse() {
        XCTAssertNil(ReaderChip.resolve(canUndoJump: false, voiceOffscreen: nil))
        XCTAssertEqual(ReaderChip.resolve(canUndoJump: false, voiceOffscreen: .down), .followVoice(.down))
    }

    /// R24: a secondary chip that opens Classics (the Bookshelf screen's
    /// title; copy never says "bookshelf").
    func testMoreClassicsCopy() {
        let chip = ReaderChip.moreClassics
        XCTAssertEqual(chip.title, "More classics")
        XCTAssertEqual(chip.systemImage, "books.vertical")
        XCTAssertEqual(chip.identifier, "reader.moreClassics")
        XCTAssertEqual(chip.hint, "Opens Classics")
        XCTAssertEqual(chip.inputLabels, ["More classics", "Classics"])
        XCTAssertEqual(chip.slotKey, "moreClassics")
    }

    func testUndoJumpCopy() {
        let chip = ReaderChip.undoJump
        XCTAssertEqual(chip.title, "Undo jump")
        XCTAssertEqual(chip.systemImage, "arrow.uturn.backward")
        XCTAssertEqual(chip.identifier, "reader.undoJump")
        XCTAssertEqual(chip.hint, "Returns to where you were")
        XCTAssertEqual(chip.inputLabels, ["Undo jump", "Undo"])
        XCTAssertEqual(chip.slotKey, "undo")
    }

    func testFollowTheVoiceCopyAndArrows() {
        let up = ReaderChip.followVoice(.up)
        let down = ReaderChip.followVoice(.down)
        for chip in [up, down] {
            XCTAssertEqual(chip.title, "Follow the voice")
            XCTAssertEqual(chip.hint, "Scrolls to the sentence being read")
            XCTAssertEqual(chip.inputLabels, ["Follow the voice", "Follow"])
        }
        XCTAssertEqual(up.systemImage, "arrow.up")
        XCTAssertEqual(down.systemImage, "arrow.down")
        XCTAssertEqual(up.identifier, "reader.followVoice.up")
        XCTAssertEqual(down.identifier, "reader.followVoice.down")
    }

    /// R4-06: scrolled away from the colophon, the chip leads back to it,
    /// the arrow pointing its way; Follow's role, under its own name.
    func testBackToTheEndCopyAndArrows() {
        let up = ReaderChip.theEnd(.up)
        let down = ReaderChip.theEnd(.down)
        for chip in [up, down] {
            XCTAssertEqual(chip.title, "Back to The End")
            XCTAssertEqual(chip.hint, "Scrolls to the end of the book")
            XCTAssertEqual(chip.inputLabels, ["Back to The End", "The End"])
            XCTAssertEqual(chip.slotKey, "follow", "a swap with Follow doesn't re-animate")
        }
        XCTAssertEqual(up.systemImage, "arrow.up")
        XCTAssertEqual(down.systemImage, "arrow.down")
        XCTAssertEqual(up.identifier, "reader.theEnd.up")
        XCTAssertEqual(down.identifier, "reader.theEnd.down")
        XCTAssertNotEqual(down.identifier, ReaderChip.followVoice(.down).identifier, "UI tests tell them apart")
    }

    /// R4-06, the round trip: away from the colophon the chip leads back;
    /// once its tap lands the colophon and following resumes, the page
    /// reports no offscreen voice and the chip is More classics again.
    func testLandingTheColophonTurnsTheChipBackIntoMoreClassics() {
        XCTAssertEqual(ReaderChip.resolve(canUndoJump: false, voiceOffscreen: .down, isAtEnd: true), .theEnd(.down))
        XCTAssertEqual(ReaderChip.resolve(canUndoJump: false, voiceOffscreen: nil, isAtEnd: true), .moreClassics)
        XCTAssertEqual(ReaderChip.resolve(canUndoJump: true, voiceOffscreen: .down, isAtEnd: true), .undoJump,
                       "a jump away from the end can still be taken back")
    }

    /// The arrow flipping is the same chip: the slot doesn't re-animate.
    func testSlotKeyIsStableAcrossDirections() {
        XCTAssertEqual(ReaderChip.followVoice(.up).slotKey, "follow")
        XCTAssertEqual(ReaderChip.followVoice(.down).slotKey, ReaderChip.followVoice(.up).slotKey)
        XCTAssertEqual(ReaderChip.theEnd(.down).slotKey, ReaderChip.followVoice(.up).slotKey)
        XCTAssertNotEqual(ReaderChip.undoJump.slotKey, ReaderChip.followVoice(.up).slotKey)
        // Three distinct chips, three keys: each swap animates.
        let keys = [ReaderChip.undoJump, .moreClassics, .followVoice(.up)].map(\.slotKey)
        XCTAssertEqual(Set(keys).count, keys.count, "\(keys)")
    }

    /// Voice Control names start with the visible text (R12h).
    func testAccessibilityNamesStartWithTheVisibleText() {
        for chip in Self.allChips {
            XCTAssertEqual(chip.inputLabels.first, chip.title, "\(chip)")
        }
    }
}
