import XCTest
import SwiftUI
import UIKit
@testable import Aloud

/// R24 on a real reading column: an offscreen 390×800 `ReaderUITextView`
/// and its coordinator, built the way ReaderFollowCoordinatorTests builds
/// one. The colophon swaps in as one tail edit, fades in through a paper
/// veil only when it appears on screen, becomes the follow target, and reads
/// to VoiceOver as one label. No window, no controller, no audio.
@MainActor
final class ColophonColumnTests: XCTestCase {

    private final class Taps {
        var sentences: [Int] = []
    }

    /// Bumped by the text storage's notification, delivered on the main
    /// thread (the edit is made there).
    private final class Edits: @unchecked Sendable {
        var count = 0
    }

    private let colophon = ReaderColophon(title: "Lines", author: "A. Writer", words: 165 * 72, rate: 1)

    /// `count` one-line sentences, one paragraph each.
    private func lines(_ count: Int) -> DocContent {
        let sentences = (0..<count).map { Sentence(id: $0, text: "Line \($0) is short.", para: $0, page: 1) }
        let paragraphs = (0..<count).map { Paragraph(id: $0, sentenceIDs: $0..<($0 + 1), page: 1) }
        return DocContent(title: "Lines", pageCount: 1, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "colophon-column-\(count)")
    }

    private func makeColumn(count: Int = 160, height: CGFloat = 800, active: Int = 0,
                            colophon: ReaderColophon? = nil, reduceMotion: Bool = false,
                            taps: Taps = Taps()) throws
        -> (coordinator: ReaderTextView.Coordinator, textView: ReaderUITextView) {
        let content = lines(count)
        let parent = ReaderTextView(content: content, fontSize: 19, activeSentence: active, activeWord: -1,
                                    colophon: colophon,
                                    voiceOffscreen: .constant(nil), textUnderTopBar: .constant(false),
                                    onTapSentence: { taps.sentences.append($0) })
        let coordinator = ReaderTextView.Coordinator(parent: parent)
        let textView = ReaderUITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        coordinator.install(on: textView)
        coordinator.reduceMotion = { reduceMotion }
        coordinator.rebuild(content: content, fontSize: 19)
        textView.layoutIfNeeded()
        coordinator.setActiveSentence(active, scroll: false)
        textView.layoutIfNeeded()
        guard textView.contentSize.height > 2 * textView.bounds.height else {
            throw XCTSkip("This host doesn't lay out a text view outside a window")
        }
        return (coordinator, textView)
    }

    /// `range`'s laid-out rect in content coordinates, measured the way the
    /// coordinator measures (TextKit 2 text segments).
    private func rect(of range: NSRange, in textView: UITextView) -> CGRect? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(layoutManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var union = CGRect.null
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull else { return nil }
        return union.offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
    }

    private func colophonRect(_ coordinator: ReaderTextView.Coordinator, _ textView: UITextView) throws -> CGRect {
        try XCTUnwrap(rect(of: coordinator.endMarkRange, in: textView))
    }

    private func tail(_ textView: UITextView, _ coordinator: ReaderTextView.Coordinator) -> String {
        (textView.textStorage.string as NSString).substring(with: coordinator.endMarkRange)
    }

    /// Layout passes until any placement check has run its course
    /// (`placementPassLimit` is 12).
    private func settleLayout(_ textView: UITextView, passes: Int = 14) {
        for _ in 0..<passes {
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
        }
    }

    // MARK: - One tail edit

