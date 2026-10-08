import XCTest
@testable import Aloud

// The shared halves of the iPhone's Contents (P025, P029), run on both
// apps: the Mac's panel picks through the same `ContentsSearch.jumpAndPlay`,
// and compiles the same `ContentsSearchMemory`.

// MARK: - P025: picks play

/// Contents' pick on both apps: from a pause it plays from the target and
/// says so (the iPhone's haptic follows that answer); from playback it only
/// moves. Undo jump restores the sentence and the pause.
@MainActor
final class ContentsJumpAndPlayTests: XCTestCase {

    func testAPickWhilePausedPlaysAndUndoRestoresThePause() async {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 2, autoplaySuppressed: true)
        rig.loadDefault(at: 2)
        XCTAssertFalse(rig.controller.isActive)

        let started = ContentsSearch.jumpAndPlay(rig.controller, to: 8, origin: .chapter)
        XCTAssertTrue(started, "a paused pick starts playback")
        XCTAssertEqual(rig.controller.currentSentence, 8)
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 2)
        XCTAssertEqual(rig.controller.undoableJump?.fromStatus, .paused)
        let playing = await rig.waitUntil(2) { rig.controller.isActive }
        XCTAssertTrue(playing)

        rig.controller.undoJump()
        let paused = await rig.waitUntil(2) { !rig.controller.isActive }
        XCTAssertTrue(paused, "Undo jump restores the pause")
        XCTAssertEqual(rig.controller.currentSentence, 2)
    }

    func testAPickWhilePlayingOnlyMoves() async {
        let rig = PlaybackTestRig(sentences: 12, clipDuration: 2, autoplaySuppressed: true)
        rig.loadDefault(at: 2)
        rig.controller.seek(to: 2, andPlay: true)
        let playing = await rig.waitUntil(2) { rig.controller.isListenerPlaying }
        XCTAssertTrue(playing)

        let started = ContentsSearch.jumpAndPlay(rig.controller, to: 9, origin: .searchResult)
        XCTAssertFalse(started, "already playing: no second start, no haptic")
        XCTAssertEqual(rig.controller.currentSentence, 9)
        XCTAssertTrue(rig.controller.isActive)
        rig.controller.pause()
    }

    func testAPickWithNoBookDoesNothing() {
        let rig = PlaybackTestRig(sentences: 12, autoplaySuppressed: true)
        XCTAssertFalse(ContentsSearch.jumpAndPlay(rig.controller, to: 3, origin: .chapter))
        XCTAssertFalse(rig.controller.isActive)
    }
}

// MARK: - P029, P033: what the sheet remembers

@MainActor
final class ContentsSearchMemoryTests: XCTestCase {

    func testAPickedSearchComesBackForItsBookOnly() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        XCTAssertNil(memory.restore(for: book), "nothing remembered yet")

        memory.remember(query: "Natasha", pickedSentence: 40, in: book)
        XCTAssertEqual(memory.restore(for: book), .init(query: "Natasha", pickedSentence: 40))
        XCTAssertEqual(memory.restore(for: book), .init(query: "Natasha", pickedSentence: 40), "restoring keeps it")

        XCTAssertNil(memory.restore(for: UUID()), "another book's Contents opens empty")
        XCTAssertNil(memory.documentID, "and the other book's search is forgotten")
        XCTAssertNil(memory.restore(for: book))
    }

    func testABlankQueryOrForgetLeavesNothing() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "   ", pickedSentence: 3, in: book)
        XCTAssertNil(memory.restore(for: book), "a blank query isn't a search")
        memory.remember(query: "whale", pickedSentence: 3, in: nil)
        XCTAssertNil(memory.documentID, "no book, nothing to remember")

        memory.remember(query: "whale", pickedSentence: 3, in: book)
        memory.forget()
        XCTAssertNil(memory.restore(for: book))
        XCTAssertEqual(memory.query, "")
        XCTAssertNil(memory.lastPickedSentence)
    }

    /// The sheet forgets on any edit (B4-R6): an edited, unpicked query is
    /// not what a reopening brings back.
    func testAForgottenSearchLeavesTheNextOpeningEmpty() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Natasha", pickedSentence: 40, in: book)
        memory.forget()
        XCTAssertNil(memory.restore(for: book))
        memory.remember(query: "Pierre", pickedSentence: 52, in: book)
        XCTAssertEqual(memory.restore(for: book), .init(query: "Pierre", pickedSentence: 52),
                       "the next pick remembers again")
    }

    func testASearchFocusRequestIsTakenOnce() {
        let memory = ContentsSearchMemory()
        XCTAssertFalse(memory.consumeSearchFocus())
        memory.requestSearchFocus()
        memory.forget()
        XCTAssertTrue(memory.consumeSearchFocus(), "forgetting a search keeps a focus request")
        XCTAssertFalse(memory.consumeSearchFocus(), "one request, one opening")
    }
}
