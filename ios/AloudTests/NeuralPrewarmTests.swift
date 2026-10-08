import Combine
import XCTest
@testable import Aloud

/// R18's pre-warm: Kokoro loads while the Continue card shows, for the
/// neural voice with the model installed, in the foreground and never under
/// Low Power Mode. A memory warning frees it and holds it cold until the card
/// appears again. It never touches playback's status, "Preparing voice…",
/// the schedule or announcements.
///
/// Silent and isolated: the frozen rig's muted controller (nothing plays),
/// a FakeNeuralEngine whose warm-up the test finishes by hand, card
/// visibility from a PassthroughSubject, install and Low Power Mode from
/// injected closures, and notifications on a private center.
@MainActor
final class NeuralPrewarmTests: XCTestCase {

    private typealias FakeNeuralEngine = PlaybackTestRig.FakeNeuralEngine

    /// What the injected closures answer.
    private final class Conditions {
        var modelInstalled = true
        var lowPowerMode = false
    }

    /// Which platform rules a harness follows: only the card asks, unless a
    /// test names an iPhone's or a Mac's rules (pinned here rather than
    /// taken from the host, so each test reads the same on both).
    private struct Rules {
        var forLoadedBook = false
        var atLaunch = false
        var holdEndsOnReturn = false
        var releasesPausedInBackground = false

        static let cardOnly = Rules()
        /// P010, P011, P013: a loaded book warms, the launch doesn't, the
        /// foreground ends a memory hold, the background frees a paused engine.
        static let iPhone = Rules(forLoadedBook: true, atLaunch: false, holdEndsOnReturn: true,
                                  releasesPausedInBackground: true)
        static let mac = Rules(forLoadedBook: true, atLaunch: true)
    }

    private struct Harness {
        let rig: PlaybackTestRig
        let neural: FakeNeuralEngine
        let card: PassthroughSubject<Bool, Never>
        let book: PassthroughSubject<UUID?, Never>
        let heat: CurrentValueSubject<Bool, Never>
        let conditions: Conditions
        let center: NotificationCenter
        let prewarm: NeuralPrewarm
    }

    /// Michael is the voice unless `neuralVoice` is false; no book is loaded.
    /// The scene starts as `sceneActive` says, never as the test host's
    /// app happens to be. Only the card asks for a warm-up unless `rules`
    /// say otherwise. Hot from the start only when `hot`, otherwise not
    /// until `heat` says so.
    private func makeHarness(neuralVoice: Bool = true, sceneActive: Bool = true,
                             rules: Rules = .cardOnly, hot: Bool = false) -> Harness {
        let neural = FakeNeuralEngine()
        let rig = PlaybackTestRig(neural: neural)
        if neuralVoice { rig.controller.voice = PlaybackTestRig.michael }
        let card = PassthroughSubject<Bool, Never>()
        let book = PassthroughSubject<UUID?, Never>()
        let heat = CurrentValueSubject<Bool, Never>(hot)
        let conditions = Conditions()
        let center = NotificationCenter()
        let prewarm = NeuralPrewarm(playback: rig.controller,
                                    kokoro: neural,
                                    cardVisible: card.eraseToAnyPublisher(),
                                    loadedBook: book.eraseToAnyPublisher(),
                                    isModelInstalled: { conditions.modelInstalled },
                                    isLowPowerMode: { conditions.lowPowerMode },
                                    heat: heat.eraseToAnyPublisher(),
                                    sceneActive: sceneActive,
                                    warmsForLoadedBook: rules.forLoadedBook,
                                    warmsAtLaunch: rules.atLaunch,
                                    memoryHoldEndsOnReturn: rules.holdEndsOnReturn,
                                    releasesPausedInBackground: rules.releasesPausedInBackground,
                                    notifications: center)
        return Harness(rig: rig, neural: neural, card: card, book: book, heat: heat, conditions: conditions,
                       center: center, prewarm: prewarm)
    }

    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits for the warm-up to be asked for, then lets it finish.
    private func warm(_ harness: Harness, call: Int = 1) async {
        let asked = await harness.rig.waitUntil(2) { harness.neural.warmUpCalls == call }
        XCTAssertTrue(asked, "warm-up \(call) should be asked for")
        harness.neural.finishWarmUp()
        let warmed = await harness.rig.waitUntil(2) { harness.neural.isWarm && !harness.prewarm.isWarming }
        XCTAssertTrue(warmed)
    }

    // MARK: - The rule

