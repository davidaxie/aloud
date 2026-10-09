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
        XCTAssertFalse(started, "already playing: no second start, so the place tick, not play")
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

    /// Two chapters of 60 sentences each (headings 0 and 61), so sentence
    /// 40 sits in CHAPTER I and 70 in CHAPTER II.
    private static let chaptered = navigation(chapters: ["CHAPTER I", "CHAPTER II"], sentencesEach: 60)
    /// One run of 200 sentences: no chapter list.
    private static let unchaptered = navigation(chapters: ["The thousand injuries of Fortunato."],
                                                sentencesEach: 200)
    private static let picked = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func navigation(chapters: [String], sentencesEach: Int) -> ReaderNavigation {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []
        func paragraph(_ text: String, page: Int) {
            sentences.append(Sentence(id: sentences.count, text: text, para: paragraphs.count, page: page))
            paragraphs.append(Paragraph(id: paragraphs.count, sentenceIDs: (sentences.count - 1)..<sentences.count,
                                        page: page))
        }
        for (index, heading) in chapters.enumerated() {
            paragraph(heading, page: index + 1)
            for _ in 0..<sentencesEach {
                paragraph("It was a bright cold day in April, and the clocks were striking thirteen.", page: index + 1)
            }
        }
        let content = DocContent(title: "Test", pageCount: chapters.count, sentences: sentences,
                                 paragraphs: paragraphs, contentHash: "h")
        return ReaderNavigation(content: content, kind: .text)
    }

    /// The restore as the sheet asks for it, on the chaptered fixture with
    /// the playhead where the pick left it, a minute later, unless told.
    private func restore(_ memory: ContentsSearchMemory, for book: UUID?, playhead: Int = 40,
                         navigation: ReaderNavigation? = nil,
                         after seconds: TimeInterval = 60) -> ContentsSearchMemory.Restored? {
        memory.restore(for: book, playhead: playhead, navigation: navigation ?? Self.chaptered,
                       now: Self.picked.addingTimeInterval(seconds))
    }

    func testTheFixturesHaveAndLackChapters() {
        XCTAssertTrue(Self.chaptered.isChaptered)
        XCTAssertNotEqual(Self.chaptered.chapterIndex(containing: 40), Self.chaptered.chapterIndex(containing: 70))
        XCTAssertFalse(Self.unchaptered.isChaptered)
    }

    func testAPickedSearchComesBackForItsBookOnly() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        XCTAssertNil(restore(memory, for: book), "nothing remembered yet")

        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        XCTAssertEqual(restore(memory, for: book), .init(query: "Natasha", pickedSentence: 40))
        XCTAssertEqual(restore(memory, for: book), .init(query: "Natasha", pickedSentence: 40), "restoring keeps it")

        XCTAssertNil(restore(memory, for: UUID()), "another book's Contents opens empty")
        XCTAssertNil(memory.documentID, "and the other book's search is forgotten")
        XCTAssertNil(restore(memory, for: book))
    }

    func testABlankQueryOrForgetLeavesNothing() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "   ", pickedSentence: 3, in: book, now: Self.picked)
        XCTAssertNil(restore(memory, for: book, playhead: 3), "a blank query isn't a search")
        memory.remember(query: "whale", pickedSentence: 3, in: nil, now: Self.picked)
        XCTAssertNil(memory.documentID, "no book, nothing to remember")

        memory.remember(query: "whale", pickedSentence: 3, in: book, now: Self.picked)
        memory.forget()
        XCTAssertNil(restore(memory, for: book, playhead: 3))
        XCTAssertEqual(memory.query, "")
        XCTAssertNil(memory.lastPickedSentence)
        XCTAssertNil(memory.pickedAt)
    }

    /// The sheet forgets on any edit (B4-R6): an edited, unpicked query is
    /// not what a reopening brings back.
    func testAForgottenSearchLeavesTheNextOpeningEmpty() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        memory.forget()
        XCTAssertNil(restore(memory, for: book))
        memory.remember(query: "Pierre", pickedSentence: 52, in: book, now: Self.picked)
        XCTAssertEqual(restore(memory, for: book, playhead: 52), .init(query: "Pierre", pickedSentence: 52),
                       "the next pick remembers again")
    }

    // MARK: - R3-14: only while still stepping through it

    /// Ten minutes after the pick the search is stale: Contents opens on its
    /// list, and the search is gone for the next opening too.
    func testASearchExpiresTenMinutesAfterItsPick() {
        XCTAssertEqual(ContentsSearchMemory.window, 600)
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        XCTAssertEqual(memory.pickedAt, Self.picked, "the pick's time is kept")
        XCTAssertNotNil(restore(memory, for: book, after: 600), "still fresh at ten minutes")
        XCTAssertNil(restore(memory, for: book, after: 601), "stale past ten minutes")
        XCTAssertNil(memory.documentID, "and forgotten")
        XCTAssertNil(restore(memory, for: book, after: 60), "it doesn't come back")

        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked.addingTimeInterval(500))
        XCTAssertNotNil(restore(memory, for: book, after: 1_000), "each pick restarts the window")
    }

    /// Listening on into the next chapter leaves the hit behind; moving
    /// within its chapter doesn't.
    func testThePlayheadLeavingTheHitsChapterForgetsTheSearch() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        XCTAssertNotNil(restore(memory, for: book, playhead: 58), "still in CHAPTER I")
        XCTAssertNotNil(restore(memory, for: book, playhead: 2), "back up the same chapter")
        XCTAssertNil(restore(memory, for: book, playhead: 70), "on into CHAPTER II")
        XCTAssertNil(memory.documentID)
        XCTAssertNil(restore(memory, for: book, playhead: 40), "gone, even back at the hit")
    }

    /// In a book without chapters the playhead may wander 40 sentences
    /// either way from the pick.
    func testABookWithoutChaptersAllowsFortySentences() {
        XCTAssertEqual(ContentsSearchMemory.unchapteredReach, 40)
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Fortunato", pickedSentence: 100, in: book, now: Self.picked)
        XCTAssertNotNil(restore(memory, for: book, playhead: 140, navigation: Self.unchaptered))
        XCTAssertNotNil(restore(memory, for: book, playhead: 60, navigation: Self.unchaptered))
        XCTAssertNil(restore(memory, for: book, playhead: 141, navigation: Self.unchaptered))
        XCTAssertNil(memory.documentID)

        memory.remember(query: "Fortunato", pickedSentence: 100, in: book, now: Self.picked)
        XCTAssertNil(restore(memory, for: book, playhead: 59, navigation: Self.unchaptered), "back up too far")
    }

    /// The sheet forgets as a chapter or a place is picked (it calls
    /// `forget()`, pinned in ContentsSheetLintTests): the next opening has
    /// no search, while the hit's chapter and the window would have kept it.
    func testAChapterOrPlacePickForgets() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        memory.forget()
        XCTAssertNil(restore(memory, for: book, playhead: 41, after: 5))
    }

    /// The menu's Contents asks for the list once: the sheet skips the
    /// restore without forgetting, and the next plain opening brings the
    /// search back.
    func testAListRequestSkipsTheRestoreOnceAndKeepsTheSearch() {
        let memory = ContentsSearchMemory()
        let book = UUID()
        XCTAssertFalse(memory.consumeListRequest())
        memory.remember(query: "Natasha", pickedSentence: 40, in: book, now: Self.picked)
        memory.requestList()
        XCTAssertTrue(memory.consumeListRequest(), "this opening shows the list")
        XCTAssertFalse(memory.consumeListRequest(), "one request, one opening")
        XCTAssertEqual(memory.documentID, book, "the search is kept")
        XCTAssertEqual(restore(memory, for: book), .init(query: "Natasha", pickedSentence: 40),
                       "the next tap on the line brings it back")

        memory.requestList()
        memory.forget()
        XCTAssertTrue(memory.consumeListRequest(), "forgetting a search keeps a list request")
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
