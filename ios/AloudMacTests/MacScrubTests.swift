import SwiftUI
import XCTest
@testable import Aloud

/// The Mac scrub's rules (M9, mac-ux §3.7): the pointer's x picks the
/// sentence whose start is nearest that fraction of the chapter, and the
/// preview names its first six words and its time; a click seeks there as a
/// `.scrub` jump that offers Undo jump; VoiceOver's increment lands on the
/// next chapter start, or a minute on without chapters; and the focused
/// keys step by chapter, to the chapter's ends, or by the one 15 s skip.
///
/// Silent: the muted rig, autoplay suppressed, paused throughout.
@MainActor
final class MacScrubTests: XCTestCase {

    /// Three chapters: sentences 0–1, 2–11 and 12–13. The middle one holds
    /// ten sentences of eight words each, so 10% of it is one sentence.
    private static let pages = [1, 1] + Array(repeating: 2, count: 10) + [3, 3]
    private static let wordsPerSentence = 8
    private static let trackWidth: CGFloat = 500

    private var rig: PlaybackTestRig?

    override func tearDown() {
        rig = nil
        super.tearDown()
    }

    /// The muted rig with `pages` loaded as a text book, paused at `sentence`.
    private func load(pages: [Int]?, count: Int, pausedAt sentence: Int)
        -> (rig: PlaybackTestRig, navigation: ReaderNavigation, content: DocContent) {
        let rig = PlaybackTestRig(sentences: count, autoplaySuppressed: true)
        self.rig = rig
        let content = PlaybackTestRig.makeContent(hash: "mac-scrub", count: count,
                                                  wordsPerSentence: Self.wordsPerSentence, pages: pages)
        let document = PlaybackTestRig.makeDocument(hash: "mac-scrub", sentences: count,
                                                    progressSentence: sentence)
        rig.controller.load(document: document, content: content)
        return (rig, ReaderNavigation(content: content, kind: .text), content)
    }

    private func chapterBook(pausedAt sentence: Int)
        -> (rig: PlaybackTestRig, navigation: ReaderNavigation, content: DocContent) {
        load(pages: Self.pages, count: Self.pages.count, pausedAt: sentence)
    }

    private func model(_ navigation: ReaderNavigation, _ content: DocContent,
                       playhead: Int) -> MacScrubModel {
        MacScrubModel(navigation: navigation, sentences: content.sentences, playhead: playhead, rate: 1)
    }

    // MARK: - Hover

    func testTheTrackSpansTheChapterHoldingThePlayhead() {
        let (_, navigation, content) = chapterBook(pausedAt: 5)
        XCTAssertEqual(model(navigation, content, playhead: 5).span, 2...11)
        XCTAssertEqual(model(navigation, content, playhead: 0).span, 0...1)
    }

    /// At the end of a book the fill covers the track: the last sentence has
    /// been heard, not just begun (F090). Before then it stops at the
    /// playhead's start.
    func testAFinishedBookFillsTheTrack() {
        let (_, navigation, content) = chapterBook(pausedAt: 13)
        let reading = model(navigation, content, playhead: 13)
        XCTAssertEqual(reading.span, 12...13)
        XCTAssertEqual(reading.fraction, 0.5, accuracy: 0.0001, "the last sentence's start, while it is read")
        let finished = MacScrubModel(navigation: navigation, sentences: content.sentences,
                                     playhead: 13, rate: 1, isFinished: true)
        XCTAssertEqual(finished.fraction, 1, "a finished book fills the track")
    }

