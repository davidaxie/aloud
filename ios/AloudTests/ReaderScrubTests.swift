import XCTest
@testable import Aloud

/// R12c/R17: the scrub spans the current chapter (the whole book without
/// chapters), maps by words, steps by chapter or page row (else ±1 minute),
/// needs an 8pt horizontal drag, and previews words and a clock, never an
/// index.
final class ReaderScrubTests: XCTestCase {

    private static let minute = Array(repeating: "word", count: 165).joined(separator: " ")

    /// One sentence per entry, its own paragraph; nil text is 165 words.
    private func content(pages: [Int], texts: [String?]? = nil) -> DocContent {
        let sentences = pages.enumerated().map { index, page in
            Sentence(id: index, text: texts?[index] ?? Self.minute, para: index, page: page)
        }
        return DocContent(title: "Test", pageCount: pages.max() ?? 0, sentences: sentences,
                          paragraphs: [], contentHash: "h")
    }

    private func navigation(pages: [Int], texts: [String?]? = nil, kind: DocKind = .text) -> ReaderNavigation {
        ReaderNavigation(content: content(pages: pages, texts: texts), kind: kind)
    }

    private func words(_ count: Int) -> String {
        Array(repeating: "w", count: count).joined(separator: " ")
    }

    /// Pages [1,1,2,2,2,3]: chapter rows start at 0, 2 and 5.
    private let rows = [1, 1, 2, 2, 2, 3]

    // MARK: - Span

    func testChapteredTextSpansTheCurrentChapter() {
        let navigation = navigation(pages: rows)
        XCTAssertEqual(navigation.scrubSpan(at: 0), 0...1)
        XCTAssertEqual(navigation.scrubSpan(at: 3), 2...4)
        XCTAssertEqual(navigation.scrubSpan(at: 5), 5...5)
        XCTAssertEqual(navigation.scrubSpan(at: 99), 5...5, "clamped into the book")
        XCTAssertEqual(navigation.scrubSpan(at: -4), 0...1)
    }

    func testChapterlessTextSpansTheBook() {
        XCTAssertEqual(navigation(pages: [1, 1, 1, 1]).scrubSpan(at: 2), 0...3)
    }

    func testPDFSpansTheWholeDocument() {
        let pdf = navigation(pages: rows, kind: .pdf)
        XCTAssertEqual(pdf.scrubSpan(at: 0), 0...5)
        XCTAssertEqual(pdf.scrubSpan(at: 4), 0...5)
    }

    func testEmptyDocumentSpan() {
        let empty = navigation(pages: [])
        XCTAssertEqual(empty.scrubSpan(at: 0), 0...0)
        XCTAssertEqual(empty.scrubFraction(of: 0, in: 0...0), 0)
        XCTAssertEqual(empty.sentence(atFraction: 0.5, in: 0...0), 0)
        XCTAssertNil(empty.adjustmentTarget(from: 0, forward: true, rate: 1))
    }

    // MARK: - Words-linear mapping

    /// 10, 30 and 60 words: starts at 0, 10 and 40 of 100.
    private var weighted: ReaderNavigation {
        navigation(pages: [1, 1, 1], texts: [words(10), words(30), words(60)])
    }

    func testFractionsAreWordsLinear() {
        let navigation = weighted
        XCTAssertEqual(navigation.scrubFraction(of: 0, in: 0...2), 0)
        XCTAssertEqual(navigation.scrubFraction(of: 1, in: 0...2), 0.1, accuracy: 1e-9)
        XCTAssertEqual(navigation.scrubFraction(of: 2, in: 0...2), 0.4, accuracy: 1e-9)
    }

    func testFractionPicksTheNearestSentenceStart() {
        let navigation = weighted
        XCTAssertEqual(navigation.sentence(atFraction: 0.39, in: 0...2), 2)
        XCTAssertEqual(navigation.sentence(atFraction: 0.2, in: 0...2), 1)
        XCTAssertEqual(navigation.sentence(atFraction: 0, in: 0...2), 0)
        XCTAssertEqual(navigation.sentence(atFraction: 1, in: 0...2), 2)
        XCTAssertEqual(navigation.sentence(atFraction: -3, in: 0...2), 0, "clamped")
        XCTAssertEqual(navigation.sentence(atFraction: 7, in: 0...2), 2, "clamped")
    }