    func testShowAndHideAreOneTailEditEach() throws {
        let (coordinator, textView) = try makeColumn()
        let edits = Edits()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
        ) { _ in edits.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertEqual(tail(textView, coordinator), "· · ·")
        let mark = coordinator.endMarkRange
        let before = textView.textStorage.attributedSubstring(from: NSRange(location: 0, length: mark.location))

        coordinator.setColophon(colophon, animated: false)
        XCTAssertEqual(edits.count, 1, "one edit to show")
        XCTAssertEqual(coordinator.shownColophon, colophon)
        XCTAssertEqual(coordinator.endMarkRange.location, mark.location)
        XCTAssertEqual(NSMaxRange(coordinator.endMarkRange), textView.textStorage.length)
        XCTAssertEqual(tail(textView, coordinator),
                       ReaderColumnText.makeEndMark(colophon: colophon, fontSize: 19,
                                                    traits: textView.traitCollection).string)
        let after = textView.textStorage.attributedSubstring(from: NSRange(location: 0, length: mark.location))
        XCTAssertTrue(after.isEqual(to: before), "nothing above the end mark changes")
        XCTAssertNotNil(textView.textLayoutManager, "still TextKit 2")

        coordinator.setColophon(colophon, animated: true)
        XCTAssertEqual(edits.count, 1, "the same colophon again is no edit")
        XCTAssertNil(coordinator.colophonVeil, "and no fade")

        coordinator.setColophon(nil, animated: true)
        XCTAssertEqual(edits.count, 2, "one edit to hide")
        XCTAssertNil(coordinator.shownColophon)
        XCTAssertEqual(tail(textView, coordinator), "· · ·", "back to the dots")
        XCTAssertEqual(coordinator.endMarkRange, mark)
        XCTAssertNil(coordinator.colophonVeil)
        XCTAssertNotNil(textView.textLayoutManager)
    }

    // MARK: - The fade

    /// The voice is on sentence 0, about 5,000pt above the end mark, a
    /// region TextKit has only estimated. Following brings the colophon in
    /// with a jump, and the jump lays out the lines it lands on: real
    /// heights replace the estimates above the end mark and move it down.
    /// The veil is framed on that geometry, not on the estimate: framed
    /// before the follow scroll, it sat 63pt above the colophon.
    func testAppearingOnScreenFadesInThroughAPaperVeil() throws {
        let (coordinator, textView) = try makeColumn()
        settleLayout(textView)   // the build's placement check has ended
        let scrolls = coordinator.programmaticScrollCount
        coordinator.setColophon(colophon, animated: true)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "following brought the end in")

        let veil = try XCTUnwrap(coordinator.colophonVeil, "an end reached on screen fades in")
        let expected = try colophonRect(coordinator, textView)
        XCTAssertTrue(veil.superview === textView)
        XCTAssertEqual(veil.frame.minX, 0)
        XCTAssertEqual(veil.frame.width, textView.bounds.width)
        XCTAssertEqual(veil.frame.minY, expected.minY, accuracy: 0.5, "on the colophon from the start")
        XCTAssertEqual(veil.frame.height, expected.height, accuracy: 0.5)

        // And kept there by every layout pass while it fades.
        settleLayout(textView)
        let settled = try colophonRect(coordinator, textView)
        XCTAssertEqual(veil.frame.minY, settled.minY, accuracy: 0.5, "still on the colophon")
        XCTAssertEqual(veil.frame.height, settled.height, accuracy: 0.5)
        XCTAssertTrue(coordinator.colophonVeil === veil, "the same fade")
        XCTAssertFalse(veil.isUserInteractionEnabled, "taps reach the text")
        XCTAssertFalse(veil.isAccessibilityElement)
        XCTAssertEqual(veil.backgroundColor, UIColor(Theme.bg).resolvedColor(with: textView.traitCollection))

