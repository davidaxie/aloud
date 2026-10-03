import XCTest
@testable import Aloud

/// The reader screen's wiring of the book page (wave 2.2) that needs no
/// window: ⌘J is offered only while the voice is off the page; the follow
/// request the page is handed changes on Play, a jump and Follow the voice,
/// and never as the voice moves on by itself (R16); the chip slot's reach
/// over the page's foot never shrinks as chips come and go; Contents
/// closing hands the keyboard back to the text (M11); and the colophon
/// shows only at the end of this book, with its title, author and
/// listening time (R24).
///
/// The one controller is the muted rig, autoplay suppressed.
@MainActor
final class MacReaderScreenTests: XCTestCase {

    private var rig: PlaybackTestRig?

    override func tearDown() {
        // Play and the jump started the muted rig: leave no chain running.
        rig?.controller.pause(rampsOut: false)
        rig = nil
        super.tearDown()
    }

    // MARK: - Follow the voice (R16)

    /// ⌘J's action is published while the voice is above or below the page,
    /// and runs Follow the voice; with the voice in view the menu item is
    /// disabled (nil).
    func testFollowTheVoiceIsOfferedOnlyWhileTheVoiceIsOffThePage() {
        let calls = Counter()
        XCTAssertNil(MacReaderScreen.followVoiceCommand(voiceOffscreen: nil) { calls.count += 1 },
                     "the voice in view: nothing to follow")
        for direction in [ReaderFollowDirection.up, .down] {
            let command = MacReaderScreen.followVoiceCommand(voiceOffscreen: direction) { calls.count += 1 }
            XCTAssertNotNil(command, "\(direction): ⌘J follows the voice")
            command?()
        }
        XCTAssertEqual(calls.count, 2)
    }

    /// The page resumes following on any change of its follow request: a
    /// user Play, a jump (a click on a sentence) and each Follow the voice
    /// change it. The voice moving on, or a seek that doesn't play, never
    /// does: nothing re-engages following by itself.
    func testTheFollowRequestChangesOnPlayAJumpAndFollowTheVoiceOnly() {
        let rig = PlaybackTestRig(sentences: 40, autoplaySuppressed: true)
        self.rig = rig
        rig.loadDefault()
        let playback = rig.controller
        var followVoiceCount = 0
        var request = ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount)

