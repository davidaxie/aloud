import XCTest
@testable import Aloud

/// Kokoro speaks part of the listener's speed itself (`NativeSpeed`) and
/// the time-pitch unit plays the rest: the pace table, the measured
/// compression, the cache keys, the scheduler and router carrying the pace,
/// the word timeline's wall time, and the controller's split. Silent: muted
/// controllers over engines that return silence.
final class NativeSpeedTests: XCTestCase {

    // MARK: - The pace for a speed

    func testThePaceGrowsWithTheSpeedAndStaysWithinTheTiers() {
        let pace = { NativeSpeed.tier(for: $0, engine: .kokoro) }
        XCTAssertEqual(pace(0.5), 1.0, "slower than 1x: the time-pitch unit alone")
        XCTAssertEqual(pace(1.0), 1.0)
        XCTAssertEqual(pace(1.1), 1.0, "a small speed-up stays with the time-pitch unit")
        XCTAssertEqual(pace(1.5), 1.25)
        XCTAssertEqual(pace(2.0), 1.5)
        XCTAssertEqual(pace(2.95), 2.0, "the listener's 2.95x: Kokoro speaks at 2x")
        XCTAssertEqual(pace(3.0), 2.0, "never past the fastest tier")
        var previous = 0.0
        for step in stride(from: 0.5, through: 3.0, by: 0.05) {
            let tier = pace(step)
            XCTAssertTrue(NativeSpeed.tiers.contains(tier), "\(step) → \(tier)")
            XCTAssertGreaterThanOrEqual(tier, previous, "the pace never drops as the speed rises (\(step))")
            previous = tier
        }
    }

    func testTheSystemVoiceKeepsItsOwnPace() {
        for rate in [0.5, 1.0, 2.0, 2.95, 3.0] {
            XCTAssertEqual(NativeSpeed.tier(for: rate, engine: .avSpeech), 1.0)
        }
        XCTAssertEqual(NativeSpeed.tier(for: .nan, engine: .kokoro), 1.0)
    }

    /// The time-pitch unit's share stays modest at every speed: what's left
    /// after Kokoro's share is never a 3x stretch.
    func testTheTimePitchShareStaysSmall() {
        for step in stride(from: 1.0, through: 3.0, by: 0.05) {
            let tier = NativeSpeed.tier(for: step, engine: .kokoro)
            for voice in ["kokoro:am_michael", "kokoro:am_puck", "kokoro:aloud_velvet"] {
                let residual = step / NativeSpeed.compression(speed: tier, voiceID: voice)
                XCTAssertLessThanOrEqual(residual, 1.8, "\(voice) at \(step)")
                XCTAssertGreaterThanOrEqual(residual, 0.95, "\(voice) at \(step)")
            }
        }
    }

    // MARK: - Measured compression

    func testCompressionFollowsTheMeasuredTable() {
        for (voice, row) in NativeSpeed.measured {
            XCTAssertEqual(row.count, 4, voice)
            XCTAssertEqual(NativeSpeed.compression(speed: 2.0, voiceID: voice), row[3], accuracy: 1e-9, voice)
            XCTAssertEqual(NativeSpeed.compression(speed: 1.25, voiceID: voice), row[0], accuracy: 1e-9, voice)
            var previous = 1.0
            for value in row {
                XCTAssertGreaterThan(value, previous, "\(voice): faster is always shorter")
                previous = value
            }
            XCTAssertLessThan(row[3], 2.0, "\(voice): Kokoro never quite halves")
        }
        XCTAssertEqual(NativeSpeed.compression(speed: 1.0, voiceID: "kokoro:am_michael"), 1.0)
        XCTAssertEqual(NativeSpeed.compression(speed: 0.8, voiceID: "kokoro:am_michael"), 0.8, accuracy: 1e-9)
        XCTAssertEqual(NativeSpeed.compression(speed: .infinity, voiceID: "kokoro:am_michael"), 1.0)
    }

