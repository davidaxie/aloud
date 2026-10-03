import XCTest
@testable import Aloud

/// R5: the natural-voice offer appears after 60 s of cumulative playback,
/// never before, and once answered (Not now, a download, or a model already
/// installed) never again. Driven directly with a fake clock: no playback,
/// no audio.
@MainActor
final class NaturalVoiceOfferTests: XCTestCase {

    private final class FakeClock {
        var now: TimeInterval = 1_000
    }

    private static let suite = "aloud.tests.naturalVoiceOffer"
    private var defaults: UserDefaults!
    private var clock: FakeClock!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suite)
        defaults.removePersistentDomain(forName: Self.suite)
        clock = FakeClock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suite)
        defaults = nil
        clock = nil
        super.tearDown()
    }

    private typealias Key = NaturalVoiceOffer.Key

    /// A fresh instance on the shared defaults, as after a relaunch, with
    /// the model state already seen (attach delivers it first in the app).
    private func makeOffer(deviceSupported: Bool = true,
                           modelState: ModelManager.ModelState = .notInstalled) -> NaturalVoiceOffer {
        let clock = self.clock!
        let offer = NaturalVoiceOffer(defaults: defaults,
                                      deviceSupported: deviceSupported,
                                      now: { clock.now })
        offer.modelStateChanged(modelState)
        return offer
    }

    private func play(_ offer: NaturalVoiceOffer, for seconds: TimeInterval) {
        offer.playbackStatusChanged(.playing)
        clock.now += seconds
        offer.playbackStatusChanged(.paused)
    }

    // MARK: - Threshold

    func testHiddenAt59SecondsOfPlaying() {
        let offer = makeOffer()
        play(offer, for: 59)
        XCTAssertEqual(offer.listenedSeconds, 59, accuracy: 0.001)
        XCTAssertFalse(offer.isVisible)
    }

    func testVisibleAfterTwoIntervalsAcrossAPause() {
        let offer = makeOffer()
        play(offer, for: 30)
        clock.now += 600   // a long pause never counts
        XCTAssertFalse(offer.isVisible)
        play(offer, for: 30)
        XCTAssertTrue(offer.isVisible)
    }

    func testCumulativeAcrossRelaunch() {
        play(makeOffer(), for: 45)
        let relaunched = makeOffer()
        XCTAssertEqual(relaunched.listenedSeconds, 45, accuracy: 0.001)
        XCTAssertFalse(relaunched.isVisible)
        play(relaunched, for: 15)
        XCTAssertTrue(relaunched.isVisible)
    }

    func testBufferingPausedAndErrorTimeNeverCounts() {
        let offer = makeOffer()
        for status in [PlayerStatus.buffering, .paused, .error, .idle, .ended] {
            offer.playbackStatusChanged(status)
            clock.now += 100
        }
        offer.playbackStatusChanged(.paused)
        XCTAssertEqual(offer.listenedSeconds, 0)
        XCTAssertFalse(offer.isVisible)

        // Playing, then buffering mid-book: only the playing stretch counts.
        offer.playbackStatusChanged(.playing)
        clock.now += 20
        offer.playbackStatusChanged(.buffering)
        clock.now += 100
        offer.playbackStatusChanged(.playing)
        clock.now += 10
        offer.playbackStatusChanged(.paused)
        XCTAssertEqual(offer.listenedSeconds, 30, accuracy: 0.001)
    }

    func testHeartbeatAloneCrossesThresholdWhilePlaying() {
        let offer = makeOffer()
        offer.playbackStatusChanged(.playing)
        clock.now += 40
        offer.heartbeat()
        XCTAssertFalse(offer.isVisible)
        clock.now += 20
        offer.heartbeat()
        XCTAssertTrue(offer.isVisible, "The offer must not wait for the next pause")
    }

    func testHeartbeatWhileNotPlayingAddsNothing() {
        let offer = makeOffer()
        offer.playbackStatusChanged(.paused)
        clock.now += 120
        offer.heartbeat()
        XCTAssertEqual(offer.listenedSeconds, 0)
    }

    func testPersistedSecondsAreCappedAt60() {
        let offer = makeOffer()
        play(offer, for: 500)
        XCTAssertEqual(offer.listenedSeconds, NaturalVoiceOffer.listenThreshold)
        XCTAssertEqual(defaults.double(forKey: Key.listenedSeconds), 60)
    }

    // MARK: - Answers

    func testNotNowHidesAndPersistsAcrossRelaunch() {
        let offer = makeOffer()
        play(offer, for: 60)
        XCTAssertTrue(offer.isVisible)
        offer.notNow()
        XCTAssertFalse(offer.isVisible)
        XCTAssertEqual(defaults.string(forKey: Key.answer), "notNow")

        let relaunched = makeOffer()
        XCTAssertEqual(relaunched.answer, .notNow)
        play(relaunched, for: 60)
        XCTAssertFalse(relaunched.isVisible)
    }

    func testDownloadStartAnswersAndCancelStaysHidden() {
        let offer = makeOffer()
        play(offer, for: 60)
        XCTAssertTrue(offer.isVisible)
        offer.modelStateChanged(.downloading(0.1))
        XCTAssertFalse(offer.isVisible)
        XCTAssertEqual(offer.answer, .download)
        XCTAssertEqual(defaults.string(forKey: Key.answer), "download")

        offer.modelStateChanged(.notInstalled)   // the user cancelled
        XCTAssertFalse(offer.isVisible)
        XCTAssertFalse(makeOffer().isVisible)
    }

    func testInstalledSeenFirstCountsAsAnsweredEvenAfterRemoval() {
        let offer = makeOffer(modelState: .installed)
        XCTAssertEqual(offer.answer, .download)
        play(offer, for: 60)
        offer.modelStateChanged(.notInstalled)   // Remove Download
        XCTAssertFalse(offer.isVisible)
        XCTAssertFalse(makeOffer().isVisible)
    }

    func testWaitingForWiFiAnswersLikeDownloading() {
        let offer = makeOffer()
        play(offer, for: 60)
        offer.modelStateChanged(.waitingForWiFi(0.2))
        XCTAssertFalse(offer.isVisible)
        XCTAssertEqual(offer.answer, .download)
    }

    /// R21: a Download that found too little space keeps the offer up (its
    /// row carries the space line) and leaves it unanswered.
    func testStaysVisibleWhenSpaceRanOutOnly() {
        let offer = makeOffer()
        play(offer, for: 60)
        offer.modelStateChanged(.failed(.notEnoughSpace))
        XCTAssertTrue(offer.isVisible)
        XCTAssertNil(offer.answer)
        offer.modelStateChanged(.failed(.interrupted))
        XCTAssertFalse(offer.isVisible)
        offer.modelStateChanged(.failed(.damaged))
        XCTAssertFalse(offer.isVisible)
        XCTAssertNil(offer.answer)
    }

    func testNeverVisibleOnUnsupportedDevice() {
        let offer = makeOffer(deviceSupported: false)
        play(offer, for: 120)
        XCTAssertFalse(offer.isVisible)
    }

    func testHiddenUntilModelStateIsKnown() {
        let clock = self.clock!
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: true, now: { clock.now })
        play(offer, for: 60)
        XCTAssertFalse(offer.isVisible, "No model state seen yet, so the model may be installed")
        offer.modelStateChanged(.notInstalled)
        XCTAssertTrue(offer.isVisible)
    }

    // MARK: - Pure rule

    func testIsVisibleTruthTable() {
        let states: [ModelManager.ModelState] = [.notInstalled, .downloading(0.5), .waitingForWiFi(0.5), .installed,
                                                 .failed(.interrupted), .failed(.notEnoughSpace), .failed(.damaged)]
        let answers: [NaturalVoiceOffer.Answer?] = [nil, .download, .notNow]
        for seconds in [0, 59.9, 60, 61] as [TimeInterval] {
            for answer in answers {
                for supported in [false, true] {
                    for state in states {
                        let offerable = state == .notInstalled || state == .failed(.notEnoughSpace)
                        let expected = supported && answer == nil && offerable && seconds >= 60
                        XCTAssertEqual(
                            NaturalVoiceOffer.isVisible(listenedSeconds: seconds, answer: answer,
                                                        deviceSupported: supported, modelState: state),
                            expected,
                            "seconds \(seconds), answer \(String(describing: answer)), supported \(supported), state \(state)")
                    }
                }
            }
        }
        XCTAssertTrue(NaturalVoiceOffer.isVisible(listenedSeconds: 60, answer: nil,
                                                  deviceSupported: true, modelState: .notInstalled))
    }

    // MARK: - The path (M17)

    /// An offer that would show stays down until a usable path is known; a
    /// costly path is usable (the metered prompt asks first). The default
    /// never gates, which is the iPhone's rule.
    func testUsablePathGatesTheRule() {
        func visible(_ usablePath: Bool?) -> Bool {
            NaturalVoiceOffer.isVisible(listenedSeconds: 60, answer: nil, deviceSupported: true,
                                        modelState: .notInstalled, usablePath: usablePath)
        }
        XCTAssertTrue(visible(true))
        XCTAssertFalse(visible(false), "offline: an offer that can only fail isn't shown")
        XCTAssertFalse(visible(nil), "not before the path is known")
        XCTAssertFalse(NaturalVoiceOffer.isVisible(listenedSeconds: 59, answer: nil, deviceSupported: true,
                                                   modelState: .notInstalled, usablePath: true),
                       "a usable path never brings the offer early")

        XCTAssertNil(NaturalVoiceOffer.hasUsablePath(UnknownPath()))
        XCTAssertEqual(NaturalVoiceOffer.hasUsablePath(FixedNetworkPath.unsatisfied), false)
        XCTAssertEqual(NaturalVoiceOffer.hasUsablePath(FixedNetworkPath(isExpensiveOrConstrained: false)), true)
        XCTAssertEqual(NaturalVoiceOffer.hasUsablePath(FixedNetworkPath(isExpensiveOrConstrained: true)), true)
    }

    /// Without a path source (the iPhone, and every test above) nothing is
    /// watched and nothing reads offline, so the offer keeps R5's rule alone.
    func testWithoutAPathSourceNothingIsWatched() {
        let offer = makeOffer()
        offer.watchNetworkPath()
        play(offer, for: 60)
        XCTAssertNil(offer.hasUsablePath)
        XCTAssertFalse(offer.isOffline)
        XCTAssertTrue(offer.isVisible)
    }

    /// The iPhone never watches the path for the offer or the card (M4);
    /// neither does a hosted unit test on the Mac, so no test starts a live
    /// monitor through the offer.
    func testDefaultPathSourceIsTheMacsAppOnly() {
        XCTAssertNil(NaturalVoiceOffer.defaultPathSource(preparesForFlight: false, isXCTestHost: false))
        XCTAssertNil(NaturalVoiceOffer.defaultPathSource(preparesForFlight: true, isXCTestHost: true))
        XCTAssertNil(NaturalVoiceOffer.defaultPathSource(), "this test host")
        #if os(iOS)
        XCTAssertNil(NaturalVoiceOffer.defaultPathSource(isXCTestHost: false), "the iPhone app")
        #endif
    }

    /// No path has landed yet.
    private final class UnknownPath: NetworkPathSource, @unchecked Sendable {
        let isExpensiveOrConstrained = false
        let allowsWiFiOnlyTransfer = true
        let hasPath = false
        func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
        func start() {}
    }
}