        playback.seek(to: 5, andPlay: false)
        XCTAssertEqual(ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount), request,
                       "the voice moving on is not a request")

        playback.togglePlayPause()
        var next = ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount)
        XCTAssertNotEqual(next, request, "a user Play follows again")
        request = next
        playback.pause(rampsOut: false)

        ReaderColumnView.playFromSentence(30, on: playback)
        next = ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount)
        XCTAssertNotEqual(next, request, "a click's jump follows again")
        XCTAssertEqual(playback.currentSentence, 30, "and plays from the clicked sentence")
        request = next

        followVoiceCount &+= 1
        XCTAssertNotEqual(ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount), request,
                          "Follow the voice (the chip, ⌘J) follows again")
    }

    // MARK: - The band's foot

    /// The page measures its band above the chip slot: the tallest chip it
    /// has shown and the slot's padding, kept while the slot is empty or
    /// shows a shorter chip, so a chip coming or going never moves the
    /// band, or the page with it.
    func testTheChipReachKeepsTheTallestChipShown() {
        XCTAssertEqual(MacReaderScreen.chipReach(previous: 0, slotHeight: 0), 0, "no chip yet: nothing covered")
        let reach = MacReaderScreen.chipReach(previous: 0, slotHeight: 28)
        XCTAssertEqual(reach, 28 + Theme.Space.sm, "the chip and the slot's padding")
        XCTAssertEqual(MacReaderScreen.chipReach(previous: reach, slotHeight: 0), reach, "an empty slot keeps it")
        XCTAssertEqual(MacReaderScreen.chipReach(previous: reach, slotHeight: 22), reach, "a shorter chip keeps it")
        XCTAssertEqual(MacReaderScreen.chipReach(previous: reach, slotHeight: 34.4), 35 + Theme.Space.sm,
                       "a taller chip (a larger chrome band) raises it, rounded up")
    }

    // MARK: - Keyboard (M11)

    /// Contents going from shown to hidden (Esc, a card's jump, the toolbar
    /// button or ⌃⌘S) puts the keyboard back on the text; showing it, or
    /// nothing changing, never does.
    func testContentsClosingReturnsFocusToThePage() {
        XCTAssertTrue(MacReaderScreen.returnsFocusToPage(contentsWasShown: true, isShown: false))
        XCTAssertFalse(MacReaderScreen.returnsFocusToPage(contentsWasShown: false, isShown: true))
        XCTAssertFalse(MacReaderScreen.returnsFocusToPage(contentsWasShown: false, isShown: false))
        XCTAssertFalse(MacReaderScreen.returnsFocusToPage(contentsWasShown: true, isShown: true))
    }

    // MARK: - The colophon (R24)

    /// The colophon shows only while the listener is at the end of THIS
    /// book: nowhere earlier, and never for another book that ended.
    func testTheColophonShowsOnlyAtTheEndOfThisBook() {
        let content = PlaybackTestRig.makeContent(hash: "mac-colophon", count: 20, wordsPerSentence: 5)
        let navigation = ReaderNavigation(content: content, kind: .text)
        let document = PlaybackTestRig.makeDocument(hash: "mac-colophon", sentences: 20)

        XCTAssertNil(MacReaderScreen.colophon(for: document, content: content, navigation: navigation,
                                              isAtEnd: false, playingID: document.id, rate: 1),
                     "before the end: the · · · mark")
        XCTAssertNil(MacReaderScreen.colophon(for: document, content: content, navigation: navigation,
                                              isAtEnd: true, playingID: UUID(), rate: 1),
                     "another book's end")
        XCTAssertNil(MacReaderScreen.colophon(for: document, content: content, navigation: navigation,
                                              isAtEnd: true, playingID: nil, rate: 1),
                     "nothing loaded")
    }

    /// At the end: the title, the author, and the listening time of the
    /// whole book at the app's speed, from the loaded text's words, or
    /// from the record's word count (the card's figure) when it has one.
    func testTheColophonNamesTheBookAndItsListeningTime() throws {
        let content = PlaybackTestRig.makeContent(hash: "mac-colophon-end", count: 20, wordsPerSentence: 5)
        let navigation = ReaderNavigation(content: content, kind: .text)
        var document = PlaybackTestRig.makeDocument(hash: "mac-colophon-end", sentences: 20)
        document.author = "Ann Author"
        let words = navigation.wordsRemaining(from: 0, through: 19)
        XCTAssertGreaterThan(words, 0)

        let colophon = try XCTUnwrap(MacReaderScreen.colophon(for: document, content: content,
                                                               navigation: navigation, isAtEnd: true,
                                                               playingID: document.id, rate: 1.5))
        XCTAssertEqual(colophon, ReaderColophon(title: document.title, author: "Ann Author", words: words, rate: 1.5))
        XCTAssertEqual(colophon.title, document.title)
        XCTAssertEqual(colophon.author, "Ann Author")

        document.wordCount = 54_000
        let counted = try XCTUnwrap(MacReaderScreen.colophon(for: document, content: content,
                                                              navigation: navigation, isAtEnd: true,
                                                              playingID: document.id, rate: 1))
        XCTAssertEqual(counted, ReaderColophon(title: document.title, author: "Ann Author", words: 54_000, rate: 1),
                       "the record's word count wins")
        XCTAssertGreaterThan(counted.minutes, colophon.minutes)
    }

    // MARK: - Helpers

    private final class Counter {
        var count = 0
    }
}
