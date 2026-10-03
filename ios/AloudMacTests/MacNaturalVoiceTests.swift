import AVFoundation
import XCTest
@testable import Aloud

/// The natural voice ready before a flight, on the Mac (M17, M10's System
/// voice): the card's Mac lines in each state, the offline state that
/// disables Download, R5's offer suppressed with no usable path and back
/// when one returns (still once, still after 60 s), the System row's
/// resolved name, and the Spoken Content pane's URL.
///
/// SAFETY: no test downloads, starts a live monitor or opens a URL. Every
/// offer gets a fake path that only reports what it is told; nothing plays
/// (the listening clock is a fake), and no voice speaks: the System voice
/// is only enumerated.
@MainActor
final class MacNaturalVoiceTests: XCTestCase {

    /// Reports what the test sets, and calls back as the live path does
    /// when it changes. Records each start.
    private final class FakePath: NetworkPathSource, @unchecked Sendable {
        private(set) var hasPath: Bool
        private(set) var isExpensiveOrConstrained = false
        private(set) var allowsWiFiOnlyTransfer = true
        private(set) var starts = 0
        private var changeHandler: (@Sendable () -> Void)?

        /// Known from the start (as `-uitest-offline`'s fixed path is), or
        /// unknown until `land`.
        init(online: Bool?) {
            hasPath = online != nil
            if let online { set(online: online) }
        }

        func setChangeHandler(_ handler: @escaping @Sendable () -> Void) { changeHandler = handler }
        func start() { starts += 1 }

        /// A new path: Wi-Fi or Ethernet when online, unsatisfied when not.
        func land(online: Bool) {
            hasPath = true
            set(online: online)
            changeHandler?()
        }

        private func set(online: Bool) {
            allowsWiFiOnlyTransfer = online
            isExpensiveOrConstrained = false
        }
    }

    private final class FakeClock {
        var now: TimeInterval = 1_000
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var clock: FakeClock!

    override func setUp() {
        super.setUp()
        suite = "aloud.tests.macNaturalVoice.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clock = FakeClock()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        clock = nil
        super.tearDown()
    }

    private func makeOffer(path: (any NetworkPathSource)?) -> NaturalVoiceOffer {
        let clock = self.clock!
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: true,
                                      now: { clock.now }, pathSource: path)
        offer.modelStateChanged(.notInstalled)
        return offer
    }

    private func play(_ offer: NaturalVoiceOffer, for seconds: TimeInterval) {
        offer.playbackStatusChanged(.playing)
        clock.now += seconds
        offer.playbackStatusChanged(.paused)
    }

    /// Turns the main actor until `condition` holds: a path change hops
    /// back to it before the offer hears it.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - The card's lines