    func testShouldWarmTruthTable() {
        var rows = 0
        for bits in 0..<128 {
            let flag = { (bit: Int) in bits & (1 << bit) != 0 }
            let expected = flag(0) && flag(1) && flag(2) && flag(3) && !flag(4) && !flag(5) && !flag(6)
            XCTAssertEqual(NeuralPrewarm.shouldWarm(asked: flag(0),
                                                    sceneActive: flag(1),
                                                    modelInstalled: flag(2),
                                                    voiceIsNeural: flag(3),
                                                    lowPowerMode: flag(4),
                                                    hot: flag(6),
                                                    suppressedByMemoryWarning: flag(5)),
                           expected, "row \(bits)")
            rows += 1
        }
        XCTAssertEqual(rows, 128)
    }

    /// The card asks everywhere; a loaded book where the platform warms
    /// for it (both), the launch where it warms at launch (a Mac).
    func testWhatAsksForAWarmUp() {
        for bits in 0..<32 {
            let flag = { (bit: Int) in bits & (1 << bit) != 0 }
            let expected = flag(0) || (flag(3) && flag(1)) || (flag(4) && flag(2))
            XCTAssertEqual(NeuralPrewarm.asksForWarmUp(cardVisible: flag(0), bookLoaded: flag(1),
                                                       launchPending: flag(2), warmsForLoadedBook: flag(3),
                                                       warmsAtLaunch: flag(4)),
                           expected, "row \(bits)")
        }
    }

    /// P010: the iPhone warms for a loaded book (the reader LaunchRestore
    /// reopens) but never for a bare launch; the Mac does both.
    func testThePlatformsRules() {
        XCTAssertTrue(PlatformTuning.prewarmsForLoadedBook)
        #if os(iOS)
        XCTAssertFalse(PlatformTuning.prewarmsAtLaunch, "an iPhone launch never warms on its own")
        XCTAssertTrue(PlatformTuning.memoryHoldEndsOnReturn)
        #else
        XCTAssertTrue(PlatformTuning.prewarmsAtLaunch)
        XCTAssertFalse(PlatformTuning.memoryHoldEndsOnReturn)
        #endif
    }

