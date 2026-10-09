import XCTest
@testable import Aloud

/// R3-07: the plan a cold start splits a long sentence by. Pure: speeds in,
/// piece sizes out, the same on both apps.
final class ColdLeadPlanTests: XCTestCase {

    private static let wpm = LibraryDocument.spokenWordsPerMinute
    /// A 60-word sentence with a comma after every fourth word.
    private static let everyFourth = Array(stride(from: 4, through: 56, by: 4))

    private func counts(k: Double?, words: Int = 60, clauseEnds: [Int] = everyFourth,
                        rate: Double = 1.5, nativeSpeed: Double = 1.5,
                        budget: TimeInterval? = 1.0) -> [Int] {
        ColdLeadPlan.pieceWordCounts(words: words, clauseEnds: clauseEnds, wordsPerMinute: Self.wpm,
                                     rate: rate, nativeSpeed: nativeSpeed, synthesisSpeed: k,
                                     firstAudioBudget: budget)
    }

    /// Making pieces 2...i takes no longer than listening to 1...i-1: each
    /// piece lands before the audio ahead of it runs out.
    private func assertStaysAhead(_ counts: [Int], k: Double, rate: Double = 1.5, nativeSpeed: Double = 1.5,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let listeningPerSecond = k * nativeSpeed / rate
        for index in counts.indices.dropFirst() {
            let making = Double(counts[1...index].reduce(0, +)) / listeningPerSecond
            let heard = Double(counts[..<index].reduce(0, +))
            XCTAssertLessThanOrEqual(making, heard + 1e-9, "piece \(index + 1) of \(counts) starves the node",
                                     file: file, line: line)
        }
    }

    private func firstAudio(words: Int, k: Double, nativeSpeed: Double = 1.5) -> TimeInterval {
        Double(words) * 60 / (Self.wpm * nativeSpeed * k)
    }

    func testLeadsAreSizedToTheBudgetAndTheChainStaysAhead() {
        // k = 3: the lead made within the 1 s budget, then three times it,
        // then the rest.
        XCTAssertEqual(counts(k: 3), [12, 36, 12])
        XCTAssertEqual(counts(k: 6), [24, 36])
        XCTAssertEqual(counts(k: 2), [8, 16, 32, 4])
        for k in [2.0, 3.0, 6.0] {
            let plan = counts(k: k)
            XCTAssertEqual(plan.reduce(0, +), 60)
            assertStaysAhead(plan, k: k)
            XCTAssertLessThanOrEqual(firstAudio(words: plan[0], k: k), 1.0, "k \(k): the lead is made within budget")
            XCTAssertLessThan(firstAudio(words: plan[0], k: k), firstAudio(words: 60, k: k))
        }
    }

    /// Two pieces: the rest is made while the lead plays, so the lead is
    /// at least total / (k + 1).
    func testATwoPieceLeadCoversTheRest() {
        for k in [4.0, 5.0, 6.0, 8.0] {
            let plan = counts(k: k)
            guard plan.count == 2 else { continue }
            XCTAssertGreaterThanOrEqual(Double(plan[0]), 60 / (k + 1), "k \(k): \(plan)")
        }
        XCTAssertEqual(counts(k: 6).count, 2)
    }

    func testCutsFallOnlyAtClauseEnds() {
        for k in [2.0, 3.0, 4.5, 6.0] {
            let ends = counts(k: k).reduce(into: [Int]()) { $0.append(($0.last ?? 0) + $1) }.dropLast()
            for end in ends { XCTAssertTrue(Self.everyFourth.contains(end), "k \(k) cut at word \(end)") }
        }
        // No clause mark at all: never a cut at a bare space.
        XCTAssertEqual(counts(k: 3, clauseEnds: []), [60])
        // Marks only where no lead or tail could be.
        XCTAssertEqual(counts(k: 3, clauseEnds: [2, 58]), [60])
        // One mark too far on for the chain to stay ahead: made whole.
        XCTAssertEqual(counts(k: 2, clauseEnds: [4]), [60])
    }

    func testNoSplitUnderTheBudgetOrWithoutAMeasure() {
        XCTAssertEqual(counts(k: 6, words: 10, clauseEnds: [5]), [10], "made whole within budget")
        XCTAssertEqual(counts(k: 3, budget: nil), [60], "no budget, no split")
        XCTAssertEqual(counts(k: nil), [60], "no measured speed (the System voice), no split")
        XCTAssertEqual(counts(k: 0), [60])
    }

