import Combine
import UIKit
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
        let conditions: Conditions
        let center: NotificationCenter
        let prewarm: NeuralPrewarm
    }

    /// Michael is the voice unless `neuralVoice` is false; no book is loaded.
    /// The scene starts as `sceneActive` says, never as the test host's
    /// UIApplication happens to be.
    private func makeHarness(neuralVoice: Bool = true, sceneActive: Bool = true) -> Harness {
        let neural = FakeNeuralEngine()
        let rig = PlaybackTestRig(neural: neural)
        if neuralVoice { rig.controller.voice = PlaybackTestRig.michael }
        let card = PassthroughSubject<Bool, Never>()
        let conditions = Conditions()
        let center = NotificationCenter()
        let prewarm = NeuralPrewarm(playback: rig.controller,
                                    kokoro: neural,
                                    cardVisible: card.eraseToAnyPublisher(),
                                    isModelInstalled: { conditions.modelInstalled },
                                    isLowPowerMode: { conditions.lowPowerMode },
                                    sceneActive: sceneActive,
                                    notifications: center)
        return Harness(rig: rig, neural: neural, card: card, conditions: conditions,
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
            XCTAssertEqual(NeuralPrewarm.shouldWarm(cardVisible: flag(0),
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

    // MARK: - Memory warnings

    func testAMemoryWarningReleasesAndHoldsUntilTheCardReturns() async {
        let harness = makeHarness()
        let rig = harness.rig
        harness.card.send(true)
        await warm(harness)

        harness.center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
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

        harness.center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let cancelled = await harness.rig.waitUntil(2) { !harness.prewarm.isWarming }
        XCTAssertTrue(cancelled)
        harness.neural.finishWarmUp()   // never leave the warm-up parked
    }
}