        // Opacity only, over Theme.Motion.colophon: nothing moves, so it is
        // the same under Reduce Motion.
        let fade = try XCTUnwrap(veil.layer.animation(forKey: "opacity"), "\(veil.layer.animationKeys() ?? [])")
        XCTAssertEqual(fade.duration, 0.6, accuracy: 1e-9)
        XCTAssertEqual(Theme.Motion.colophon, 0.6)
        XCTAssertEqual(veil.alpha, 0, "fading to clear")
        XCTAssertEqual(veil.layer.animationKeys()?.filter { $0 != "opacity" } ?? [], [], "no movement")
    }

    /// The reader is up at the top when the end comes, so nothing scrolls
    /// and the veil is framed on TextKit's estimate of the end. Scrolling
    /// down lays the end out for real, and the layout pass moves the veil
    /// with the colophon (`handleLayout`).
    func testALayoutPassKeepsAFadingVeilOnTheColophon() throws {
        let (coordinator, textView) = try makeColumn()
        settleLayout(textView)
        coordinator.userTookOverScroll()
        let scrolls = coordinator.programmaticScrollCount
        coordinator.setColophon(colophon, animated: true)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the reader has the scroll")
        let veil = try XCTUnwrap(coordinator.colophonVeil, "the end fades in all the same")

        // The reader scrolls down to where the end was estimated.
        let estimated = veil.frame
        textView.setContentOffset(CGPoint(x: 0, y: estimated.minY - textView.bounds.height / 2), animated: false)
        settleLayout(textView)

        let colophonNow = try colophonRect(coordinator, textView)
        XCTAssertTrue(coordinator.colophonVeil === veil, "the same fade")
        XCTAssertEqual(veil.frame.minY, colophonNow.minY, accuracy: 0.5, "the veil moved with the colophon")
        XCTAssertEqual(veil.frame.height, colophonNow.height, accuracy: 0.5)
        XCTAssertEqual(veil.frame.width, textView.bounds.width)
        XCTAssertEqual(veil.layer.animationKeys()?.filter { $0 != "opacity" } ?? [], [], "moved, not animated")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "still the reader's scroll")
    }

    func testNonAnimatedShowsAndRebuildsNeverFade() throws {
        let (coordinator, textView) = try makeColumn()
        coordinator.setColophon(colophon, animated: false)
        XCTAssertNil(coordinator.colophonVeil)

        coordinator.setColophon(nil, animated: false)
        coordinator.setColophon(colophon, animated: true)
        XCTAssertNotNil(coordinator.colophonVeil)
        // A rebuild (text size, Bold Text, light/dark) is a fresh column:
        // the veil goes, and none comes back.
        let veil = coordinator.colophonVeil
        coordinator.rebuild(content: coordinator.parent.content, fontSize: 19)
        XCTAssertNil(coordinator.colophonVeil)
        XCTAssertNil(veil?.superview, "the old veil left the column")
        XCTAssertFalse(textView.subviews.contains { $0 === veil })

        // A column built at the end (a reopen) shows it in place.
        let (reopened, reopenedView) = try makeColumn(active: 159, colophon: colophon)
        XCTAssertEqual(reopened.shownColophon, colophon)
        XCTAssertNil(reopened.colophonVeil, "a reopen never fades")
        XCTAssertEqual(tail(reopenedView, reopened),
                       ReaderColumnText.makeEndMark(colophon: colophon, fontSize: 19,
                                                    traits: reopenedView.traitCollection).string)
    }

    // MARK: - The follow target

    /// A reopen lands the colophon's top on the landing line. The column is
    /// short enough that the end of the text can reach it: the deep bottom
    /// inset is 45% of the screen, and the colophon plus that inset must
    /// cover the 72% of the view below the line.
    func testAReopenPlacesTheColophonOnTheLandingLine() throws {
        let (coordinator, textView) = try makeColumn(height: 560, active: 159, colophon: colophon)
        coordinator.placeActiveSentence()
        settleLayout(textView)

        let viewport = try XCTUnwrap(coordinator.viewport())
        let top = try colophonRect(coordinator, textView).minY
        XCTAssertEqual(top, viewport.minY + FollowBand.landing * viewport.height, accuracy: 1,
                       "the colophon's top at 28%")
    }

    /// The voice reaches the end low in the band; the colophon below it is
    /// out of the band, so following brings it in, once.
    func testANaturalEndWhileFollowingBringsTheColophonIntoTheBand() throws {
        let (coordinator, textView) = try makeColumn(active: 159, reduceMotion: true)
        try placeTheLastSentenceLowInTheBand(coordinator, textView)
        let scrolls = coordinator.programmaticScrollCount

        coordinator.setColophon(colophon, animated: true)
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "one follow scroll")
        settleLayout(textView)

        let viewport = try XCTUnwrap(coordinator.viewport())
        XCTAssertTrue(FollowBand.contains(try colophonRect(coordinator, textView), in: viewport),
                      "the colophon is in the band")
        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls + 1, "and stays put")
        XCTAssertTrue(coordinator.isFollowing)
    }

    func testANaturalEndAfterTheReaderScrolledAwayDoesNotScroll() throws {
        let (coordinator, textView) = try makeColumn(active: 159, reduceMotion: true)
        try placeTheLastSentenceLowInTheBand(coordinator, textView)
        coordinator.userTookOverScroll()
        let scrolls = coordinator.programmaticScrollCount
        let offset = textView.contentOffset

        coordinator.setColophon(colophon, animated: true)
        settleLayout(textView)

        XCTAssertEqual(coordinator.programmaticScrollCount, scrolls, "the reader has the scroll")
        XCTAssertEqual(textView.contentOffset, offset)
    }

    /// The last sentence placed, then the text moved (without a follow
    /// scroll) so the sentence sits at the bottom of the band and the
    /// colophon would land below it.
    private func placeTheLastSentenceLowInTheBand(_ coordinator: ReaderTextView.Coordinator,
                                                  _ textView: UITextView) throws {
        coordinator.placeActiveSentence()
        settleLayout(textView)
        let sentence = try XCTUnwrap(coordinator.measureActiveSentenceRect())
        let viewport = try XCTUnwrap(coordinator.viewport())
        let y = textView.contentOffset.y + sentence.maxY - (viewport.minY + 0.68 * viewport.height)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        settleLayout(textView)

        let moved = try XCTUnwrap(coordinator.viewport())
        XCTAssertTrue(FollowBand.contains(try XCTUnwrap(coordinator.measureActiveSentenceRect()), in: moved),
                      "the voice is in the band")
        // Where the colophon will start: right after the dots it replaces.
        let dots = try XCTUnwrap(rect(of: coordinator.endMarkRange, in: textView))
        XCTAssertGreaterThan(dots.maxY, moved.minY + FollowBand.bottom * moved.height,
                             "the end of the text is below the band")
    }

    // MARK: - Never a sentence

    func testATapOnTheColophonPlaysNothing() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(active: 159, colophon: colophon, taps: taps)
        coordinator.placeActiveSentence()
        settleLayout(textView)
        let area = try colophonRect(coordinator, textView)

        for y in stride(from: area.minY + 2, to: area.maxY, by: 12) {
            coordinator.handleTap(at: CGPoint(x: area.midX, y: y), isDecelerating: false)
        }
        XCTAssertEqual(taps.sentences, [], "the colophon is never tapped as a sentence")

        // The last sentence above it still plays.
        let last = try XCTUnwrap(rect(of: NSRange(location: (textView.textStorage.string as NSString)
            .range(of: "Line 159 is short.").location, length: 18), in: textView))
        coordinator.handleTap(at: CGPoint(x: last.minX + 8, y: last.midY), isDecelerating: false)
        XCTAssertEqual(taps.sentences, [159])
    }

    // MARK: - Light/dark (H017)

    /// A light/dark flip in the foreground (Control Center, sunset, the Aa
    /// sheet) set the whole book again and laid it out from the top on the
    /// main thread. Now the column takes the look in place: no rebuild, no
    /// storage edit, and the colophon's rule shows its variant for the new
    /// look.
    func testALightDarkFlipRecolorsTheColumnInPlace() throws {
        let (coordinator, textView) = try makeColumn(active: 159, colophon: colophon)
        coordinator.isInBackground = { false }
        let storage = textView.textStorage
        var rule: NSTextAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment { rule = attachment; stop.pointee = true }
        }
        let attachment = try XCTUnwrap(rule, "the colophon opens on a rule")
        let asset = try XCTUnwrap(attachment.image?.imageAsset, "the rule carries every look")
        let before = try XCTUnwrap(attachment.image?.pngData())
        let builds = coordinator.columnBuilds
        let recolors = coordinator.columnRecolors
        let text = storage.string
        let edits = Edits()
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: storage, queue: nil) { _ in edits.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let original = textView.traitCollection.userInterfaceStyle
        textView.overrideUserInterfaceStyle = original == .dark ? .light : .dark
        textView.updateTraitsIfNeeded()
        guard textView.traitCollection.userInterfaceStyle != original else {
            throw XCTSkip("This host doesn't override traits outside a window")
        }
        coordinator.rebuildForTraitChange()

        XCTAssertEqual(coordinator.columnBuilds, builds, "a recolor never sets the book again")
        XCTAssertEqual(coordinator.columnRecolors, recolors + 1)
        XCTAssertEqual(edits.count, 0, "no storage edit, so no layout from the top")
        XCTAssertEqual(storage.string, text)
        XCTAssertEqual(coordinator.builtLook, TraitLook(textView.traitCollection), "the new look is taken")
        let after = try XCTUnwrap(attachment.image?.pngData())
        XCTAssertEqual(after, asset.image(with: textView.traitCollection).pngData(), "the rule shows the new look")
        XCTAssertNotEqual(after, before, "accent differs between light and dark")
    }

    // MARK: - VoiceOver (R12)

    func testVoiceOverReadsTheColophonAsOneLabel() throws {
        let taps = Taps()
        let (coordinator, textView) = try makeColumn(active: 159, taps: taps)
        coordinator.setColophon(colophon, animated: false)

        XCTAssertEqual(textView.accessibilityLabel, colophon.spokenText)
        XCTAssertEqual(textView.accessibilityHint, "", "double-tap does nothing here")
        XCTAssertNil(textView.accessibilityValue)
        // Handled, doing nothing: a false has VoiceOver fall back to a tap
        // at the column's center, which played the sentence drawn there.
        XCTAssertTrue(textView.accessibilityActivate(), "double-tap is handled, so VoiceOver never taps the center")
        XCTAssertEqual(taps.sentences, [], "no sentence plays")
        let playFromHere = try XCTUnwrap(textView.accessibilityCustomActions?.first)
        XCTAssertEqual(playFromHere.actionHandler?(playFromHere), false, "Play from here still has nothing to play")
        XCTAssertEqual(taps.sentences, [])

        // A Sentences rotor step brings the sentence behaviour back.
        let rotor = try XCTUnwrap(textView.accessibilityCustomRotors?.first { $0.name == "Sentences" })
        let predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .next
        XCTAssertNotNil(rotor.itemSearchBlock(predicate))
        let sentence = try XCTUnwrap(coordinator.accessibilitySentence)
        XCTAssertEqual(textView.accessibilityLabel, coordinator.parent.content.sentences[sentence].text)
        XCTAssertEqual(textView.accessibilityHint, ReaderRotor.textHint)
        XCTAssertEqual(textView.accessibilityHint, "Plays from this sentence")
        XCTAssertTrue(textView.accessibilityActivate())
        XCTAssertEqual(taps.sentences, [sentence])

        // Played: the rotor position is gone, and the colophon reads again.
        XCTAssertEqual(textView.accessibilityLabel, colophon.spokenText)

        coordinator.setColophon(nil, animated: false)
        XCTAssertEqual(textView.accessibilityLabel, coordinator.parent.content.sentences[159].text)
        XCTAssertEqual(textView.accessibilityHint, ReaderRotor.textHint)
    }

    // MARK: - The shared column layout

    /// `ReaderColumnLayout` reaches the text through the content manager,
    /// never `.layoutManager`. That must be the very storage the colophon
    /// swap edits, or a deep jump's one-shot layout would measure another
    /// text and stop short.
    func testTheColumnLayoutReadsTheStorageTheColophonEdits() throws {
        let (coordinator, textView) = try makeColumn()
        let contentManager = try XCTUnwrap(textView.textLayoutManager?.textContentManager)
        let storage = (contentManager as? NSTextContentStorage)?.textStorage
        XCTAssertTrue(storage === textView.textStorage)
        coordinator.setColophon(colophon, animated: false)
        XCTAssertEqual(storage?.length, textView.textStorage.length, "the swap is seen through both")
        XCTAssertNotNil(textView.textLayoutManager, "still TextKit 2")
    }
}