    func testClauseMarks() {
        for token in ["word,", "word;", "word:", "(aside)", "—", "word–", "said,\u{201D}", "it,\""] {
            XCTAssertTrue(ColdLeadPlan.endsClause(token), token)
        }
        for token in ["word", "word.", "Mr.", "end?", "\u{201C}Oh"] {
            XCTAssertFalse(ColdLeadPlan.endsClause(token), token)
        }
    }

    /// The token-level plan: pieces cover the tokens end to end, each
    /// handed its own spoken words, cut just past a clause mark.
    func testASentenceSplitsIntoItsClauses() throws {
        let words = (0..<60).map { "word\($0)" + (($0 + 1) % 4 == 0 && $0 < 59 ? "," : "") }
        let sentence = words.joined(separator: " ") + "."
        let tokens = SentenceSegmenter.tokenizeSentence(sentence)
        let plan = try XCTUnwrap(ColdLeadPlan.make(tokens: tokens, skipBrackets: true, wordsPerMinute: Self.wpm,
                                                   rate: 1.5, nativeSpeed: 1.5, synthesisSpeed: 3,
                                                   firstAudioBudget: 1.0))
        XCTAssertEqual(plan.pieces.map(\.words), [12, 36, 12])
        XCTAssertEqual(plan.pieces.first?.tokens.lowerBound, 0)
        XCTAssertEqual(plan.pieces.last?.tokens.upperBound, tokens.count)
        for (before, after) in zip(plan.pieces, plan.pieces.dropFirst()) {
            XCTAssertEqual(before.tokens.upperBound, after.tokens.lowerBound, "end to end")
            XCTAssertTrue(before.text.hasSuffix(","), before.text)
        }
        XCTAssertEqual(plan.pieces[0].text, words[0..<12].joined(separator: " "))
        XCTAssertEqual(plan.text, SentenceSegmenter.spokenText(sentence, skipBrackets: true))
        XCTAssertEqual(plan.rate, 1.5)

        let unmarked = (0..<60).map { "word\($0)" }.joined(separator: " ") + "."
        XCTAssertNil(ColdLeadPlan.make(tokens: SentenceSegmenter.tokenizeSentence(unmarked), skipBrackets: true,
                                       wordsPerMinute: Self.wpm, rate: 1.5, nativeSpeed: 1.5, synthesisSpeed: 3,
                                       firstAudioBudget: 1.0))
    }

    // MARK: - Seams

    private static let sampleRate = 24_000.0

    /// `before` s of quiet, `sound` s of a tone, `after` s of quiet.
    private func clip(before: TimeInterval, sound: TimeInterval = 0.5, after: TimeInterval,
                      nativeSpeed: Double = 1) -> SynthesizedAudio {
        let quiet = { (seconds: TimeInterval) in [Float](repeating: 0, count: Int(seconds * Self.sampleRate)) }
        let tone = (0..<Int(sound * Self.sampleRate)).map { Float(sin(Double($0) / 8)) * 0.5 }
        return SynthesizedAudio(samples: quiet(before) + tone + quiet(after), sampleRate: Self.sampleRate,
                                nativeSpeed: nativeSpeed)
    }

    private func quiet(atStartOf clip: SynthesizedAudio) -> TimeInterval {
        Double(clip.samples.firstIndex { abs($0) >= ColdLeadPlan.silenceFloor } ?? 0) / Self.sampleRate
    }

    private func quiet(atEndOf clip: SynthesizedAudio) -> TimeInterval {
        let last = clip.samples.lastIndex { abs($0) >= ColdLeadPlan.silenceFloor } ?? clip.samples.count - 1
        return Double(clip.samples.count - 1 - last) / Self.sampleRate
    }

