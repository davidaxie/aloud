import Foundation

/// R3-07: how a cold start speaks a long sentence without first making all
/// of it. Kokoro renders a sentence whole before returning, so a jump that
/// misses the cache (a sentence tap, a search or scrub pick, a second
/// Forward 15) was silent for the whole synthesis: about 3x real time on
/// an iPhone's two threads, so 7 to 8 s at the segmenter's 350-character
/// cap. Instead the sentence is cut at its clause marks into a chain: a
/// lead made in about the first-audio budget, then pieces each made while
/// the audio already queued ahead of it plays. The chain plays gaplessly as
/// one sentence (`PlaybackController.scheduleColdLead`), and once every
/// piece has landed the joined clip is cached under the sentence's key.
///
/// Pure: the speeds come in, so the plan is the same on both apps and in
/// tests. A slower engine (Low Power Mode, heat) measures a lower speed,
/// so its chain grows from a shorter lead and needs more clause marks to
/// stay ahead of the voice.
struct ColdLeadPlan: Sendable, Equatable {

    struct Piece: Sendable, Equatable {
        /// Indices into the sentence's `SentenceSegmenter.tokenizeSentence`
        /// tokens; the pieces cover them in order, end to end.
        let tokens: Range<Int>
        /// What the engine is handed for this piece.
        let text: String
        /// Its spoken words.
        let words: Int
    }

    let pieces: [Piece]
    /// The listener's speed the plan was made at: a seam is sized in wall
    /// time at it (`seamed`).
    let rate: Double

    /// The whole sentence, as the pieces say it.
    var text: String { pieces.map(\.text).joined(separator: " ") }

    // MARK: - Tuning

    /// The marks a cut may follow: the set `SentenceSegmenter.softSplitLongSentence` cuts on.
    static let clauseMarks: Set<Character> = [",", ";", ":", ")", "—", "–", "、", "，", "；", "："]
    /// No lead shorter than this many words: a one-word lead is a stammer.
    static let minimumLeadWords = 4
    /// Nor a last piece shorter than this.
    static let minimumTailWords = 3
    /// A chain that would need more pieces than this is not planned.
    static let maximumPieces = 6
    /// The share of the measured speed a plan counts on: the engine's
    /// rolling figure is an average, and one slow piece must not starve
    /// the node.
    static let headroom = 0.85

    // MARK: - Planning

    /// Each piece's word count, in order: one entry (the whole sentence)
    /// when it should not be split.
    ///
    /// A word lasts `60 / (wordsPerMinute × rate)` wall seconds to the
    /// listener, and costs `60 / (wordsPerMinute × nativeSpeed × synthesisSpeed)`
    /// to make: the engine speaks at `nativeSpeed` and makes
    /// `synthesisSpeed` seconds of its audio per second. With serial
    /// synthesis, piece i (from the second on) lands before the audio ahead
    /// of it runs out when the making of pieces 2...i takes no longer than
    /// the listening to pieces 1...i-1. For two pieces that is
    /// `lead ≥ total / (k + 1)`, k the listening made per second of
    /// synthesis; a longer chain grows from a shorter lead (at k = 3, about
    /// 12 / 36 / the rest of 60 words).
    ///
    /// No split when the whole sentence's estimated first audio is within
    /// `firstAudioBudget` (or either figure is missing). The lead is the
    /// longest clause prefix made within the budget whose chain stays ahead
    /// of the voice, else the shortest whose chain does; each piece after it
    /// runs to the furthest clause end it can. Cuts fall only at
    /// `clauseEnds` (word counts after which a clause mark ends a word),
    /// never at a bare space: with no clause end where a lead could be, the
    /// sentence is made whole.
    static func pieceWordCounts(words: Int, clauseEnds: [Int], wordsPerMinute: Double, rate: Double,
                                nativeSpeed: Double, synthesisSpeed: Double?,
                                firstAudioBudget: TimeInterval?) -> [Int] {
        let whole = words > 0 ? [words] : []
        guard words > 0, let k = synthesisSpeed, let budget = firstAudioBudget,
              k.isFinite, k > 0, wordsPerMinute.isFinite, wordsPerMinute > 0,
              rate.isFinite, rate > 0, nativeSpeed.isFinite, nativeSpeed > 0 else { return whole }
        let secondsToMake = { (count: Int) in Double(count) * 60 / (wordsPerMinute * nativeSpeed * k) }
        guard secondsToMake(words) > budget else { return whole }
        // Listening seconds made per second of synthesis.
        let listeningPerSecond = k * nativeSpeed / rate
        let cuts = Array(Set(clauseEnds.filter { $0 >= minimumLeadWords && $0 <= words - minimumTailWords })).sorted()

        // The chain from `lead`, each piece as long as it can be; nil when
        // a gap opens with no clause end to close it.
        func chain(from lead: Int) -> [Int]? {
            var ends = [lead]
            while let covered = ends.last, covered < words {
                let reach = Double(lead) + listeningPerSecond * Double(covered)
                if reach >= Double(words) {
                    ends.append(words)
                } else if let next = cuts.last(where: { $0 > covered && Double($0) <= reach }) {
                    ends.append(next)
                } else {
                    return nil
                }
                if ends.count > maximumPieces { return nil }
            }
            return zip(ends, [0] + ends).map { $0 - $1 }
        }

        let feasible = cuts.compactMap { lead in chain(from: lead).map { (lead: lead, counts: $0) } }
        let withinBudget = feasible.filter { secondsToMake($0.lead) <= budget }
        return (withinBudget.last ?? feasible.first)?.counts ?? whole
    }