    /// Each Mac state of the card, as M17 words it.
    func testTheCardsMacLines() {
        // Not installed, online.
        XCTAssertEqual(NaturalVoiceCopy.offer, "Natural voice \u{00B7} 353 MB, once")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: false),
                       "Download before you fly. After that, everything works offline.")
        XCTAssertEqual(NaturalVoiceCopy.privacyLine, "Downloads once from Hugging Face. Nothing about you is sent.")
        // Not installed, offline.
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: true), "Connect to the internet to download.")
        // A Personal Hotspot or Low Data Mode asks first.
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt, "Download 353 MB on a metered connection?")
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage,
                       "Your Mac is using a Personal Hotspot or Low Data Mode. "
                       + "Downloads once from Hugging Face. Nothing about you is sent.")
        // In flight, waiting, failed, checking.
        XCTAssertEqual(NaturalVoiceCopy.downloading(0.42), "Downloading natural voice \u{00B7} 42%")
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, "Download paused \u{00B7} waiting for Wi-Fi or Ethernet")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.notEnoughSpace), "Not enough space \u{00B7} need 707 MB free")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.interrupted), "Download failed \u{00B7} Try again")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.damaged), "Voice files damaged \u{00B7} Download again")
        XCTAssertEqual(NaturalVoiceCopy.verifying, "Checking voice files\u{2026}")
        // Installed.
        XCTAssertEqual(NaturalVoiceCopy.installed, "Natural voice installed")
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on this Mac \u{00B7} works offline")
        XCTAssertEqual(DeviceCopy.removeDownload, "Remove Download\u{2026}")
    }

    // MARK: - Offline

    /// `-uitest-offline`'s path, as on a plane: the card's Download is
    /// disabled with its line from the moment the card shows, before any
    /// listening, and the offer never appears.
    func testOfflineDisablesDownloadAndTheOfferNeverShows() {
        let offer = makeOffer(path: FixedNetworkPath.unsatisfied)
        XCTAssertFalse(offer.isOffline, "nothing is known before the card or the offer asks")
        offer.watchNetworkPath()   // the not-installed card appeared
        XCTAssertTrue(offer.isOffline, "the card disables Download")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: offer.isOffline), "Connect to the internet to download.")
        play(offer, for: 120)
        XCTAssertFalse(offer.isVisible, "an offer that can only fail isn't shown")
        XCTAssertNil(offer.answer, "hiding isn't answering")
    }

    /// Online, the card's Download is live and says to download before the
    /// flight; a metered path counts as usable, since its prompt asks.
    func testAUsablePathKeepsDownloadLive() {
        for path in [FixedNetworkPath(isExpensiveOrConstrained: false),
                     FixedNetworkPath(isExpensiveOrConstrained: true)] {
            let offer = makeOffer(path: path)
            offer.watchNetworkPath()
            XCTAssertEqual(offer.hasUsablePath, true)
            XCTAssertFalse(offer.isOffline)
            XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: offer.isOffline),
                           "Download before you fly. After that, everything works offline.")
            play(offer, for: 60)
            XCTAssertTrue(offer.isVisible)
        }
    }

    /// The path is watched only once there is a download to offer: never
    /// before 60 s of listening, once at the mark, and never again.
    func testTheOfferWatchesThePathOnlyWhenItWouldShow() async {
        let path = FakePath(online: nil)
        let offer = makeOffer(path: path)
        play(offer, for: 59)
        XCTAssertEqual(path.starts, 0, "a launch and the first minute watch nothing")
        play(offer, for: 1)
        XCTAssertEqual(path.starts, 1)
        XCTAssertFalse(offer.isVisible, "not before the first path lands")
        path.land(online: true)
        let shown = await waitUntil { offer.isVisible }
        XCTAssertTrue(shown, "online: the offer shows once the path lands")
        play(offer, for: 30)
        offer.watchNetworkPath()
        XCTAssertEqual(path.starts, 1, "started once")
    }

    /// Losing the path hides the offer; a path's return brings it back,
    /// still unanswered, and once answered it never returns.
    func testTheOfferReturnsWithAPathAndStillOnlyOnce() async {
        let path = FakePath(online: true)
        let offer = makeOffer(path: path)
        play(offer, for: 60)
        XCTAssertTrue(offer.isVisible)

        path.land(online: false)
        let hidden = await waitUntil { !offer.isVisible }
        XCTAssertTrue(hidden, "offline: suppressed")
        XCTAssertTrue(offer.isOffline)

        path.land(online: true)
        let back = await waitUntil { offer.isVisible }
        XCTAssertTrue(back, "online again: the unanswered offer returns")

        offer.notNow()
        path.land(online: false)
        let lost = await waitUntil { offer.isOffline }
        XCTAssertTrue(lost)
        path.land(online: true)
        let found = await waitUntil { offer.hasUsablePath == true }
        XCTAssertTrue(found)
        XCTAssertFalse(offer.isVisible, "answered once, never again")
    }

    /// The app's offer watches the download's own path, so
    /// `-uitest-offline` reaches it; a hosted test gets none, and building
    /// the live one watches nothing.
    func testTheAppsPathIsTheDownloadsAndStartsNothing() throws {
        XCTAssertNil(NaturalVoiceOffer.defaultPathSource(), "this hosted test")
        let live = try XCTUnwrap(NaturalVoiceOffer.defaultPathSource(isXCTestHost: false))
        let system = try XCTUnwrap(live as? SystemNetworkPath, "this host isn't launched offline")
        XCTAssertFalse(system.isMonitoring, "built, not started")
    }

    // MARK: - The System voice (M10)

    /// The row's name: the voice and its tier, as System Settings lists it.
    func testSystemVoiceDisplayName() {
        typealias Candidate = AVSpeechEngine.VoiceCandidate
        XCTAssertEqual(AVSpeechEngine.displayName(of: Candidate(name: "Ava", language: "en-US", quality: 3)),
                       "Ava (Premium)")
        XCTAssertEqual(AVSpeechEngine.displayName(of: Candidate(name: "Samantha", language: "en-US", quality: 2)),
                       "Samantha (Enhanced)")
        XCTAssertEqual(AVSpeechEngine.displayName(of: Candidate(name: "Samantha", language: "en-US", quality: 1)),
                       "Samantha")
        XCTAssertEqual(AVSpeechEngine.displayName(of: Candidate(name: "Zoe (Premium)", language: "en-US", quality: 3)),
                       "Zoe (Premium)", "a name that carries its tier keeps it")
    }

    /// The name is the voice synthesis resolves to: the same ranking picks
    /// it, so naming it changes nothing about which voice speaks.
    func testTheResolvedNameIsTheVoiceThatSpeaks() {
        let resolved = AVSpeechEngine.resolvedVoiceDisplayName()
        guard let best = AVSpeechEngine.bestSystemVoice() else {
            XCTAssertNil(resolved, "no installed voice: the row keeps its subtitle")
            return
        }
        let quality = best.quality == .premium ? 3 : (best.quality == .enhanced ? 2 : 1)
        let expected = AVSpeechEngine.displayName(of: AVSpeechEngine.VoiceCandidate(
            name: best.name, language: best.language, quality: quality))
        XCTAssertEqual(resolved, expected)
    }

    /// The row re-resolves when System Settings adds or removes a voice.
    func testTheRowListensForInstalledVoiceChanges() {
        XCTAssertEqual(AVSpeechEngine.installedVoicesDidChange,
                       AVSpeechSynthesizer.availableVoicesDidChangeNotification)
        XCTAssertTrue(PlatformVoiceSetup.namesResolvedSystemVoice)
    }

    /// "Add voices in System Settings…" opens Accessibility › Spoken
    /// Content. Only the URL is checked: nothing is opened.
    func testAddVoicesOpensSpokenContent() throws {
        XCTAssertEqual(DeviceCopy.addSystemVoices, "Add voices in System Settings\u{2026}")
        let url = try XCTUnwrap(PlatformVoiceSetup.addVoicesURL)
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    }
}