    func testASeamSoundsLikeAComma() {
        for rate in [1.0, 2.0] {
            let lead = ColdLeadPlan.seamed(clip(before: 0.3, after: 0.5), trimsLeading: false, trimsTrailing: true,
                                           rate: rate, precedingTail: 0)
            XCTAssertEqual(quiet(atStartOf: lead.clip), 0.3, accuracy: 0.001, "a lead's start is its own")
            XCTAssertEqual(lead.tail, ColdLeadPlan.seamTarget / 2, accuracy: 0.001)
            let next = ColdLeadPlan.seamed(clip(before: 0.4, after: 0.4), trimsLeading: true, trimsTrailing: false,
                                           rate: rate, precedingTail: lead.tail)
            XCTAssertEqual(quiet(atEndOf: next.clip), 0.4, accuracy: 0.001, "the last piece's end is its own")
            // Media seconds play at `rate` here (nativeSpeed 1).
            let seam = (quiet(atEndOf: lead.clip) + quiet(atStartOf: next.clip)) / rate
            XCTAssertTrue(ColdLeadPlan.seamGap.contains(seam), "rate \(rate): seam \(seam) s")
        }
        // Too little quiet on both sides: padded to the gap's floor.
        let short = ColdLeadPlan.seamed(clip(before: 0.01, after: 0.3), trimsLeading: true, trimsTrailing: false,
                                        rate: 1, precedingTail: 0.02)
        XCTAssertEqual(quiet(atStartOf: short.clip) + 0.02, ColdLeadPlan.seamGap.lowerBound, accuracy: 0.001)
        // Nothing to hear: left as it is.
        let silent = SynthesizedAudio.silence(duration: 0.5)
        XCTAssertEqual(ColdLeadPlan.seamed(silent, trimsLeading: true, trimsTrailing: true, rate: 1,
                                           precedingTail: 0).clip.samples.count, silent.samples.count)
    }

    func testThePiecesJoinIntoOneClip() throws {
        let pieces = [clip(before: 0.1, after: 0.1, nativeSpeed: 1.5), clip(before: 0.1, after: 0.2, nativeSpeed: 1.5)]
        let joined = try XCTUnwrap(ColdLeadPlan.joined(pieces))
        XCTAssertEqual(joined.samples.count, pieces.reduce(0) { $0 + $1.samples.count })
        XCTAssertEqual(joined.nativeSpeed, 1.5)
        XCTAssertNil(ColdLeadPlan.joined([]))
    }
}

/// R3-07 in the controller: a seek onto a long, uncached sentence starts on
/// its lead clause, the rest following gaplessly as one sentence. Silent:
/// the rig's muted controller over an engine that makes silence at a set
/// speed.
@MainActor
final class ColdLeadPlaybackTests: XCTestCase {

    /// A warm stand-in for Kokoro that makes `secondsPerWord` of silence a
    /// word, taking a `k`th of that to make it, and reports `k` as its
    /// measured speed.
    final class PacedNeuralEngine: WarmableTtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = [KokoroVoiceCatalog.defaultVoice]
        let k: Double
        let secondsPerWord: TimeInterval
        private let lock = NSLock()
        private var log: [(text: String, audio: TimeInterval)] = []

        init(k: Double, secondsPerWord: TimeInterval = 0.2) {
            self.k = k
            self.secondsPerWord = secondsPerWord
        }

