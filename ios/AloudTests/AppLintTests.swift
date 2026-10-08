import XCTest

/// Phase 3's app-wide source lints (R11, R14, R20): one copy table, one
/// volume writer, one haptic player, one motion vocabulary, and DEBUG-only
/// test plumbing. Reads ios/Aloud through SourceTree; skips when the test
/// host can't see the checkout. The silence lints read both apps
/// (`SourceTree.appSources()`: ios/Aloud, plus ios/AloudMac once it exists).
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
    /// writer in either app (through CutSpliceSilencer's one write, which
    /// adds only a cut splice's zero and the restore of that level), so the
    /// mute and every ramp hold everywhere. The
    /// Mac's own files set no volume at all (AVSpeech's utterance volume is
    /// the shared engine's).
    func testOneOutputVolumeWriter() throws {
        let sources = try SourceTree.appSources()
        XCTAssertEqual(SourceTree.occurrences(of: "outputVolume =", in: sources), 1)
        XCTAssertEqual(SourceTree.files(containing: "outputVolume =", in: sources),
                       ["Playback/PlaybackController.swift"])
        let mac = sources.filter { $0.key.hasPrefix(SourceTree.macPrefix) }
        XCTAssertEqual(SourceTree.files(containing: ".volume =", in: mac), [], "a volume outside the mixer's writer")
    }

    /// R20 and testing.md §1.2(g): one `.sensoryFeedback` plays every
    /// haptic, and neither app makes a sound outside the muted engine: no UI
    /// or alert sound, no second player, no notification sound. Type names
    /// match as whole words, so the engine's `AVAudioPlayerNode` passes.
    func testOneHapticPlayerAndNoUISounds() throws {
        let sources = try SourceTree.appSources()
        XCTAssertEqual(SourceTree.files(containing: ".sensoryFeedback(", in: sources),
                       ["Playback/TransportHaptics.swift"])
        for banned in ["UIImpactFeedbackGenerator", "UISelectionFeedbackGenerator",
                       "UINotificationFeedbackGenerator", "AudioServicesPlaySystemSound",
                       "AudioServicesPlayAlertSound", "AudioServicesPlay", "NSBeep(", ".beep()"] {
            XCTAssertEqual(SourceTree.files(containing: banned, in: sources), [], "'\(banned)' should be gone")
        }
        for api in ["NSHapticFeedbackManager", "NSSound", "NSBeep", "AVAudioPlayer", "AVPlayer",
                    "AVQueuePlayer", "UNNotificationSound"] {
            let word = try NSRegularExpression(pattern: "\\b\(api)\\b")
            XCTAssertEqual(Self.files(matching: word, in: sources), [],
                           "'\(api)' would sound outside the muted engine")
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

    /// Fault injection, the announcement log, the muted render pump and the
    /// fixture PDF writer never reach a Release build.
    func testTestPlumbingIsDebugOnly() throws {
        let plumbing = ["App/UITestAnnouncementLog.swift", "App/UITestFaults.swift", "Platform/FixturePDF.swift",
                        "Playback/MutedRenderPump.swift"]
        let sources = try SourceTree.sources(only: plumbing)
        XCTAssertEqual(sources.keys.sorted(), plumbing)
        for (path, text) in sources {
            XCTAssertTrue(text.hasPrefix("#if DEBUG"), "\(path) should begin with #if DEBUG")
        }
    }

    /// Testing.md §1.2(e): probes (a `"debug.` accessibility identifier) and
    /// the Mac's test plumbing (MacTestSilence.swift, or any AloudMac file
    /// named for a probe or a UI test) live only in files that begin with
    /// #if DEBUG, in either app, so no probe or beep fence reaches Release.
    func testProbeFilesAreDebugOnly() throws {
        let sources = try SourceTree.appSources()
        let probes = SourceTree.files(containing: "\"debug.", in: sources)
        XCTAssertTrue(probes.contains("App/UITestFaults.swift"), "the scan sees today's probes")
        let macPlumbing = sources.keys.filter { path in
            guard path.hasPrefix(SourceTree.macPrefix) else { return false }
            let name = (path as NSString).lastPathComponent
            return ["TestSilence", "UITest", "Probe"].contains { name.contains($0) }
        }
        for path in Set(probes).union(macPlumbing).sorted() {
            XCTAssertTrue(sources[path]?.hasPrefix("#if DEBUG") == true, "\(path) should begin with #if DEBUG")
        }
    }

    /// L029: UI tests that need the Kokoro model read the shared seed that
    /// ios/tools/fetch_kokoro_model.sh fills, never a session's scratch
    /// directory, which is gone by the next run and turns them into skips.
    func testUITestsReadTheSharedModelSeed() throws {
        for root in [SourceTree.uiTestsRoot, SourceTree.macUITestsRoot] where SourceTree.exists(root) {
            let sources = try SourceTree.sources(in: root)
            XCTAssertEqual(SourceTree.files(containing: "/private/tmp/claude-", in: sources), [],
                           "\(root.lastPathComponent) names no session scratch directory")
        }
        let sources = try SourceTree.sources(in: SourceTree.uiTestsRoot, only: ["KokoroPlaybackUITest.swift"])
        let kokoro = try XCTUnwrap(sources["KokoroPlaybackUITest.swift"])
        XCTAssertTrue(kokoro.contains("static let modelDirectory = \"/Users/Shared/AloudKokoroModel\""))
    }

    /// The files whose text `pattern` matches, sorted.
    private static func files(matching pattern: NSRegularExpression, in sources: [String: String]) -> [String] {
        sources.filter { _, text in
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.map(\.key).sorted()
    }

    /// R1-26: section eyebrows are capitals everywhere, as on Classics and
    /// the Continue card: every eyebrow font is followed by
    /// `.textCase(.uppercase)` (its words kept as written for VoiceOver and
    /// Voice Control). The cover's author keeps its small caps, and the
    /// theme defines the token.
    func testEveryEyebrowIsCapitals() throws {
        let sources = try SourceTree.appSources()
        let exempt = ["Library/BookCover.swift", "Theme/AloudTheme.swift"]
        var checked = 0
        for (path, text) in sources where !exempt.contains(path) {
            var from = text.startIndex
            while let hit = text.range(of: "Theme.font(.eyebrow", range: from..<text.endIndex) {
                checked += 1
                let following = text[hit.lowerBound...].prefix(250)
                XCTAssertTrue(following.contains(".textCase(.uppercase)"),
                              "\(path): an eyebrow without capitals: \(String(following))")
                from = hit.upperBound
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "the lint reads the eyebrows")
    }
}
