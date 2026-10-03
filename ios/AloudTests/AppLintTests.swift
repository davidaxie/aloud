import XCTest

/// Phase 3's app-wide source lints (R11, R14, R20): one copy table, one
/// volume writer, one haptic player, one motion vocabulary, and DEBUG-only
/// test plumbing. Reads ios/Aloud through SourceTree; skips when the test
/// host can't see the checkout.
final class AppLintTests: XCTestCase {

    /// R11: the floating toast layer is gone, name and all (any case, so a
    /// `ToastView` counts too).
    func testNoToastLeft() throws {
        let sources = try SourceTree.sources()
        let hits = sources.filter { $0.value.range(of: "toast", options: .caseInsensitive) != nil }
        XCTAssertEqual(hits.keys.sorted(), [])
    }

    /// R11: every stopped reason and notice is spelled once, in the fixed
    /// table, so what the line shows and what VoiceOver says never drift.
    /// C1: a line worded per platform is spelled whole in DeviceNoun.swift,
    /// and the device a line names comes from `DeviceNoun`, so the table is
    /// PlaybackNotice.swift plus DeviceNoun.swift and nothing else.
    func testStopAndNoticeCopyLivesOnlyInTheTable() throws {
        let sources = try SourceTree.sources()
        let notice = "Playback/PlaybackNotice.swift"
        let deviceNoun = "Platform/DeviceNoun.swift"
        let homes = [
            "Paused by sleep timer": notice, "headphones disconnected": notice,
            "Using the System voice while": notice, "went to sleep": notice,
            "Skipped a sentence": notice, "Backed up": notice, "Now reading in": notice,
            "iOS closed Aloud": deviceNoun,
        ]
        for (copy, home) in homes {
            XCTAssertEqual(SourceTree.files(containing: copy, in: sources), [home],
                           "'\(copy)' belongs only to the copy table")
        }
        // The iPhone's lines as they read: written out nowhere but beside
        // the noun itself.
        for spelled in ["while iPhone cools", "iPhone is too hot", "iPhone went to sleep"] {
            XCTAssertEqual(SourceTree.files(containing: spelled, in: sources).filter { $0 != deviceNoun }, [],
                           "'\(spelled)' takes its device from DeviceNoun")
        }
    }

    /// R19/R20: PlaybackController.setOutputVolume is the mixer's only
    /// writer, so the mute and every ramp hold everywhere.
    func testOneOutputVolumeWriter() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.occurrences(of: "outputVolume =", in: sources), 1)
        XCTAssertEqual(SourceTree.files(containing: "outputVolume =", in: sources),
                       ["Playback/PlaybackController.swift"])
    }

    /// R20: one `.sensoryFeedback` plays every haptic, and the app makes no
    /// UI sounds.
    func testOneHapticPlayerAndNoUISounds() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.files(containing: ".sensoryFeedback(", in: sources),
                       ["Playback/TransportHaptics.swift"])
        for banned in ["UIImpactFeedbackGenerator", "UISelectionFeedbackGenerator",
                       "UINotificationFeedbackGenerator", "AudioServicesPlaySystemSound",
                       "AudioServicesPlayAlertSound"] {
            XCTAssertEqual(SourceTree.files(containing: banned, in: sources), [], "'\(banned)' should be gone")
        }
    }

    /// R20: movement lives in the theme's one transition helper, so Reduce
    /// Motion turns every chip and message into a plain fade. `.slide` is
    /// matched as a whole word: "listening.speed.slider" is an identifier.
    func testMotionOnlyInTheTheme() throws {
        let sources = try SourceTree.sources()
        let theme = ["Theme/AloudTheme.swift"]
        for motion in [".move(edge:", ".scale(scale:", "repeatForever"] {
            let outside = SourceTree.files(containing: motion, in: sources).filter { !theme.contains($0) }
            XCTAssertEqual(outside, [], "'\(motion)' belongs only to the theme")
        }
        let slide = try NSRegularExpression(pattern: #"\.slide\b"#)
        let slides = sources.filter { _, text in
            slide.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.map(\.key).filter { !theme.contains($0) }
        XCTAssertEqual(slides.sorted(), [], "'.slide' belongs only to the theme")
    }

    /// R14: skip(seconds:) is the only skip.
    func testSentenceStepsAreGone() throws {
        let sources = try SourceTree.sources()
        for removed in ["nextSentence(", "previousSentence("] {
            XCTAssertEqual(SourceTree.files(containing: removed, in: sources), [], "'\(removed)' should be gone")
        }
    }

    /// Fault injection, the announcement log and the muted render pump never
    /// reach a Release build.
    func testTestPlumbingIsDebugOnly() throws {
        let plumbing = ["App/UITestAnnouncementLog.swift", "App/UITestFaults.swift", "Playback/MutedRenderPump.swift"]
        let sources = try SourceTree.sources(only: plumbing)
        XCTAssertEqual(sources.keys.sorted(), plumbing)
        for (path, text) in sources {
            XCTAssertTrue(text.hasPrefix("#if DEBUG"), "\(path) should begin with #if DEBUG")
        }
    }
}