        var isWarm: Bool { true }
        func warmUp() async throws {}
        func release() {}
        var measuredSynthesisSpeed: Double? { k }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await synthesize(text, voice: voice, speed: 1)
        }

        func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
            let words = text.split(whereSeparator: \.isWhitespace).count
            let audio = Double(words) * secondsPerWord / max(speed, 0.1)
            lock.withLock { log.append((text, audio)) }
            try await Task.sleep(nanoseconds: UInt64(audio / k * 1_000_000_000))
            return .silence(duration: audio, sampleRate: 24_000, nativeSpeed: speed)
        }

        var requests: [(text: String, audio: TimeInterval)] { lock.withLock { log } }
    }

    private static let longSentence = 30
    /// 60 words, a comma after every sixth.
    private static let longText = (0..<60).map { "word\($0)" + (($0 + 1) % 6 == 0 && $0 < 59 ? "," : "") }
        .joined(separator: " ") + "."

    private static func content() -> DocContent {
        let sentences = (0..<40).map { index in
            Sentence(id: index, text: index == longSentence ? longText : "Line\(index) word word.", para: 0, page: 0)
        }
        return DocContent(title: "Cold lead", pageCount: 1, sentences: sentences,
                          paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<40, page: 0)], contentHash: "cold-lead")
    }

    private struct Started {
        let rig: PlaybackTestRig
        let engine: PacedNeuralEngine
        let plan: ColdLeadPlan
        let key: String
        let firstAudio: TimeInterval
        let requestMark: Int
    }

    /// Reading at sentence 0 in the natural voice, then a seek onto the long
    /// sentence, to its first audio.
    private func seekOntoTheLongSentence(k: Double = 3) async throws -> Started {
        let engine = PacedNeuralEngine(k: k)
        let paced = PlaybackTestRig(sentences: 40, kokoro: engine,
                                    extraRoutes: [PlaybackTestRig.michael.id: engine])
        paced.controller.voice = PlaybackTestRig.michael   // no book yet: nothing restarts
        let content = Self.content()
        paced.controller.load(document: PlaybackTestRig.makeDocument(hash: "cold-lead", sentences: 40),
                              content: content)
        paced.controller.play()
        try await paced.waitUntilPlayingOrSkip()

        let pace = NativeSpeed.tier(for: paced.controller.rate, engine: .kokoro)
        let tokens = SentenceSegmenter.tokenizeSentence(Self.longText)
        let plan = try XCTUnwrap(ColdLeadPlan.make(
            tokens: tokens, skipBrackets: paced.controller.skipBrackets,
            wordsPerMinute: LibraryDocument.spokenWordsPerMinute, rate: paced.controller.rate, nativeSpeed: pace,
            synthesisSpeed: k * ColdLeadPlan.headroom,
            firstAudioBudget: PlatformPlaybackTuning.coldLeadFirstAudioBudget))
        XCTAssertGreaterThan(plan.pieces.count, 1)
        let key = AudioClipCache.key(voice: PlaybackTestRig.michael, skipBrackets: paced.controller.skipBrackets,
                                     contentHash: content.contentHash, nativeSpeed: pace,
                                     sentenceID: Self.longSentence)
        XCTAssertNil(paced.cache.clip(forKey: key), "cold")

        let mark = paced.statuses.count
        let requestMark = engine.requests.count
        let start = Date()
        paced.controller.seek(to: Self.longSentence, andPlay: true)
        _ = await paced.waitUntil {
            paced.statuses[mark...].contains(.playing) && paced.controller.currentSentence == Self.longSentence
        }
        let firstAudio = Date().timeIntervalSince(start)
        XCTAssertEqual(paced.controller.status, .playing)
        return Started(rig: paced, engine: engine, plan: plan, key: key, firstAudio: firstAudio,
                       requestMark: requestMark)
    }

    private func pieceRequests(_ started: Started) -> [(text: String, audio: TimeInterval)] {
        started.engine.requests[started.requestMark...].filter { !$0.text.hasPrefix("Line") }
    }

    func testAColdSeekStartsOnTheLeadAndPlaysTheSentenceAsOne() async throws {
        let started = try await seekOntoTheLongSentence()
        let rig = started.rig
        let wholeSynthesis = 60 * started.engine.secondsPerWord / started.engine.k

        // First audio: the lead's synthesis, never the whole sentence's.
        XCTAssertEqual(pieceRequests(started).first?.text, started.plan.pieces.first?.text, "the lead is made first")
        XCTAssertLessThan(started.firstAudio, wholeSynthesis / 2, "first audio waits on the lead alone")

        // Every piece lands, then the joined clip is cached once.
        let cached = await rig.waitUntil(8) { rig.cache.clip(forKey: started.key) != nil }
        XCTAssertTrue(cached, "the joined clip is cached under the sentence's key")
        let pieces = pieceRequests(started)
        XCTAssertEqual(pieces.map(\.text), started.plan.pieces.map(\.text), "each piece made once, in order")
        XCTAssertFalse(pieces.contains { $0.text == Self.longText }, "never made whole")
        let pieceSeconds = pieces.reduce(0) { $0 + $1.audio }
        let joined = try XCTUnwrap(rig.cache.clip(forKey: started.key))
        XCTAssertEqual(joined.duration, pieceSeconds, accuracy: 0.001)
        let requests = started.engine.requests.count
        let again = try await rig.scheduler.synthesize(Self.longText, voice: PlaybackTestRig.michael,
                                                        speed: NativeSpeed.tier(for: rig.controller.rate,
                                                                                engine: .kokoro),
                                                        key: started.key)
        XCTAssertEqual(started.engine.requests.count, requests, "asked again, it comes from the cache")
        XCTAssertEqual(again.duration, joined.duration, accuracy: 0.001)

        // One sentence on the node: no starving between pieces (a dry
        // stretch would lengthen the clip), word timings run on across
        // each seam, and the sentence is still the one reading.
        XCTAssertEqual(rig.controller.currentSentence, Self.longSentence)
        let clip = try XCTUnwrap(rig.controller.wordTiming.clip(for: Self.longSentence))
        XCTAssertEqual(clip.duration, pieceSeconds, accuracy: 0.01, "the node never starved")
        let windows = clip.windows
        let tokens = SentenceSegmenter.tokenizeSentence(Self.longText)
        let spoken = tokens.indices.filter { tokens[$0].weight > 0 }
        XCTAssertEqual(windows.map(\.token), spoken, "every word, in order, across the seams")
        XCTAssertEqual(windows.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(windows.last?.end ?? -1, clip.duration, accuracy: 0.001)
        for (before, after) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(before.end, after.start, accuracy: 1e-6, "contiguous at token \(after.token)")
        }
        let scheduled = rig.events.filter {
            if case .scheduled(let sentence, _) = $0 { return sentence == Self.longSentence }
            return false
        }
        XCTAssertEqual(scheduled.count, 1, "reported scheduled once, as one sentence")
    }

    func testAPauseMidLeadResumesAtTheSameWord() async throws {
        let started = try await seekOntoTheLongSentence()
        let rig = started.rig
        let leadSeconds = try XCTUnwrap(pieceRequests(started).first?.audio)

        rig.controller.pause(rampsOut: false)
        let paused = rig.controller.currentSentenceElapsed
        XCTAssertLessThan(paused, leadSeconds, "paused inside the lead")
        let eventMark = rig.events.count

        // The rest lands on the paused node.
        let cached = await rig.waitUntil(8) { rig.cache.clip(forKey: started.key) != nil }
        XCTAssertTrue(cached)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, Self.longSentence)

        rig.controller.play(userInitiated: false)
        XCTAssertEqual(rig.controller.status, .playing)
        XCTAssertEqual(rig.controller.currentSentence, Self.longSentence, "the same sentence")
        XCTAssertFalse(rig.events[eventMark...].contains(.stopped), "the queue was kept, not rebuilt")
        let resumed = rig.controller.currentSentenceElapsed
        XCTAssertEqual(resumed, paused, accuracy: 0.25, "the same place in it")
        let clip = try XCTUnwrap(rig.controller.wordTiming.clip(for: Self.longSentence))
        XCTAssertEqual(WordTimingEstimator.wordIndex(at: resumed, in: clip.windows),
                       WordTimingEstimator.wordIndex(at: paused, in: clip.windows), "the same word")
    }
}

