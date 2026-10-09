import XCTest
import SwiftUI
import UIKit
@testable import Aloud

/// R15 tap-to-play and R16 calm follow on a real reading column: a 390×800
/// `ReaderUITextView` and its coordinator, with no window, no controller and
/// no audio. Drags are simulated through the scroll-view delegate calls.
/// The tap's haptic is checked on a muted `PlaybackTestRig`.
@MainActor
final class ReaderFollowCoordinatorTests: XCTestCase {

    private final class Taps {
        var sentences: [Int] = []
    }

    private final class Arrow {
        var direction: ReaderFollowDirection?
    }

    /// `count` one-line sentences, one paragraph each: a short line fits
    /// the 342pt measure at 19pt, so every advance moves down one line.
    /// From `chapterAt` on they sit on page 2: a text book's second chapter.
    private func lines(_ count: Int, chapterAt: Int? = nil) -> DocContent {
        let page = { (id: Int) in chapterAt.map { id >= $0 ? 2 : 1 } ?? 1 }
        let sentences = (0..<count).map { Sentence(id: $0, text: "Line \($0) is short.", para: $0, page: page($0)) }
        let paragraphs = (0..<count).map { Paragraph(id: $0, sentenceIDs: $0..<($0 + 1), page: page($0)) }
        return DocContent(title: "Lines", pageCount: chapterAt == nil ? 1 : 2, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "follow-\(count)-\(chapterAt ?? 0)")
    }

