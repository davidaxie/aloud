import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Aloud

/// The Platform seam's iOS half (M1): every shim returns exactly what the
/// iPhone app computed before the seam existed, so routing a call site
/// through it changes nothing. The expectations are spelled with UIKit
/// directly, never through the app code the seam replaces.
@MainActor
final class PlatformSeamTests: XCTestCase {

    // MARK: S1 · images

    func testPlatformImageIsUIImage() {
        XCTAssertTrue(PlatformImage.self == UIImage.self)

        let image = solidImage(.red, size: CGSize(width: 4, height: 2), scale: 2)
        XCTAssertNotNil(image.pngDataRepresentation())
        XCTAssertEqual(image.pngDataRepresentation(), image.pngData())
    }

    func testImageRendererYieldsTheSameImageAsUIImage() throws {
        let renderer = ImageRenderer(content: Color.red.frame(width: 6, height: 4))
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.platformImage)
        let expected = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size, CGSize(width: 6, height: 4))
        XCTAssertEqual(image.scale, 2)
        XCTAssertEqual(image.pngData(), expected.pngData())
    }

    func testImageViewShowsThePlatformImage() throws {
        let source = solidImage(.blue, size: CGSize(width: 5, height: 3), scale: 1)
        let renderer = ImageRenderer(content: Image(platformImage: source))
        renderer.scale = 1

        let rendered = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(rendered.size, CGSize(width: 5, height: 3))
    }

    // MARK: S4, S5, S13 · the app

    func testIsActiveIsTheApplicationState() {
        XCTAssertEqual(PlatformApp.isActive, UIApplication.shared.applicationState == .active)
    }

    func testLifecycleEventsArriveAsTheUIKitNotifications() {
        XCTAssertEqual(PlatformLifecycle.Event.willTerminate.name, UIApplication.willTerminateNotification)
        XCTAssertEqual(PlatformLifecycle.Event.didEnterBackground.name,
                       UIApplication.didEnterBackgroundNotification)
        XCTAssertEqual(PlatformLifecycle.Event.memoryWarning.name,
                       UIApplication.didReceiveMemoryWarningNotification)
        // Never posted on the iPhone; its own name, so it can't alias another.
        let names = Set(PlatformLifecycle.Event.allCases.map(\.name))
        XCTAssertEqual(names.count, PlatformLifecycle.Event.allCases.count)

        for event in PlatformLifecycle.Event.allCases {
            XCTAssertTrue(PlatformLifecycle.center(for: event) === NotificationCenter.default, "\(event)")
        }
    }

    /// An injected center throughout: posting on the default one would reach
    /// the host app's real observers (a willTerminate flushes its library).
    func testPostReachesAnObserver() {
        let center = NotificationCenter()
        for event in PlatformLifecycle.Event.allCases {
            let received = LockedNames()
            let token = PlatformLifecycle.observe(event, in: center) { received.append($0.name) }

            PlatformLifecycle.post(event, to: center)

            // No queue: delivered synchronously, as a dying process needs.
            XCTAssertEqual(received.names, [event.name], "\(event)")
            center.removeObserver(token)
            PlatformLifecycle.post(event, to: center)
            XCTAssertEqual(received.names.count, 1, "\(event) still observed after removal")
        }
    }

    func testPostReachesAPublisherAndNoOtherEvent() {
        let center = NotificationCenter()
        var received: [Notification.Name] = []
        let subscription = PlatformLifecycle.publisher(for: .memoryWarning, in: center)
            .sink { received.append($0.name) }

        PlatformLifecycle.post(.didEnterBackground, to: center)
        PlatformLifecycle.post(.memoryWarning, to: center)

        XCTAssertEqual(received, [UIApplication.didReceiveMemoryWarningNotification])
        subscription.cancel()
    }

    /// P012: the shipping engine is built with spinning off, so it names
    /// the provider config file wherever one can be written.
    func testTheShippingEngineStopsThreadSpinning() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlatformSeamTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = KokoroSherpaEngine(modelDirectory: folder, runtimeConfigDirectory: folder)
        XCTAssertTrue(engine.stopsThreadSpinning)
        XCTAssertEqual(engine.numThreads, 2)
        XCTAssertFalse(engine.isWarm, "building it loads nothing")
        let provider = KokoroSherpaEngine.runtimeProvider(stopsThreadSpinning: engine.stopsThreadSpinning,
                                                          configDirectory: folder)
        XCTAssertTrue(provider.hasPrefix("cpu:"), provider)
    }

    // MARK: P013 · memory pressure levels on the iPhone

    /// What `PlatformLifecycle.memoryPressure` delivers on a private center.
    @MainActor
    private func pressures(window: TimeInterval, during deliver: (NotificationCenter) async -> Void)
        async -> [PlatformLifecycle.MemoryPressure] {
        let center = NotificationCenter()
        var received: [PlatformLifecycle.MemoryPressure] = []
        let subscription = PlatformLifecycle.memoryPressure(in: center, window: window)
            .sink { received.append($0) }
        await deliver(center)
        subscription.cancel()
        return received
    }

    @MainActor
    private func elapse(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The relay's levels arrive at once, each as itself.
    @MainActor
    func testTheRelaysLevelsArriveAtOnce() async {
        let received = await pressures(window: 0.3) { center in
            MemoryPressureRelay.deliver(.warning, to: center)
            MemoryPressureRelay.deliver(.critical, to: center)
        }
        XCTAssertEqual(received, [.warning, .critical])
    }

    /// UIKit's own warning names no level, and may come just before this
    /// app's jetsam: it acts at once as a `.warning` (a load in flight is
    /// cancelled), then with nothing from the relay turns critical once the
    /// window has passed (and is critical at once with no window).
    @MainActor
    func testUIKitsWarningAloneActsAtOnceThenTurnsCritical() async {
        let center = NotificationCenter()
        var received: [PlatformLifecycle.MemoryPressure] = []
        let subscription = PlatformLifecycle.memoryPressure(in: center, window: 0.2)
            .sink { received.append($0) }
        PlatformLifecycle.post(.memoryWarning, to: center)
        XCTAssertEqual(received, [.warning], "at once, never a second's wait")
        await elapse(0.5)
        XCTAssertEqual(received, [.warning, .critical])
        subscription.cancel()

        let atOnce = await pressures(window: 0) { center in
            PlatformLifecycle.post(.memoryWarning, to: center)
        }
        XCTAssertEqual(atOnce, [.critical])
    }

    /// The relay's `.warning` and UIKit's warning for the same pressure, in
    /// either order, are one `.warning`: a paused natural voice stays warm.
    @MainActor
    func testTheRelaysLevelStandsForUIKitsWarning() async {
        let relayFirst = await pressures(window: 0.3) { center in
            MemoryPressureRelay.deliver(.warning, to: center)
            PlatformLifecycle.post(.memoryWarning, to: center)
            await self.elapse(0.6)
        }
        XCTAssertEqual(relayFirst, [.warning])
        let uiKitFirst = await pressures(window: 0.3) { center in
            PlatformLifecycle.post(.memoryWarning, to: center)
            await self.elapse(0.05)
            MemoryPressureRelay.deliver(.warning, to: center)
            await self.elapse(0.6)
        }
        XCTAssertEqual(uiKitFirst, [.warning])
        let uiKitThenCritical = await pressures(window: 0.3) { center in
            PlatformLifecycle.post(.memoryWarning, to: center)
            await self.elapse(0.05)
            MemoryPressureRelay.deliver(.critical, to: center)
            await self.elapse(0.6)
        }
        XCTAssertEqual(uiKitThenCritical, [.warning, .critical], "the relay's level replaces the escalation")
    }

    /// The default center's observer starts the kernel's pressure source on
    /// the iPhone too.
    @MainActor
    func testTheRelayRunsOnTheIPhone() {
        let subscription = PlatformLifecycle.memoryPressure().sink { _ in }
        XCTAssertTrue(MemoryPressureRelay.isRunning)
        subscription.cancel()
    }

    // MARK: P011 · AppModel's background release

    /// The move to the background leaves a paused natural voice to the idle
    /// stop while the audio engine runs (`releaseNeuralEngineOnBackground`).
    func testTheBackgroundReleaseWaitsForTheIdleEngine() throws {
        let s = try SourceTree.sources(only: ["App/AppModel.swift", "Playback/PlaybackController.swift"])
        let model = try XCTUnwrap(s["App/AppModel.swift"])
        let controller = try XCTUnwrap(s["Playback/PlaybackController.swift"])
        XCTAssertTrue(model.contains("playback.releaseNeuralEngineOnBackground()"))
        XCTAssertFalse(model.contains("PlatformTuning.releasesNeuralOnBackground else { return }\n"
                                      + "        playback.releaseNeuralEngineIfIdle()"),
                       "never at once while the idle engine runs")
        XCTAssertTrue(controller.contains("guard !isAudioEngineRunning else { return }"))
        // P009 and P010: the strain and the heat reach the controller and the
        // pre-warm. The heat gate holds on both apps (AppModel is shared), as
        // R11's heat policy does: never a platform flag around it.
        XCTAssertTrue(model.contains(
            "playback.isUnderStrain = Self.strain(of: thermalGuard) { ProcessInfo.processInfo.isLowPowerModeEnabled }"),
            "the strain AppModel installs is the one ThermalGuardTests drive")
        XCTAssertTrue(model.contains("heat: thermalGuard.$isHot.eraseToAnyPublisher()"))
    }

    func testActivityHoldsNothingOnTheIPhone() {
        let token = PlatformActivity.begin(reason: "Reading aloud")
        XCTAssertNil(token)
        PlatformActivity.end(token)
    }

    // MARK: S3 · announcements

    func testAnnouncementQueuesBehindVoiceOverByDefault() {
        let queued = A11yAnnounce.argument(for: "Paused · headphones disconnected", queued: true)
        XCTAssertEqual(queued.string, "Paused · headphones disconnected")
        XCTAssertEqual(queued.attribute(.accessibilitySpeechQueueAnnouncement, at: 0,
                                        effectiveRange: nil) as? Bool, true)

        let interrupting = A11yAnnounce.argument(for: "Now", queued: false)
        XCTAssertEqual(interrupting.attribute(.accessibilitySpeechQueueAnnouncement, at: 0,
                                              effectiveRange: nil) as? Bool, false)
    }

    // MARK: S6 · paths

    func testLibraryStaysInDocuments() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(PlatformPaths.libraryRoot,
                       documents.appendingPathComponent("Library", isDirectory: true))
        XCTAssertEqual(PlatformPaths.fixtureRoot, documents)
    }

    // MARK: S9 · frame ticker

    func testFrameTickerFiresUntilInvalidated() {
        var ticks = 0
        let fired = expectation(description: "ticked")
        fired.assertForOverFulfill = false
        let ticker = FrameTicker { ticks += 1; if ticks >= 3 { fired.fulfill() } }

        ticker.start()
        ticker.start()   // a second start while running adds no second link
        wait(for: [fired], timeout: 3)

        ticker.invalidate()
        let stoppedAt = ticks
        spinRunLoop(0.2)
        XCTAssertEqual(ticks, stoppedAt, "ticked after invalidate()")
    }

    func testReleasingATickerStopsIt() {
        var ticks = 0
        weak var released: FrameTicker?
        do {
            let ticker = FrameTicker { ticks += 1 }
            released = ticker
            ticker.start()
        }
        XCTAssertNil(released, "the display link kept the ticker alive")
        let stoppedAt = ticks
        spinRunLoop(0.2)
        XCTAssertEqual(ticks, stoppedAt, "a released ticker kept ticking")
    }

    // MARK: S10 · Now Playing

    func testNowPlayingKeepsTodaysBehaviour() {
        XCTAssertTrue(PlatformNowPlaying.publishesWhenMuted)
        for state in [NowPlayingState.playing, .paused, .stopped] {
            PlatformNowPlaying.setState(state)   // a no-op on the iPhone
        }
    }

    // MARK: S15 · tuning

    func testTuningKeepsTheIPhoneValues() {
        XCTAssertEqual(PlatformTuning.kokoroThreads, 2, "two until a device measurement says otherwise (P012)")
        XCTAssertTrue(PlatformTuning.kokoroStopsThreadSpinning, "idle ONNX threads never spin (P012)")
        XCTAssertTrue(PlatformTuning.prewarmsForLoadedBook, "the reopened reader warms its book (P010)")
        XCTAssertFalse(PlatformTuning.prewarmsAtLaunch, "a bare launch never warms (P010)")
        XCTAssertTrue(PlatformTuning.memoryHoldEndsOnReturn)
        XCTAssertTrue(PlatformTuning.releasesNeuralOnBackground)
        XCTAssertEqual(PlatformTuning.idleEngineStopDelay, 60)
        XCTAssertFalse(PlatformAudio.debugBuildsStartMuted)
        XCTAssertEqual(PlatformAudio.mutedOutputMode, .deviceAtZeroVolume)
    }

    // MARK: C1 · copy

    func testDeviceNounsAreTheIPhoneWords() {
        XCTAssertEqual(DeviceNoun.device, "iPhone")
        XCTAssertEqual(DeviceNoun.subject, "iPhone")
        XCTAssertEqual(DeviceNoun.Subject, "iPhone")
        XCTAssertEqual(DeviceNoun.withArticle, "an iPhone")
    }

    func testDeviceCopyIsTodaysIPhoneCopy() {
        XCTAssertEqual(DeviceCopy.meteredPrompt, "Download \(ModelManager.downloadSizeText) on cellular?")
        XCTAssertNil(DeviceCopy.meteredDetail)
        XCTAssertEqual(DeviceCopy.waitingForNetwork, "Download paused · waiting for Wi-Fi")
    }

    // MARK: R1, R5 · color

    func testDynamicColorResolvesStyleAndContrast() {
        XCTAssertTrue(PlatformColor.self == UIColor.self)
        XCTAssertTrue(PlatformFont.self == UIFont.self)

        let color = UIColor(PlatformColor.dynamic { dark, highContrast in
            switch (dark, highContrast) {
            case (false, false): return .red
            case (true, false): return .blue
            case (false, true): return .green
            case (true, true): return .yellow
            }
        })

        func resolved(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UIColor {
            color.resolvedColor(with: UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = contrast
            })
        }
        XCTAssertEqual(resolved(.light, .normal), .red)
        XCTAssertEqual(resolved(.dark, .normal), .blue)
        XCTAssertEqual(resolved(.light, .high), .green)
        XCTAssertEqual(resolved(.dark, .high), .yellow)
        XCTAssertEqual(resolved(.unspecified, .unspecified), .red)
    }

    func testHairlineIsOnePhysicalPixel() {
        XCTAssertEqual(PlatformScreen.hairline, 1 / max(UIScreen.main.scale, 1))
    }

    // MARK: R2 · typography

    func testNamedFontIsUIFontByName() throws {
        let font = try XCTUnwrap(PlatformFont.named("Georgia", size: 19))
        XCTAssertEqual(font, UIFont(name: "Georgia", size: 19))
        XCTAssertNil(PlatformFont.named("No Such Face", size: 19))
        XCTAssertTrue(PlatformFont.exists(named: "Georgia"))
        XCTAssertFalse(PlatformFont.exists(named: "No Such Face"))
        XCTAssertEqual(PlatformFont.exists(named: "Iowan Old Style"),
                       UIFont(name: "Iowan Old Style", size: 17) != nil)
    }

    func testBoldAndItalicStayInTheFamily() throws {
        let georgia = try XCTUnwrap(UIFont(name: "Georgia", size: 19))
        for (derived, trait) in [(PlatformFontTraits.bold(georgia), UIFontDescriptor.SymbolicTraits.traitBold),
                                 (PlatformFontTraits.italic(georgia), .traitItalic)] {
            let expectedDescriptor = try XCTUnwrap(georgia.fontDescriptor.withSymbolicTraits(
                georgia.fontDescriptor.symbolicTraits.union(trait)))
            let expected = UIFont(descriptor: expectedDescriptor, size: 19)
            let font = try XCTUnwrap(derived)
            XCTAssertEqual(font.fontName, expected.fontName)
            XCTAssertEqual(font.pointSize, 19)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(trait))
            XCTAssertEqual(font.familyName, "Georgia")
        }
    }

    func testSmallCapsSetsTheLowercaseFeature() throws {
        let georgia = try XCTUnwrap(UIFont(name: "Georgia", size: 21))
        let font = PlatformFontTraits.smallCaps(georgia)

        XCTAssertEqual(font.fontName, georgia.fontName)
        XCTAssertEqual(font.pointSize, 21)
        // Compared with the UIKit call made directly. The feature can't be read
        // back (on iOS 26 the font reports only name and size), so whether the
        // small caps draw is the R13 glyph test's job, not this one's.
        let features: [[UIFontDescriptor.FeatureKey: Int]] = [[
            .type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector,
        ]]
        let reference = UIFont(descriptor: georgia.fontDescriptor.addingAttributes([.featureSettings: features]),
                               size: 21)
        XCTAssertEqual(font.fontDescriptor, reference.fontDescriptor)
    }

    func testRuleImageIsASolidFillAtTheDisplayScale() {
        let size = CGSize(width: 10, height: 2)
        for scale in [CGFloat(0), 2, 3] {
            let image = PlatformRuleImage.make(size: size, color: .red, scale: scale)

            let format = UIGraphicsImageRendererFormat()
            format.scale = max(scale, 1)
            let expected = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            XCTAssertEqual(image.size, size)
            XCTAssertEqual(image.scale, max(scale, 1))
            XCTAssertEqual(image.pngData(), expected.pngData(), "scale \(scale)")
        }
    }

    func testBoldTextFollowsLegibilityWeight() {
        XCTAssertTrue(PlatformLegibility.isBold(UITraitCollection(legibilityWeight: .bold)))
        XCTAssertFalse(PlatformLegibility.isBold(UITraitCollection(legibilityWeight: .regular)))
        XCTAssertFalse(PlatformLegibility.isBold(UITraitCollection(legibilityWeight: .unspecified)))
    }

    /// J027: the serif chrome reads Bold Text where it has no traits, and
    /// hears it change.
    func testBoldTextIsTheSystemSetting() {
        XCTAssertEqual(PlatformLegibility.isBoldTextOn, UIAccessibility.isBoldTextEnabled)
        XCTAssertEqual(PlatformLegibility.boldTextDidChange, UIAccessibility.boldTextStatusDidChangeNotification)
        XCTAssertEqual(Theme.BoldText.shared.isOn, UIAccessibility.isBoldTextEnabled)
    }

    // MARK: R4 · accessibility

    func testReduceMotionIsTheSystemSetting() {
        XCTAssertEqual(PlatformAccessibility.reduceMotion, UIAccessibility.isReduceMotionEnabled)
        XCTAssertEqual(PlatformAccessibility.reduceMotionDidChange,
                       UIAccessibility.reduceMotionStatusDidChangeNotification)
        XCTAssertTrue(PlatformAccessibility.reduceMotionCenter === NotificationCenter.default)
    }

    // MARK: U1, U2 · view modifiers

    func testViewModifiersRender() {
        let views: [AnyView] = [
            AnyView(Text("Listening").inlineTitleOnPhone()),
            AnyView(Text("Play").largeContentViewerIfAvailable()),
            AnyView(Image(systemName: "play.fill").largeContentViewerIfAvailable { Label("Play", systemImage: "play.fill") }),
        ]
        for view in views {
            let renderer = ImageRenderer(content: view.frame(width: 120, height: 60))
            XCTAssertNotNil(renderer.uiImage)
        }
    }

    // MARK: R1-38 · the page follows Dynamic Type until a size is picked

    private func textSizeDefaults() throws -> UserDefaults {
        let suite = "PlatformSeamTests.textSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func storedPoints(_ defaults: UserDefaults) -> CGFloat {
        ReaderTextSize.points(forStep: defaults.integer(forKey: ReaderTextSize.prefKey))
    }

    func testAFreshInstallFollowsTheSystemTextSize() throws {
        let defaults = try textSizeDefaults()
        ReaderTextSize.seedIfNeeded(defaults, category: .large)
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .large)
        XCTAssertEqual(storedPoints(defaults), 19)
        XCTAssertEqual(defaults.object(forKey: ReaderTextSize.seededKey) as? Int, 2, "the seed is recorded")

        ReaderTextSize.followSystemIfUnchosen(defaults, category: .accessibilityLarge)   // AX2
        XCTAssertEqual(storedPoints(defaults), 30)
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .large)
        XCTAssertEqual(storedPoints(defaults), 19, "and back down")
    }

    func testAPickedSizeIsNeverOverwritten() throws {
        let defaults = try textSizeDefaults()
        ReaderTextSize.seedIfNeeded(defaults, category: .large)
        // One A+ tap: the stepper writes the size alone.
        let tapped = try XCTUnwrap(ReaderTextSize.stepped(from: defaults.integer(forKey: ReaderTextSize.prefKey),
                                                          bigger: true))
        defaults.set(tapped, forKey: ReaderTextSize.prefKey)

        ReaderTextSize.followSystemIfUnchosen(defaults, category: .accessibilityLarge)
        XCTAssertEqual(defaults.integer(forKey: ReaderTextSize.prefKey), tapped)
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .extraSmall)
        XCTAssertEqual(defaults.integer(forKey: ReaderTextSize.prefKey), tapped)
    }

    func testAnExistingInstallOffTheSeedKeepsItsSize() throws {
        let defaults = try textSizeDefaults()
        defaults.set(4, forKey: ReaderTextSize.prefKey)   // stored before the seed was recorded
        ReaderTextSize.seedIfNeeded(defaults, category: .large)   // not a first launch
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .large)
        XCTAssertEqual(defaults.integer(forKey: ReaderTextSize.prefKey), 4)
        XCTAssertNil(defaults.object(forKey: ReaderTextSize.seededKey))
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .accessibilityLarge)
        XCTAssertEqual(defaults.integer(forKey: ReaderTextSize.prefKey), 4, "the listener's size")
    }

    func testAnExistingInstallAtTheSeedStartsFollowing() throws {
        let defaults = try textSizeDefaults()
        defaults.set(2, forKey: ReaderTextSize.prefKey)   // stored before the seed was recorded
        ReaderTextSize.seedIfNeeded(defaults, category: .large)
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .large)
        XCTAssertEqual(defaults.object(forKey: ReaderTextSize.seededKey) as? Int, 2)
        ReaderTextSize.followSystemIfUnchosen(defaults, category: .accessibilityLarge)
        XCTAssertEqual(storedPoints(defaults), 30)
    }

    /// The seed is written only where the size is seeded and followed: the
    /// stepper, the VoiceOver adjust and the pinch write the size alone, so
    /// the listener's pick wins. AppModel follows at launch and live.
    func testOnlyTheSeedWritesTheSeedAndAppModelFollows() throws {
        let s = try SourceTree.appSources().mapValues(SwiftLiterals.code(in:))
        XCTAssertEqual(SourceTree.files(containing: "seededKey", in: s), ["Platform/ReaderTextSizeSeed.swift"])
        let model = try XCTUnwrap(s["App/AppModel.swift"])
        XCTAssertTrue(model.contains("seedKey: ReaderTextSize.platformSeedKey"))
        XCTAssertTrue(model.contains("ReaderTextSize.followSystemIfUnchosen(defaults)"))
        XCTAssertTrue(model.contains("ReaderTextSize.systemTextSizeDidChange"))
        XCTAssertEqual(ReaderTextSize.systemTextSizeDidChange, UIContentSizeCategory.didChangeNotification)
    }

    // MARK: R1-39 · assistive tech

    func testAssistiveTechIsVoiceOverOrSwitchControl() {
        XCTAssertEqual(PlatformAccessibility.assistiveTechRunning,
                       UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning)
    }

    /// The iPhone announces a new Undo jump offer; the Mac's half keeps
    /// its silence (MacPlatformTests).
    func testTheIPhoneAnnouncesTheUndoOffer() {
        XCTAssertTrue(PlatformAccessibility.announcesUndoOffer)
    }

    // MARK: - Helpers

    private func solidImage(_ color: UIColor, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Names a `@Sendable` observer block appends to.
private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Notification.Name] = []

    var names: [Notification.Name] { lock.withLock { stored } }

    func append(_ name: Notification.Name) {
        lock.withLock { stored.append(name) }
    }
}
