import XCTest
@testable import Aloud

final class WordTimingEstimatorTests: XCTestCase {

    private let accuracy = 1e-9

    private func windows(_ text: String,
                         duration: TimeInterval,
                         skipBrackets: Bool = false) -> [WordWindow] {
        WordTimingEstimator.windows(sentenceText: text,
                                    duration: duration,
                                    skipBrackets: skipBrackets)
    }

    // MARK: - Layout invariants

    func testDurationsSumToClipLength() {
        let clip = 3.7
        let result = windows("The quick brown fox jumps over the lazy dog.", duration: clip)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.start ?? -1, 0, accuracy: accuracy)
        XCTAssertEqual(result.last?.end ?? -1, clip, accuracy: accuracy)

        let total = result.reduce(0.0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(total, clip, accuracy: 1e-6)
    }

    func testWindowsAreContiguousAndMonotonic() {
        let result = windows("Alpha beta, gamma delta; epsilon zeta.", duration: 5.0)
        XCTAssertGreaterThan(result.count, 1)
        for window in result {
            XCTAssertLessThan(window.start, window.end)
        }
        for i in 1..<result.count {
            // Each window begins exactly where the previous ended (cumulative
            // end-times are strictly increasing).
            XCTAssertEqual(result[i].start, result[i - 1].end, accuracy: accuracy)
            XCTAssertGreaterThan(result[i].end, result[i - 1].end)
            // Token indices ascend into the original token array.
            XCTAssertGreaterThan(result[i].token, result[i - 1].token)
        }
    }

    func testWhitespaceTokensCarryNoWindow() {
        let text = "one two three"
        let tokens = SentenceSegmenter.tokenizeSentence(text)
        let result = windows(text, duration: 1.0)
        XCTAssertEqual(result.count, 3)
        for window in result {
            XCTAssertGreaterThan(tokens[window.token].weight, 0)
        }
    }

    // MARK: - Punctuation

    func testTrailingPunctuationSlowsWords() {
        // Identical words, one with a sentence-final mark: the punctuated word
        // must hold a strictly longer share of the same clip.
        let plain = windows("stop stop", duration: 2.0)
        let punctuated = windows("stop. stop", duration: 2.0)
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(punctuated.count, 2)

        let plainFirst = plain[0].end - plain[0].start
        let punctFirst = punctuated[0].end - punctuated[0].start
        XCTAssertEqual(plainFirst, 1.0, accuracy: accuracy)   // equal weights split evenly
        XCTAssertGreaterThan(punctFirst, plainFirst)
    }

    func testSentenceFinalMarkOutweighsComma() {
        let comma = windows("word, word", duration: 2.0)
        let period = windows("word. word", duration: 2.0)
        let commaFirst = comma[0].end - comma[0].start
        let periodFirst = period[0].end - period[0].start
        XCTAssertGreaterThan(periodFirst, commaFirst)
    }

    func testSyllableCountWeighsWords() {
        // "impossible" (4 vowel groups) should get more time than "it" (1).
        let result = windows("impossible it", duration: 5.0)
        XCTAssertEqual(result.count, 2)
        XCTAssertGreaterThan(result[0].end - result[0].start,
                             result[1].end - result[1].start)
    }

    // MARK: - Edges

    func testSingleWordSentenceSpansWholeClip() {
        let result = windows("Hello.", duration: 1.25)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, 0, accuracy: accuracy)
        XCTAssertEqual(result[0].end, 1.25, accuracy: accuracy)
        XCTAssertEqual(result[0].token, 0)
    }

    func testEmptyGuards() {
        XCTAssertTrue(windows("", duration: 1.0).isEmpty)
        XCTAssertTrue(windows("   ", duration: 1.0).isEmpty)
        XCTAssertTrue(windows("Hello world", duration: 0).isEmpty)
        XCTAssertTrue(windows("Hello world", duration: -1).isEmpty)
        XCTAssertTrue(windows("Hello world", duration: .nan).isEmpty)
        XCTAssertTrue(windows("Hello world", duration: .infinity).isEmpty)
        XCTAssertTrue(WordTimingEstimator.windows(tokens: [], duration: 1, skipBrackets: false).isEmpty)
    }

    func testSkipBracketsOmitsSkippableTokensButKeepsFullDuration() {
        let text = "Keep (drop this) going."
        let kept = windows(text, duration: 3.0, skipBrackets: true)
        let all = windows(text, duration: 3.0, skipBrackets: false)
        XCTAssertGreaterThan(all.count, kept.count)

        let tokens = SentenceSegmenter.tokenizeSentence(text)
        for window in kept {
            XCTAssertFalse(tokens[window.token].isSkippable)
        }
        // The spoken words still cover the entire (shorter) clip exactly.
        XCTAssertEqual(kept.first?.start ?? -1, 0, accuracy: accuracy)
        XCTAssertEqual(kept.last?.end ?? -1, 3.0, accuracy: accuracy)
    }

    func testFullySkippableSentenceFallsBackToAllTokens() {
        // spokenText speaks a fully bracketed sentence in full; the timing
        // layout mirrors that fallback instead of returning no windows.
        let text = "(An entire aside.)"
        let result = windows(text, duration: 2.0, skipBrackets: true)
        XCTAssertEqual(result, windows(text, duration: 2.0, skipBrackets: false))
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.first?.start ?? -1, 0, accuracy: accuracy)
        XCTAssertEqual(result.last?.end ?? -1, 2.0, accuracy: accuracy)
    }

    func testStandaloneDaggerCarriesNoWindowWhenSkipping() {
        let text = "Noted † indeed."
        let tokens = SentenceSegmenter.tokenizeSentence(text)
        let kept = windows(text, duration: 1.0, skipBrackets: true)
        XCTAssertEqual(kept.count, 2)
        for window in kept {
            XCTAssertFalse(tokens[window.token].isSkippable)
        }
    }

    // MARK: - wordIndex(at:)

    func testWordIndexLookup() {
        let result = windows("one two three four", duration: 4.0)
        XCTAssertEqual(result.count, 4)

        // Before the first window and past the last clamp to first/last token.
        XCTAssertEqual(WordTimingEstimator.wordIndex(at: -0.5, in: result), result[0].token)
        XCTAssertEqual(WordTimingEstimator.wordIndex(at: 99, in: result), result[3].token)

        // Every window's midpoint maps back to its own token.
        for window in result {
            let mid = (window.start + window.end) / 2
            XCTAssertEqual(WordTimingEstimator.wordIndex(at: mid, in: result), window.token)
        }
        // Boundaries are [start, end): an exact end time belongs to the next word.
        XCTAssertEqual(WordTimingEstimator.wordIndex(at: result[0].end, in: result),
                       result[1].token)
    }

    func testWordIndexEmptyWindows() {
        XCTAssertEqual(WordTimingEstimator.wordIndex(at: 0, in: []), -1)
    }
}
