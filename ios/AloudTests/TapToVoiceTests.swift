import XCTest
@testable import Aloud

/// Tap to voice: C3's phrase leads, C4's background pieces, C2's seeded
/// speed, and the scheduler's yields at piece boundaries (C4) and to a
/// Mac click's held warm-up (C5). Pure plans and a scheduler over fake
/// engines: the same on both apps.
@MainActor
final class TapToVoiceTests: XCTestCase {

    private static let wpm = LibraryDocument.spokenWordsPerMinute

    /// Seconds to make `words` at the plans' native 1.5 and `k`.
    private func making(_ words: Int, k: Double) -> TimeInterval {
        Double(words) * 60 / (Self.wpm * 1.5 * k)
    }

    private func plan(_ sentence: String, k: Double = 3, budget: TimeInterval? = 1.0,
                      rate: Double = 1.5, nativeSpeed: Double = 1.5) -> ColdLeadPlan? {
        ColdLeadPlan.make(tokens: SentenceSegmenter.tokenizeSentence(sentence), skipBrackets: true,
                          wordsPerMinute: Self.wpm, rate: rate, nativeSpeed: nativeSpeed, synthesisSpeed: k,
                          firstAudioBudget: budget)
    }

    /// The text before a phrase piece's engine comma.
    private func spokenEnd(of piece: ColdLeadPlan.Piece) -> String {
        String(piece.text.dropLast(piece.endsAtPhrase ? 1 : 0))
    }

    /// An engine speed at which `words` takes 1.5 s to make whole: split
    /// under the 1 s budget, with a lead of up to two thirds of it.
    private func slowEnough(for words: Int) -> Double {
        Double(words) * 60 / (Self.wpm * 1.5) / 1.5
    }

    private static let commaFree = "The old captain walked slowly along the narrow harbour wall and watched the grey "
        + "ships sail out into the morning fog."

    // MARK: - C3: phrase leads

