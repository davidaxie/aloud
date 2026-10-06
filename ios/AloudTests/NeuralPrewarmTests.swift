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

    private struct Harness {
        let rig: PlaybackTestRig
        let neural: FakeNeuralEngine
        let card: PassthroughSubject<Bool, Never>
        let book: PassthroughSubject<UUID?, Never>
        let conditions: Conditions
        let center: NotificationCenter
        let prewarm: NeuralPrewarm
    }

    /// Michael is the voice unless `neuralVoice` is false; no book is loaded.
    /// The scene starts as `sceneActive` says, never as the test host's
    /// app happens to be. Only the card asks for a warm-up unless
    /// `warmsBeyondTheCard` (a Mac's rule, pinned here rather than taken
    /// from the host, so each test reads the same on both).
    private func makeHarness(neuralVoice: Bool = true, sceneActive: Bool = true,
                             warmsBeyondTheCard: Bool = false) -> Harness {
        let neural = FakeNeuralEngine()
        let rig = PlaybackTestRig(neural: neural)
        if neuralVoice { rig.controller.voice = PlaybackTestRig.michael }
        let card = PassthroughSubject<Bool, Never>()
        let book = PassthroughSubject<UUID?, Never>()
        let conditions = Conditions()
        let center = NotificationCenter()
        let prewarm = NeuralPrewarm(playback: rig.controller,
                                    kokoro: neural,
                                    cardVisible: card.eraseToAnyPublisher(),
                                    loadedBook: book.eraseToAnyPublisher(),
                                    isModelInstalled: { conditions.modelInstalled },
                                    isLowPowerMode: { conditions.lowPowerMode },
                                    sceneActive: sceneActive,
                                    warmsBeyondTheCard: warmsBeyondTheCard,
                                    notifications: center)
        return Harness(rig: rig, neural: neural, card: card, book: book, conditions: conditions,
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
        for bits in 0..<64 {
            let flag = { (bit: Int) in bits & (1 << bit) != 0 }
            let expected = flag(0) && flag(1) && flag(2) && flag(3) && !flag(4) && !flag(5)
            XCTAssertEqual(NeuralPrewarm.shouldWarm(asked: flag(0),
                                                    sceneActive: flag(1),
                                                    modelInstalled: flag(2),
                                                    voiceIsNeural: flag(3),
                                                    lowPowerMode: flag(4),
                                                    suppressedByMemoryWarning: flag(5)),
                           expected, "row \(bits)")
            rows += 1
        }
        XCTAssertEqual(rows, 64)
    }

    /// The card asks everywhere; a loaded book and the launch ask only
    /// where the platform warms beyond the card (a Mac).
    func testWhatAsksForAWarmUp() {
        for bits in 0..<16 {
            let flag = { (bit: Int) in bits & (1 << bit) != 0 }
            let expected = flag(0) || (flag(3) && (flag(1) || flag(2)))
            XCTAssertEqual(NeuralPrewarm.asksForWarmUp(cardVisible: flag(0), bookLoaded: flag(1),
                                                       launchPending: flag(2), warmsBeyondTheCard: flag(3)),
                           expected, "row \(bits)")
        }
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

    // MARK: - Beyond the card (a Mac)

    /// Where the platform warms beyond the card, the launch asks once (no
    /// card ever shows when a book opens straight into the reader), and a
    /// different book loaded after a memory warning asks again.
    func testTheLaunchAndALoadedBookWarmBeyondTheCard() async {
        let harness = makeHarness(warmsBeyondTheCard: true)
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

    /// Where only the card asks (an iPhone), neither the launch nor a loaded
    /// book warms the engine.
    func testOnlyTheCardWarmsWhereThePlatformDoesNotWarmBeyondIt() async {
        let harness = makeHarness(warmsBeyondTheCard: false)
        harness.prewarm.reevaluate()
        harness.book.send(UUID())
        await elapse(0.3)
        XCTAssertEqual(harness.neural.warmUpCalls, 0)
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
}