    /// The plan for a sentence's `tokens`, or nil to make it whole. The
    /// clause ends are its spoken tokens ending in a clause mark (a closing
    /// quote after it still counts); each piece is handed the spoken text
    /// of its own tokens.
    static func make(tokens: [WordToken], skipBrackets: Bool, wordsPerMinute: Double, rate: Double,
                     nativeSpeed: Double, synthesisSpeed: Double?,
                     firstAudioBudget: TimeInterval?) -> ColdLeadPlan? {
        guard synthesisSpeed != nil, firstAudioBudget != nil else { return nil }
        var words = 0
        var clauseEnds: [Int] = []
        // The token index each clause end cuts before, by word count.
        var cutBefore: [Int: Int] = [:]
        for (index, token) in tokens.enumerated()
        where token.weight > 0 && SentenceSegmenter.isSpoken(token, skipBrackets: skipBrackets) {
            if token.isWord { words += 1 }
            if endsClause(token.text), words > 0 {
                clauseEnds.append(words)
                cutBefore[words] = index + 1
            }
        }
        let counts = pieceWordCounts(words: words, clauseEnds: clauseEnds, wordsPerMinute: wordsPerMinute,
                                     rate: rate, nativeSpeed: nativeSpeed, synthesisSpeed: synthesisSpeed,
                                     firstAudioBudget: firstAudioBudget)
        guard counts.count > 1 else { return nil }
        var pieces: [Piece] = []
        var start = 0
        var spokenSoFar = 0
        for (offset, count) in counts.enumerated() {
            spokenSoFar += count
            let isLast = offset == counts.count - 1
            guard let end = isLast ? tokens.count : cutBefore[spokenSoFar], end > start else { return nil }
            let text = SentenceSegmenter.spokenText(tokens: Array(tokens[start..<end]), skipBrackets: skipBrackets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            pieces.append(Piece(tokens: start..<end, text: text, words: count))
            start = end
        }
        return ColdLeadPlan(pieces: pieces, rate: rate)
    }

    /// Whether a cut may follow `token`: its last mark, past any closing
    /// quotes, is a clause mark.
    static func endsClause(_ token: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", "]"]
        guard let last = token.reversed().first(where: { !closers.contains($0) }) else { return false }
        return clauseMarks.contains(last)
    }

    // MARK: - Seams

    /// The quiet a seam between two pieces lasts, in wall seconds at the
    /// listener's speed: about a comma's pause.
    static let seamGap: ClosedRange<TimeInterval> = 0.12...0.18
    /// What a seam aims at: half of it at the end of the piece before.
    static let seamTarget: TimeInterval = 0.15
    /// Below this a sample counts as quiet (-40 dBFS).
    static let silenceFloor: Float = 0.01