    /// A comma-free sentence leads on its longest phrase made within the
    /// budget, cut before a phrase opener, its engine text alone ending in
    /// a comma; the pieces still cover the tokens end to end.
    func testACommaFreeSentenceLeadsOnAPhraseWithinTheBudget() throws {
        let tokens = SentenceSegmenter.tokenizeSentence(Self.commaFree)
        let k = slowEnough(for: 21)
        let made = try XCTUnwrap(plan(Self.commaFree, k: k), "split, not made whole")
        let lead = try XCTUnwrap(made.pieces.first)
        XCTAssertTrue(lead.endsAtPhrase)
        XCTAssertTrue(lead.text.hasSuffix(","), lead.text)
        XCTAssertLessThanOrEqual(making(lead.words, k: k), 1.0, "made within the budget")
        XCTAssertGreaterThanOrEqual(lead.words, ColdLeadPlan.minimumLeadWords)
        let next = try XCTUnwrap(made.pieces.dropFirst().first)
        let opener = try XCTUnwrap(next.text.split(separator: " ").first.map(String.init))
        XCTAssertTrue(ColdLeadPlan.opensPhrase(opener), "cut before a phrase opener, got \(opener)")
        // The comma is the engine's alone: the tokens say the words as written.
        let spokenLead = SentenceSegmenter.spokenText(tokens: Array(tokens[lead.tokens]), skipBrackets: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(spokenLead.hasSuffix(","), spokenLead)
        XCTAssertEqual(lead.text, spokenLead + ",")
        XCTAssertEqual(made.pieces.first?.tokens.lowerBound, 0)
        XCTAssertEqual(made.pieces.last?.tokens.upperBound, tokens.count)
        for (before, after) in zip(made.pieces, made.pieces.dropFirst()) {
            XCTAssertEqual(before.tokens.upperBound, after.tokens.lowerBound, "end to end")
        }
        XCTAssertEqual(made.pieces.reduce(0) { $0 + $1.words }, 21)
        XCTAssertEqual(made.pieces.last?.endsAtPhrase, false, "the last piece ends the sentence")
    }

    /// A clause mark that gives a lead within the budget still wins over
    /// any phrase.
    func testAClauseMarkWithinTheBudgetStillWins() throws {
        let marked = "The old captain walked slowly, along the narrow harbour wall and watched the grey ships "
            + "sail out into the morning fog."
        let made = try XCTUnwrap(plan(marked, k: slowEnough(for: 21)))
        XCTAssertEqual(made.pieces.first?.words, 5)
        XCTAssertEqual(made.pieces.first?.endsAtPhrase, false)
        XCTAssertEqual(made.pieces.first?.text, "The old captain walked slowly,")
    }

    /// No clause mark and no phrase opener: made whole, as before. Four
    /// words or fewer: never split.
    func testNoOpenerMeansWholeAndFourWordsNeverSplit() {
        let unmarked = (0..<40).map { "word\($0)" }.joined(separator: " ") + "."
        XCTAssertNil(plan(unmarked, k: 1))
        XCTAssertNil(plan("Walk to the sea.", k: 0.1))
        XCTAssertNil(plan(Self.commaFree, k: 3, budget: nil), "no budget, no split")
        XCTAssertNil(plan(Self.commaFree, k: 100), "made whole within the budget")
    }

    /// Phrase cuts keep the chain's limits: at most `maximumPieces`, the
    /// last at least `minimumTailWords`, the chain ahead of the voice.
    func testPhraseCutsKeepThePieceLimits() {
        let phrases = Array(stride(from: 3, to: 60, by: 3))
        for k in [1.0, 2.0, 3.0] {
            let counts = ColdLeadPlan.pieceWordCounts(words: 60, clauseEnds: [], phraseEnds: phrases,
                                                      wordsPerMinute: Self.wpm, rate: 1.5, nativeSpeed: 1.5,
                                                      synthesisSpeed: k, firstAudioBudget: 1.0)
            XCTAssertEqual(counts.reduce(0, +), 60)
            XCTAssertLessThanOrEqual(counts.count, ColdLeadPlan.maximumPieces, "k \(k): \(counts)")
            guard counts.count > 1 else { continue }
            XCTAssertGreaterThanOrEqual(counts[counts.count - 1], ColdLeadPlan.minimumTailWords, "k \(k): \(counts)")
            XCTAssertGreaterThanOrEqual(counts[0], ColdLeadPlan.minimumLeadWords)
            for index in counts.indices.dropFirst() {
                let makingRest = Double(counts[1...index].reduce(0, +)) / k
                XCTAssertLessThanOrEqual(makingRest, Double(counts[..<index].reduce(0, +)) + 1e-9, "k \(k): \(counts)")
            }
        }
        // A clause end within the budget: the phrase ends change nothing.
        let clauses = Array(stride(from: 4, through: 56, by: 4))
        for k in [2.0, 3.0, 6.0] {
            XCTAssertEqual(
                ColdLeadPlan.pieceWordCounts(words: 60, clauseEnds: clauses, phraseEnds: [5, 9, 13],
                                             wordsPerMinute: Self.wpm, rate: 1.5, nativeSpeed: 1.5,
                                             synthesisSpeed: k, firstAudioBudget: 1.0),
                ColdLeadPlan.pieceWordCounts(words: 60, clauseEnds: clauses, wordsPerMinute: Self.wpm, rate: 1.5,
                                             nativeSpeed: 1.5, synthesisSpeed: k, firstAudioBudget: 1.0))
        }
    }

    /// Coordinators, relatives, subordinators and a few prepositions open a
    /// phrase; never a determiner, "to", "of", nor the ambiguous "that"
    /// and "as".
    func testPhraseOpeners() {
        for token in ["and", "\u{201C}which", "Because", "when", "with", "for"] {
            XCTAssertTrue(ColdLeadPlan.opensPhrase(token), token)
        }
        for token in ["word", "into", "sand", "Anne", "theory", "The", "a", "an", "to", "of", "that", "as"] {
            XCTAssertFalse(ColdLeadPlan.opensPhrase(token), token)
        }
        for token in ["and", "who", "until"] {
            XCTAssertTrue(ColdLeadPlan.opensPhrase(token, in: ColdLeadPlan.strongPhraseOpeners), token)
        }
        for token in ["for", "in", "with"] {
            XCTAssertFalse(ColdLeadPlan.opensPhrase(token, in: ColdLeadPlan.strongPhraseOpeners), token)
        }
    }

    /// No phrase cut straight after a preposition, determiner, possessive,
    /// "to", an auxiliary or a contraction; after a content word, yes.
    func testNoPhraseCutAfterAWordThatNeedsWhatFollows() {
        for token in ["along", "for", "the", "an", "his", "to", "of", "was", "and", "that", "captain's",
                      "captain\u{2019}s", "didn't", "he'd", "boys'", "The"] {
            XCTAssertFalse(ColdLeadPlan.mayCutAfter(token), token)
        }
        for token in ["wall", "pocket", "slowly", "door", "watched", "ships\u{201D}"] {
            XCTAssertTrue(ColdLeadPlan.mayCutAfter(token), token)
        }
    }

    /// The review's cuts: "walked slowly along | the narrow" and "pocket
    /// for | the key" are never chosen at any engine speed or listener
    /// speed, and no phrase piece ends on a word a cut may not follow.
    func testNoLeadEndsOnAStrandedPrepositionOrDeterminer() {
        let pocket = "He reached into his pocket for the key to the old door and turned it slowly in the rusted lock."
        let speeds: [(rate: Double, native: Double)] = [(1, 1), (1.5, 1.25), (1.5, 1.5), (2.95, 2)]
        for sentence in [Self.commaFree, pocket] {
            for k in stride(from: 0.3, through: 12, by: 0.05) {
                for speed in speeds {
                    guard let made = plan(sentence, k: k, rate: speed.rate, nativeSpeed: speed.native) else { continue }
                    let label = "k \(k), \(speed): \(made.pieces.map(\.text))"
                    for piece in made.pieces.dropLast() where piece.endsAtPhrase {
                        let last = spokenEnd(of: piece).split(separator: " ").last.map(String.init) ?? ""
                        XCTAssertTrue(ColdLeadPlan.mayCutAfter(last), label)
                    }
                    for piece in made.pieces {
                        XCTAssertFalse(piece.text.hasPrefix("the "), label)
                        XCTAssertFalse(spokenEnd(of: piece).hasSuffix(" along"), label)
                        XCTAssertFalse(spokenEnd(of: piece).hasSuffix(" for"), label)
                    }
                }
            }
        }
    }

    /// At the iPhone 16 Pro's figure (about 3x real time, at the plan's
    /// headroom 2.55) and 1x, the comma-free fixture leads up to "and":
    /// past the budget (no opener earlier fits it), still much sooner than
    /// the whole sentence.
    func testAtTheIPhonesSpeedTheFixtureCutsBeforeAnd() throws {
        let made = try XCTUnwrap(plan(Self.commaFree, k: 3 * ColdLeadPlan.headroom, rate: 1, nativeSpeed: 1))
        XCTAssertEqual(made.pieces.first?.text, "The old captain walked slowly along the narrow harbour wall,")
        XCTAssertEqual(made.pieces.first?.endsAtPhrase, true)
        XCTAssertTrue(made.pieces[1].text.hasPrefix("and watched"), made.pieces[1].text)
        XCTAssertEqual(made.pieces.reduce(0) { $0 + $1.words }, 21)
    }

    /// A coordinator wins over a preposition when both give a lead within
    /// the budget, though the preposition's lead is longer.
    func testAStrongOpenerWinsOverAPrepositionWithinTheBudget() throws {
        let pocket = "He reached into his pocket for the key to the old door and turned it slowly in the rusted lock."
        // At k 6 and 1x, sixteen words are made within the budget: up to
        // "slowly | in" as well as "door | and".
        XCTAssertLessThanOrEqual(Double(16) * 60 / (Self.wpm * 6), 1.0)
        let made = try XCTUnwrap(plan(pocket, k: 6, rate: 1, nativeSpeed: 1))
        XCTAssertEqual(made.pieces.first?.text, "He reached into his pocket for the key to the old door,")
        XCTAssertTrue(made.pieces[1].text.hasPrefix("and turned"), made.pieces[1].text)
        // Only a preposition within the budget: it is taken.
        let slower = try XCTUnwrap(plan(pocket, k: 2.55, rate: 1, nativeSpeed: 1))
        XCTAssertEqual(slower.pieces.first?.text, "He reached into his pocket,")
        XCTAssertTrue(slower.pieces[1].text.hasPrefix("for the key"), slower.pieces[1].text)
        // The pure plan: the strong end, not the longer weak one.
        XCTAssertEqual(ColdLeadPlan.pieceWordCounts(words: 40, clauseEnds: [], phraseEnds: [6, 9],
                                                    strongPhraseEnds: [6], wordsPerMinute: Self.wpm, rate: 1,
                                                    nativeSpeed: 1, synthesisSpeed: 6, firstAudioBudget: 1.0).first,
                       6)
        XCTAssertEqual(ColdLeadPlan.pieceWordCounts(words: 40, clauseEnds: [], phraseEnds: [6, 9],
                                                    wordsPerMinute: Self.wpm, rate: 1,
                                                    nativeSpeed: 1, synthesisSpeed: 6, firstAudioBudget: 1.0).first,
                       9)
    }

    // MARK: - C4: background pieces

    /// Away from the voice, a long sentence is made in clause pieces of
    /// about `pieceSeconds`, never at a phrase; a quick one, or one with
    /// no clause mark or no measured speed, whole.
    func testBackgroundPiecesFollowClauseMarksOnly() throws {
        let clauses = Array(stride(from: 6, through: 54, by: 6))
        let counts = ColdLeadPlan.backgroundPieceWordCounts(words: 60, clauseEnds: clauses, wordsPerMinute: Self.wpm,
                                                            nativeSpeed: 1.5, synthesisSpeed: 2, pieceSeconds: 1)
        XCTAssertGreaterThan(counts.count, 1)
        XCTAssertLessThanOrEqual(counts.count, ColdLeadPlan.maximumPieces)
        XCTAssertEqual(counts.reduce(0, +), 60)
        let ends = counts.reduce(into: [Int]()) { $0.append(($0.last ?? 0) + $1) }.dropLast()
        for end in ends { XCTAssertTrue(clauses.contains(end), "cut at \(end), off a clause end") }
        XCTAssertEqual(ColdLeadPlan.backgroundPieceWordCounts(words: 60, clauseEnds: [], wordsPerMinute: Self.wpm,
                                                              nativeSpeed: 1.5, synthesisSpeed: 2, pieceSeconds: 1),
                       [60], "no clause mark: whole")
        XCTAssertEqual(ColdLeadPlan.backgroundPieceWordCounts(words: 8, clauseEnds: [4], wordsPerMinute: Self.wpm,
                                                              nativeSpeed: 1.5, synthesisSpeed: 20, pieceSeconds: 1),
                       [8], "quick to make: whole")
        XCTAssertEqual(ColdLeadPlan.backgroundPieceWordCounts(words: 60, clauseEnds: clauses, wordsPerMinute: Self.wpm,
                                                              nativeSpeed: 1.5, synthesisSpeed: nil, pieceSeconds: 1),
                       [60], "no measured speed: whole")
        let marked = Self.commaFree.replacingOccurrences(of: "wall and", with: "wall, and")
        let made = try XCTUnwrap(ColdLeadPlan.background(
            tokens: SentenceSegmenter.tokenizeSentence(marked), skipBrackets: true, wordsPerMinute: Self.wpm,
            rate: 1.5, nativeSpeed: 1.5, synthesisSpeed: 0.3, pieceSeconds: 1))
        XCTAssertEqual(made.pieces.map(\.endsAtPhrase), Array(repeating: false, count: made.pieces.count))
        XCTAssertTrue(made.pieces[0].text.hasSuffix("wall,"), made.pieces[0].text)
    }

    // MARK: - C2: the seeded speed

    func testTheSeededSpeedIsTheLastLaunchsAtItsShare() throws {
        XCTAssertNil(KokoroSherpaEngine.seededSynthesisSpeed(stored: nil, lowPower: false), "nothing kept")
        for bad in [0.0, -1.0, .nan, .infinity] {
            XCTAssertNil(KokoroSherpaEngine.seededSynthesisSpeed(stored: bad, lowPower: false), "\(bad) is no speed")
        }
        let seeded = try XCTUnwrap(KokoroSherpaEngine.seededSynthesisSpeed(stored: 3, lowPower: false))
        XCTAssertEqual(seeded, 3 * PlatformPlaybackTuning.seededSynthesisSpeedShare, accuracy: 1e-9)
        XCTAssertLessThan(PlatformPlaybackTuning.seededSynthesisSpeedShare, 1, "a discount")
        let lowPower = try XCTUnwrap(KokoroSherpaEngine.seededSynthesisSpeed(stored: 3, lowPower: true))
        XCTAssertLessThan(lowPower, seeded, "Low Power Mode counts on less")
        XCTAssertNotEqual(KokoroSherpaEngine.synthesisSpeedKey(numThreads: 2),
                          KokoroSherpaEngine.synthesisSpeedKey(numThreads: 4), "kept per thread count")

        // An engine starts from what its thread count kept, and only that.
        let suite = "aloud.tests.seededSpeed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(3.0, forKey: KokoroSherpaEngine.synthesisSpeedKey(numThreads: 2))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite)
        let two = KokoroSherpaEngine(modelDirectory: directory, numThreads: 2, runtimeConfigDirectory: nil,
                                     speedDefaults: defaults, lowPowerAtLaunch: false)
        XCTAssertEqual(try XCTUnwrap(two.measuredSynthesisSpeed), seeded, accuracy: 1e-9)
        let four = KokoroSherpaEngine(modelDirectory: directory, numThreads: 4, runtimeConfigDirectory: nil,
                                      speedDefaults: defaults, lowPowerAtLaunch: false)
        XCTAssertNil(four.measuredSynthesisSpeed)
        XCTAssertNil(KokoroSherpaEngine(modelDirectory: directory, numThreads: 2, runtimeConfigDirectory: nil,
                                        speedDefaults: nil, lowPowerAtLaunch: false).measuredSynthesisSpeed)
    }

    // MARK: - The scheduler

    private let voice = KokoroVoiceCatalog.defaultVoice

    private static let fourPieces = ColdLeadPlan(pieces: [
        ColdLeadPlan.Piece(tokens: 0..<7, text: "one two three four,", words: 4),
        ColdLeadPlan.Piece(tokens: 7..<14, text: "five six seven eight,", words: 4),
        ColdLeadPlan.Piece(tokens: 14..<21, text: "nine ten eleven twelve,", words: 4),
        ColdLeadPlan.Piece(tokens: 21..<28, text: "thirteen fourteen fifteen sixteen.", words: 4),
    ], rate: 1)

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// A scheduler over an engine that parks its first call.
    private func parked(signposts: BudgetSignposts = .live) -> (SynthesisScheduler, CatchingUpTests.HeldEngine) {
        let held = CatchingUpTests.HeldEngine(voices: [voice], holding: 0)
        addTeardownBlock { held.release() }   // never leave a synthesis parked
        return (SynthesisScheduler(engine: held, cache: AudioClipCache(), signposts: signposts), held)
    }

    /// C1: a whole `now` job behind a different job in flight signposts
    /// its wait from its admit to its turn; with nothing ahead, no wait.
    func testAWholeNowJobBehindAJobInFlightSignpostsItsWait() async throws {
        let recorder = BudgetSignpostsTests.Recorder()
        let (scheduler, held) = parked(signposts: recorder.signposts)
        await scheduler.prefetch("A warm-up in flight.", voice: voice, key: "warm")
        let started = await eventually { held.isHolding }
        try XCTSkipUnless(started, "the warm-up never started")
        let start = Task { [voice] in try await scheduler.synthesize("Tapped.", voice: voice, key: "tap") }
        let waiting = await eventually { recorder.trace(.nowWait) == ["begin"] }
        XCTAssertTrue(waiting, "waiting in line, got \(recorder.trace(.nowWait))")
        held.release()
        _ = try await start.value
        XCTAssertEqual(recorder.trace(.nowWait), ["begin", "end"], "its turn came")
        _ = try await scheduler.synthesize("Nothing ahead.", voice: voice, key: "idle")
        XCTAssertEqual(recorder.trace(.nowWait), ["begin", "end"], "a start with nothing ahead never waits")
        XCTAssertEqual(recorder.trace(.leadWait), [], "a whole start is no lead")
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// C1: a whole start dropped while it waits (its tap superseded) gives
    /// its wait up.
    func testAWholeNowJobDroppedWhileWaitingGivesUp() async throws {
        let recorder = BudgetSignpostsTests.Recorder()
        let (scheduler, held) = parked(signposts: recorder.signposts)
        await scheduler.prefetch("A warm-up in flight.", voice: voice, key: "warm")
        let started = await eventually { held.isHolding }
        try XCTSkipUnless(started, "the warm-up never started")
        let start = Task { [voice] in try await scheduler.synthesize("Tapped.", voice: voice, key: "tap") }
        let waiting = await eventually { recorder.trace(.nowWait) == ["begin"] }
        XCTAssertTrue(waiting)
        start.cancel()
        let gaveUp = await eventually { recorder.trace(.nowWait) == ["begin", "gave up"] }
        XCTAssertTrue(gaveUp, "dropped before its turn, got \(recorder.trace(.nowWait))")
        XCTAssertEqual(recorder.unpaired, [])
    }

    /// C4: a look-ahead sentence made in four pieces whose waiter leaves
    /// (a tap's restart cancels the old top-up) stops at its next piece,
    /// and the tap's whole job runs after the one piece in flight.
    func testATapWaitsBehindOnePieceOfABackgroundJob() async throws {
        let (scheduler, held) = parked()
        let plan = Self.fourPieces
        let lookAhead = Task { [voice] in
            try await scheduler.synthesize(plan.text, voice: voice, key: "ahead", priority: .prefetch, plan: plan)
        }
        let started = await eventually { held.isHolding }
        try XCTSkipUnless(started, "the first piece never started")
        lookAhead.cancel()
        let tap = Task { [voice] in try await scheduler.synthesize("Tapped.", voice: voice, key: "tap") }
        let queued = await eventually { await scheduler.queuedKeys == ["tap"] }
        XCTAssertTrue(queued)
        held.release()
        _ = try await tap.value
        XCTAssertEqual(held.requestedTexts, [plan.pieces[0].text, "Tapped."], "one piece, then the tap")
    }

    /// C4 (a): a lead a pause left as a cue warm-up stops at its next piece
    /// once another start is admitted; Play on its own sentence still
    /// follows it, every piece replayed.
    func testADemotedWarmUpStopsAndASameKeyPlayFollowsIt() async throws {
        let plan = Self.fourPieces
        let (scheduler, held) = parked()
        await scheduler.prefetch(plan.text, voice: voice, key: "cue", plan: plan)
        let started = await eventually { held.isHolding }
        try XCTSkipUnless(started, "the warm-up never started")
        let tap = Task { [voice] in try await scheduler.synthesize("Elsewhere.", voice: voice, key: "tap") }
        let queued = await eventually { await scheduler.queuedKeys == ["tap"] }
        XCTAssertTrue(queued)
        held.release()
        _ = try await tap.value
        XCTAssertEqual(held.requestedTexts, [plan.pieces[0].text, "Elsewhere."], "demoted at its next piece")

        let (other, otherHeld) = parked()
        await other.prefetch(plan.text, voice: voice, key: "cue", plan: plan)
        let otherStarted = await eventually { otherHeld.isHolding }
        try XCTSkipUnless(otherStarted, "the warm-up never started")
        let stream = await other.synthesizeLead(plan, voice: voice, key: "cue")
        let nothingQueued = await other.queuedKeys
        XCTAssertEqual(nothingQueued, [], "followed, never queued again")
        otherHeld.release()
        var landed: [LandedPiece] = []
        for try await piece in stream { landed.append(piece) }
        XCTAssertEqual(landed.compactMap { $0.piece?.text }, plan.pieces.map(\.text))
        XCTAssertEqual(otherHeld.requestedTexts, plan.pieces.map(\.text), "each piece made once")
    }

    /// C4: a background job someone waits on delivers one joined clip, the
    /// one cached, with the pieces it was joined from on record, which cut
    /// it back end to end.
    func testABackgroundJobDeliversTheJoinedClipItCaches() async throws {
        let engine = ColdLeadPlaybackTests.PacedNeuralEngine(k: 20, secondsPerWord: 0.05)
        let cache = AudioClipCache()
        let scheduler = SynthesisScheduler(engine: engine, cache: cache)
        let plan = Self.fourPieces
        let clip = try await scheduler.synthesize(plan.text, voice: voice, key: "ahead", priority: .prefetch,
                                                  plan: plan)
        XCTAssertEqual(engine.requests.map(\.text), plan.pieces.map(\.text), "made in its pieces")
        XCTAssertEqual(cache.clip(forKey: "ahead")?.samples, clip.samples, "the clip given is the one cached")
        let recorded = await scheduler.madePieces(forKey: "ahead")
        let pieces = try XCTUnwrap(recorded)
        XCTAssertEqual(pieces.map(\.tokens), plan.pieces.map(\.tokens))
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.frames }, clip.samples.count)
        let slices = PlaybackController.slices(of: clip, into: pieces)
        XCTAssertEqual(slices.map(\.tokens), plan.pieces.map(\.tokens))
        XCTAssertEqual(slices.reduce(0) { $0 + $1.clip.samples.count }, clip.samples.count, "cut back end to end")
        let whole = try await scheduler.synthesize("made whole", voice: voice, key: "whole", priority: .prefetch)
        XCTAssertFalse(whole.samples.isEmpty)
        let none = await scheduler.madePieces(forKey: "whole")
        XCTAssertNil(none, "a clip made whole has no pieces")
    }