    private func makeColumn(count: Int = 160, content custom: DocContent? = nil, chapterAt: Int? = nil,
                            obscuredBottom: CGFloat = 0, reduceMotion: Bool = false, taps: Taps = Taps(), arrow: Arrow = Arrow())
        throws -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let content = custom ?? lines(count, chapterAt: chapterAt)
        // A chaptered text book gets the Chapters rotor.
        let navigation = chapterAt.map { _ in ReaderNavigation(content: content, kind: .text) }
        let parent = ReaderTextView(content: content, isChapterBook: chapterAt != nil, navigation: navigation,
                                    fontSize: 19, activeSentence: 0, activeWord: -1,
                                    obscuredBottom: obscuredBottom,
                                    voiceOffscreen: Binding(get: { arrow.direction },
                                                            set: { arrow.direction = $0 }),
                                    textUnderTopBar: .constant(false),
                                    onTapSentence: { taps.sentences.append($0) })
        let coordinator = ReaderTextView.Coordinator(parent: parent)
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.install(on: textView)
        coordinator.reduceMotion = { reduceMotion }
        coordinator.rebuild(content: content, fontSize: 19)
        textView.layoutIfNeeded()
        coordinator.setActiveSentence(0, scroll: false)
        textView.layoutIfNeeded()
        guard textView.contentSize.height > 2 * textView.bounds.height else {
            throw XCTSkip("This host doesn't lay out a text view outside a window")
        }
        return (coordinator, textView)
    }

    /// Measured from the layout as it stands, never the cached rect: the
    /// cache would only replay the numbers the scroll was aimed with.
    private func isInBand(_ coordinator: ReaderTextView.Coordinator) -> Bool {
        guard let rect = coordinator.measureActiveSentenceRect(), let viewport = coordinator.viewport() else { return false }
        return FollowBand.contains(rect, in: viewport)
    }

    /// Lets the main-actor hops that publish the binding run.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// The layout passes the run loop runs after a scroll, which finish a
    /// placement still being verified on fresh geometry.
    private func settleLayout(_ textView: UITextView) {
        for _ in 0..<3 {
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
        }
    }

    /// Layout passes as the run loop runs them: only when something asked
    /// for one. Unlike `settleLayout`, never forces a pass, so a placement
    /// that stops asking is left where it is.
    private func runLayoutPasses(_ textView: UITextView) {
        for _ in 0..<6 { textView.layoutIfNeeded() }
    }

    /// A drag on the scroll indicator that ends deep in a long book, in
    /// text TextKit has so far laid out only at estimated heights.
    private func dragIndicator(_ coordinator: ReaderTextView.Coordinator, _ textView: UITextView, to y: CGFloat) {
        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        runLayoutPasses(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
    }

    /// A tap at `fraction` of the visible height, then what `updateUIView`
    /// does with the jump it starts: the tapped sentence becomes the
    /// playhead's. Returns the tapped sentence and its frame before
    /// following resumes.
    private func tap(at fraction: CGFloat, _ coordinator: ReaderTextView.Coordinator, _ textView: UITextView,
                     _ taps: Taps) throws -> (id: Int, frame: CGRect) {
        let viewport = try XCTUnwrap(coordinator.viewport())
        coordinator.handleTap(at: CGPoint(x: textView.textContainerInset.left + 8,
                                          y: viewport.minY + fraction * viewport.height), isDecelerating: false)
        let id = try XCTUnwrap(taps.sentences.last)
        coordinator.setActiveSentence(id, scroll: false)
        return (id, try XCTUnwrap(coordinator.measureActiveSentenceRect()))
    }

    /// The first line of the first screen, in the text view's coordinates.
    private func firstLine(_ textView: UITextView) -> CGPoint {
        CGPoint(x: textView.textContainerInset.left + 8, y: textView.textContainerInset.top + 8)
    }

    /// Sentence 0's frame and the line pitch, measured on the first screen
    /// (laid out for real), from which any line's real frame follows.
    private func lineGeometry(_ coordinator: ReaderTextView.Coordinator) throws -> (first: CGRect, pitch: CGFloat) {
        coordinator.setActiveSentence(1, scroll: false)
        let second = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        coordinator.setActiveSentence(0, scroll: false)
        let first = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        let pitch = second.minY - first.minY
        XCTAssertGreaterThan(pitch, 0)
        return (first, pitch)
    }

    /// Sentence `id`'s frame where it is laid out now. It becomes the
    /// playhead's, which moves nothing while the column isn't following.
    private func frame(ofSentence id: Int, _ coordinator: ReaderTextView.Coordinator) throws -> CGRect {
        coordinator.setActiveSentence(id, scroll: false)
        return try XCTUnwrap(coordinator.measureActiveSentenceRect())
    }

    private func step(_ rotor: UIAccessibilityCustomRotor,
                      _ direction: UIAccessibilityCustomRotor.Direction = .next)
        -> UIAccessibilityCustomRotorItemResult? {
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = direction
        return rotor.itemSearchBlock(predicate)
    }

    // MARK: - Tap (R15)

    func testATapOnMovingTextOnlyStopsItAndAStillTapPlays() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)

        coordinator.handleTap(at: firstLine(textView), isDecelerating: true)
        XCTAssertEqual(taps.sentences, [], "a tap on decelerating text only stops the scroll")

        coordinator.handleTap(at: firstLine(textView), isDecelerating: false)
        XCTAssertEqual(taps.sentences, [0], "a tap on still text plays from the tapped sentence")
    }

    /// Play (or the Follow chip) while a flick still coasts takes the
    /// scroll back. The coast is over, so the next tap on still text plays
    /// instead of being read as stopping a scroll.
    func testFollowingDuringAFlickEndsItSoTheNextStillTapPlays() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(CGPoint(x: 0, y: 3_000), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: true)
        XCTAssertEqual(coordinator.voiceOffscreen, .up)

        coordinator.resumeFollowing()
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.5, "back on the voice")

        coordinator.touchLanded()
        coordinator.tapEnded(at: firstLine(textView))
        XCTAssertEqual(taps.sentences, [0], "a tap on still text plays (R15)")
    }

    /// A touch that stops a glide short is the reader taking the scroll:
    /// with the voice still off screen, the Follow chip comes back.
    func testATouchThatStopsAGlideShortBringsBackTheFollowChip() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        coordinator.scrollViewWillBeginDragging(textView)
        _ = try XCTUnwrap((1..<160).first { sentence in
            coordinator.setActiveSentence(sentence, scroll: true)
            return coordinator.voiceOffscreen == .down
        }, "a sentence just below the first screen")

        coordinator.resumeFollowing()   // the Follow chip
        XCTAssertTrue(coordinator.isGliding, "within one viewport the voice glides")
        // The touch lands as the glide sets off, before the text has moved
        // on screen. A view outside a window has no presentation layer to
        // read that from, so put the offset back by hand.
        textView.contentOffset = .zero

        coordinator.touchLanded()
        XCTAssertFalse(coordinator.isGliding)
        XCTAssertFalse(coordinator.isFollowing, "the glide stopped with the voice off screen")
        XCTAssertEqual(coordinator.voiceOffscreen, .down, "the Follow chip offers the way back")

        coordinator.tapEnded(at: firstLine(textView))
        XCTAssertEqual(taps.sentences, [], "a tap on moving text only stops it")
        XCTAssertFalse(coordinator.isFollowing)
        XCTAssertEqual(coordinator.voiceOffscreen, .down)
    }

    /// The play haptic answers a tap that starts the book. A voice
    /// audition is active, but it is a sample over the listener's pause
    /// (R8): a tap over it starts the book, so it ticks. A tap while the
    /// book reads on doesn't.
    func testATapOverAnAuditionStartsTheBookWithThePlayHaptic() {
        let haptics = TransportHaptics.shared
        defer { haptics.resetLog() }

        let paused = PlaybackTestRig(sentences: 40)
        paused.loadDefault(at: 10)
        haptics.resetLog()
        ReaderScreen.playFromSentence(12, on: paused.controller)
        XCTAssertEqual(haptics.log, [.play], "a tap on a paused book starts it")
        XCTAssertTrue(paused.controller.isActive)

        haptics.resetLog()
        ReaderScreen.playFromSentence(20, on: paused.controller)
        XCTAssertEqual(haptics.log, [], "the book was already reading")
        XCTAssertEqual(paused.controller.currentSentence, 20)

        let auditioning = PlaybackTestRig(sentences: 40)
        auditioning.loadDefault(at: 10)
        auditioning.controller.selectVoice(PlaybackTestRig.voiceB)
        XCTAssertTrue(auditioning.controller.isActive, "the audition speaks")
        let plays = auditioning.controller.userPlayAction
        haptics.resetLog()
        ReaderScreen.playFromSentence(12, on: auditioning.controller)
        XCTAssertEqual(haptics.log, [.play], "the tap started the book over the sample")
        XCTAssertEqual(auditioning.controller.userPlayAction, plays + 1)
        XCTAssertEqual(auditioning.controller.currentSentence, 12)
    }

    // MARK: - Calm follow (R16)

    /// Play within a moment of letting go of a pull past the top: following
    /// stops the bounce, and must not leave bare paper above the first line
    /// (stopped mid-bounce, UIKit skips its spring back into range).
    func testFollowingDuringABouncePinsTheTextBackInRange() throws {
        let (coordinator, textView) = try makeColumn()
        let first = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        let viewport = try XCTUnwrap(coordinator.viewport())
        // Pulled down far enough that the voice sits on the landing line.
        let pulled = first.minY - (viewport.minY + FollowBand.landing * viewport.height)
        XCTAssertLessThan(pulled, -textView.adjustedContentInset.top - 50, "past the top")

        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(CGPoint(x: 0, y: pulled), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: true)
        XCTAssertTrue(isInBand(coordinator), "following has nothing to scroll")

        coordinator.isCoasting = { _ in true }   // springing back
        coordinator.resumeFollowing()
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertEqual(textView.contentOffset.y, -textView.adjustedContentInset.top, accuracy: 0.5,
                       "at rest on the first line, no bare paper above it")
    }

    func testAfterTheUserScrollsTheTextNeverFollowsByItself() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertTrue(coordinator.isFollowing, "a drag that ends with the voice in view follows again")

        // Away from the voice, then a long stretch of playback.
        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(CGPoint(x: 0, y: 3_000), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertFalse(coordinator.isFollowing)
        let scrolls = coordinator.programmaticScrollCount
        let offset = textView.contentOffset
        for sentence in 1...100 {
            coordinator.setActiveSentence(sentence, scroll: true)
        }
        settle()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "no idle re-follow, ever")
        XCTAssertEqual(textView.contentOffset, offset)
        XCTAssertFalse(coordinator.isFollowing)
    }

    func testResumingScrollsOnlyWhenTheVoiceIsOutsideTheBand() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(80, scroll: true)
        XCTAssertFalse(coordinator.isFollowing)
        XCTAssertFalse(isInBand(coordinator), "sentence 80 is far below the first screen")

        let scrolls = coordinator.programmaticScrollCount
        coordinator.resumeFollowing()
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1)
        // As in the app, the layout passes after the jump finish verifying it.
        settleLayout(textView)
        XCTAssertTrue(isInBand(coordinator), "the voice lands in the band")
        XCTAssertNil(coordinator.voiceOffscreen)

        let offset = textView.contentOffset
        coordinator.resumeFollowing()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "a sentence already in the band stays put")
        XCTAssertEqual(textView.contentOffset, offset)
    }

    /// Drawing a far sentence's highlight lays it out alone at TextKit's
    /// ESTIMATED height. A jump must aim at its real frame: on uniform
    /// lines, exactly 80 line pitches below sentence 0.
    func testADeepJumpAimsAtTheSentencesRealFrame() throws {
        let (coordinator, textView) = try makeColumn()
        let (first, pitch) = try lineGeometry(coordinator)

        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(80, scroll: true)
        coordinator.resumeFollowing()

        // No layout pass yet: the jump itself must already be right.
        let landed = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertEqual(landed.minY, first.minY + 80 * pitch, accuracy: 1, "its real frame, not the estimate")
        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "on the landing line")
    }

    /// Playback read on while the reader looked elsewhere: each highlight
    /// laid its sentence out alone at an estimate, right after the one
    /// before. The fragment above the target is then already placed too,
    /// and a layout pass that stops at the target leaves it where it was.
    func testADeepJumpAfterPlaybackReadOnOffScreenAimsAtTheRealFrame() throws {
        let (coordinator, textView) = try makeColumn()
        let (first, pitch) = try lineGeometry(coordinator)

        coordinator.scrollViewWillBeginDragging(textView)
        for sentence in 76...80 { coordinator.setActiveSentence(sentence, scroll: true) }
        XCTAssertFalse(coordinator.isFollowing)
        coordinator.resumeFollowing()

        let landed = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertEqual(landed.minY, first.minY + 80 * pitch, accuracy: 1, "its real frame, not the estimate")
        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "on the landing line")
    }

    /// A Contents pick deep into a long book. The layout pass that confirms
    /// the sentence's frame grows the text by thousands of points (real
    /// line heights replacing estimates), but UIKit refreshes contentSize
    /// only later: a landing clamped to it stopped about 5,000 pt short,
    /// and the next layout pass took the clamped offset for placed.
    func testADeepJumpIntoTheTailOfALongBookLandsOnTheLandingLineAndStays() throws {
        let (coordinator, textView) = try makeColumn(count: 1_200)
        let (first, pitch) = try lineGeometry(coordinator)

        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(1_100, scroll: true)
        coordinator.resumeFollowing()

        var landed = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertEqual(landed.minY, first.minY + 1_100 * pitch, accuracy: 1, "its real frame")
        var viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "the jump itself lands on the landing line")

        runLayoutPasses(textView)
        landed = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "and stays there")
        XCTAssertNil(coordinator.voiceOffscreen)
    }

    /// The last sentence lands on the landing line, or as near as the real
    /// end of the text lets it: not at the end of the estimated text,
    /// thousands of points above it.
    func testAJumpToTheLastSentenceRestsAtTheRealEndOfTheText() throws {
        let (coordinator, textView) = try makeColumn(count: 1_200)
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(1_199, scroll: true)
        coordinator.resumeFollowing()
        runLayoutPasses(textView)

        XCTAssertTrue(isInBand(coordinator), "the last sentence is in the band")
        let rect = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        let viewport = try XCTUnwrap(coordinator.viewport())
        let onLandingLine = textView.contentOffset.y + rect.minY - (viewport.minY + FollowBand.landing * viewport.height)
        // contentSize has caught up with the text by now.
        let end = textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height
        XCTAssertEqual(textView.contentOffset.y, min(onLandingLine, end), accuracy: 1,
                       "on the landing line, or at rest at the real end of the text")
    }

    /// A jump without motion keeps checking its landing past the text
    /// view's own layout pass: UIKit lays out the lines newly on screen and
    /// refreshes the content size only after it, which can still move the
    /// landing. A change then, without a drag, is put back as part of the
    /// same jump, not as another follow scroll.
    func testADeepJumpKeepsCheckingItsLandingAfterTheTextViewsOwnPass() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(80, scroll: true)
        coordinator.resumeFollowing()
        let placed = textView.contentOffset
        let scrolls = coordinator.programmaticScrollCount
        coordinator.handleLayout()   // the text view's own pass, finding it placed

        // What UIKit's own layout does next moves the text under it.
        textView.setContentOffset(CGPoint(x: 0, y: placed.y + 400), animated: false)
        runLayoutPasses(textView)
        XCTAssertEqual(textView.contentOffset.y, placed.y, accuracy: 1, "back on the landing line")
        XCTAssertTrue(isInBand(coordinator))
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a correction of the jump, uncounted")
    }

    // MARK: - Taps in text not laid out yet (R15, R16)

    /// Dragged by the scroll indicator deep into a long book, a tap on a
    /// line in the band plays it where it is. Laying the book out from its
    /// start under a still offset moved the line from TextKit's estimate
    /// to its real y, and it jumped to the landing line.
    func testATapInTextNotLaidOutYetLeavesTheTappedLineWhereItIs() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(count: 600, taps: taps)
        let (first, pitch) = try lineGeometry(coordinator)
        dragIndicator(coordinator, textView, to: 12_000)
        XCTAssertFalse(coordinator.isFollowing)

        let tapped = try tap(at: 0.5, coordinator, textView, taps)
        XCTAssertTrue(isInBand(coordinator))
        XCTAssertGreaterThan(abs(first.minY + CGFloat(tapped.id) * pitch - tapped.frame.minY), 100,
                             "TextKit laid this text out at estimated heights")
        let onScreen = tapped.frame.minY - textView.contentOffset.y
        let scrolls = coordinator.programmaticScrollCount

        coordinator.resumeFollowing()
        runLayoutPasses(textView)
        let after = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertEqual(after.minY - textView.contentOffset.y, onScreen, accuracy: 0.5,
                       "the tapped line stays where the reader saw it")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a sentence already in the band stays put")
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertNil(coordinator.voiceOffscreen)
    }

    /// The same, for a line tapped below the band: it glides up to the
    /// landing line from where it is drawn. Laying the book out first put
    /// it thousands of points away, so the glide became a jump.
    func testATapBelowTheBandInTextNotLaidOutYetGlidesFromWhereItIsDrawn() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(count: 600, taps: taps)
        dragIndicator(coordinator, textView, to: 12_000)

        let tapped = try tap(at: 0.8, coordinator, textView, taps)
        XCTAssertFalse(isInBand(coordinator), "below the band, still on screen")

        coordinator.resumeFollowing()
        XCTAssertTrue(coordinator.isGliding, "within one screen the line glides")
        // Outside a window the glide's end is already the model offset.
        let landed = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertEqual(landed.minY, tapped.frame.minY, accuracy: 0.5, "measured where it is drawn")
        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "the glide ends on the landing line")
    }

    // MARK: - VoiceOver rotor reveal (R12a)

    /// A Chapters rotor step to a far chapter is placed like a deep jump:
    /// its first sentence lands on its real frame, and later layout passes
    /// keep checking the landing until it holds in the band.
    func testARotorStepToAFarChapterLandsOnTheRealFrameAndHolds() throws {
        let (coordinator, textView) = try makeColumn(chapterAt: 80)
        try withExtendedLifetime(coordinator) {   // the rotors hold it weakly
            let (first, pitch) = try lineGeometry(coordinator)
            let chapters = try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == "Chapters" })
            XCTAssertNotNil(step(chapters))
            XCTAssertEqual(coordinator.accessibilitySentence, 0, "the chapter holding the playhead")
            XCTAssertNotNil(step(chapters))
            XCTAssertEqual(coordinator.accessibilitySentence, 80)
            XCTAssertFalse(coordinator.isFollowing, "browsing stops following")

            // No layout pass yet: the reveal itself must already be right.
            let landed = try frame(ofSentence: 80, coordinator)
            XCTAssertEqual(landed.minY, first.minY + 80 * pitch, accuracy: 1, "its real frame, not the estimate")
            let viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                           "on the landing line")

            // The text moves under the stop without a drag (VoiceOver's own
            // scroll into view, insets settling): the next passes re-place it.
            let placed = textView.contentOffset
            textView.setContentOffset(CGPoint(x: 0, y: placed.y + 400), animated: false)
            XCTAssertFalse(isInBand(coordinator))
            settleLayout(textView)
            XCTAssertTrue(isInBand(coordinator), "the stop holds in the band")
            XCTAssertEqual(textView.contentOffset.y, placed.y, accuracy: 1)
        }
    }

    /// The same deep into a long book. The landing was clamped to a content
    /// size UIKit hadn't refreshed yet, the check then took the clamped
    /// offset for placed, and the stop stayed about 5,000 pt below the
    /// screen.
    func testARotorStepDeepIntoALongBookLandsOnScreenAndStays() throws {
        let (coordinator, textView) = try makeColumn(count: 1_200, chapterAt: 1_100)
        try withExtendedLifetime(coordinator) {
            let (first, pitch) = try lineGeometry(coordinator)
            let chapters = try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == "Chapters" })
            XCTAssertNotNil(step(chapters))
            XCTAssertNotNil(step(chapters))
            XCTAssertEqual(coordinator.accessibilitySentence, 1_100)

            var landed = try frame(ofSentence: 1_100, coordinator)
            XCTAssertEqual(landed.minY, first.minY + 1_100 * pitch, accuracy: 1, "its real frame")
            var viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                           "on the landing line")

            runLayoutPasses(textView)
            landed = try frame(ofSentence: 1_100, coordinator)
            viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertEqual(landed.minY, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                           "and it stays there")
        }
    }

    /// A drag ends a rotor stop's landing check: the column never fights
    /// the reader's own scroll.
    func testADragEndsARotorStopsLandingCheck() throws {
        let (coordinator, textView) = try makeColumn(chapterAt: 80)
        try withExtendedLifetime(coordinator) {
            let chapters = try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == "Chapters" })
            XCTAssertNotNil(step(chapters))
            XCTAssertNotNil(step(chapters))
            XCTAssertGreaterThan(textView.contentOffset.y, 1_000, "revealed the far chapter")

            coordinator.scrollViewWillBeginDragging(textView)
            textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
            settleLayout(textView)
            XCTAssertEqual(textView.contentOffset.y, 500, accuracy: 0.5, "left where the reader put it")
        }
    }

    /// The landing check ends after a bounded number of layout passes, so
    /// the column never fights an offset that keeps moving.
    func testALandingCheckEndsAfterABoundedNumberOfPasses() throws {
        let (coordinator, textView) = try makeColumn(chapterAt: 80)
        try withExtendedLifetime(coordinator) {
            let chapters = try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == "Chapters" })
            XCTAssertNotNil(step(chapters))
            XCTAssertNotNil(step(chapters))
            let placed = textView.contentOffset
            for _ in 0..<40 {
                textView.setContentOffset(CGPoint(x: 0, y: placed.y + 400), animated: false)
                textView.layoutIfNeeded()
            }
            textView.setContentOffset(CGPoint(x: 0, y: placed.y + 400), animated: false)
            runLayoutPasses(textView)
            XCTAssertEqual(textView.contentOffset.y, placed.y + 400, accuracy: 0.5, "the check has ended")
        }
    }

    func testOneLineSentencesUnderReduceMotionStayWithinTheBudget() throws {
        let (coordinator, _) = try makeColumn(reduceMotion: true)
        let scrolls = coordinator.programmaticScrollCount
        for sentence in 0..<100 {
            coordinator.setActiveSentence(sentence, scroll: true)
            let rect = try XCTUnwrap(coordinator.activeSentenceRect())
            let viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertNil(FollowBand.direction(of: rect, in: viewport), "sentence \(sentence) stays on screen")
        }
        let measured = coordinator.programmaticScrollCount - scrolls
        print("ReaderFollowCoordinatorTests: \(measured) follow scrolls per 100 one-line sentences")
        XCTAssertLessThanOrEqual(measured, 15, "the PRD's budget; the old follow scrolled ~100 times")
        XCTAssertGreaterThan(measured, 0, "100 lines don't fit one screen")
    }

    func testAUserScrollThatEndsWithTheVoiceInViewFollowsAgain() throws {
        let arrow = Arrow()
        let (coordinator, textView) = try makeColumn(arrow: arrow)
        coordinator.setActiveSentence(5, scroll: true)

        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(CGPoint(x: 0, y: 3_000), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertFalse(coordinator.isFollowing, "the voice is off screen")
        XCTAssertEqual(coordinator.voiceOffscreen, .up, "the arrow points toward the voice")
        settle()
        XCTAssertEqual(arrow.direction, .up, "the Follow chip's binding hears it")

        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(.zero, animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: true)
        XCTAssertFalse(coordinator.isFollowing, "still decelerating")
        coordinator.scrollViewDidEndDecelerating(textView)
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertNil(coordinator.voiceOffscreen)
        settle()
        XCTAssertNil(arrow.direction)
    }

    func testTheArrowPointsDownWhenTheVoiceIsBelow() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(120, scroll: true)
        XCTAssertEqual(coordinator.voiceOffscreen, .down)
    }

    /// A three-finger scroll that moves the text is the user taking over.
    /// Driven through the view's hook: a column outside a window can't
    /// scroll by accessibility in this host (`...MovesNothingKeepsFollowing`
    /// covers that case).
    func testAVoiceOverScrollStopsFollowing() throws {
        let (coordinator, textView) = try makeColumn()
        XCTAssertTrue(coordinator.isFollowing)
        textView.onAccessibilityScroll?()
        XCTAssertFalse(coordinator.isFollowing)
    }

    func testTheBandSitsAboveThePlayerBar() throws {
        let (coordinator, _) = try makeColumn(obscuredBottom: 300)
        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(viewport.height, 800 - 300, accuracy: 0.5)
    }

    /// A three-finger scroll that can't move the text (up at its top, or
    /// sideways on this vertical column) gets no scroll-end callback: it
    /// must not stop following while the voice is still in view.
    func testAVoiceOverScrollThatMovesNothingKeepsFollowing() throws {
        let (coordinator, textView) = try makeColumn()
        let before = textView.contentOffset
        for direction: UIAccessibilityScrollDirection in [.up, .left, .right] {
            guard !textView.accessibilityScroll(direction) else { continue }
            XCTAssertEqual(textView.contentOffset, before, "\(direction.rawValue) moved nothing")
            XCTAssertTrue(coordinator.isFollowing, "\(direction.rawValue) took nothing over")
            XCTAssertNil(coordinator.voiceOffscreen)
        }
    }

    /// R16 at a large text size on a short screen: a sentence taller than
    /// the band parks its top on the landing line, then following tracks
    /// the underlined word, so the end of a long sentence is never read
    /// below the band (under the player bar).
    func testASentenceTallerThanTheBandKeepsItsSpokenWordInTheBand() throws {
        let words = (0..<240).map { "word\($0)" }
        var sentences = (0..<40).map { Sentence(id: $0, text: "Line \($0) is short.", para: $0, page: 1) }
        sentences[20] = Sentence(id: 20, text: words.joined(separator: " ") + ".", para: 20, page: 1)
        let paragraphs = (0..<40).map { Paragraph(id: $0, sentenceIDs: $0..<($0 + 1), page: 1) }
        let content = DocContent(title: "Long", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                                 contentHash: "follow-long-sentence")
        let (coordinator, textView) = try makeColumn(content: content)

        coordinator.setActiveSentence(20, scroll: true)
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        var viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertTrue(FollowBand.isTall(sentence, in: viewport), "the sentence can't fit in the band")
        let startY = textView.contentOffset.y

        // Tokens alternate word and space: word n is token 2n.
        for word in words.indices {
            coordinator.setActiveWord(2 * word, follows: true)
            let rect = try XCTUnwrap(coordinator.activeWordRect())
            viewport = try XCTUnwrap(coordinator.viewport())
            XCTAssertLessThanOrEqual(rect.maxY, viewport.minY + FollowBand.bottom * viewport.height + 0.5,
                                     "word \(word) is read in the band")
            XCTAssertGreaterThanOrEqual(rect.minY, viewport.minY + FollowBand.top * viewport.height - 0.5,
                                        "word \(word) is read in the band")
        }
        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertGreaterThan(textView.contentOffset.y, startY, "the text moved up with the voice")

        // A relayout re-checks the band without pulling the text back up
        // to the sentence's top.
        settleLayout(textView)
        coordinator.followIfNeeded(animated: false)
        let last = try XCTUnwrap(coordinator.activeWordRect())
        viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertTrue(FollowBand.contains(last, in: viewport), "the last word stays in the band")
    }

    // MARK: Word ticks and tall sentences (audit loop 2: G002, G003, G006)

    /// 40 sentences, sentence 20 240 words long: taller than the band at
    /// 19pt on this column. Its tokens alternate word and space, so word n
    /// is token 2n.
    private func makeTallColumn(arrow: Arrow = Arrow()) throws
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let words = (0..<240).map { "word\($0)" }
        var sentences = (0..<40).map { Sentence(id: $0, text: "Line \($0) is short.", para: $0, page: 1) }
        sentences[20] = Sentence(id: 20, text: words.joined(separator: " ") + ".", para: 20, page: 1)
        let paragraphs = (0..<40).map { Paragraph(id: $0, sentenceIDs: $0..<($0 + 1), page: 1) }
        let content = DocContent(title: "Long", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                                 contentHash: "follow-long-sentence-ticks")
        let (coordinator, textView) = try makeColumn(content: content, arrow: arrow)
        coordinator.setActiveSentence(20, scroll: true)
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertTrue(FollowBand.isTall(sentence, in: try XCTUnwrap(coordinator.viewport())))
        return (coordinator, textView)
    }

    /// Speaks sentence 20's words from `word` on (underlined only with
    /// `underline`) until following has moved the text with the voice and
    /// the word has just moved onto a new line. Returns that word.
    private func speakToAFollowedLine(_ coordinator: ReaderTextView.Coordinator, _ textView: UITextView,
                                      from start: Int = 0, underline: Bool = true) throws -> Int {
        let startY = textView.contentOffset.y
        var lineY: CGFloat?
        for word in start..<200 {
            if underline {
                coordinator.setActiveWord(2 * word, follows: true)
            } else {
                coordinator.setSpokenWord(2 * word, follows: true)
            }
            let rect = try XCTUnwrap(coordinator.spokenWordRect())
            defer { lineY = rect.minY }
            if let lineY, abs(rect.minY - lineY) > 0.5, textView.contentOffset.y > startY + 1 { return word }
        }
        throw XCTSkip("following never tracked the word on this host")
    }

    private func isInBand(word coordinator: ReaderTextView.Coordinator) throws -> Bool {
        let viewport = try XCTUnwrap(coordinator.viewport())
        return FollowBand.contains(try XCTUnwrap(coordinator.spokenWordRect()), in: viewport)
    }

    /// G002: a word tick never moves a sentence that fits. A drag that
    /// leaves the spoken sentence in view but above the band follows again,
    /// and the text then stays put until the next sentence.
    func testWordTicksNeverPullBackASentenceThatFitsAfterADrag() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.setActiveSentence(20, scroll: true)
        XCTAssertTrue(isInBand(coordinator))

        coordinator.scrollViewWillBeginDragging(textView)
        let viewport = try XCTUnwrap(coordinator.viewport())
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        // The sentence's top to 8% of the band's height: in view, above it.
        let lift = sentence.minY - (viewport.minY + 0.08 * viewport.height)
        textView.setContentOffset(CGPoint(x: 0, y: textView.contentOffset.y + lift), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertTrue(coordinator.isFollowing, "the voice is in view")
        XCTAssertFalse(isInBand(coordinator))

        let (scrolls, offset) = (coordinator.programmaticScrollCount, textView.contentOffset)
        // "Line 20 is short.": words at tokens 0, 2, 4, 6.
        for token in [0, 2, 4, 6] {
            coordinator.setActiveWord(token, follows: true)
        }
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "no word tick follows a sentence that fits")
        XCTAssertEqual(textView.contentOffset, offset)

        coordinator.setActiveSentence(21, scroll: true)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "the next sentence follows")
        XCTAssertTrue(isInBand(coordinator))
    }

    /// G002 in a tall sentence: after a drag that leaves the spoken word in
    /// view, the text stays put until the voice moves on to its next line,
    /// and a drag back to the sentence's start that hides the word doesn't
    /// follow again: the chip points at the word.
    func testATallSentenceWaitsForTheNextLineAfterADragAndJudgesTheWord() throws {
        let arrow = Arrow()
        let (coordinator, textView) = try makeTallColumn(arrow: arrow)
        let word = try speakToAFollowedLine(coordinator, textView)
        XCTAssertTrue(try isInBand(word: coordinator))

        // Drag the text down until the word sits at 80%: in view, below the band.
        coordinator.scrollViewWillBeginDragging(textView)
        var viewport = try XCTUnwrap(coordinator.viewport())
        var rect = try XCTUnwrap(coordinator.spokenWordRect())
        let drop = viewport.minY + 0.80 * viewport.height - rect.minY
        textView.setContentOffset(CGPoint(x: 0, y: textView.contentOffset.y - drop), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertTrue(coordinator.isFollowing, "the spoken word is in view")
        XCTAssertFalse(try isInBand(word: coordinator))

        // The next word, on the same line: nothing moves.
        let (scrolls, offset) = (coordinator.programmaticScrollCount, textView.contentOffset)
        coordinator.setActiveWord(2 * (word + 1), follows: true)
        rect = try XCTUnwrap(coordinator.spokenWordRect())
        let line = rect.minY
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "a word on the same line stays put")
        XCTAssertEqual(textView.contentOffset, offset)

        // The voice moves on to its next line: following brings it back.
        var next = word + 2
        while abs(try XCTUnwrap(coordinator.spokenWordRect()).minY - line) < 0.5 {
            coordinator.setActiveWord(2 * next, follows: true)
            next += 1
        }
        XCTAssertGreaterThan(coordinator.programmaticScrollCount, scrolls, "the next line follows")
        XCTAssertTrue(try isInBand(word: coordinator))

        // Back to the sentence's start, which leaves the sentence in view
        // and hides the spoken word below.
        coordinator.scrollViewWillBeginDragging(textView)
        viewport = try XCTUnwrap(coordinator.viewport())
        rect = try XCTUnwrap(coordinator.spokenWordRect())
        let past = viewport.maxY - rect.minY + 20
        textView.setContentOffset(CGPoint(x: 0, y: textView.contentOffset.y - past), animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        XCTAssertNil(FollowBand.direction(of: sentence, in: try XCTUnwrap(coordinator.viewport())),
                     "the sentence is still in view")
        XCTAssertFalse(coordinator.isFollowing, "the spoken word is not")
        XCTAssertEqual(coordinator.voiceOffscreen, .down)
        let held = textView.contentOffset
        coordinator.setActiveWord(2 * next, follows: true)
        XCTAssertEqual(textView.contentOffset, held, "the reader keeps the start of the sentence")
    }

    /// G003: with Word highlight off nothing is underlined, yet following
    /// still tracks the spoken word through a sentence taller than the band.
    func testATallSentenceFollowsTheSpokenWordWithTheUnderlineOff() throws {
        let (coordinator, textView) = try makeTallColumn()
        let startY = textView.contentOffset.y
        for word in 0..<240 {
            coordinator.setSpokenWord(2 * word, follows: true)
            XCTAssertTrue(try isInBand(word: coordinator), "word \(word) is read in the band")
        }
        XCTAssertGreaterThan(textView.contentOffset.y, startY, "the text moved up with the voice")
        XCTAssertNil(coordinator.activeWordRect(), "no underline is drawn")
    }

    /// G003: the playback's word ticker runs while playing even with Word
    /// highlight off, at a coarse rate, so `currentWord` still reaches the
    /// reader's follow; the full rate only feeds the tint.
    func testTheWordTickerRunsForFollowingWithTheHighlightOff() {
        let rig = PlaybackTestRig(sentences: 4)
        let controller = rig.controller
        controller.wordHighlightEnabled = false
        controller.wordTimingStatusChanged(.playing)
        XCTAssertEqual(controller.wordTiming.tickerRate, WordKaraokeState.followFramesPerSecond)
        controller.wordHighlightEnabled = true
        controller.wordTimingStatusChanged(.playing)
        XCTAssertEqual(controller.wordTiming.tickerRate, WordKaraokeState.tintFramesPerSecond)
        controller.wordTimingStatusChanged(.paused)
        XCTAssertEqual(controller.wordTiming.tickerRate, 0, "no ticker while paused")
        controller.wordHighlightEnabled = false
    }

    /// G006: Play from a pause in the tail of a tall sentence keeps the
    /// spoken word where following left it: no scroll up to the sentence's
    /// top that would hide the word under the player bar.
    func testPlayFromAPauseInATallSentenceKeepsTheSpokenWordInTheBand() throws {
        let (coordinator, textView) = try makeTallColumn()
        _ = try speakToAFollowedLine(coordinator, textView)
        let (scrolls, offset) = (coordinator.programmaticScrollCount, textView.contentOffset)
        coordinator.resumeFollowing()
        settleLayout(textView)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the word is already in the band")
        XCTAssertEqual(textView.contentOffset, offset)
        XCTAssertTrue(try isInBand(word: coordinator))
    }

    /// G006: the Follow chip, and a placement without motion (a reflow),
    /// mid tall sentence land the spoken word in the band, not the
    /// sentence's top with the word below it.
    func testResumingOrPlacingMidTallSentenceLandsTheSpokenWord() throws {
        let (coordinator, textView) = try makeTallColumn()
        _ = try speakToAFollowedLine(coordinator, textView, underline: false)

        // Scrolled away to the top of the book, then the Follow chip.
        coordinator.scrollViewWillBeginDragging(textView)
        textView.setContentOffset(.zero, animated: false)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        XCTAssertFalse(coordinator.isFollowing)
        coordinator.resumeFollowing()
        settleLayout(textView)
        XCTAssertTrue(try isInBand(word: coordinator), "the chip lands the spoken word")

        // Moved without a drag, then placed again as a reflow does.
        textView.setContentOffset(.zero, animated: false)
        coordinator.placeActiveSentence()
        settleLayout(textView)
        XCTAssertTrue(try isInBand(word: coordinator), "a reflow lands the spoken word")
    }

    /// The traits the column was built for, flipped to the other
    /// appearance; false when this host does not apply an override to a view
    /// outside a window.
    private func flipAppearance(_ textView: ReaderUITextView) -> Bool {
        let original = textView.traitCollection.userInterfaceStyle
        textView.overrideUserInterfaceStyle = original == .dark ? .light : .dark
        textView.updateTraitsIfNeeded()
        return textView.traitCollection.userInterfaceStyle != original
    }

    /// With Appearance on System, iOS flips light/dark and back while the
    /// app is in the background, to snapshot it for the app switcher. Each
    /// flip set the whole book again on the main thread; now neither does,
    /// and a real change made meanwhile is taken, in place, once the app is
    /// back.
    func testTheAppSwitchersSnapshotFlipsRebuildNothing() throws {
        let (coordinator, textView) = try makeColumn()
        let builds = coordinator.columnBuilds
        // Back to the look it was built for, explicitly: clearing the
        // override doesn't bring a view outside a window back.
        let builtStyle: UIUserInterfaceStyle = textView.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        coordinator.isInBackground = { true }
        guard flipAppearance(textView) else { throw XCTSkip("This host doesn't override traits outside a window") }
        coordinator.rebuildForTraitChange()
        textView.overrideUserInterfaceStyle = builtStyle
        textView.updateTraitsIfNeeded()
        coordinator.rebuildForTraitChange()
        let recolors = coordinator.columnRecolors
        XCTAssertEqual(coordinator.columnBuilds, builds, "both snapshot flips leave the column as built")
        XCTAssertEqual(coordinator.columnRecolors, recolors)

        coordinator.isInBackground = { false }
        coordinator.appBecameActive()
        XCTAssertEqual(coordinator.columnBuilds, builds, "back with the look it was built for: nothing to redo")

        coordinator.isInBackground = { true }
        XCTAssertTrue(flipAppearance(textView))
        coordinator.rebuildForTraitChange()
        XCTAssertEqual(coordinator.columnBuilds, builds, "a real change waits for the app to be active")
        coordinator.isInBackground = { false }
        coordinator.appBecameActive()
        XCTAssertEqual(coordinator.columnRecolors, recolors + 1, "and is taken once it is")
        XCTAssertEqual(coordinator.columnBuilds, builds, "in place: a recolor never sets the book again")
    }

    /// A light/dark flip deep in a long book keeps the passage on screen.
    /// It used to rebuild the column and lay the book out again from the
    /// top on the main thread (H017); now it only recolors, so TextKit
    /// keeps its layout and the reader who scrolled away from the voice
    /// keeps reading where they were.
    func testALightDarkFlipKeepsThePassageOnScreen() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(count: 1_200, taps: taps)
        coordinator.isInBackground = { false }
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(1_100, scroll: true)
        coordinator.resumeFollowing()
        runLayoutPasses(textView)
        coordinator.userTookOverScroll()   // the reader reads on there, not following
        let builds = coordinator.columnBuilds

        func sentenceMidScreen() throws -> Int {
            let viewport = try XCTUnwrap(coordinator.viewport())
            coordinator.handleTap(at: CGPoint(x: textView.textContainerInset.left + 8, y: viewport.midY),
                                  isDecelerating: false)
            return try XCTUnwrap(taps.sentences.last)
        }
        let before = try sentenceMidScreen()

        guard flipAppearance(textView) else { throw XCTSkip("This host doesn't override traits outside a window") }
        coordinator.rebuildForTraitChange()
        XCTAssertEqual(coordinator.columnBuilds, builds, "no rebuild for the flip")
        runLayoutPasses(textView)

        XCTAssertFalse(coordinator.isFollowing)
        XCTAssertEqual(try sentenceMidScreen(), before, "the same passage is on screen")
    }

    /// A column whose reader scrolled away from the voice: the passage
    /// around sentence 1,100 is on screen, following is off, and the voice
    /// sits back at sentence 10.
    private func readAwayFromTheVoice(taps: Taps) throws
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView, sentenceAtTop: () throws -> Int) {
        let (coordinator, textView) = try makeColumn(count: 1_200, taps: taps)
        coordinator.isInBackground = { false }
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.setActiveSentence(1_100, scroll: true)
        coordinator.resumeFollowing()
        runLayoutPasses(textView)
        coordinator.userTookOverScroll()   // the reader reads on there, not following
        coordinator.setActiveSentence(10, scroll: true)
        runLayoutPasses(textView)
        XCTAssertFalse(coordinator.isFollowing)

        func sentenceAtTop() throws -> Int {
            let viewport = try XCTUnwrap(coordinator.viewport())
            coordinator.handleTap(at: CGPoint(x: textView.textContainerInset.left + 8, y: viewport.minY + 4),
                                  isDecelerating: false)
            return try XCTUnwrap(taps.sentences.last)
        }
        return (coordinator, textView, sentenceAtTop)
    }

    /// A text-size step while the reader is away from the voice keeps the
    /// passage at the top of the screen and leaves following off. It used
    /// to take the fresh-column path: following forced on and the paused
    /// voice's sentence placed, so the reader lost their place (H018).
    func testATextSizeStepKeepsTheReadersPassage() throws {
        let taps = Taps()
        let (coordinator, textView, sentenceAtTop) = try readAwayFromTheVoice(taps: taps)
        let before = try sentenceAtTop()
        XCTAssertGreaterThan(before, 1_000)

        coordinator.reflowKeepingPlace(fontSize: 23)
        runLayoutPasses(textView)
        settle()

        XCTAssertEqual(coordinator.builtFontSize, 23)
        XCTAssertFalse(coordinator.isFollowing, "following is left as it was")
        XCTAssertEqual(coordinator.activeSentence, 10, "the voice is where it was")
        let after = try sentenceAtTop()
        XCTAssertLessThanOrEqual(abs(after - before), 1, "the same passage is at the top")
    }

    /// With no rotor stop and the voice scrolled out of view, VoiceOver's
    /// label and double-tap are the passage on screen, as a sighted tap
    /// is: never the voice's sentence, which a double-tap would restart
    /// and pull the column back to (L020).
    func testVoiceOverRestsOnThePassageOnScreenWhileTheVoiceIsAway() throws {
        let taps = Taps()
        let (coordinator, textView, sentenceAtTop) = try readAwayFromTheVoice(taps: taps)
        let sentences = coordinator.parent.content.sentences
        XCTAssertNil(coordinator.accessibilitySentence, "no rotor stop")

        let label = try XCTUnwrap(textView.accessibilityLabel)
        XCTAssertNotEqual(label, sentences[10].text, "never the voice's sentence off screen")
        XCTAssertTrue(textView.accessibilityActivate())
        let played = try XCTUnwrap(taps.sentences.last)
        XCTAssertNotEqual(played, 10, "a double-tap plays the passage on screen")
        XCTAssertEqual(label, sentences[played].text, "the label names what a double-tap plays")
        let top = try sentenceAtTop()
        XCTAssertLessThanOrEqual(abs(played - top), 1, "the sentence at the top of the screen")
    }

    /// While following, a text-size step stays on the voice.
    func testATextSizeStepWhileFollowingStaysOnTheVoice() throws {
        let (coordinator, textView) = try makeColumn(count: 1_200)
        coordinator.setActiveSentence(600, scroll: false)
        coordinator.resumeFollowing()
        settleLayout(textView)
        XCTAssertTrue(coordinator.isFollowing)

        coordinator.reflowKeepingPlace(fontSize: 23)
        settle()
        settleLayout(textView)

        XCTAssertTrue(coordinator.isFollowing)
        XCTAssertTrue(isInBand(coordinator), "the voice is placed in the band")
    }

    /// Bold Text reflows the book like a size step and keeps the reader's
    /// passage too, with following left off (H018).
    func testABoldTextFlipKeepsTheReadersPassage() throws {
        let taps = Taps()
        let (coordinator, textView, sentenceAtTop) = try readAwayFromTheVoice(taps: taps)
        let before = try sentenceAtTop()
        let builds = coordinator.columnBuilds

        textView.traitOverrides.legibilityWeight = .bold
        textView.updateTraitsIfNeeded()
        guard textView.traitCollection.legibilityWeight == .bold else {
            throw XCTSkip("This host doesn't override traits outside a window")
        }
        coordinator.rebuildForTraitChange()
        runLayoutPasses(textView)
        settle()

        XCTAssertEqual(coordinator.columnBuilds, builds + 1, "Bold Text reflows, so it rebuilds")
        XCTAssertFalse(coordinator.isFollowing, "following is left as it was")
        XCTAssertLessThanOrEqual(abs(try sentenceAtTop() - before), 1, "the same passage is at the top")
    }
}