    func testContinueCardVisibility() {
        let started = PlaybackTestRig.makeDocument(hash: "started", sentences: 10,
                                                   progressSentence: 3, progressFraction: 0.3)
        var opened = started
        opened.lastOpenedAt = Date()
        let fresh = PlaybackTestRig.makeDocument(hash: "fresh", sentences: 10)

        XCTAssertTrue(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [opened], loadedID: nil))
        XCTAssertFalse(NeuralPrewarm.continueCardVisible(pathIsEmpty: false, documents: [opened], loadedID: nil),
                       "a pushed screen covers the Library")
        XCTAssertFalse(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [], loadedID: nil))
        XCTAssertFalse(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [fresh], loadedID: nil),
                       "nothing listened to, nothing loaded: no card")
        XCTAssertTrue(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [fresh], loadedID: fresh.id),
                      "the loaded book is the card even at 0%")
        XCTAssertFalse(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [fresh], loadedID: UUID()),
                       "a loaded book that left the shelf shows nothing")

        // F045: a sleep stop in the last minute reads Finished, yet the card
        // offers it after a relaunch, so the card's warm-up follows the shelf.
        var stoppedNearTheEnd = PlaybackTestRig.makeDocument(hash: "near-end", sentences: 10,
                                                             progressSentence: 9, progressFraction: 0.995)
        stoppedNearTheEnd.lastOpenedAt = Date()
        XCTAssertTrue(stoppedNearTheEnd.isFinished, "the record reads Finished")
        let stop = PlaybackStop(reason: .sleepTimer, documentID: stoppedNearTheEnd.id)
        XCTAssertFalse(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [stoppedNearTheEnd],
                                                         loadedID: nil))
        XCTAssertTrue(NeuralPrewarm.continueCardVisible(pathIsEmpty: true, documents: [stoppedNearTheEnd],
                                                        loadedID: nil, stop: stop))
    }

    // MARK: - Warming

    func testWarmsOnceWhenTheCardShows() async {
        let harness = makeHarness()
        let rig = harness.rig

        harness.card.send(true)
        let asked = await rig.waitUntil(2) { harness.neural.warmUpCalls == 1 }
        XCTAssertTrue(asked)
        XCTAssertTrue(harness.prewarm.isWarming)
        harness.card.send(true)   // a repeat while loading starts nothing
        harness.prewarm.reevaluate()
        await elapse(0.2)
        XCTAssertEqual(harness.neural.warmUpCalls, 1)

        harness.neural.finishWarmUp()
        let warmed = await rig.waitUntil(2) { harness.neural.isWarm && !harness.prewarm.isWarming }
        XCTAssertTrue(warmed)
        harness.card.send(false)
        harness.card.send(true)   // already warm: nothing to do
        await elapse(0.2)
        XCTAssertEqual(harness.neural.warmUpCalls, 1)

        XCTAssertEqual(rig.statuses, [.idle], "playback never moved")
        XCTAssertFalse(rig.controller.isPreparingVoice)
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.announcements, [])
        XCTAssertNil(rig.controller.notice)
    }

    func testNoWarmUnderLowPowerMode() async {
        let harness = makeHarness()
        harness.conditions.lowPowerMode = true
        harness.card.send(true)
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)
        XCTAssertFalse(harness.prewarm.isWarming)
    }

    func testNoWarmForTheSystemVoice() async {
        let harness = makeHarness(neuralVoice: false)
        harness.card.send(true)
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)
    }

    func testNoWarmWithoutTheModel() async {
        let harness = makeHarness()
        harness.conditions.modelInstalled = false
        harness.card.send(true)
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)

        // AppModel re-evaluates when the install lands.
        harness.conditions.modelInstalled = true
        harness.prewarm.reevaluate()
        let asked = await harness.rig.waitUntil(2) { harness.neural.warmUpCalls == 1 }
        XCTAssertTrue(asked)
        harness.neural.finishWarmUp()
    }

    func testNoWarmWhileTheSceneIsInactive() async {
        let harness = makeHarness()
        harness.prewarm.sceneActivityChanged(false)
        harness.card.send(true)
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)

        harness.prewarm.sceneActivityChanged(true)
        await warm(harness)
    }

    /// An App Intent cold-launching Aloud in the background builds AppModel
    /// there: with the Continue card already "visible" the model must stay
    /// cold until the scene really comes forward.
    func testNoWarmWhenBuiltInTheBackground() async {
        let harness = makeHarness(sceneActive: false)
        harness.card.send(true)
        harness.prewarm.reevaluate()
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)
        XCTAssertFalse(harness.prewarm.isWarming)

        harness.prewarm.sceneActivityChanged(true)
        await warm(harness)
    }

    func testAVoiceChangeReevaluates() async {
        let harness = makeHarness(neuralVoice: false)
        harness.card.send(true)
        await elapse(0.2)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)

        harness.rig.controller.voice = PlaybackTestRig.michael   // no book: nothing restarts
        await warm(harness)
    }

    func testAPowerStateChangeReevaluates() async {
        let harness = makeHarness()
        harness.conditions.lowPowerMode = true
        harness.card.send(true)
        await elapse(0.2)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)

        harness.conditions.lowPowerMode = false
        harness.center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        await warm(harness)
    }

    func testLowPowerModeAndHidingTheCardNeverRelease() async {
        let harness = makeHarness()
        harness.card.send(true)
        await warm(harness)

        harness.conditions.lowPowerMode = true
        harness.center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        harness.card.send(false)
        await elapse(0.3)
        XCTAssertTrue(harness.neural.isWarm)
    }

    // MARK: - Beyond the card

    /// Where the platform warms beyond the card, the launch asks once (no
    /// card ever shows when a book opens straight into the reader), and a
    /// different book loaded after a memory warning asks again.
    func testTheLaunchAndALoadedBookWarmBeyondTheCard() async {
        let harness = makeHarness(rules: .mac)
        let rig = harness.rig
        harness.prewarm.reevaluate()
        await warm(harness)

        PlatformLifecycle.post(.memoryWarning, to: harness.center)
        let released = await rig.waitUntil(2) { !harness.neural.isWarm }
        XCTAssertTrue(released, "an idle engine gives its memory back")
        harness.prewarm.reevaluate()
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 1, "the launch asks once, never again behind a warning")

        harness.book.send(UUID())
        await warm(harness, call: 2)
        XCTAssertEqual(rig.statuses, [.idle], "playback never moved")
        XCTAssertFalse(rig.controller.isPreparingVoice)
    }

    /// Where only the card asks, neither the launch nor a loaded book warms
    /// the engine.
    func testOnlyTheCardWarmsWhereThePlatformDoesNotWarmBeyondIt() async {
        let harness = makeHarness(rules: .cardOnly)
        harness.prewarm.reevaluate()
        harness.book.send(UUID())
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)
    }

    /// P010: on an iPhone the launch alone asks for nothing; the reader for
    /// a natural-voice book that LaunchRestore reopens does, with no card
    /// ever showing, and playback never moves for it.
    func testTheIPhoneWarmsForALoadedBookButNotAtLaunch() async {
        let harness = makeHarness(rules: .iPhone)
        harness.prewarm.reevaluate()
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0, "a bare launch is no ask on an iPhone")

        harness.book.send(UUID())
        await warm(harness)
        XCTAssertEqual(harness.rig.statuses, [.idle], "playback never moved")
        XCTAssertFalse(harness.rig.controller.isPreparingVoice)
        XCTAssertNil(harness.rig.controller.notice)
    }

    /// P010: a loaded book under Low Power Mode, at `.serious` heat, in the
    /// background or behind a memory warning starts nothing.
    func testALoadedBookKeepsEveryGate() async {
        for gate in ["low power", "hot", "background", "memory warning"] {
            let harness = makeHarness(sceneActive: gate != "background", rules: .iPhone)
            if gate == "low power" { harness.conditions.lowPowerMode = true }
            if gate == "hot" { harness.heat.send(true) }
            if gate == "memory warning" {
                // The book loads first (a new book ends a hold), held back
                // by Low Power Mode until the warning lands.
                harness.conditions.lowPowerMode = true
                harness.book.send(UUID())
                PlatformLifecycle.post(.memoryWarning, to: harness.center)
                await elapse(0.1)
                harness.conditions.lowPowerMode = false
            } else {
                harness.book.send(UUID())
            }
            harness.prewarm.reevaluate()
            await elapse(0.3)
            XCTAssertEqual(harness.neural.warmUpCalls, 0, gate)
            XCTAssertFalse(harness.prewarm.isWarming, gate)
        }
    }

    /// The heat gate, on both apps (P010; R11's heat policy is shared): no
    /// warm-up while hot, whatever asks (the card, an iPhone's or a Mac's
    /// loaded book, a Mac's launch); cooling down asks again, and heating
    /// up never releases a warm engine.
    func testHeatHoldsTheWarmUpUntilItCools() async {
        for (name, rules) in [("card", Rules.cardOnly), ("iPhone", Rules.iPhone), ("Mac", Rules.mac)] {
            let harness = makeHarness(rules: rules, hot: true)
            harness.card.send(true)
            harness.book.send(UUID())
            await elapse(0.3)
            XCTAssertEqual(harness.neural.warmUpCalls, 0, name)

            harness.heat.send(false)
            await warm(harness)
            harness.heat.send(true)
            await elapse(0.2)
            XCTAssertTrue(harness.neural.isWarm, "\(name): heat alone never releases")
        }
    }

    /// P013: on an iPhone the app coming back to the foreground ends a
    /// memory warning's hold, with the reader's book still loaded; a Mac's
    /// window coming back doesn't.
    func testComingBackToTheForegroundEndsAMemoryHoldOnAnIPhone() async {
        for rules in [Rules.iPhone, Rules.mac] {
            let harness = makeHarness(rules: rules)
            harness.book.send(UUID())
            harness.prewarm.reevaluate()
            await warm(harness)
            PlatformLifecycle.post(.memoryWarning, to: harness.center)
            let released = await harness.rig.waitUntil(2) { !harness.neural.isWarm }
            XCTAssertTrue(released)

            harness.prewarm.sceneActivityChanged(false)
            harness.prewarm.sceneActivityChanged(true)
            if rules.holdEndsOnReturn {
                await warm(harness, call: 2)
            } else {
                await elapse(0.3)
                XCTAssertEqual(harness.neural.warmUpCalls, 1, "a Mac's hold waits for the card or another book")
            }
        }
    }

    /// A load holds the platform activity from its start to its end.
    func testAWarmUpHoldsTheActivityWhileItLoads() async {
        let harness = makeHarness()
        var begun: [String] = []
        var ended = 0
        harness.prewarm.activity = .init(begin: { reason in begun.append(reason); return nil },
                                         end: { _ in ended += 1 })
        harness.card.send(true)
        let asked = await harness.rig.waitUntil(2) { harness.neural.warmUpCalls == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(begun.count, 1)
        XCTAssertEqual(ended, 0, "held while it loads")
        harness.neural.finishWarmUp()
        let done = await harness.rig.waitUntil(2) { ended == 1 }
        XCTAssertTrue(done, "let go when it's loaded")
    }

    // MARK: - Memory warnings

    func testAMemoryWarningReleasesAndHoldsUntilTheCardReturns() async {
        let harness = makeHarness()
        let rig = harness.rig
        harness.card.send(true)
        await warm(harness)

        PlatformLifecycle.post(.memoryWarning, to: harness.center)
        let released = await rig.waitUntil(2) { !harness.neural.isWarm }
        XCTAssertTrue(released, "an idle engine gives its memory back")

        // Still showing, still suppressed: no reload behind the warning.
        harness.card.send(true)
        harness.prewarm.reevaluate()
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 1)

        // The card leaving and coming back is the listener returning.
        harness.card.send(false)
        harness.card.send(true)
        await warm(harness, call: 2)

        XCTAssertEqual(rig.statuses, [.idle])
        XCTAssertFalse(rig.controller.isPreparingVoice)
        XCTAssertEqual(rig.events, [])
        XCTAssertEqual(rig.announcements, [])
    }

    func testAMemoryWarningCancelsAWarmUpInFlight() async {
        let harness = makeHarness()
        harness.card.send(true)
        let asked = await harness.rig.waitUntil(2) { harness.neural.warmUpCalls == 1 }
        XCTAssertTrue(asked)

        PlatformLifecycle.post(.memoryWarning, to: harness.center)
        let cancelled = await harness.rig.waitUntil(2) { !harness.prewarm.isWarming }
        XCTAssertTrue(cancelled)
        harness.neural.finishWarmUp()   // never leave the warm-up parked
    }

    /// The System voice reading with the natural voice's engine still
    /// loaded (heat's switch to System, the fallback after three failures):
    /// nothing reads the engine, so a memory warning frees it mid-play, at
    /// either level, and the reading goes on.
    func testAMemoryWarningFreesAnEngineTheSystemVoiceLeftLoaded() async throws {
        let harness = makeHarness(neuralVoice: false)
        let rig = harness.rig
        harness.neural.finishWarmUp()   // loaded, as the switch to System leaves it
        rig.loadDefault()
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        PlatformLifecycle.post(.memoryWarning, to: harness.center, pressure: .warning)
        let released = await rig.waitUntil(2) { !harness.neural.isWarm }
        XCTAssertTrue(released, "the System voice playing never holds the natural voice's memory")
        XCTAssertEqual(rig.controller.status, .playing, "the reading never stops for it")
        XCTAssertTrue(harness.neural.requests.isEmpty)
        rig.controller.pause()
    }

    /// Michael paused on a warm engine, mid-book, with the iPhone's rules.
    private func pausedOnAWarmEngine(sceneActive: Bool = true) async throws -> Harness {
        let harness = makeHarness(sceneActive: sceneActive, rules: .iPhone)
        harness.neural.finishWarmUp()
        harness.rig.loadDefault(at: 3)
        harness.rig.controller.play()
        try await harness.rig.waitUntilPlayingOrSkip()
        harness.rig.controller.pause()
        XCTAssertEqual(harness.rig.controller.status, .paused)
        XCTAssertTrue(harness.neural.isWarm)
        return harness
    }

    /// P013: the relay's `.warning` keeps a paused book's voice warm, so
    /// Play never pays the load again; `.critical` frees it, and so does
    /// UIKit's own warning, which names no level. The levels come as the
    /// kernel's relay posts them (its own notification on both apps), the
    /// level-less one as UIKit's (the relay's, bare, on a Mac).
    func testEachLevelAndAPausedEngine() async throws {
        for (pressure, frees) in [(PlatformLifecycle.MemoryPressure?.some(.warning), false),
                                  (.some(.critical), true),
                                  (nil, true)] {
            let harness = try await pausedOnAWarmEngine()
            if let pressure {
                MemoryPressureRelay.deliver(pressure, to: harness.center)
            } else {
                PlatformLifecycle.post(.memoryWarning, to: harness.center)
            }
            let released = await harness.rig.waitUntil(frees ? 2 : 0.5) { !harness.neural.isWarm }
            XCTAssertEqual(released, frees, "\(pressure.map(\.rawValue) ?? "UIKit's")")
            XCTAssertEqual(harness.rig.controller.status, .paused)
            XCTAssertFalse(harness.rig.controller.isPreparingVoice)
        }
    }

    /// P011: in the background (where the platform frees memory there) a
    /// warning at either level frees a paused engine.
    func testInTheBackgroundAWarningFreesAPausedEngine() async throws {
        let harness = try await pausedOnAWarmEngine()
        harness.prewarm.sceneActivityChanged(false)
        PlatformLifecycle.post(.memoryWarning, to: harness.center, pressure: .warning)
        let released = await harness.rig.waitUntil(2) { !harness.neural.isWarm }
        XCTAssertTrue(released, "a backgrounded app is the first to go")
    }
}