    func testAnUnmeasuredVoiceUsesTheTypicalCompression() {
        XCTAssertEqual(NativeSpeed.compression(speed: 2.0, voiceID: "kokoro:unknown"),
                       NativeSpeed.typicalTable[3], accuracy: 1e-9)
        let between = NativeSpeed.compression(speed: 1.875, voiceID: "kokoro:am_michael")
        let row = NativeSpeed.measured["kokoro:am_michael"]!
        XCTAssertEqual(between, (row[2] + row[3]) / 2, accuracy: 1e-9, "linear between measured paces")
    }

    func testEveryListedNaturalVoiceIsMeasured() {
        for voice in KokoroVoiceCatalog.curatedVoices {
            XCTAssertNotNil(NativeSpeed.measured[voice.id], "\(voice.id) needs a measured row")
        }
    }

    // MARK: - Cache keys

    func testClipsAtAnotherPaceNeverStandIn() {
        let voice = KokoroVoiceCatalog.defaultVoice
        let at1 = AudioClipCache.key(voice: voice, skipBrackets: true, contentHash: "abc", nativeSpeed: 1.0, sentenceID: 4)
        let at2 = AudioClipCache.key(voice: voice, skipBrackets: true, contentHash: "abc", nativeSpeed: 2.0, sentenceID: 4)
        XCTAssertNotEqual(at1, at2)
        XCTAssertEqual(NativeSpeed.keyComponent(2.0), "x200")
        XCTAssertEqual(NativeSpeed.keyComponent(1.25), "x125")
        let prefix = AudioClipCache.keyPrefix(voice: voice, skipBrackets: true, contentHash: "abc")
        XCTAssertTrue(at1.hasPrefix(prefix) && at2.hasPrefix(prefix), "a voice or skip purge keeps every pace")
        XCTAssertNotEqual(AudioClipCache.key(voice: voice, skipBrackets: true, contentHash: "abc", nativeSpeed: 1.0,
                                             sentenceID: 1),
                          AudioClipCache.key(voice: voice, skipBrackets: true, contentHash: "abc", nativeSpeed: 1.0,
                                             sentenceID: 11), "sentence 1 and 11 never collide")
    }

    // MARK: - Carrying the pace