// MARK: - iPhone parity (B6): the reader page

extension ReaderFollowCoordinatorTests {

    // MARK: Long-press menu (P042)

    /// A long press names the sentence under the finger and the word there,
    /// and moves nothing: no tap, no playhead change, no scroll.
    func testALongPressFindsTheSentenceAndMovesNothing() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let scrolls = coordinator.programmaticScrollCount
        let viewport = try XCTUnwrap(coordinator.viewport())
        let point = CGPoint(x: textView.textContainerInset.left + 8, y: viewport.minY + 0.3 * viewport.height)
        let target = try XCTUnwrap(coordinator.menuTarget(at: point))

        coordinator.handleTap(at: point, isDecelerating: false)
        XCTAssertEqual(taps.sentences, [target.sentence], "the press lands on the sentence a tap there plays")
        taps.sentences.removeAll()

        // Look Up names the word under the finger (R2-12): the press sits in
        // the first-line indent, which maps to the line's first word.
        let wordRange = try XCTUnwrap(target.word, "the press finds a word")
        let term = (textView.textStorage.string as NSString).substring(with: wordRange)
        XCTAssertEqual(term, "Line")
        let menu = coordinator.menu(for: target)
        XCTAssertEqual(menu.children.map(\.title),
                       ["Play from Here", "Copy", ReaderMenuCopy.lookUpTitle(for: term), "Share\u{2026}"])
        XCTAssertEqual(menu.children.map(\.title)[2], "Look Up \u{201C}Line\u{201D}", "Look Up quotes its word")
        XCTAssertEqual(taps.sentences, [], "building the menu plays nothing")
        XCTAssertEqual(coordinator.activeSentence, 0, "the playhead stays")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
    }

    /// The menu takes the press only once it shows: UIKit asks for the
    /// configuration as the lift highlight starts, and a finger lifting
    /// then gets its tap back, which still plays. Once the menu shows, the
    /// tap that would end it plays nothing; the next touch taps again.
    func testTheMenuTakesThePressFromTheTap() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let viewport = try XCTUnwrap(coordinator.viewport())
        let point = CGPoint(x: textView.textContainerInset.left + 8, y: viewport.minY + 0.3 * viewport.height)
        let tap = try XCTUnwrap(textView.gestureRecognizers?.first {
            $0 is UITapGestureRecognizer && $0.delegate === coordinator
        })
        coordinator.touchLanded()
        let interaction = UIContextMenuInteraction(delegate: coordinator)
        let configuration = try XCTUnwrap(coordinator.contextMenuInteraction(interaction,
                                                                            configurationForMenuAtLocation: point))
        XCTAssertFalse(coordinator.menuOwnsTouch, "asking for the menu takes nothing from the tap")
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(tap), "a lift before the menu commits still taps")
        coordinator.handleTap(at: point, isDecelerating: false)
        XCTAssertEqual(taps.sentences.count, 1, "and that tap plays")
        let target = try XCTUnwrap(coordinator.menuTarget(at: point))
        XCTAssertEqual(taps.sentences, [target.sentence])

        coordinator.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        XCTAssertTrue(coordinator.menuOwnsTouch, "the menu showing takes the press")
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(tap))
        coordinator.touchLanded()
        XCTAssertFalse(coordinator.menuOwnsTouch, "a new touch taps again")
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(tap))
    }

    /// On moving text a long press only stops it, as a tap does: no menu.
    func testALongPressOnMovingTextOnlyStopsIt() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let viewport = try XCTUnwrap(coordinator.viewport())
        let point = CGPoint(x: textView.textContainerInset.left + 8, y: viewport.minY + 0.3 * viewport.height)
        coordinator.isCoasting = { _ in true }
        coordinator.touchLanded()
        coordinator.isCoasting = { _ in false }
        let interaction = UIContextMenuInteraction(delegate: coordinator)
        XCTAssertNil(coordinator.contextMenuInteraction(interaction, configurationForMenuAtLocation: point))
        XCTAssertFalse(coordinator.menuOwnsTouch)
        XCTAssertEqual(taps.sentences, [])
    }

    /// Copy quotes the sentence as the page sets it; VoiceOver's Copy
    /// sentence and Look up act on the sentence Play from here would play.
    func testCopyQuotesTheSentenceAndVoiceOverCanCopyAndLookUp() throws {
        let (coordinator, textView) = try makeColumn()
        var copied: [String] = []
        var shown: [UIViewController] = []
        coordinator.writePasteboard = { copied.append($0) }
        coordinator.present = { shown.append($0) }

        XCTAssertTrue(coordinator.copySentence(3))
        XCTAssertEqual(copied, [ReaderTypography.typeset(coordinator.parent.content.sentences[3].text)])
        XCTAssertFalse(copied[0].contains("\u{FFFC}"))

        let actions = textView.accessibilityCustomActions ?? []
        XCTAssertEqual(actions.map(\.name), [ReaderRotor.playFromHere, ReaderRotor.copySentence, ReaderRotor.lookUp])
        XCTAssertEqual(actions[1].actionHandler?(actions[1]), true)
        XCTAssertEqual(copied.count, 2, "Copy sentence copies the sentence VoiceOver rests on")
        XCTAssertEqual(actions[2].actionHandler?(actions[2]), true)
        XCTAssertTrue(shown.last is UIReferenceLibraryViewController, "Look up shows the dictionary")

        coordinator.shareSentence(3)
        XCTAssertTrue(shown.last is UIActivityViewController, "Share shows the share sheet")
    }

    // MARK: Pinch to size (P044)

    func testAPinchStepsOncePerThresholdAndClampsAtTheEnds() {
        XCTAssertEqual(ReaderPinch.step(scale: 1.2, anchor: 1).delta, 1)
        XCTAssertEqual(ReaderPinch.step(scale: 0.8, anchor: 1).delta, -1)
        XCTAssertEqual(ReaderPinch.step(scale: 1.1, anchor: 1).delta, 0, "under the threshold, no step")
        XCTAssertEqual(ReaderPinch.step(scale: 1.6, anchor: 1).delta, 3, "three thresholds in one move")
        let first = ReaderPinch.step(scale: 1.2, anchor: 1)
        XCTAssertEqual(ReaderPinch.step(scale: 1.25, anchor: first.anchor).delta, 0, "measured from the last step")
        XCTAssertEqual(ReaderPinch.step(scale: 1.35, anchor: first.anchor).delta, 1)
        let last = ReaderTextSize.steps.count - 1
        XCTAssertEqual(ReaderPinch.clamped(last, by: 1), last)
        XCTAssertEqual(ReaderPinch.clamped(0, by: -2), 0)
        XCTAssertEqual(ReaderPinch.clamped(2, by: 1), 3)
        XCTAssertEqual(ReaderMenuCopy.textSize(points: 21), "21 point")
    }

    // MARK: VoiceOver's lines (P045)

    func testVoiceOverReadsThePageLineByLine() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let lines = coordinator.readingLines()
        XCTAssertGreaterThan(lines.count, 3)
        let third = lines[2]
        let point = CGPoint(x: third.frame.midX, y: third.frame.midY)
        XCTAssertEqual(coordinator.accessibilityLineNumber(at: point), 2)
        // A scroll view's own coordinates are its content coordinates.
        XCTAssertEqual(textView.accessibilityLineNumber(for: point), 2)
        let text = try XCTUnwrap(textView.accessibilityContent(forLineNumber: 2))
        XCTAssertEqual(text, third.text)
        XCTAssertFalse(text.contains("\u{FFFC}"))
        XCTAssertTrue(coordinator.parent.content.sentences.contains { ReaderTypography.typeset($0.text) == text })
        XCTAssertNil(textView.accessibilityContent(forLineNumber: lines.count), "nothing past the screen")

        let page = try XCTUnwrap(textView.accessibilityPageContent())
        XCTAssertLessThanOrEqual(page.count, ReaderRotor.pageContentLimit)
        XCTAssertTrue(page.contains(text))
        XCTAssertNil(textView.accessibilityValue, "the value never carries the book (R12e)")
        XCTAssertTrue(textView.accessibilityTraits.contains(.causesPageTurn), "Read All turns the page")

        // Play from here plays the line just heard.
        XCTAssertTrue(coordinator.playFromHere())
        let played = try XCTUnwrap(taps.sentences.last)
        XCTAssertEqual(ReaderTypography.typeset(coordinator.parent.content.sentences[played].text), text)
    }

    /// The protocol's point is in the view's coordinate space, which for
    /// this scroll view is content coordinates. In a window at a non-zero
    /// origin, scrolled, a screen conversion would land it lines away.
    func testVoiceOverFindsTheLineUnderTheFingerInAWindowScrolledDown() throws {
        let (coordinator, textView) = try makeColumn()
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        defer { window.isHidden = true; textView.removeFromSuperview() }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.isHidden = false
        window.addSubview(textView)
        textView.frame = CGRect(x: 0, y: 64, width: 390, height: 800)
        coordinator.userTookOverScroll()
        textView.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        settleLayout(textView)
        guard textView.window != nil, textView.contentOffset.y > 1000 else {
            throw XCTSkip("This host doesn't scroll a text view in a window")
        }

        let lines = coordinator.readingLines()
        XCTAssertGreaterThan(lines.count, 3)
        let third = lines[2]
        let point = CGPoint(x: third.frame.midX, y: third.frame.midY)
        XCTAssertEqual(textView.accessibilityLineNumber(for: point), 2, "the third line on screen")
        XCTAssertEqual(textView.accessibilityContent(forLineNumber: 2), third.text)
    }

    /// Read All (`causesPageTurn`) turns the page on line boundaries above
    /// the player bar: each page starts where the last one's band stopped,
    /// so no line under the bar is skipped and none is read twice; it
    /// reports false at the end of the book, and back at its start.
    func testReadAllTurnsThePageWithoutSkippingTheLinesUnderTheBar() throws {
        let (coordinator, textView) = try makeColumn(obscuredBottom: 200)
        let storage = textView.textStorage
        var heard = coordinator.readingLines().map(\.text)
        var turns = 0
        while turns < 100 {
            let before = coordinator.readingLines()
            guard textView.accessibilityScroll(.next) else { break }
            turns += 1
            let after = coordinator.readingLines()
            let last = try XCTUnwrap(before.last)
            let first = try XCTUnwrap(after.first)
            XCTAssertGreaterThanOrEqual(first.range.location, NSMaxRange(last.range), "page \(turns) repeats a line")
            let between = NSRange(location: NSMaxRange(last.range),
                                  length: max(first.range.location - NSMaxRange(last.range), 0))
            XCTAssertEqual(ReaderColumnText.quote(of: between, in: storage)
                .trimmingCharacters(in: .whitespacesAndNewlines), "", "page \(turns) skips words")
            heard += after.map(\.text)
        }
        XCTAssertGreaterThan(turns, 3, "the book is several pages")
        XCTAssertLessThan(turns, 100, "the last page turns no further")
        let sentences = heard.filter { $0.hasPrefix("Line ") }
        XCTAssertEqual(sentences, (0..<160).map { ReaderTypography.typeset("Line \($0) is short.") },
                       "Read All hears every line once, in order")
        let end = textView.contentOffset
        XCTAssertFalse(textView.accessibilityScroll(.next))
        XCTAssertEqual(textView.contentOffset, end, "at the end nothing moves")

        let lastPage = coordinator.readingLines()
        XCTAssertTrue(textView.accessibilityScroll(.previous))
        let pageBefore = coordinator.readingLines()
        let top = try XCTUnwrap(lastPage.first)
        let bottom = try XCTUnwrap(pageBefore.last)
        XCTAssertLessThanOrEqual(NSMaxRange(bottom.range), top.range.location, "back a page repeats nothing")
        var backs = 1
        while backs < 100, textView.accessibilityScroll(.previous) { backs += 1 }
        XCTAssertLessThan(backs, 100)
        XCTAssertEqual(coordinator.readingLines().first?.text, heard.first, "back at the start")
    }

    // MARK: A finger resting on the page (P047)

    /// Twin of the Mac's held-button case: while a finger rests on the page
    /// the voice moving past the band scrolls nothing; the touch ending
    /// glides once, landing the voice in the band near the landing line.
    func testAFollowHeldBackUnderARestingFingerRunsOnceItLifts() throws {
        let (coordinator, textView) = try makeColumn()
        let scrolls = coordinator.programmaticScrollCount
        coordinator.isTouching = { _ in true }
        coordinator.setActiveSentence(40, scroll: true)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "never under a finger")
        XCTAssertTrue(coordinator.followKeptBack)
        XCTAssertFalse(isInBand(coordinator))

        coordinator.isTouching = { _ in false }
        coordinator.touchesEnded()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "exactly one glide")
        XCTAssertFalse(coordinator.followKeptBack)
        settleLayout(textView)
        XCTAssertTrue(isInBand(coordinator))
        let rect = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertEqual(rect.minY - viewport.minY, 0.28 * viewport.height, accuracy: 30, "on the landing line")

        coordinator.touchesEnded()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "nothing held, nothing runs")
    }

    func testAHeldTouchEndingWithTheVoiceInTheBandScrollsNothing() throws {
        let (coordinator, _) = try makeColumn()
        let scrolls = coordinator.programmaticScrollCount
        coordinator.isTouching = { _ in true }
        coordinator.setActiveSentence(2, scroll: true)
        coordinator.isTouching = { _ in false }
        coordinator.touchesEnded()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
    }

    /// A resume (Play, a jump) under a resting finger waits for it too.
    func testAResumeHeldBackUnderAFingerRunsOnceItLifts() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.scrollViewWillBeginDragging(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)
        coordinator.setActiveSentence(80, scroll: false)
        let scrolls = coordinator.programmaticScrollCount
        coordinator.isTouching = { _ in true }
        coordinator.resumeFollowing()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls)
        XCTAssertTrue(coordinator.resumeKeptBack)
        coordinator.isTouching = { _ in false }
        coordinator.touchesEnded()
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1)
        settleLayout(textView)
        XCTAssertTrue(isInBand(coordinator))
    }

    // MARK: One reflow per pinch (R1-15)

    private final class Stored {
        var deltas: [Int] = []
        var ticks = 0
    }

    private func pinch(_ coordinator: ReaderTextView.Coordinator, _ states: [(UIGestureRecognizer.State, CGFloat)]) {
        for (state, scale) in states {
            coordinator.handlePinch(state: state, scale: scale, at: CGPoint(x: 195, y: 300))
        }
    }

    func testAPinchReflowsOnceWhenItEnds() throws {
        let (coordinator, _) = try makeColumn()
        let stored = Stored()
        coordinator.parent.onPinchTextSize = { stored.deltas.append($0) }
        coordinator.pinchTick = { stored.ticks += 1 }
        let builds = coordinator.columnBuilds

        pinch(coordinator, [(.began, 1)])
        for scale: CGFloat in [1.2, 1.4, 1.6] {   // past 1.15, 1.15², 1.15³
            pinch(coordinator, [(.changed, scale)])
            XCTAssertEqual(coordinator.columnBuilds, builds, "nothing rebuilds while the fingers move")
        }
        XCTAssertEqual(stored.ticks, 3, "a tick at each step")
        XCTAssertEqual(stored.deltas, [], "nothing stored mid-pinch")

        pinch(coordinator, [(.ended, 1.6)])
        XCTAssertEqual(coordinator.columnBuilds, builds + 1, "one reflow for the whole pinch")
        XCTAssertEqual(stored.deltas, [3], "the net step, stored once")
        XCTAssertEqual(coordinator.builtFontSize, ReaderTextSize.points(forStep: ReaderTextSize.defaultStep + 3))
        XCTAssertNil(coordinator.pinchPreview, "the live preview is gone")
    }

    func testAPinchIsClampedToTheStepper() throws {
        let (coordinator, _) = try makeColumn()
        let stored = Stored()
        coordinator.parent.onPinchTextSize = { stored.deltas.append($0) }
        coordinator.pinchTick = { stored.ticks += 1 }
        pinch(coordinator, [(.began, 1), (.changed, 6), (.changed, 9), (.ended, 9)])
        let top = ReaderTextSize.steps.count - 1
        XCTAssertEqual(stored.deltas, [top - ReaderTextSize.defaultStep])
        XCTAssertEqual(stored.ticks, 1, "the clamp ticks once")
        XCTAssertEqual(coordinator.builtFontSize, ReaderTextSize.points(forStep: top))
    }

    /// `parent` as the text-size store hands it over at `size`.
    private func resized(_ parent: ReaderTextView, to size: CGFloat) -> ReaderTextView {
        ReaderTextView(content: parent.content, isChapterBook: parent.isChapterBook, navigation: parent.navigation,
                       fontSize: size, activeSentence: parent.activeSentence, activeWord: parent.activeWord,
                       followWord: parent.followWord, obscuredBottom: parent.obscuredBottom,
                       voiceOffscreen: parent.$voiceOffscreen, textUnderTopBar: parent.$textUnderTopBar,
                       onTapSentence: parent.onTapSentence)
    }

    /// A stepper size change while the voice reads: every word tick
    /// updates the view, each still seeing the old size built, and none
    /// may push back the one reflow the step owes.
    func testWordTicksNeverHoldBackATextSizeStep() throws {
        let (coordinator, _) = try makeColumn()
        let builds = coordinator.columnBuilds
        coordinator.parent = resized(coordinator.parent, to: 23)
        let start = Date()
        // A tick every 40 ms for 0.6 s; as `updateUIView`, each asks for
        // the reflow while the built size differs.
        while Date().timeIntervalSince(start) < 0.6 {
            if coordinator.builtFontSize != coordinator.parent.fontSize { coordinator.reflowSoon() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        XCTAssertEqual(coordinator.builtFontSize, 23, "the page took the new size while the ticks ran")
        XCTAssertEqual(coordinator.columnBuilds, builds + 1, "in one build")
        XCTAssertNil(coordinator.pendingReflowSize)
    }

    /// A rebuild at the old size inside the wait (Bold Text, a new
    /// measure) leaves the waiting size step to land when it is due.
    func testARebuildAtTheOldSizeKeepsAWaitingSizeStep() throws {
        let (coordinator, _) = try makeColumn()
        let builds = coordinator.columnBuilds
        coordinator.parent = resized(coordinator.parent, to: 23)
        coordinator.reflowSoon()
        coordinator.reflowKeepingPlace(fontSize: coordinator.builtFontSize)   // as Bold Text does
        XCTAssertEqual(coordinator.builtFontSize, 19)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(coordinator.builtFontSize, 23, "the size step still lands")
        XCTAssertEqual(coordinator.columnBuilds, builds + 2)
    }

    func testACancelledPinchAppliesNothing() throws {
        let (coordinator, _) = try makeColumn()
        let stored = Stored()
        coordinator.parent.onPinchTextSize = { stored.deltas.append($0) }
        coordinator.pinchTick = { stored.ticks += 1 }
        let builds = coordinator.columnBuilds
        pinch(coordinator, [(.began, 1), (.changed, 1.6), (.cancelled, 1.6)])
        XCTAssertEqual(coordinator.columnBuilds, builds, "no build")
        XCTAssertEqual(stored.deltas, [], "the stored step is unchanged")
        XCTAssertEqual(coordinator.builtFontSize, 19)
        XCTAssertNil(coordinator.pinchPreview)
        pinch(coordinator, [(.began, 1), (.changed, 1.2), (.failed, 1.2)])
        XCTAssertEqual(coordinator.columnBuilds, builds)
        XCTAssertEqual(stored.deltas, [])
    }

    /// The cost of one reflow 60% into a long chaptered book (1.2M
    /// characters) at step 6. The baseline is recorded per machine in
    /// Xcode's test report.
    func testReflowDeepInALongChapteredBook() throws {
        let filler = String(repeating: "and the river ran on past the houses ", count: 3)
        let count = 10_000
        let sentences = (0..<count).map {
            Sentence(id: $0, text: "Sentence \($0) \(filler)to the sea.", para: $0 / 5, page: $0 / 400 + 1)
        }
        let paragraphs = (0..<(count / 5)).map {
            Paragraph(id: $0, sentenceIDs: ($0 * 5)..<($0 * 5 + 5), page: $0 / 80 + 1)
        }
        let book = DocContent(title: "Long", pageCount: count / 400, sentences: sentences,
                              paragraphs: paragraphs, contentHash: "follow-long-chaptered")
        XCTAssertGreaterThan(sentences.reduce(0) { $0 + $1.text.count }, 1_200_000)
        let (coordinator, _) = try makeColumn(content: book, chapterAt: 1)
        coordinator.setActiveSentence(count * 6 / 10, scroll: false)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            coordinator.reflowKeepingPlace(fontSize: ReaderTextSize.points(forStep: 6))
        }
        XCTAssertEqual(coordinator.builtFontSize, ReaderTextSize.points(forStep: 6))
    }

    // MARK: With the Aa sheet up (R1-14)

    func testWithTheSheetUpATapClosesItAndPlaysNothing() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let stored = Stored()
        coordinator.parent.onDismissTap = { stored.ticks += 1 }
        coordinator.handleTap(at: firstLine(textView), isDecelerating: false)
        XCTAssertEqual(stored.ticks, 1, "the tap closed the sheet")
        XCTAssertEqual(taps.sentences, [], "and played nothing")

        coordinator.parent.onDismissTap = nil
        coordinator.handleTap(at: firstLine(textView), isDecelerating: false)
        XCTAssertEqual(taps.sentences.count, 1, "with no sheet, a tap plays at once")
    }

    // MARK: A fresh column, built off the main thread (R1-16)

    private final class Shown {
        var count = 0
    }

    private func freshParent(_ content: DocContent, shown: Shown) -> ReaderTextView {
        var parent = ReaderTextView(content: content, fontSize: 19, activeSentence: 0, activeWord: -1,
                                    voiceOffscreen: .constant(nil), textUnderTopBar: .constant(false),
                                    onTapSentence: { _ in })
        parent.onColumnShown = { shown.count += 1 }
        return parent
    }

    func testAStaleAsyncBuildIsDiscardedAndReplaced() async throws {
        let first = lines(40)
        let second = lines(60)
        let shown = Shown()
        let coordinator = ReaderTextView.Coordinator(parent: freshParent(first, shown: shown))
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.install(on: textView)

        coordinator.buildFreshColumn()
        XCTAssertNotNil(coordinator.freshBuild, "built off the main thread")
        XCTAssertEqual(coordinator.columnBuilds, 0, "the paper stays bare meanwhile")
        // The book changes mid-build.
        coordinator.parent = freshParent(second, shown: shown)
        await coordinator.columnSettled()

        XCTAssertEqual(coordinator.builtHash, second.contentHash, "replaced by the current book")
        XCTAssertEqual(coordinator.columnBuilds, 1, "the stale string never reached the page")
        XCTAssertTrue(textView.textStorage.string.contains("Line 59 is short."))
        XCTAssertEqual(shown.count, 1, "one first frame")
        XCTAssertTrue(coordinator.isFollowing, "a fresh column starts on the voice")
    }

    // MARK: The end of the book lands on the chip (R1-19)

    func testTheColophonLandsJustAboveTheChip() {
        let viewport = CGRect(x: 0, y: 1000, width: 390, height: 600)
        let last = CGRect(x: 24, y: 1440, width: 342, height: 50)
        let colophon = CGRect(x: 24, y: 1500, width: 342, height: 120)
        let y = FollowBand.colophonLandingOffsetY(colophon: colophon, lastSentence: last, viewport: viewport,
                                                  contentOffsetY: 1000, range: 0...5000)
        let landed = viewport.offsetBy(dx: 0, dy: y - 1000)
        XCTAssertEqual(colophon.maxY, landed.maxY, accuracy: 1, "the colophon's bottom on the chip line")
        XCTAssertGreaterThanOrEqual(last.minY, landed.minY, "the last sentence's top below the top chrome")
    }

    func testAnEndBlockTooTallShowsTheColophonInFullFirst() {
        let viewport = CGRect(x: 0, y: 1000, width: 390, height: 600)
        let last = CGRect(x: 24, y: 800, width: 342, height: 500)
        let colophon = CGRect(x: 24, y: 1310, width: 342, height: 400)
        let y = FollowBand.colophonLandingOffsetY(colophon: colophon, lastSentence: last, viewport: viewport,
                                                  contentOffsetY: 1000, range: 0...5000)
        XCTAssertEqual(colophon.maxY, viewport.offsetBy(dx: 0, dy: y - 1000).maxY, accuracy: 1,
                       "the colophon whole, on the chip")
        let huge = CGRect(x: 24, y: 1310, width: 342, height: 700)
        let top = FollowBand.colophonLandingOffsetY(colophon: huge, lastSentence: last, viewport: viewport,
                                                    contentOffsetY: 1000, range: 0...5000)
        XCTAssertEqual(huge.minY, viewport.offsetBy(dx: 0, dy: top - 1000).minY, accuracy: 1,
                       "taller than the screen: its top under the chrome")
        XCTAssertEqual(FollowBand.colophonLandingOffsetY(colophon: colophon, lastSentence: last, viewport: viewport,
                                                         contentOffsetY: 1000, range: 0...1100), 1100,
                       "within the resting range")
    }

    // MARK: The colophon, scrolled back from (P048)

    /// Twin of the Mac's testScrolledBackFromTheColophonThePageIsTheLabelAgain.
    func testScrolledBackFromTheColophonThePageIsTheLabelAgain() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(taps: taps)
        let colophon = ReaderColophon(title: "Lines", author: "A. Writer", words: 165 * 72, rate: 1)
        coordinator.setActiveSentence(159, scroll: false)
        coordinator.resumeFollowing()
        settleLayout(textView)
        coordinator.setColophon(colophon, animated: false)
        coordinator.resumeFollowing()
        settleLayout(textView)
        XCTAssertEqual(textView.accessibilityLabel, colophon.spokenText, "at the end the colophon is the label")

        coordinator.scrollViewWillBeginDragging(textView)
        let up = max(textView.contentOffset.y - textView.bounds.height, 0)
        textView.setContentOffset(CGPoint(x: 0, y: up), animated: false)
        runLayoutPasses(textView)
        coordinator.scrollViewDidEndDragging(textView, willDecelerate: false)

        let label = try XCTUnwrap(textView.accessibilityLabel)
        XCTAssertNotEqual(label, colophon.spokenText, "scrolled back, the page is the label")
        XCTAssertTrue(textView.accessibilityActivate())
        let played = try XCTUnwrap(taps.sentences.last, "a double-tap plays the page")
        XCTAssertEqual(coordinator.parent.content.sentences[played].text, label)
        XCTAssertLessThan(played, 159)
    }

    // MARK: Large type on a phone (P043)

    /// The gutter narrows at the largest sizes, the mark stays 8 pt in, and
    /// the bottom inset is the view's own.
    func testTheGutterNarrowsAtTheLargestSizes() throws {
        XCTAssertEqual(ReaderUITextView.gutter(fontSize: 19), Theme.Space.sheetGutter)
        XCTAssertEqual(ReaderUITextView.gutter(fontSize: 30), Theme.Space.lg)
        XCTAssertEqual(ReaderUITextView.gutter(fontSize: 40), Theme.Space.md)
        XCTAssertEqual(ReaderUITextView.columnWidth(viewWidth: 402, fontSize: 19), 402 - 2 * Theme.Space.sheetGutter)
        XCTAssertEqual(ReaderUITextView.columnWidth(viewWidth: 1_024, fontSize: 40), 640, "the measure's cap")
        XCTAssertGreaterThanOrEqual(ReaderUITextView.minimumMarkGutter - HighlightLayers.markGap - HighlightLayers.markWidth, 8)

        let (coordinator, textView) = try makeColumn()
        XCTAssertEqual(textView.textContainerInset.bottom, textView.bounds.height * 0.45, accuracy: 0.5)
        coordinator.reflowKeepingPlace(fontSize: 40)
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.textContainerInset.left, Theme.Space.md)
    }
}

