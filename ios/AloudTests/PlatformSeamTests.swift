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
        XCTAssertEqual(PlatformTuning.kokoroThreads, 2)
        XCTAssertTrue(PlatformTuning.releasesNeuralOnBackground)
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
