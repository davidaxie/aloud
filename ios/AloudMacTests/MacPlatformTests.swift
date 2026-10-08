import AppKit
import XCTest
@testable import Aloud

/// The macOS halves of the platform seam (contracts §4, S1-B): silence by
/// default, the library inside the sandbox container, announcements that a
/// muted process only records, a 30 fps ticker with no display link, the
/// lifecycle the store and playback save at, and the Mac's words. The
/// iPhone halves are pinned by PlatformSeamTests.
@MainActor
final class MacPlatformTests: XCTestCase {

    // MARK: S15 · tuning and silence

    /// A Debug build is silent unless Xcode's Run action asks for sound, and
    /// a muted process renders offline with no device at all.
    func testDebugBuildsStartMuted() {
        XCTAssertTrue(PlatformAudio.debugBuildsStartMuted)
        XCTAssertEqual(PlatformAudio.mutedOutputMode, .manualRendering)
        let plainLaunch = UITestHooks.muteAudio(in: ["Aloud Dev"], environment: [:], xcTestLoaded: false,
                                                debugStartsMuted: PlatformAudio.debugBuildsStartMuted)
        XCTAssertTrue(plainLaunch, "a Finder or `open` launch of the dev build is muted")
        let runAction = UITestHooks.muteAudio(in: ["Aloud Dev"], environment: ["ALOUD_AUDIBLE": "1"],
                                              xcTestLoaded: false,
                                              debugStartsMuted: PlatformAudio.debugBuildsStartMuted)
        XCTAssertFalse(runAction, "only ALOUD_AUDIBLE=1 lifts it")
        XCTAssertTrue(UITestHooks.muteAudio, "this test host")
    }

    func testTuningIsTheMacs() {
        XCTAssertEqual(PlatformTuning.kokoroThreads,
                       PlatformTuning.kokoroThreadCount(performanceCores: PlatformTuning.performanceCoreCount))
        XCTAssertTrue((4...6).contains(PlatformTuning.kokoroThreads))
        XCTAssertTrue(PlatformTuning.kokoroStopsThreadSpinning)
        XCTAssertTrue(PlatformTuning.prewarmsForLoadedBook)
        XCTAssertTrue(PlatformTuning.prewarmsAtLaunch)
        XCTAssertFalse(PlatformTuning.memoryHoldEndsOnReturn)
        XCTAssertFalse(PlatformTuning.releasesNeuralOnBackground)
    }

    /// All but two performance cores, never fewer than 4 (an M1's four
    /// P-cores still get four) nor more than 6 (an M4 Pro's ten get six).
    func testTheThreadCountFollowsThePerformanceCores() {
        let counts = [2, 4, 6, 8, 10, 12, 16].map { PlatformTuning.kokoroThreadCount(performanceCores: $0) }
        XCTAssertEqual(counts, [4, 4, 4, 6, 6, 6, 6])
        XCTAssertGreaterThan(PlatformTuning.performanceCoreCount, 0)
    }

    // MARK: S6 · paths