    /// C5: a Mac click's warm-up goes ahead of the warm-ups no one waits
    /// on; the jump that follows the hold follows it in flight, with no
    /// second job queued; and a dropped one stops at its next piece.
    func testAClickWarmUpIsFollowedByItsJumpOrDropped() async throws {
        let plan = Self.fourPieces
        // Ahead of the warm-ups no one waits on.
        let (ordered, orderedHeld) = parked()
        await ordered.prefetch("A warm-up in flight.", voice: voice, key: "warm")
        let parkedFirst = await eventually { orderedHeld.isHolding }
        try XCTSkipUnless(parkedFirst, "the warm-up never started")
        await ordered.prefetch("A skip warm-up.", voice: voice, key: "skip")
        await ordered.prefetch(plan.text, voice: voice, key: "click", plan: plan, aheadOfWarmUps: true)
        let order = await ordered.queuedKeys
        XCTAssertEqual(order, ["click", "skip"], "ahead of the other warm-ups")

        // The jump at the hold's end follows it in flight, every piece.
        let (scheduler, held) = parked()
        await scheduler.prefetch(plan.text, voice: voice, key: "click", plan: plan, aheadOfWarmUps: true)
        let started = await eventually { held.isHolding }
        try XCTSkipUnless(started, "the warm-up never started")
        let stream = await scheduler.synthesizeLead(plan, voice: voice, key: "click")
        let nothingQueued = await scheduler.queuedKeys
        XCTAssertEqual(nothingQueued, [], "followed, never queued again")
        held.release()
        var landed: [LandedPiece] = []
        for try await piece in stream { landed.append(piece) }
        XCTAssertEqual(landed.compactMap { $0.piece?.text }, plan.pieces.map(\.text), "every piece reaches the jump")
        XCTAssertEqual(held.requestedTexts, plan.pieces.map(\.text), "each piece made once")

        // Dropped (a double-click, a key): it stops at its next piece.
        let (other, otherHeld) = parked()
        await other.prefetch(plan.text, voice: voice, key: "click", plan: plan, aheadOfWarmUps: true)
        let otherStarted = await eventually { otherHeld.isHolding }
        try XCTSkipUnless(otherStarted, "the warm-up never started")
        await other.dropWarmUp(key: "click")
        otherHeld.release()
        let idle = await eventually { await other.inFlightKey == nil }
        XCTAssertTrue(idle)
        XCTAssertEqual(otherHeld.requestedTexts, [plan.pieces[0].text], "dropped at its next piece")
    }

