import XCTest
@testable import Aloud

/// R11/R15/R16/R24: one chip slot, "Undo jump" over "More classics" over
/// "Follow the voice", with fixed copy, icons, identifiers and Voice Control
/// names.
final class ReaderChipTests: XCTestCase {

    private static let allChips: [ReaderChip] = [.undoJump, .moreClassics, .followVoice(.up), .followVoice(.down)]

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
                    case (false, true, _):
                        XCTAssertEqual(chip, .moreClassics, "the end beats follow: \(context)")
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

    /// The arrow flipping is the same chip: the slot doesn't re-animate.
    func testSlotKeyIsStableAcrossDirections() {
        XCTAssertEqual(ReaderChip.followVoice(.up).slotKey, "follow")
        XCTAssertEqual(ReaderChip.followVoice(.down).slotKey, ReaderChip.followVoice(.up).slotKey)
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