    /// x is a fraction of the chapter, and the target is the sentence whose
    /// start is nearest it: 80% of ten sentences is the ninth one's start.
    func testHoverMapsXToTheNearestSentenceAtThatFractionOfTheChapter() {
        let (_, navigation, content) = chapterBook(pausedAt: 5)
        let scrub = model(navigation, content, playhead: 5)
        let width = Self.trackWidth
        XCTAssertEqual(scrub.target(atX: 0, width: width), 2, "the left end is the chapter's first sentence")
        XCTAssertEqual(scrub.target(atX: width * 0.8, width: width), 10)
        XCTAssertEqual(scrub.target(atX: width * 0.22, width: width), 4, "22% is nearer the 20% start than the 30%")
        XCTAssertEqual(scrub.target(atX: width * 0.27, width: width), 5, "27% is nearer the 30% start")
        XCTAssertEqual(scrub.target(atX: width, width: width), 11, "the right end is the last sentence's start")
        XCTAssertEqual(scrub.target(atX: -40, width: width), 2, "past the left end clamps")
        XCTAssertEqual(scrub.target(atX: width + 40, width: width), 11, "past the right end clamps")
        for x in stride(from: CGFloat(0), through: width, by: 25) {
            XCTAssertTrue((2...11).contains(scrub.target(atX: x, width: width)), "x \(x) leaves the chapter")
        }
    }

    /// The preview is the target's first six words and its time into the
    /// chapter: never a sentence number.
    func testThePreviewShowsTheFirstSixWordsAndTheTimeIntoTheChapter() {
        let (_, navigation, content) = chapterBook(pausedAt: 5)
        let scrub = model(navigation, content, playhead: 5)
        let target = scrub.target(atX: Self.trackWidth * 0.8, width: Self.trackWidth)
        XCTAssertEqual(scrub.previewWords(of: target), "Line10 word word word word word\u{2026}")
        // Eight sentences of eight words before it, at 165 words a minute.
        let seconds = Double(8 * Self.wordsPerSentence) / LibraryDocument.spokenWordsPerMinute * 60
        XCTAssertEqual(scrub.previewTime(of: target), ListeningEstimate.clock(seconds: seconds))
        XCTAssertEqual(scrub.preview(of: target),
                       "Line10 word word word word word\u{2026} \u{00B7} \(ListeningEstimate.clock(seconds: seconds))")
    }

    // MARK: - Click

    func testAClickAt80PercentSeeksThereAndOffersUndoJump() async {
        let (rig, navigation, _) = chapterBook(pausedAt: 3)
        let controller = rig.controller
        XCTAssertNil(controller.undoableJump)

        MacScrubModel.click(controller, navigation: navigation, atX: Self.trackWidth * 0.8, width: Self.trackWidth)

        let landed = await rig.waitUntil { controller.currentSentence == 10 }
        XCTAssertTrue(landed, "a click at 80% of the chapter lands on its nearest sentence start")
        XCTAssertEqual(controller.undoableJump?.fromSentence, 3)
        XCTAssertEqual(controller.undoableJump?.toSentence, 10)
        XCTAssertFalse(controller.isActive, "a scrub click keeps the pause")

        // ⌘Z and the chip run the same undo.
        controller.undoJump()
        let restored = await rig.waitUntil { controller.currentSentence == 3 }
        XCTAssertTrue(restored, "Undo jump restores the sentence")
        XCTAssertFalse(controller.isActive, "and the paused state")
        XCTAssertNil(controller.undoableJump)
    }

    func testAClickOnThePlayheadOffersNoUndo() async {
        let (rig, navigation, _) = chapterBook(pausedAt: 10)
        MacScrubModel.click(rig.controller, navigation: navigation, atX: Self.trackWidth * 0.8, width: Self.trackWidth)
        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertNil(rig.controller.undoableJump, "a seek to where the voice already is moves nothing")
    }

    // MARK: - VoiceOver adjust

    func testIncrementLandsOnTheNextChapterStart() async {
        let (rig, navigation, _) = chapterBook(pausedAt: 3)
        XCTAssertTrue(MacScrubModel.adjust(rig.controller, navigation: navigation, forward: true))
        let landed = await rig.waitUntil { rig.controller.currentSentence == 12 }
        XCTAssertTrue(landed, "one increment is the next chapter's first sentence")
        XCTAssertNotNil(rig.controller.undoableJump, "an adjust is a scrub jump, so it offers Undo")

        // Decrement from a chapter's start goes to the previous chapter's.
        XCTAssertTrue(MacScrubModel.adjust(rig.controller, navigation: navigation, forward: false))
        let back = await rig.waitUntil { rig.controller.currentSentence == 2 }
        XCTAssertTrue(back)
    }