    /// `clip` with the quiet at its seams evened out. A piece before
    /// another (`trimsTrailing`) keeps at most half the target at its end;
    /// a piece after one (`trimsLeading`) keeps the rest of the target at
    /// its start, given the `precedingTail` the piece before kept, and is
    /// padded with silence up to the gap's lower bound when it has too
    /// little. Returns the wall seconds of quiet it kept at its end. A clip
    /// with no sound in it is left as it is.
    static func seamed(_ clip: SynthesizedAudio, trimsLeading: Bool, trimsTrailing: Bool, rate: Double,
                       precedingTail: TimeInterval) -> (clip: SynthesizedAudio, tail: TimeInterval) {
        let samples = clip.samples
        guard clip.sampleRate > 0, rate > 0, clip.nativeSpeed > 0,
              let firstLoud = samples.firstIndex(where: { abs($0) >= silenceFloor }),
              let lastLoud = samples.lastIndex(where: { abs($0) >= silenceFloor }) else { return (clip, 0) }
        // Wall seconds play `rate / nativeSpeed` media seconds.
        let framesPerWallSecond = clip.sampleRate * rate / clip.nativeSpeed
        let frames = { (wall: TimeInterval) in max(0, Int((wall * framesPerWallSecond).rounded())) }
        let leadingQuiet = firstLoud
        let trailingQuiet = samples.count - 1 - lastLoud

        var keepTrailing = trailingQuiet
        if trimsTrailing { keepTrailing = min(trailingQuiet, frames(seamTarget / 2)) }
        var keepLeading = leadingQuiet
        var pad = 0
        if trimsLeading {
            keepLeading = min(leadingQuiet, frames(seamTarget - precedingTail))
            pad = max(0, frames(seamGap.lowerBound - precedingTail) - keepLeading)
        }
        guard keepLeading != leadingQuiet || keepTrailing != trailingQuiet || pad > 0 else {
            return (clip, Double(trailingQuiet) / framesPerWallSecond)
        }
        var out = [Float](repeating: 0, count: pad)
        out.reserveCapacity(pad + keepLeading + (lastLoud - firstLoud + 1) + keepTrailing)
        out += samples[(firstLoud - keepLeading)..<(lastLoud + 1 + keepTrailing)]
        // The kept quiet fades to true zero at a trimmed edge.
        if trimsLeading { fade(&out, from: pad, count: keepLeading, rising: true) }
        if trimsTrailing { fade(&out, from: out.count - keepTrailing, count: keepTrailing, rising: false) }
        let seamed = SynthesizedAudio(samples: out, sampleRate: clip.sampleRate, nativeSpeed: clip.nativeSpeed)
        return (seamed, Double(keepTrailing) / framesPerWallSecond)
    }

    private static func fade(_ samples: inout [Float], from start: Int, count: Int, rising: Bool) {
        guard count > 0, start >= 0, start + count <= samples.count else { return }
        for offset in 0..<count {
            let gain = Float(offset) / Float(count)
            samples[start + offset] *= rising ? gain : 1 - gain
        }
    }

    /// The pieces as one clip: the sentence's audio as cached.
    static func joined(_ pieces: [SynthesizedAudio]) -> SynthesizedAudio? {
        guard let first = pieces.first else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(pieces.reduce(0) { $0 + $1.samples.count })
        for piece in pieces { samples += piece.samples }
        return SynthesizedAudio(samples: samples, sampleRate: first.sampleRate, nativeSpeed: first.nativeSpeed)
    }
}

/// Where a clip sits in its sentence: all of it, or one piece of a cold
/// lead's chain (`ColdLeadPlan`). Only a sentence's first clip switches the
/// time-pitch unit and reports it scheduled; only its last ends it.
struct SentencePart: Equatable, Sendable {
    let isFirst: Bool
    let isLast: Bool
    /// The tokens it speaks; nil for all of them.
    let tokens: Range<Int>?

    static let whole = SentencePart(isFirst: true, isLast: true, tokens: nil)
}
