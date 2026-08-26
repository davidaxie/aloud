import Foundation

/// One word's playback window inside a sentence clip, in media time
/// (seconds at 1× — the clip's natural duration; the time-pitch unit's rate
/// is folded in by reading the player node's media-time position, so these
/// windows never need re-deriving on speed changes).
struct WordWindow: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// Index into the `SentenceSegmenter.tokenizeSentence` token array.
    let token: Int
}

/// Port of the web player's proven word-timing heuristic
/// (`frontend/src/lib/player.ts` `computeWindows` / `wordIndexAt`):
/// each non-whitespace token weighs its estimated syllable count plus a
/// trailing-punctuation pause bonus (sentence-final marks heavier than
/// clause marks), and the KNOWN exact clip duration is distributed across
/// the tokens proportionally. Pure and synchronous — trivially testable.
enum WordTimingEstimator {

    /// Lay the clip's duration out over the sentence's tokens by weight.
    ///
    /// Whitespace tokens (weight 0) carry no window. When `skipBrackets` is
    /// on, skippable tokens are omitted from BOTH the weight total and the
    /// layout — the spoken-token set comes from
    /// `SentenceSegmenter.isSpoken`, the same predicate `spokenText` uses
    /// to build the synthesized string, so timing and audio can never
    /// disagree. A fully skippable sentence synthesizes to empty text and
    /// plays as a short silence; it gets no windows here (`total == 0`).
    ///
    /// Windows are contiguous, monotonically increasing, start at 0 and end
    /// exactly at `duration`. Returns `[]` for empty input or a
    /// non-positive/non-finite duration.
    static func windows(tokens: [WordToken],
                        duration: TimeInterval,
                        skipBrackets: Bool) -> [WordWindow] {
        guard duration.isFinite, duration > 0 else { return [] }

        func spoken(_ token: WordToken) -> Bool {
            token.weight > 0 && SentenceSegmenter.isSpoken(token, skipBrackets: skipBrackets)
        }

        var total = 0.0
        for token in tokens where spoken(token) { total += token.weight }
        guard total > 0 else { return [] }

        var result: [WordWindow] = []
        result.reserveCapacity(tokens.count / 2 + 1)
        var accumulated = 0.0
        for (index, token) in tokens.enumerated() where spoken(token) {
            let start = (accumulated / total) * duration
            accumulated += token.weight
            let end = (accumulated / total) * duration
            result.append(WordWindow(start: start, end: end, token: index))
        }
        return result
    }

    /// Convenience: tokenize `sentenceText` and lay out its windows.
    static func windows(sentenceText: String,
                        duration: TimeInterval,
                        skipBrackets: Bool) -> [WordWindow] {
        windows(tokens: SentenceSegmenter.tokenizeSentence(sentenceText),
                duration: duration,
                skipBrackets: skipBrackets)
    }

    /// Token index of the word whose `[start, end)` window contains `time`
    /// (-1 only when `windows` is empty). Times before the first window clamp
    /// to the first word; times at/after the last window's end clamp to the
    /// last word — matching the web player, which keeps the final word lit
    /// through the inter-sentence gap. Binary search: O(log n) per frame.
    static func wordIndex(at time: TimeInterval, in windows: [WordWindow]) -> Int {
        guard let first = windows.first, let last = windows.last else { return -1 }
        if time <= first.start { return first.token }
        if time >= last.end { return last.token }

        var low = 0
        var high = windows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let window = windows[mid]
            if time < window.start {
                high = mid - 1
            } else if time >= window.end {
                low = mid + 1
            } else {
                return window.token
            }
        }
        return last.token
    }
}
