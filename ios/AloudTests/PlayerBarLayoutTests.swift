import SwiftUI
import XCTest
@testable import Aloud

/// The player bar's height must not depend on the height it is offered. The
/// reader's safeAreaInset reserves the bar's ideal height and then places it
/// with that finite height; a bar that comes out shorter than its inset
/// leaves its paper short of the screen bottom, with reader text showing
/// under the controls (seen at AX3 with a chapterless book, whose title
/// wraps the chapter line). Measured with silent rigs: nothing here plays.
@MainActor
final class PlayerBarLayoutTests: XCTestCase {

    private static let longTitle = "The Narrative of Arthur Gordon Pym of Nantucket"
    private static let shortTitle = "Gatsby"
    /// A 402pt phone (the size the defect was captured on).
    private static let width: CGFloat = 402

    // Kept alive for the hosted views' lifetime.
    private var rig: PlaybackTestRig?
    private var offers: [NaturalVoiceOffer] = []
    private var modelManager: ModelManager?
    private var sleepTimer: SleepTimer?
    private var suites: [String] = []
    private var modelDirectory: URL?
    private var host: AccessibilityHost?
    private var restoreAccessibility: (() -> Void)?

    override func tearDown() {
        host?.close()
        host = nil
        restoreAccessibility?()
        restoreAccessibility = nil
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        if let modelDirectory { try? FileManager.default.removeItem(at: modelDirectory) }
        super.tearDown()
    }

    // MARK: - Harness

    /// A chapterless text book (one page), so the chapter line shows its title.
    private func makeBar(title: String, offerVisible: Bool, size: DynamicTypeSize) -> some View {
        let rig = self.rig ?? PlaybackTestRig(sentences: 40, autoplaySuppressed: true)
        self.rig = rig
        let directory = modelDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerBarLayoutTests-\(UUID().uuidString)", isDirectory: true)
        modelDirectory = directory
        // An expensive path and an empty directory: nothing is ever downloaded.
        let manager = modelManager ?? ModelManager(
            pathSource: FixedNetworkPath(isExpensiveOrConstrained: true), installDirectory: directory)
        modelManager = manager
        let timer = sleepTimer ?? SleepTimer()
        sleepTimer = timer

        let suite = "aloud.tests.playerBarLayout.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(NaturalVoiceOffer.listenThreshold, forKey: NaturalVoiceOffer.Key.listenedSeconds)
        let offer = NaturalVoiceOffer(defaults: defaults, deviceSupported: offerVisible, now: { 0 })
        offer.modelStateChanged(.notInstalled)
        XCTAssertEqual(offer.isVisible, offerVisible, "offer fixture")
        offers.append(offer)

        let content = PlaybackTestRig.makeContent(hash: "bar-layout", count: 40, wordsPerSentence: 12)
        var document = PlaybackTestRig.makeDocument(hash: "bar-layout", sentences: 40)
        document.title = title
        return PlayerBarView(document: document,
                             content: content,
                             navigation: ReaderNavigation(content: content, kind: .text))
            .environmentObject(rig.controller)
            .environmentObject(offer)
            .environmentObject(manager)
            .environmentObject(timer)
            .environment(\.dynamicTypeSize, size)
    }