// MARK: - iPhone critique round 2: the reader page

extension ReaderFollowCoordinatorTests {

    /// `parent` with the band's foot at `band` (the bar, the chip, a sheet).
    private func withBand(_ parent: ReaderTextView, _ band: CGFloat) -> ReaderTextView {
        ReaderTextView(content: parent.content, isChapterBook: parent.isChapterBook, navigation: parent.navigation,
                       fontSize: parent.fontSize, activeSentence: parent.activeSentence, activeWord: parent.activeWord,
                       followWord: parent.followWord, obscuredBottom: band,
                       voiceOffscreen: parent.$voiceOffscreen, textUnderTopBar: parent.$textUnderTopBar,
                       onTapSentence: parent.onTapSentence)
    }

    /// The colophon's foot against the viewport's, measured afresh.
    private func colophonFoot(_ coordinator: ReaderTextView.Coordinator) throws -> (colophon: CGFloat, viewport: CGFloat) {
        let rect = try XCTUnwrap(coordinator.measureActiveSentenceRect(), "the colophon is measured")
        let viewport = try XCTUnwrap(coordinator.viewport())
        return (rect.maxY, viewport.maxY)
    }

    /// The last of 160 lines read, following, `obscuredBottom` covered.
    private func atTheEnd(obscuredBottom: CGFloat = 0, reduceMotion: Bool = false) throws
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let (coordinator, textView) = try makeColumn(obscuredBottom: obscuredBottom, reduceMotion: reduceMotion)
        coordinator.setActiveSentence(159, scroll: false)
        coordinator.resumeFollowing()
        settleLayout(textView)
        return (coordinator, textView)
    }

    private var endColophon: ReaderColophon {
        ReaderColophon(title: "Lines", author: "A. Writer", words: 165 * 72, rate: 1)
    }

    // MARK: R2-09: the colophon lands whole above the chip

    /// The end reached on screen is placed at once, with no glide: a glide
    /// pauses the placement check, which then spent its passes on a band
    /// still growing. The colophon's foot is on the chip line before any
    /// animation could run.
    func testTheColophonIsPlacedAtOnceWhenTheEndArrives() throws {
        let (coordinator, _) = try atTheEnd(obscuredBottom: 120)
        coordinator.setColophon(endColophon, animated: true)
        let foot = try colophonFoot(coordinator)
        XCTAssertEqual(foot.colophon, foot.viewport, accuracy: 1, "the colophon's foot on the chip line at once")
        XCTAssertEqual(coordinator.colophonBand, 120, "placed on the band as it is")
    }

    /// The band moving under a showing colophon (the bar or the chip
    /// measured after the first placement, a chip's reach growing from 0)
    /// places it again at once, and the passes after keep it there.
    func testABandMovingUnderTheColophonPlacesItAgainAboveTheChip() throws {
        let (coordinator, textView) = try atTheEnd()
        coordinator.setColophon(endColophon, animated: false)
        settleLayout(textView)
        let before = try colophonFoot(coordinator)
        XCTAssertEqual(before.colophon, before.viewport, accuracy: 1, "on the band's foot with no chrome")

        coordinator.parent = withBand(coordinator.parent, 200)
        coordinator.bandMoved()
        let moved = try colophonFoot(coordinator)
        XCTAssertLessThanOrEqual(moved.colophon, moved.viewport + 1,
                                 "placed again above the chip at once, not left gliding under it")
        runLayoutPasses(textView)
        let settled = try colophonFoot(coordinator)
        XCTAssertEqual(settled.colophon, settled.viewport, accuracy: 1, "the passes after keep it on the chip line")
        XCTAssertEqual(coordinator.colophonBand, 200)
    }

    /// A band that moved without the view's update seeing it (a fresh
    /// column building, when the update returns early) is caught by the
    /// layout passes that follow. Under Reduce Motion, so no glide is left
    /// in flight on this windowless host.
    func testALayoutPassPlacesTheColophonAgainOnABandItWasNotAimedWith() throws {
        let (coordinator, textView) = try atTheEnd(reduceMotion: true)
        coordinator.setColophon(endColophon, animated: false)
        settleLayout(textView)
        XCTAssertEqual(coordinator.colophonBand, 0)

        coordinator.parent = withBand(coordinator.parent, 180)   // no bandMoved(): the update was skipped
        settleLayout(textView)
        settle()
        settleLayout(textView)
        let foot = try colophonFoot(coordinator)
        XCTAssertEqual(foot.colophon, foot.viewport, accuracy: 1, "on the chip line of the band as it is")
        XCTAssertEqual(coordinator.colophonBand, 180)
    }

    /// R2-09 review: a colophon the resting range keeps below the band (its
    /// target one the offset already holds) never turns the check into a
    /// run of no-op moves up to the pass limit; it moves only to a target
    /// that differs. DEBUG builds log every input the landing is aimed with.
    func testTheColophonCheckNeverMovesToWhereItIs() throws {
        let s = try SourceTree.sources(only: ["Reader/ReaderTextView.swift"])
        let view = try XCTUnwrap(s["Reader/ReaderTextView.swift"])
        let check = try XCTUnwrap(view.range(of: "private func checkPlacement() -> ReaderFollowEngine.PlacementCheck {"))
        let body = String(view[check.upperBound...].prefix(2_000))
        XCTAssertFalse(body.contains("return .moveTo(confirmed)"), body)
        XCTAssertTrue(body.contains("guard let settled, abs(settled - textView.contentOffset.y) > 1 else { return .holds }"),
                      body)
        let landing = try XCTUnwrap(view.range(of: "private func landingTarget(caller: String = #function) -> CGFloat? {"))
        let target = String(view[landing.upperBound...].prefix(2_400))
        XCTAssertTrue(target.contains("Self.colophonLog.debug("), target)
        XCTAssertTrue(target.contains("self.parent.obscuredBottom"), target)
        XCTAssertTrue(target.contains("self.restingOffsets()"), target)
    }

    /// A chip counts toward the band from the pass it resolves in, at its
    /// 44pt minimum and the slot's padding, before it is ever measured;
    /// measured, the running maximum holds.
    func testAShowingChipCountsAtItsMinimumBeforeItIsMeasured() throws {
        XCTAssertEqual(FollowBand.chipReach(previous: 0, showsChip: true),
                       (FollowBand.chipMinimumHeight + Theme.Space.sm).rounded(.up))
        XCTAssertEqual(FollowBand.chipReach(previous: 0, showsChip: false), 0, "no chip, no reach")
        XCTAssertEqual(FollowBand.chipReach(previous: 70, showsChip: true), 70, "a taller chip seen holds")
        let s = try SourceTree.sources(only: ["Reader/ReaderScreen.swift"])
        let screen = try XCTUnwrap(s["Reader/ReaderScreen.swift"])
        XCTAssertTrue(screen.contains("chipReach: FollowBand.chipReach(previous: chipReach,"),
                      "the band counts a resolved chip before it is measured")
    }

    // MARK: R2-10 / R2-11: the failed-load screen

    func testTheFailureCopySaysWhatCanStillGoWrong() {
        XCTAssertEqual(ReaderFailureCopy.title, "Couldn\u{2019}t open this book")
        XCTAssertEqual(ReaderFailureCopy.detail, "It may be damaged or missing.")
        XCTAssertEqual(ReaderFailureCopy.deleteBook, "Delete Book\u{2026}")
        XCTAssertEqual(ReaderFailureCopy.deleteTitle("Emma"), "Delete \u{201C}Emma\u{201D}?")
    }

    /// The failure state: its icon a masked colour with no image element,
    /// hidden at a container that ignores its children, its title a heading, magic tap on the page only, Delete
    /// Book through the shelf's own entry point, and no Aa.
    func testTheFailureStateHidesItsIconAndOffersDelete() throws {
        let s = try SourceTree.sources(only: ["Reader/ReaderScreen.swift"])
        let screen = try XCTUnwrap(s["Reader/ReaderScreen.swift"])
        let failure = try XCTUnwrap(screen.range(of: "private var failureState: some View {"))
        let state = String(screen[failure.lowerBound...].prefix(3_200))
        XCTAssertTrue(state.contains("failureGlyph\n                .accessibilityElement(children: .ignore)\n"
                                     + "                .accessibilityHidden(true)"), state)
        let glyph = try XCTUnwrap(screen.range(of: "private var failureGlyph: some View {"))
        let drawn = String(screen[glyph.upperBound...].prefix(320))
        XCTAssertTrue(drawn.contains(".hidden()\n            .overlay { Theme.textFaint.mask { glyph } }"),
                      "no image element for VoiceOver to read: \(drawn)")
        XCTAssertTrue(state.contains("Text(ReaderFailureCopy.title)"), state)
        XCTAssertTrue(state.contains(".accessibilityAddTraits(.isHeader)"), state)
        XCTAssertTrue(state.contains("reader.deleteBook"), state)
        XCTAssertTrue(state.contains("DocumentAction.deleteMessage(for: liveDocument)"), state)
        XCTAssertTrue(screen.contains("model.deleteDocument(liveDocument)"), "the shelf's own delete")
        XCTAssertTrue(screen.contains("if !loadFailed {"), "Aa hides on a page with no text")
        // Magic tap sits on the page, never on the stack that also holds
        // the failure state.
        let magicTap = ".accessibilityAction(.magicTap)"
        let bodyStart = try XCTUnwrap(screen.range(of: "    var body: some View {\n"))
        let bodyEnd = try XCTUnwrap(screen.range(of: "\n    }\n", range: bodyStart.upperBound..<screen.endIndex))
        let body = String(screen[bodyStart.upperBound..<bodyEnd.lowerBound])
        XCTAssertEqual(body.components(separatedBy: magicTap).count - 1, 2,
                       "two magic taps in the body, the page's and the bar's: \(body)")
        let page = try XCTUnwrap(body.range(of: "page(content: content, navigation: navigation)\n"))
        let failed = try XCTUnwrap(body.range(of: "} else if loadFailed {", range: page.upperBound..<body.endIndex))
        let pageBranch = String(body[page.upperBound..<failed.lowerBound])
        XCTAssertTrue(pageBranch.contains(magicTap), "the page plays and pauses: \(pageBranch)")
        let bar = try XCTUnwrap(body.range(of: "PlayerBarView(document: liveDocument"))
        let barEnd = try XCTUnwrap(body.range(of: ".accessibilityHidden(showAppearanceSheet)",
                                              range: bar.upperBound..<body.endIndex))
        let barModifiers = String(body[bar.upperBound..<barEnd.lowerBound])
        XCTAssertTrue(barModifiers.contains(magicTap), "the bar plays and pauses: \(barModifiers)")
        // The stack's own modifiers (it also holds the failure state) carry none.
        let stack = try XCTUnwrap(body.range(of: ".coordinateSpace(.named(Self.space))"))
        let stackEnd = try XCTUnwrap(body.range(of: ".navigationBarTitleDisplayMode(.inline)",
                                                range: stack.upperBound..<body.endIndex))
        let stackModifiers = String(body[stack.lowerBound..<stackEnd.upperBound])
        XCTAssertFalse(stackModifiers.contains(magicTap), stackModifiers)
        XCTAssertFalse(String(body[barEnd.upperBound...]).contains(magicTap),
                       "no screen-wide magic tap over the failure state")
    }

    /// The Mac's failure state reads the shared copy, its title a heading.
    func testTheMacFailureStateReadsTheSharedCopy() throws {
        guard SourceTree.exists(SourceTree.macRoot) else { throw XCTSkip("No Mac sources in this checkout") }
        let s = try SourceTree.sources(in: SourceTree.macRoot, only: ["Reader/MacReaderScreen.swift"])
        let mac = try XCTUnwrap(s["Reader/MacReaderScreen.swift"])
        XCTAssertTrue(mac.contains("Text(ReaderFailureCopy.title)"))
        XCTAssertTrue(mac.contains("Text(ReaderFailureCopy.detail)"))
        XCTAssertFalse(mac.contains("Couldn't open this book"), "no literal of its own")
        XCTAssertTrue(mac.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(mac.contains(".accessibilityAddTraits(.isHeader)"))
    }

    /// R2-11 on the Mac: a book that fails to open can be deleted from its
    /// failure state, confirmed with the shelf's wording, through the
    /// shared entry point (which also takes the reader's route off the
    /// stack), then back to the shelf.
    func testTheMacFailureStateOffersDelete() throws {
        guard SourceTree.exists(SourceTree.macRoot) else { throw XCTSkip("No Mac sources in this checkout") }
        let s = try SourceTree.sources(in: SourceTree.macRoot, only: ["Reader/MacReaderScreen.swift"])
        let mac = try XCTUnwrap(s["Reader/MacReaderScreen.swift"])
        let failure = try XCTUnwrap(mac.range(of: "private var failureState: some View {"))
        let state = String(mac[failure.lowerBound...].prefix(3_000))
        XCTAssertTrue(state.contains("Button(role: .destructive) { confirmingDelete = true }"), state)
        XCTAssertTrue(state.contains("Text(ReaderFailureCopy.deleteBook)"), state)
        XCTAssertTrue(state.contains(".accessibilityIdentifier(\"reader.deleteBook\")"), state)
        XCTAssertTrue(state.contains("ReaderFailureCopy.deleteTitle("), state)
        XCTAssertTrue(state.contains("Button(DocumentAction.delete.title, role: .destructive) { deleteFailedBook() }"),
                      state)
        XCTAssertTrue(state.contains("DocumentAction.deleteMessage(for:)"), state)
        XCTAssertTrue(state.contains("Text(failure.nextStep)"), "a delete that fails says why")
        let delete = try XCTUnwrap(mac.range(of: "private func deleteFailedBook() {"))
        let body = String(mac[delete.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("model.deleteDocument(document)"), body)
        XCTAssertTrue(body.contains("router.popToRoot()"), body)
    }

    // MARK: R2-12: Look Up names its word

    func testLookUpNamesTheWordItWillDefine() throws {
        XCTAssertEqual(ReaderMenuCopy.lookUpTitle(for: "borne"), "Look Up \u{201C}borne\u{201D}")
        XCTAssertEqual(ReaderMenuCopy.lookUpTitle(for: nil), "Look Up", "no word under the finger")
        let limit = String(repeating: "a", count: ReaderMenuCopy.lookUpTermLimit)
        XCTAssertEqual(ReaderMenuCopy.lookUpTitle(for: limit), "Look Up \u{201C}\(limit)\u{201D}")
        XCTAssertEqual(ReaderMenuCopy.lookUpTitle(for: limit + "a"), "Look Up", "past the limit, plain")
        let s = try SourceTree.sources(only: ["Reader/ReaderTextView.swift"])
        let view = try XCTUnwrap(s["Reader/ReaderTextView.swift"])
        XCTAssertFalse(view.contains("ReaderMenuCopy.lookUp(nil)"), "the term is no longer dropped")
        XCTAssertTrue(view.contains("ReaderMenuCopy.lookUpTitle(for: term)"))
    }
}