/// R3-07 in the scheduler: a cold lead is one job, its pieces made back to
/// back and handed on as each lands, the joined clip cached under its key.
final class ColdLeadSchedulerTests: XCTestCase {

    func testThePiecesAreOneJobAndTheJoinedClipIsCached() async throws {
        let engine = ColdLeadPlaybackTests.PacedNeuralEngine(k: 20, secondsPerWord: 0.05)
        let cache = AudioClipCache()
        let scheduler = SynthesisScheduler(engine: engine, cache: cache)
        let plan = ColdLeadPlan(pieces: [
            ColdLeadPlan.Piece(tokens: 0..<7, text: "one two three four,", words: 4),
            ColdLeadPlan.Piece(tokens: 7..<12, text: "five six seven.", words: 3),
        ], rate: 1)
        let voice = KokoroVoiceCatalog.defaultVoice
        let stream = await scheduler.synthesizeLead(plan, voice: voice, key: "lead")
        // Queued while the lead is being made: it waits for the whole chain.
        await scheduler.prefetch("warm up", voice: voice, key: "warm")
        var landed: [LandedPiece] = []
        for try await piece in stream { landed.append(piece) }

        XCTAssertEqual(landed.map { $0.piece?.text }, plan.pieces.map(\.text))
        XCTAssertEqual(landed.map(\.isLast), [false, true])
        XCTAssertEqual(engine.requests.prefix(2).map(\.text), plan.pieces.map(\.text), "nothing between the pieces")
        let joined = try XCTUnwrap(cache.clip(forKey: "lead"))
        XCTAssertEqual(joined.samples.count, landed.reduce(0) { $0 + $1.clip.samples.count })

        // Asked again, the cached clip comes whole, made by no one.
        let requests = engine.requests.count
        var again: [LandedPiece] = []
        for try await piece in await scheduler.synthesizeLead(plan, voice: voice, key: "lead") { again.append(piece) }
        XCTAssertEqual(again.count, 1)
        XCTAssertNil(again.first?.piece)
        XCTAssertEqual(engine.requests.count, requests)
    }
}