    func testIncrementPastTheLastChapterDoesNothing() {
        let (rig, navigation, _) = chapterBook(pausedAt: 12)
        XCTAssertFalse(MacScrubModel.adjust(rig.controller, navigation: navigation, forward: true))
        XCTAssertEqual(rig.controller.currentSentence, 12)
    }

    /// Without chapters the scrub spans the book, and one increment is a
    /// minute on at the current speed: the landing sentence starts within
    /// one sentence's time of 60 s past the playhead.
    func testIncrementWithoutChaptersMovesOneMinute() async {
        let count = 80
        let (rig, navigation, content) = load(pages: nil, count: count, pausedAt: 3)
        XCTAssertFalse(navigation.hasChapterList)
        XCTAssertEqual(model(navigation, content, playhead: 3).span, 0...(count - 1))

        XCTAssertTrue(MacScrubModel.adjust(rig.controller, navigation: navigation, forward: true))
        let moved = await rig.waitUntil { rig.controller.currentSentence > 3 }
        XCTAssertTrue(moved)
        let target = rig.controller.currentSentence
        let span = 0...(count - 1)
        let seconds = navigation.secondsIntoSpan(of: target, in: span, rate: 1)
            - navigation.secondsIntoSpan(of: 3, in: span, rate: 1)
        let sentenceSeconds = Double(Self.wordsPerSentence) / LibraryDocument.spokenWordsPerMinute * 60
        XCTAssertEqual(seconds, 60, accuracy: sentenceSeconds, "+1 min, to the nearest sentence")
    }

    // MARK: - Keys

    func testFocusedKeysStepByChapterAndToTheChaptersEnds() async {
        let (rig, navigation, _) = chapterBook(pausedAt: 5)
        let controller = rig.controller

        XCTAssertTrue(MacScrubModel.perform(.end, on: controller, navigation: navigation))
        var landed = await rig.waitUntil { controller.currentSentence == 11 }
        XCTAssertTrue(landed, "End is the chapter's last sentence")

        XCTAssertTrue(MacScrubModel.perform(.home, on: controller, navigation: navigation))
        landed = await rig.waitUntil { controller.currentSentence == 2 }
        XCTAssertTrue(landed, "Home is the chapter's first sentence")

        XCTAssertTrue(MacScrubModel.perform(.pageDown, on: controller, navigation: navigation))
        landed = await rig.waitUntil { controller.currentSentence == 12 }
        XCTAssertTrue(landed, "PageDown is the next chapter's start")

        XCTAssertTrue(MacScrubModel.perform(.pageUp, on: controller, navigation: navigation))
        landed = await rig.waitUntil { controller.currentSentence == 2 }
        XCTAssertTrue(landed, "PageUp from a chapter's start is the previous chapter's")
        XCTAssertFalse(controller.isActive, "no key starts playback")
    }

    /// ← and → are the one skip (R14): the same landing as `skip(seconds:)`.
    func testArrowsAreTheOneFifteenSecondSkip() {
        let (rig, navigation, content) = chapterBook(pausedAt: 5)
        let controller = rig.controller
        let expected = PlaybackController.skipTarget(
            from: 5, seconds: PlaybackController.skipInterval, sentenceCount: content.sentences.count,
            wordsPerMinute: LibraryDocument.spokenWordsPerMinute * controller.rate,
            words: { _ in Self.wordsPerSentence })
        XCTAssertTrue(MacScrubModel.perform(.right, on: controller, navigation: navigation))
        XCTAssertEqual(controller.currentSentence, expected)
        XCTAssertTrue(MacScrubModel.perform(.left, on: controller, navigation: navigation))
        XCTAssertLessThan(controller.currentSentence, expected)
    }

    func testTheScrubAnswersExactlyItsSixKeys() {
        XCTAssertEqual(MacScrubModel.keys,
                       [.leftArrow, .rightArrow, .pageUp, .pageDown, .home, .end])
        for key in MacScrubModel.Key.allCases {
            XCTAssertEqual(MacScrubModel.Key(key.equivalent), key)
        }
        XCTAssertNil(MacScrubModel.Key(.space), "Space falls through to Play/Pause")
    }
}