    /// Records the pace asked for, and answers with a clip that much
    /// shorter, saying so.
    final class PacedEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice]
        private let lock = NSLock()
        private var asked: [Double] = []

        init(voices: [TtsVoice]) { self.voices = voices }

        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            try await synthesize(text, voice: voice, speed: 1.0)
        }

        func synthesize(_ text: String, voice: TtsVoice, speed: Double) async throws -> SynthesizedAudio {
            lock.withLock { asked.append(speed) }
            let compression = NativeSpeed.compression(speed: speed, voiceID: voice.id)
            return .silence(duration: 0.3 / compression, sampleRate: 24_000, nativeSpeed: compression)
        }

        var speeds: [Double] { lock.withLock { asked } }
    }

    /// An engine that only knows its natural pace.
    final class NaturalEngine: TtsEngine, @unchecked Sendable {
        let voices: [TtsVoice] = []
        func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
            .silence(duration: 0.3)
        }
    }

    func testTheSchedulerAsksForThePaceAndKeepsPacesApart() async throws {
        let engine = PacedEngine(voices: [KokoroVoiceCatalog.defaultVoice])
        let scheduler = SynthesisScheduler(engine: engine, cache: AudioClipCache())
        let voice = KokoroVoiceCatalog.defaultVoice
        let fast = try await scheduler.synthesize("One.", voice: voice, speed: 2.0, key: "k|x200|0")
        XCTAssertEqual(fast.nativeSpeed, NativeSpeed.compression(speed: 2.0, voiceID: voice.id), accuracy: 1e-9)
        _ = try await scheduler.synthesize("One.", voice: voice, speed: 2.0, key: "k|x200|0")
        _ = try await scheduler.synthesize("One.", voice: voice, speed: 1.0, key: "k|x100|0")
        XCTAssertEqual(engine.speeds, [2.0, 1.0], "the same pace is served from the cache; another is made")
    }

    func testTheRouterForwardsThePaceAndANaturalEngineSaysSo() async throws {
        let voice = KokoroVoiceCatalog.defaultVoice
        let paced = PacedEngine(voices: [voice])
        let router = EngineRouter(system: NaturalEngine(), kokoro: paced)
        let clip = try await router.synthesize("One.", voice: voice, speed: 2.0)
        XCTAssertEqual(paced.speeds, [2.0])
        XCTAssertLessThan(clip.duration, 0.3)
        let system = TtsVoice(id: "system", name: "System", lang: "en-US", gender: "female",
                              engine: .avSpeech, quality: 1)
        let natural = try await router.synthesize("One.", voice: system, speed: 2.0)
        XCTAssertEqual(natural.nativeSpeed, 1.0, "an engine that can't speak faster returns its own pace")
        XCTAssertEqual(natural.naturalDuration, natural.duration, accuracy: 1e-9)
    }

    // MARK: - Wall time

    @MainActor
    func testWallTimeDividesEachClipsCompressionBackOut() {
        let timeline = WordKaraokeState()
        timeline.appendScheduled(sentence: 0, duration: 1.0, windows: [], compression: 1.0)
        timeline.appendGap(0.5)
        timeline.appendScheduled(sentence: 1, duration: 1.0, windows: [], compression: 2.0)
        XCTAssertEqual(timeline.clip(for: 1)?.start ?? -1, 1.5, accuracy: 1e-9, "a gap pushes later clips back")
        // 1 s of clip 0 at compression 1, 0.5 s gap at 2, 1 s of clip 1 at 2: 1 + 1 + 2 = 4 natural seconds.
        XCTAssertEqual(timeline.wallSeconds(from: 0, to: 2.5, rate: 2.0, gapCompression: 2.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(timeline.wallSeconds(from: 2.0, to: 2.5, rate: 1.0, gapCompression: 1.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(timeline.wallSeconds(from: 3, to: 2, rate: 1, gapCompression: 1), 0)
    }

    // MARK: - The controller's split

    @MainActor
    func testAtTwoNinetyFiveKokoroSpeaksAtTwiceAndTheUnitPlaysTheRest() async throws {
        let michael = KokoroVoiceCatalog.defaultVoice
        let paced = PacedEngine(voices: [michael])
        let rig = PlaybackTestRig(extraRoutes: [michael.id: paced])
        rig.controller.rate = 2.95
        rig.controller.voice = michael
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertFalse(paced.speeds.isEmpty)
        XCTAssertTrue(paced.speeds.allSatisfy { $0 == 2.0 }, "asked \(paced.speeds)")
        XCTAssertEqual(Double(rig.controller.timePitchRate),
                       2.95 / NativeSpeed.compression(speed: 2.0, voiceID: michael.id), accuracy: 0.001)
        rig.controller.pause(rampsOut: false)
    }

    @MainActor
    func testTheSystemVoiceLeavesTheWholeSpeedToTheUnit() async throws {
        let rig = PlaybackTestRig()
        rig.controller.rate = 2.0
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        XCTAssertEqual(rig.controller.timePitchRate, 2.0, accuracy: 0.0001)
        rig.controller.rate = 2.5   // a slider step: only the unit moves
        XCTAssertEqual(rig.controller.timePitchRate, 2.5, accuracy: 0.0001)
        rig.controller.pause(rampsOut: false)
    }

    /// A speed pick that changes Kokoro's pace mid-book: later sentences
    /// come at the new pace, and the unit switches to their share once they
    /// play; the queued clips keep theirs.
    @MainActor
    func testANewPaceTakesOverAtASentenceBoundary() async throws {
        let michael = KokoroVoiceCatalog.defaultVoice
        let paced = PacedEngine(voices: [michael])
        let rig = PlaybackTestRig(sentences: 30, extraRoutes: [michael.id: paced])
        rig.controller.rate = 2.95
        rig.controller.voice = michael
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.controller.selectRate(1.0)
        let switched = await rig.waitUntil(8) { abs(rig.controller.timePitchRate - 1.0) < 0.001 }
        XCTAssertTrue(switched, "the unit plays the new clips' share: \(rig.controller.timePitchRate)")
        XCTAssertEqual(paced.speeds.last, 1.0, "later sentences were asked at the new pace")
        XCTAssertTrue(paced.speeds.contains(2.0))
        rig.controller.pause(rampsOut: false)
    }
}