    // MARK: - C4 in the controller

    /// 60 words, a comma after every sixth.
    private static let longText = (0..<60).map { "word\($0)" + (($0 + 1) % 6 == 0 && $0 < 59 ? "," : "") }
        .joined(separator: " ") + "."

    /// Reading from sentence 28 in the natural voice, the look-ahead
    /// reaches sentence 30, the long one: what the engine was asked for it.
    private func lookAheadRequests(following: Bool, strained: Bool, active: Bool = true) async throws -> [String] {
        let engine = ColdLeadPlaybackTests.PacedNeuralEngine(k: 3, secondsPerWord: 0.01)
        let rig = PlaybackTestRig(sentences: 40, kokoro: engine, extraRoutes: [PlaybackTestRig.michael.id: engine])
        rig.controller.voice = PlaybackTestRig.michael   // no book yet: nothing restarts
        rig.controller.readerIsFollowing = following
        rig.controller.isUnderStrain = { strained }
        rig.appActive = active
        let sentences = (0..<40).map { index in
            Sentence(id: index, text: index == 30 ? Self.longText : "Line\(index) word word.", para: 0, page: 0)
        }
        let content = DocContent(title: "Away", pageCount: 1, sentences: sentences,
                                 paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<40, page: 0)], contentHash: "away")
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "away", sentences: 40), content: content)
        rig.controller.seek(to: 28, andPlay: true)
        let asked = await rig.waitUntil(10) { engine.requests.contains { $0.text.hasSuffix("word59.") } }
        rig.controller.pause(rampsOut: false)
        XCTAssertTrue(asked, "the look-ahead reached the long sentence")
        return engine.requests.map(\.text).filter { $0.hasPrefix("word") }
    }

    /// C4 (b): with the page scrolled away from the voice and no strain,
    /// the long look-ahead sentence is made in clause pieces; following
    /// the voice, or under strain, whole as before.
    func testTheLookAheadIsMadeInPiecesOnlyWhileTheReaderIsAway() async throws {
        let away = try await lookAheadRequests(following: false, strained: false)
        XCTAssertGreaterThan(away.count, 1, "away: in clause pieces, got \(away)")
        XCTAssertLessThanOrEqual(away.count, ColdLeadPlan.maximumPieces)
        XCTAssertTrue(away.dropLast().allSatisfy { $0.hasSuffix(",") }, "each cut after a clause mark: \(away)")
        let following = try await lookAheadRequests(following: true, strained: false)
        XCTAssertEqual(following.count, 1, "following the voice: whole, got \(following)")
        let strained = try await lookAheadRequests(following: false, strained: true)
        XCTAssertEqual(strained.count, 1, "under strain: whole, got \(strained)")
    }

    /// C4: the page left scrolled away while the app is inactive (the
    /// iPhone locked or in the background, another app frontmost on the
    /// Mac): no tap can come, so the long look-ahead sentence is made
    /// whole.
    func testTheLookAheadIsMadeWholeWhileTheAppIsInactive() async throws {
        let inactive = try await lookAheadRequests(following: false, strained: false, active: false)
        XCTAssertEqual(inactive.count, 1, "inactive, reader away: whole, got \(inactive)")
        XCTAssertTrue(inactive.first?.hasSuffix("word59.") == true, "the whole sentence, got \(inactive)")
    }
}