    /// The library lives in Application Support inside the sandbox
    /// container, never in the listener's own ~/Library or ~/Documents. An
    /// unsandboxed host (an unsigned build) fails here first.
    func testLibraryRootIsInsideTheContainer() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        XCTAssertTrue(home.contains("/Library/Containers/"),
                      "the test host isn't sandboxed (\(home)): sign it, never CODE_SIGNING_ALLOWED=NO")
        let root = PlatformPaths.libraryRoot.standardizedFileURL
        XCTAssertTrue(root.path.hasPrefix(home + "/"), root.path)
        XCTAssertTrue(root.path.hasSuffix("/Library/Application Support/Aloud/Library"), root.path)
        XCTAssertEqual(PlatformPaths.fixtureRoot.standardizedFileURL, root.deletingLastPathComponent(),
                       "fixtures sit beside the library")
    }

    // MARK: S3 · announcements

    /// A muted process records what VoiceOver would have said and posts
    /// nothing: VoiceOver would read it aloud on the listener's own output.
    func testAnnouncementsAreRecordOnlyWhenMuted() {
        let line = StopReason.headphonesDisconnected.spokenText
        UITestAnnouncementLog.shared.reset()
        let posted = A11yAnnounce.postedCount

        PlaybackController.postAnnouncement(line, muted: true)
        XCTAssertEqual(UITestAnnouncementLog.shared.entries, [line], "recorded")
        XCTAssertEqual(A11yAnnounce.postedCount, posted, "the muted controller posted")

        // The seam holds the line by itself, whatever a caller checked.
        A11yAnnounce.post(line)
        A11yAnnounce.post(line, queued: false)
        ModelManager.postAnnouncement(line)
        XCTAssertEqual(A11yAnnounce.postedCount, posted, "a muted process reached VoiceOver")
        UITestAnnouncementLog.shared.reset()
    }

    /// Queued waits behind VoiceOver; not queued cuts in.
    func testAnnouncementPriority() {
        let queued = A11yAnnounce.userInfo(for: "Now", queued: true)
        XCTAssertEqual(queued[.announcement] as? String, "Now")
        XCTAssertEqual(queued[.priority] as? Int, NSAccessibilityPriorityLevel.medium.rawValue)
        let interrupting = A11yAnnounce.userInfo(for: "Now", queued: false)
        XCTAssertEqual(interrupting[.priority] as? Int, NSAccessibilityPriorityLevel.high.rawValue)
    }

    // MARK: S9 · frame ticker

    func testFrameTickerTicksAtThirtyFramesPerSecond() {
        var ticks = 0
        let ticker = FrameTicker(framesPerSecond: 30) { ticks += 1 }
        ticker.start()
        ticker.start()   // a second start while running adds no second timer
        let started = Date()
        spinRunLoop(2)
        ticker.invalidate()
        let rate = Double(ticks) / Date().timeIntervalSince(started)
        XCTAssertEqual(rate, 30, accuracy: 3, "\(ticks) ticks")

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
        XCTAssertNil(released, "the timer kept the ticker alive")
        let stoppedAt = ticks
        spinRunLoop(0.2)
        XCTAssertEqual(ticks, stoppedAt, "a released ticker kept ticking")
    }

    // MARK: S5, S13 · lifecycle and activity

    func testLifecycleEventsArriveAsTheAppKitNotifications() {
        XCTAssertEqual(PlatformLifecycle.Event.willTerminate.name, NSApplication.willTerminateNotification)
        XCTAssertEqual(PlatformLifecycle.Event.didEnterBackground.name, NSApplication.didResignActiveNotification)
        XCTAssertEqual(PlatformLifecycle.Event.systemWillSleep.name, NSWorkspace.willSleepNotification)
        XCTAssertEqual(Set(PlatformLifecycle.Event.allCases.map(\.name)).count,
                       PlatformLifecycle.Event.allCases.count)
        XCTAssertTrue(PlatformLifecycle.center(for: .systemWillSleep) === NSWorkspace.shared.notificationCenter,
                      "sleep arrives only on the workspace's center")
        for event in [PlatformLifecycle.Event.willTerminate, .didEnterBackground, .memoryWarning] {
            XCTAssertTrue(PlatformLifecycle.center(for: event) === NotificationCenter.default, "\(event)")
        }
    }

    /// AppKit has no memory warning: the kernel's pressure source posts it,
    /// and it runs once something observes the default center. The app's
    /// observer (NeuralPrewarm) passes `.default` itself, so injecting the
    /// default center must start it too.
    func testAMemoryWarningObserverOnTheDefaultCenterStartsTheRelay() {
        let token = PlatformLifecycle.observe(.memoryWarning, in: .default) { _ in }
        NotificationCenter.default.removeObserver(token)
        XCTAssertTrue(MemoryPressureRelay.isRunning)
    }

    /// Delivered synchronously, once, on the center a test injects.
    func testPostReachesAnObserverOnAnInjectedCenter() {
        for event in PlatformLifecycle.Event.allCases {
            let center = NotificationCenter()
            let delivered = expectation(description: "\(event)")
            let token = PlatformLifecycle.observe(event, in: center) { _ in delivered.fulfill() }
            PlatformLifecycle.post(event, to: center)
            center.removeObserver(token)
            wait(for: [delivered], timeout: 0)
        }
    }

    func testIsActiveIsTheApplications() {
        XCTAssertEqual(PlatformApp.isActive, NSApp?.isActive ?? false)
    }

    /// A stop held while Aloud was behind another app is spoken when Aloud
    /// comes to the front (J026): its window never left the screen, so no
    /// scene phase change speaks it. The app delegate's activation hands
    /// it over, on the next turn, once.
    func testAStopHeldBehindAnotherAppIsSpokenWhenAloudComesForward() async throws {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 0.5)
        rig.loadDefault(at: 0)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        rig.clearRecordings()
        rig.appActive = false
        rig.controller.stop(because: .headphonesDisconnected)
        XCTAssertEqual(rig.announcements, [], "held while Aloud is behind")
        XCTAssertEqual(rig.controller.stopped?.reason, .headphonesDisconnected)

        rig.appActive = true
        MacAppDelegate.announceHeldStop(of: rig.controller)
        XCTAssertEqual(rig.announcements, [], "not before the window is main")
        let turn = expectation(description: "the next main-queue turn")
        DispatchQueue.main.async { turn.fulfill() }
        await fulfillment(of: [turn], timeout: 2)
        XCTAssertEqual(rig.announcements, [StopReason.headphonesDisconnected.spokenText])

        MacAppDelegate.announceHeldStop(of: rig.controller)
        let again = expectation(description: "another turn")
        DispatchQueue.main.async { again.fulfill() }
        await fulfillment(of: [again], timeout: 2)
        XCTAssertEqual(rig.announcements.count, 1, "once")
    }

    func testActivityIsHeldAndEnded() {
        let token = PlatformActivity.begin(reason: "Reading aloud")
        XCTAssertNotNil(token, "App Nap would throttle look-ahead")
        PlatformActivity.end(token)
        PlatformActivity.end(nil)
    }

    // MARK: R4 · accessibility

    func testReduceMotionIsTheSystemSetting() {
        XCTAssertEqual(PlatformAccessibility.reduceMotion,
                       NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UITestHooks.forceReduceMotion)
        XCTAssertEqual(PlatformAccessibility.reduceMotionDidChange,
                       NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        XCTAssertTrue(PlatformAccessibility.reduceMotionCenter === NSWorkspace.shared.notificationCenter)
    }

    // MARK: R1-39 · the Undo jump offer

    /// R1-39 is the iPhone's: on the Mac a new offer says nothing new and
    /// keeps its 10 s with VoiceOver or Switch Control on (Command-Z takes
    /// it from anywhere), so the shared controller behaves as before.
    func testTheUndoOfferKeepsTheMacsBehaviour() {
        XCTAssertFalse(PlatformAccessibility.announcesUndoOffer)
        XCTAssertFalse(PlatformAccessibility.assistiveTechRunning)
    }

    // MARK: S10 · Now Playing

    /// A muted Mac process never takes Now Playing from the listener.
    func testMutedProcessesDontPublishNowPlaying() {
        XCTAssertFalse(PlatformNowPlaying.publishesWhenMuted)
        XCTAssertFalse(NowPlayingManager.takesSystemNowPlaying(outputMuted: true,
                                                               publishesWhenMuted: PlatformNowPlaying.publishesWhenMuted))
    }

    // MARK: C1 · the Mac's words

    func testDeviceNounsAreTheMacsWords() {
        XCTAssertEqual(DeviceNoun.device, "Mac")
        XCTAssertEqual(DeviceNoun.subject, "your Mac")
        XCTAssertEqual(DeviceNoun.Subject, "Your Mac")
        XCTAssertEqual(DeviceNoun.withArticle, "a Mac")
    }

    /// M12 and M17 as the listener reads them.
    func testStopsAndNoticesReadAsTheMacs() {
        XCTAssertEqual(StopReason.macSlept.text, "Paused \u{00B7} your Mac went to sleep")
        XCTAssertEqual(StopReason.tooHot.text, "Paused \u{00B7} your Mac is too hot")
        XCTAssertEqual(PlaybackNotice.coolingDown.text, "Using the System voice while your Mac cools")
        XCTAssertEqual(StopReason.closedByIOS.text, "Stopped when Aloud quit unexpectedly")
        XCTAssertEqual(StopReason.playbackError.text, "Playback stopped", "the Mac's Try again button retries")
    }

    /// The Mac's error line names no action, so its button's hint says what
    /// pressing it does (H049): VoiceOver heard only "Playback stopped,
    /// button". The hint is its own sentence, not the label again.
    func testTheErrorLineHintSaysItRetries() {
        XCTAssertEqual(ReaderMessageLine.retryHint, "Plays from the sentence that failed")
        XCTAssertFalse(StopReason.playbackError.spokenText.localizedCaseInsensitiveContains("try again"),
                       "the Mac's label carries no action: the hint is the only one")
        XCTAssertNotEqual(ReaderMessageLine.retryHint, StopReason.playbackError.spokenText)
    }

    func testDownloadCopyReadsAsTheMacs() {
        XCTAssertEqual(DeviceCopy.meteredPrompt, "Download 353 MB on a metered connection?")
        XCTAssertEqual(DeviceCopy.meteredDetail, "Your Mac is using a Personal Hotspot or Low Data Mode.")
        XCTAssertEqual(DeviceCopy.waitingForNetwork, "Download paused \u{00B7} waiting for Wi-Fi or Ethernet")
    }

    // MARK: - Helpers

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