    private func height(of view: some View, offered height: CGFloat, width: CGFloat = PlayerBarLayoutTests.width) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: height))
            .height
    }

    // MARK: - Tests

    /// Offered exactly its ideal height, the bar takes all of it — at every
    /// text size, with a one-line or wrapping chapter line, and with the
    /// natural-voice offer in the line. Before the fix a wrapping line made
    /// the bar ~20pt shorter than its inset at AX3.
    func testBarFillsItsIdealHeightWhenOfferedExactlyThat() {
        let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
        for size in sizes {
            for title in [Self.shortTitle, Self.longTitle] {
                for offerVisible in [false, true] {
                    let bar = makeBar(title: title, offerVisible: offerVisible, size: size)
                    let ideal = height(of: bar, offered: .greatestFiniteMagnitude)
                    let placed = height(of: bar, offered: ideal)
                    XCTAssertEqual(placed, ideal, accuracy: 0.5,
                                   "\(size), \"\(title)\", offer \(offerVisible): offered its ideal "
                                   + "\(ideal)pt, the bar took \(placed)pt")
                }
            }
        }
    }

    /// Guards the test above: at AX3 the long title really wraps the chapter
    /// line (the case that went short), so the bar is taller than with a
    /// one-line title.
    func testLongTitleWrapsTheChapterLineAtAX3() {
        let short = height(of: makeBar(title: Self.shortTitle, offerVisible: false, size: .accessibility3),
                           offered: .greatestFiniteMagnitude)
        let long = height(of: makeBar(title: Self.longTitle, offerVisible: false, size: .accessibility3),
                          offered: .greatestFiniteMagnitude)
        XCTAssertGreaterThan(long, short + 20, "the AX3 chapter line should wrap the long title")
    }

    /// The scrub drag (chapter line, track fill, preview) must end with the
    /// touch even when the system cancels the drag, which never calls
    /// onEnded. @GestureState is reset on cancel; plain @State stayed frozen
    /// on the drag target. A gesture can't be cancelled from a test, so this
    /// pins the storage that gives that guarantee.
    func testScrubDragTargetIsGestureState() {
        let content = PlaybackTestRig.makeContent(hash: "bar-scrub", count: 4)
        let bar = PlayerBarView(document: PlaybackTestRig.makeDocument(hash: "bar-scrub", sentences: 4),
                                content: content,
                                navigation: ReaderNavigation(content: content, kind: .text))
        let storage = Mirror(reflecting: bar).children.first { $0.label == "_drag" }?.value
        XCTAssertNotNil(storage, "PlayerBarView.drag is gone; update this test")
        XCTAssertTrue(storage is GestureState<ScrubDrag?>,
                      "drag must be @GestureState, got \(storage.map { type(of: $0) } as Any)")
    }

    /// After a playback error, a skip or scrub leaves the status paused
    /// while the chapter line still offers "tap to try again". The circle
    /// turned back to "Play, paused" beside it; now it keeps the retry face
    /// until the stop clears (H050).
    func testAPlaybackErrorStopKeepsTheCircleOnTryAgain() {
        for status in [PlayerStatus.paused, .idle, .error] {
            let state = PlayButtonState(status: PlayButtonState.circleStatus(status, stop: .playbackError),
                                        isPreparingVoice: false, reduceMotion: false)
            XCTAssertEqual(state.glyph, .retry, "\(status) beside the error line")
            XCTAssertEqual(state.label, "Try again")
        }
        // Playing again clears the stop; until it does, active playback
        // and the end of the book keep their own faces.
        for status in [PlayerStatus.playing, .buffering, .ended] {
            XCTAssertEqual(PlayButtonState.circleStatus(status, stop: .playbackError), status)
        }
        // Every other stop sits beside a plain Play circle, as before.
        for stop in StopReason.allCases where stop != .playbackError {
            XCTAssertEqual(PlayButtonState.circleStatus(.paused, stop: stop), .paused, "\(stop)")
        }
        XCTAssertEqual(PlayButtonState.circleStatus(.paused, stop: nil), .paused)
    }

    // MARK: - Play on the center line (P001-P003, P005, P006)

    private enum SleepState: CaseIterable { case off, countdown, bookEnd }

    private static let voices: [(name: String, rate: Double)] = [("System", 1), ("Samantha", 2.25)]
    private static let phoneWidths: [CGFloat] = [375, 402, 440]
    private static let fiveControls = ["player.listening", "player.back15", "player.play",
                                       "player.forward15", "player.sleep"]

    /// The bar in a real window `width` wide, with the voice, speed and
    /// sleep state given; silent throughout (the rig is muted and paused,
    /// and the sleep timer is never attached to it).
    private func hostBar(width: CGFloat, size: DynamicTypeSize = .large, voice: (name: String, rate: Double),
                         sleep: SleepState, title: String = PlayerBarLayoutTests.shortTitle) async throws
        -> AccessibilityHost {
        host?.close()
        if restoreAccessibility == nil { restoreAccessibility = AccessibilityRuntime.enable() }
        if sleepTimer == nil {
            let suite = "aloud.tests.playerBarLayout.sleep.\(UUID().uuidString)"
            suites.append(suite)
            sleepTimer = SleepTimer(defaults: UserDefaults(suiteName: suite)!)
        }
        let bar = makeBar(title: title, offerVisible: false, size: size)
        let controller = try XCTUnwrap(rig).controller
        controller.voice = TtsVoice(id: "test:\(voice.name)", name: voice.name, lang: "en-US",
                                    gender: "f", engine: .avSpeech, quality: 1)
        controller.rate = voice.rate
        let timer = try XCTUnwrap(sleepTimer)
        switch sleep {
        case .off: timer.select(.off)
        case .countdown: timer.select(.minutes(30))
        case .bookEnd: timer.select(.endOfChapter)
        }
        let host = AccessibilityHost(bar, keepAlive: [], width: width)
        self.host = host
        _ = try await host.require("player.play")
        // The measured row width and the chips' full widths settle in a
        // layout pass or two after the first.
        try await Task.sleep(nanoseconds: 150_000_000)
        return host
    }

    private func frame(_ identifier: String, in host: AccessibilityHost) async throws -> CGRect {
        try await host.require(identifier).accessibilityFrame
    }

    /// P001: Play sits on the bar's center line whatever the chips say. The
    /// Spacers put it about 23pt right of center with the default chips.
    func testPlaySitsOnTheCenterLineWhateverTheChipsSay() async throws {
        for width in Self.phoneWidths {
            for voice in Self.voices {
                for sleep in SleepState.allCases {
                    let host = try await hostBar(width: width, voice: voice, sleep: sleep)
                    let play = try await frame("player.play", in: host)
                    XCTAssertEqual(play.midX, width / 2, accuracy: 0.5,
                                   "\(width)pt, \(voice.name) \(voice.rate)×, sleep \(sleep)")
                }
            }
        }
    }

    /// P002: from .xxLarge both chips share the top row and the cluster sits
    /// centred below them (Play hugged the leading gutter).
    func testTheStackedTransportCentresPlayUnderOneRowOfChips() async throws {
        for size in [DynamicTypeSize.xxLarge, .accessibility1, .accessibility3] {
            for width in [CGFloat(375), 402] {
                let host = try await hostBar(width: width, size: size, voice: Self.voices[1], sleep: .countdown)
                let play = try await frame("player.play", in: host)
                let listening = try await frame("player.listening", in: host)
                let sleep = try await frame("player.sleep", in: host)
                XCTAssertEqual(play.midX, width / 2, accuracy: 0.5, "\(size) at \(width)pt")
                XCTAssertEqual(listening.minY, sleep.minY, accuracy: 0.5, "\(size): the chips share one row")
                XCTAssertLessThanOrEqual(listening.maxY, play.minY + 0.5, "\(size): the chips sit above Play")
            }
        }
    }

    /// P001, P002: VoiceOver reads voice · speed, back, play, forward, sleep
    /// in the one-row bar and the stacked one, where the chips' row comes
    /// first on screen.
    func testVoiceOverReadsTheTransportInOneOrder() async throws {
        for size in [DynamicTypeSize.large, .accessibility1] {
            let host = try await hostBar(width: 402, size: size, voice: Self.voices[0], sleep: .off)
            XCTAssertEqual(host.order(of: Set(Self.fiveControls)), Self.fiveControls, "\(size)")
        }
    }

    /// P003: breathing room between the skips and Play. The tight gap is
    /// taken only where it lets a chip keep its full label.
    func testTheSkipsStandApartFromPlay() async throws {
        for width in Self.phoneWidths {
            let host = try await hostBar(width: width, voice: Self.voices[0], sleep: .off)
            let back = try await frame("player.back15", in: host)
            let play = try await frame("player.play", in: host)
            let forward = try await frame("player.forward15", in: host)
            let listening = try await frame("player.listening", in: host)
            let leading = play.minX - back.maxX
            let trailing = forward.minX - play.maxX
            XCTAssertEqual(leading, trailing, accuracy: 0.5, "\(width)pt: an even cluster")
            if leading >= PlayerBarLayout.roomyClusterGap - 0.5 { continue }
            let roomy = PlayerBarLayout(barWidth: width - 2 * Theme.Space.screenGutter, dynamicTypeSize: .large,
                                        playDiameter: play.width, skipTarget: back.width,
                                        clusterGap: PlayerBarLayout.roomyClusterGap)
            XCTAssertGreaterThan(listening.width, roomy.chipSideWidth,
                                 "\(width)pt: the gap tightened to \(leading)pt for a chip that fit anyway")
        }
    }

    /// P006: Play is never smaller than a chip, at any text size, and stays
    /// at least the 54pt target.
    func testPlayIsNeverSmallerThanAChip() async throws {
        let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2,
                                        .accessibility3, .accessibility4, .accessibility5]
        for size in sizes {
            let host = try await hostBar(width: 375, size: size, voice: Self.voices[1], sleep: .countdown)
            let play = try await frame("player.play", in: host)
            let listening = try await frame("player.listening", in: host)
            let sleep = try await frame("player.sleep", in: host)
            XCTAssertGreaterThanOrEqual(play.height, Theme.PlayCircle.diameter - 0.5, "\(size)")
            XCTAssertGreaterThanOrEqual(play.height + 0.5, listening.height, "\(size): the voice chip outgrew Play")
            XCTAssertGreaterThanOrEqual(play.height + 0.5, sleep.height, "\(size): the sleep chip outgrew Play")
        }
    }

    /// P006: at AX5 on a 375pt phone, with a title that wraps the chapter
    /// line, the bar leaves most of a 667pt screen to the page.
    func testTheBarKeepsToItsHeightBudgetAtAX5() {
        let bar = makeBar(title: Self.longTitle, offerVisible: false, size: .accessibility5)
        let ideal = height(of: bar, offered: .greatestFiniteMagnitude, width: 375)
        XCTAssertLessThanOrEqual(ideal, 0.45 * 667, "the AX5 bar is \(ideal)pt tall")
    }

    /// P005, after the Mac's clip test: at every phone width and every size
    /// through .xxxLarge, each chip label fits its side at full type size,
    /// in its full form or its short one. The countdown and +15 min never
    /// shorten, so they must always fit whole.
    func testEveryChipLabelFitsItsSideWithoutShrinking() throws {
        let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge]
        let voiceShort = { (rate: Double) in Text(ListeningFormat.chipShortTitle(rate: rate)).monospacedDigit() }
        // (name, full face, short face or nil, armed)
        let cases: [(String, AnyView, AnyView?, Bool)] = [
            ("System · 1×", AnyView(Text("System · 1×").monospacedDigit()), AnyView(voiceShort(1)), false),
            ("Samantha · 2.25×", AnyView(Text("Samantha · 2.25×").monospacedDigit()), AnyView(voiceShort(2.25)), false),
            (SleepTimer.Copy.chapterEnd, AnyView(Text(SleepTimer.Copy.chapterEnd)),
             AnyView(Image(systemName: "moon.fill")), true),
            (SleepTimer.Copy.bookEnd, AnyView(Text(SleepTimer.Copy.bookEnd)), AnyView(Image(systemName: "moon.fill")), true),
            (SleepTimer.Copy.extendChip, AnyView(Text(SleepTimer.Copy.extendChip).monospacedDigit()), nil, true),
            ("28:14", AnyView(Text(ListeningEstimate.countdown(seconds: 28 * 60 + 14)).monospacedDigit()), nil, true),
        ]
        for width in Self.phoneWidths {
            for size in sizes {
                let limit = Self.layout(width: width, size: size).chipWidthLimit
                for (name, full, short, armed) in cases {
                    let fullWidth = Self.chipWidth(full, isOn: armed, size: size)
                    if fullWidth <= limit { continue }
                    let shortWidth = short.map { Self.chipWidth($0, isOn: armed, size: size) }
                    XCTAssertNotNil(shortWidth, "\(name) is \(fullWidth)pt at \(size) on \(width)pt; its side is \(limit)pt")
                    if let shortWidth {
                        XCTAssertLessThanOrEqual(shortWidth, limit,
                                                 "\(name)'s short form is \(shortWidth)pt at \(size) on \(width)pt")
                    }
                }
            }
        }
    }

    /// P004: the chips rest on surface and turn surface2 under the finger.
    func testAChipRestsOnSurfaceAndPressesToSurface2() throws {
        XCTAssertEqual(ReaderChipStyle.ground(isPressed: false), Theme.surface)
        XCTAssertEqual(ReaderChipStyle.ground(isPressed: true), Theme.surface2)
        func center(pressed: Bool) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let chip = Text(" ")
                .readerChip()
                .environment(\.readerChipIsPressed, pressed)
                .environment(\.colorScheme, .light)
            let pixels = try XCTUnwrap(RenderedPixels(chip, size: CGSize(width: 120, height: 44), scale: 1))
            return pixels.rgba(x: 60, y: 22)
        }
        let rest = try center(pressed: false)
        let pressed = try center(pressed: true)
        let light = RenderedPixels.matches(rest, rgb: 0xFEFCF8, tolerance: 3)
            && RenderedPixels.matches(pressed, rgb: 0xF6F0E5, tolerance: 3)
        let dark = RenderedPixels.matches(rest, rgb: 0x1A150E, tolerance: 3)
            && RenderedPixels.matches(pressed, rgb: 0x231D13, tolerance: 3)
        XCTAssertTrue(light || dark, "rest \(rest), pressed \(pressed): surface, then surface2")
    }

    /// Pure rules (P001-P003, P006).
    func testThePlayerBarLayoutRules() {
        let layout = PlayerBarLayout(barWidth: 362, dynamicTypeSize: .large, playDiameter: 54, skipTarget: 44,
                                     clusterGap: 8)
        XCTAssertFalse(layout.stacksTransport)
        XCTAssertEqual(layout.clusterWidth, 158)
        XCTAssertEqual(layout.chipSideWidth, 102)
        XCTAssertEqual(layout.chipWidthLimit, 102)
        XCTAssertTrue(PlayerBarLayout(barWidth: 362, dynamicTypeSize: .xxLarge, playDiameter: 54, skipTarget: 44,
                                      clusterGap: 8).stacksTransport)
        XCTAssertFalse(PlayerBarLayout(barWidth: 362, dynamicTypeSize: .xLarge, playDiameter: 54, skipTarget: 44,
                                       clusterGap: 8).stacksTransport)
        XCTAssertEqual(PlayerBarLayout(barWidth: 335, dynamicTypeSize: .accessibility1, playDiameter: 66,
                                       skipTarget: 52, clusterGap: 8).chipWidthLimit, 163, "half the chip row")
        XCTAssertEqual(PlayerBarLayout(barWidth: 0, dynamicTypeSize: .large, playDiameter: 54, skipTarget: 44,
                                       clusterGap: 8).chipWidthLimit, .infinity, "unmeasured: no cap")

        XCTAssertEqual(PlayerBarLayout.playDiameter(scaled: 40), 54, "never under the 54pt target")
        XCTAssertEqual(PlayerBarLayout.playDiameter(scaled: 90), 66)
        XCTAssertEqual(PlayerBarLayout.skipTarget(scaled: 30), 44)
        XCTAssertEqual(PlayerBarLayout.skipTarget(scaled: 70), 52)
        XCTAssertLessThanOrEqual(ReaderChipStyle.maxHeight, PlayerBarLayout.playDiameterRange.lowerBound)

        func gap(_ barWidth: CGFloat, chip: CGFloat, size: DynamicTypeSize = .large) -> CGFloat {
            PlayerBarLayout.clusterGap(barWidth: barWidth, dynamicTypeSize: size, playDiameter: 54, skipTarget: 44,
                                       widestFullChip: chip)
        }
        XCTAssertEqual(gap(335, chip: 80), 8, "a 375pt phone keeps the room")
        XCTAssertEqual(gap(280, chip: 40), 4, "a narrow bar tightens")
        XCTAssertEqual(gap(335, chip: 90), 4, "4pt more lets an 90pt chip keep its words")
        XCTAssertEqual(gap(335, chip: 120), 8, "no gap saves a 120pt chip: it shortens, the room stays")
        XCTAssertEqual(gap(335, chip: 90, size: .xxLarge), 8, "stacked chips aren't beside the cluster")

        let order = PlayerBarLayout.Control.allCases.map(PlayerBarLayout.voiceOverOrder(of:))
        XCTAssertEqual(order, order.sorted(by: >), "voice · speed, back, play, forward, sleep")
        XCTAssertEqual(Set(order).count, 5)
    }

    // MARK: - Measuring

    /// The bar's layout at `size`, Play and the skips scaled as the bar's
    /// @ScaledMetric scales them, with the roomy gap (the least room a chip
    /// can be given).
    private static func layout(width: CGFloat, size: DynamicTypeSize) -> PlayerBarLayout {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory(size))
        let metrics = UIFontMetrics(forTextStyle: .title2)
        return PlayerBarLayout(barWidth: width - 2 * Theme.Space.screenGutter, dynamicTypeSize: size,
                               playDiameter: PlayerBarLayout.playDiameter(
                                   scaled: metrics.scaledValue(for: Theme.PlayCircle.diameter, compatibleWith: traits)),
                               skipTarget: PlayerBarLayout.skipTarget(
                                   scaled: metrics.scaledValue(for: 44, compatibleWith: traits)),
                               clusterGap: PlayerBarLayout.roomyClusterGap)
    }

    /// A chip face's own width at `size`, its label on one line.
    private static func chipWidth(_ label: AnyView, isOn: Bool, size: DynamicTypeSize) -> CGFloat {
        let face = label
            .readerChip(isOn: isOn)
            .fixedSize()
            .dynamicTypeSize(...PlayerBarLayout.chipTypeCap)
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: face)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            .width
    }

    private static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