    func testFractionRoundTrips() {
        let byWords = weighted
        for sentence in 0...2 {
            let fraction = byWords.scrubFraction(of: sentence, in: 0...2)
            XCTAssertEqual(byWords.sentence(atFraction: fraction, in: 0...2), sentence)
        }
        let chaptered = navigation(pages: rows)
        for sentence in 2...4 {
            let fraction = chaptered.scrubFraction(of: sentence, in: 2...4)
            XCTAssertEqual(chaptered.sentence(atFraction: fraction, in: 2...4), sentence)
        }
    }

    func testZeroWordSpanFallsBackToSentenceCounts() {
        let navigation = navigation(pages: [1, 1, 1, 1], texts: ["", "", "", ""])
        XCTAssertEqual(navigation.scrubFraction(of: 2, in: 0...3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(navigation.sentence(atFraction: 0.5, in: 0...3), 2)
        XCTAssertEqual(navigation.sentence(atFraction: 1, in: 0...3), 3)
        XCTAssertEqual(navigation.sentence(atFraction: 0, in: 0...3), 0)
    }

    func testSecondsIntoSpanAtTheSpokenRate() {
        let navigation = navigation(pages: [1, 1, 1])
        XCTAssertEqual(navigation.secondsIntoSpan(of: 1, in: 0...2, rate: 1), 60, accuracy: 1e-9)
        XCTAssertEqual(navigation.secondsIntoSpan(of: 1, in: 0...2, rate: 2), 30, accuracy: 1e-9)
        XCTAssertEqual(navigation.secondsIntoSpan(of: 0, in: 0...2, rate: 1), 0)
        XCTAssertEqual(navigation.secondsIntoSpan(of: 2, in: 1...2, rate: 1), 60, accuracy: 1e-9,
                       "measured from the span's start, not the book's")
    }

    // MARK: - Adjustable steps

    func testChapteredTextStepsByChapterStart() {
        let navigation = navigation(pages: rows)
        XCTAssertEqual(navigation.adjustmentTarget(from: 0, forward: true, rate: 1), 2)
        XCTAssertEqual(navigation.adjustmentTarget(from: 1, forward: true, rate: 1), 2)
        XCTAssertEqual(navigation.adjustmentTarget(from: 2, forward: true, rate: 1), 5)
        XCTAssertNil(navigation.adjustmentTarget(from: 5, forward: true, rate: 1))

        XCTAssertEqual(navigation.adjustmentTarget(from: 4, forward: false, rate: 1), 2,
                       "past the chapter start: back to it")
        XCTAssertEqual(navigation.adjustmentTarget(from: 2, forward: false, rate: 1), 0,
                       "at the chapter start: the previous chapter")
        XCTAssertEqual(navigation.adjustmentTarget(from: 1, forward: false, rate: 1), 0)
        XCTAssertNil(navigation.adjustmentTarget(from: 0, forward: false, rate: 1))
    }

    func testStepsNeverReturnTheCurrentSentence() {
        for kind in [DocKind.text, .pdf] {
            for pages in [rows, [1, 1, 1, 1, 1]] {
                let navigation = navigation(pages: pages, kind: kind)
                for sentence in pages.indices {
                    for forward in [true, false] {
                        XCTAssertNotEqual(navigation.adjustmentTarget(from: sentence, forward: forward, rate: 1),
                                          sentence, "\(kind) \(pages) from \(sentence) forward \(forward)")
                    }
                }
            }
        }
    }

    func testChapterlessTextStepsAMinute() {
        let navigation = navigation(pages: [1, 1, 1, 1])
        XCTAssertEqual(navigation.adjustmentTarget(from: 0, forward: true, rate: 1), 1)
        XCTAssertEqual(navigation.adjustmentTarget(from: 0, forward: true, rate: 2), 2,
                       "a minute at 2× covers two 165-word sentences")
        XCTAssertEqual(navigation.adjustmentTarget(from: 3, forward: false, rate: 1), 2)
        XCTAssertNil(navigation.adjustmentTarget(from: 3, forward: true, rate: 1))
        XCTAssertNil(navigation.adjustmentTarget(from: 0, forward: false, rate: 1))
    }

    func testPDFStepsByPageRow() {
        let pdf = navigation(pages: rows, kind: .pdf)
        XCTAssertEqual(pdf.adjustmentTarget(from: 0, forward: true, rate: 1), 2)
        XCTAssertEqual(pdf.adjustmentTarget(from: 3, forward: true, rate: 1), 5)
        XCTAssertEqual(pdf.adjustmentTarget(from: 4, forward: false, rate: 1), 2)
        XCTAssertEqual(pdf.adjustmentTarget(from: 2, forward: false, rate: 1), 0)

        let onePage = navigation(pages: [1, 1, 1], kind: .pdf)
        XCTAssertEqual(onePage.adjustmentTarget(from: 0, forward: true, rate: 1), 1,
                       "one page row: a minute instead")
    }

    // MARK: - Gesture

    func testOnlyAHorizontalDragOfEightPointsSeeks() {
        XCTAssertEqual(ScrubGesture.minimumDistance, 8)
        XCTAssertFalse(ScrubGesture.isSeek(translation: .zero))
        XCTAssertFalse(ScrubGesture.isSeek(translation: CGSize(width: 5, height: 0)))
        XCTAssertFalse(ScrubGesture.isSeek(translation: CGSize(width: 0, height: 40)))
        XCTAssertTrue(ScrubGesture.isSeek(translation: CGSize(width: 8, height: 0)))
        XCTAssertTrue(ScrubGesture.isSeek(translation: CGSize(width: -100, height: 3)))
    }

    func testTrackFractionClamps() {
        XCTAssertEqual(ScrubGesture.fraction(atX: 50, width: 200), 0.25, accuracy: 1e-9)
        XCTAssertEqual(ScrubGesture.fraction(atX: -10, width: 200), 0)
        XCTAssertEqual(ScrubGesture.fraction(atX: 300, width: 200), 1)
        XCTAssertEqual(ScrubGesture.fraction(atX: 10, width: 0), 0)
    }

    func testDragKeepsItsSpan() {
        var drag = ScrubDrag(span: 2...4, target: 2)
        drag.target = 4
        XCTAssertEqual(drag, ScrubDrag(span: 2...4, target: 4))
    }

    /// Drags the way the bar runs them: each frame steps the gesture state
    /// (the preview) from the last and hands it to the latch in the same
    /// `.updating` call; `reset()` is SwiftUI clearing that state when a
    /// drag ends or the system cancels it.
    private final class DragRig {
        let latch = ScrubReleaseSpan()
        var playheadSpan: ClosedRange<Int>
        private(set) var preview: ScrubDrag?

        init(playheadSpan: ClosedRange<Int>) {
            self.playheadSpan = playheadSpan
        }

        func frame(_ width: CGFloat, height: CGFloat = 0) {
            preview = ScrubDrag.next(after: preview, translation: CGSize(width: width, height: height),
                                     current: { self.playheadSpan }, target: { $0.upperBound })
            latch.track(preview)
        }

        func reset() {
            preview = nil
        }

        func release(_ width: CGFloat, height: CGFloat = 0) -> ClosedRange<Int>? {
            latch.release(translation: CGSize(width: width, height: height)) { self.playheadSpan }
        }
    }

    func testADragFrameFreezesTheSpanOnItsFirstSeekFrame() {
        let rig = DragRig(playheadSpan: 2...4)
        rig.frame(3, height: 9)
        XCTAssertNil(rig.preview, "not a seek yet: no preview")
        rig.frame(-12)
        XCTAssertEqual(rig.preview, ScrubDrag(span: 2...4, target: 4))
        rig.playheadSpan = 5...5
        rig.frame(40)
        XCTAssertEqual(rig.preview?.span, 2...4, "the span never follows the playhead mid-drag")
        rig.frame(7)
        XCTAssertNil(rig.preview, "back under 8pt: no preview, so nothing seeks")
    }

    /// The release seeks in the span the drag froze, even when the voice
    /// carried the playhead into the next chapter before the finger lifted
    /// (onEnded can't read the gesture state: SwiftUI has reset it).
    func testReleaseSeeksInTheSpanTheDragFroze() {
        let rig = DragRig(playheadSpan: 2...4)
        rig.frame(3, height: 9)
        XCTAssertNil(rig.latch.span, "not a seek yet: nothing frozen")
        rig.frame(12)
        XCTAssertEqual(rig.latch.span, 2...4, "frozen on the first seek frame")

        rig.playheadSpan = 5...5   // the voice crossed into the next chapter mid-drag
        rig.frame(60, height: 2)
        XCTAssertEqual(rig.latch.span, rig.preview?.span, "the latch holds what the preview shows")
        rig.reset()
        XCTAssertEqual(rig.release(64, height: 2), 2...4, "the release lands in the chapter the preview showed")
        XCTAssertNil(rig.latch.span, "a release forgets the span")

        rig.frame(20)
        rig.reset()
        XCTAssertNil(rig.release(4, height: 30), "a release under 8pt sideways seeks nothing")
        XCTAssertNil(rig.latch.span, "and forgets the span too")
    }

    /// Back under 8pt the drag stops being a seek, as the preview does; over
    /// 8pt again it freezes the playhead's span of that moment.
    func testADragBackUnderEightPointsRefreezes() {
        let rig = DragRig(playheadSpan: 0...1)
        rig.frame(20)
        XCTAssertEqual(rig.latch.span, 0...1)
        rig.frame(2)
        XCTAssertNil(rig.latch.span)
        rig.playheadSpan = 2...4
        rig.frame(-15)
        XCTAssertEqual(rig.latch.span, 2...4)
        XCTAssertEqual(rig.preview?.span, 2...4)
    }

    /// A drag the system cancelled (an alert, Siri, a call) never reaches
    /// onEnded, so its span stays behind. The next drag, wherever it starts
    /// (keyed by the start x, one from the same point kept the stale
    /// chapter), seeks in the span its own preview froze.
    func testACancelledDragLendsNoSpanToTheNext() {
        let rig = DragRig(playheadSpan: 0...1)
        rig.frame(30)
        rig.frame(45)
        XCTAssertEqual(rig.latch.span, 0...1)
        rig.reset()                 // cancelled: no release
        rig.playheadSpan = 2...4    // and the voice moves on a chapter

        rig.frame(30)
        XCTAssertEqual(rig.preview?.span, 2...4, "the new drag's preview freezes the playhead's span")
        XCTAssertEqual(rig.latch.span, 2...4, "and so does its release")
        rig.reset()
        rig.playheadSpan = 5...5
        XCTAssertEqual(rig.release(44), 2...4)
    }

    /// A seek release whose frames never froze a span falls back to the
    /// playhead's.
    func testAReleaseWithNothingFrozenUsesThePlayheadsSpan() {
        let rig = DragRig(playheadSpan: 2...4)
        XCTAssertEqual(rig.release(40), 2...4)
        rig.playheadSpan = 0...1
        rig.frame(30)
        rig.frame(5)
        rig.reset()
        rig.playheadSpan = 2...4
        XCTAssertEqual(rig.release(9), 2...4)
    }

    // MARK: - Preview

    func testPreviewShowsSixTypesetWords() {
        let opening = "\"Well, Prince, so Genoa and Lucca are now just family estates of the Buonapartes."
        XCTAssertEqual(ScrubPreview.words(of: opening), "\u{201C}Well, Prince, so Genoa and Lucca\u{2026}")
    }

    func testPreviewDropsADanglingMarkBeforeTheEllipsis() {
        XCTAssertEqual(ScrubPreview.words(of: "It was the best of times, it was the worst of times."),
                       "It was the best of times\u{2026}")
        XCTAssertEqual(ScrubPreview.words(of: "I was going to say - but never mind that now."),
                       "I was going to say\u{2026}")
        XCTAssertEqual(ScrubPreview.words(of: "one two three four five six-- seven eight"),
                       "one two three four five six\u{2026}")
    }

    func testShortSentencesShowWhole() {
        XCTAssertEqual(ScrubPreview.words(of: "Call me Ishmael."), "Call me Ishmael.")
        XCTAssertEqual(ScrubPreview.words(of: "One two three four five six."), "One two three four five six.")
    }

    func testPreviewTextEndsWithTheClock() {
        XCTAssertTrue(ScrubPreview.text(sentence: "Call me Ishmael.", seconds: 245).hasSuffix(" · 4:05"))
        XCTAssertEqual(ScrubPreview.text(sentence: "Call me Ishmael.", seconds: 0), "Call me Ishmael. · 0:00")
    }

    func testPreviewNeverNamesASentenceIndex() throws {
        let pattern = try NSRegularExpression(pattern: "Sentence \\d+ of")
        let words = ["the", "river", "ran", "cold", "and", "slow", "past", "Sentence", "mill", "of"]
        for index in 0..<50 {
            let sentence = (0..<(3 + index % 9)).map { words[($0 * 7 + index) % words.count] }
                .joined(separator: " ") + "."
            let text = ScrubPreview.text(sentence: sentence, seconds: Double(index * 37))
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pattern.firstMatch(in: text, range: range), text)
        }
    }
}
