import SwiftUI
import XCTest
@testable import Aloud

/// Pins the centralized `-uitest-*` launch-argument parsing (UITestHooks),
/// including the mute and autoplay rules that keep every test silent.
/// The hooks themselves only exist in DEBUG builds — which is exactly the
/// configuration tests run in — and Release gets no-op accessors, so the
/// gate is structural rather than per-call-site `#if DEBUG` discipline.
final class UITestHooksTests: XCTestCase {

    // MARK: - forcedColorScheme

    func testForcedColorSchemeDark() {
        XCTAssertEqual(UITestHooks.forcedColorScheme(in: ["app", "-uitest-force-dark"]), .dark)
    }

    func testForcedColorSchemeLight() {
        XCTAssertEqual(UITestHooks.forcedColorScheme(in: ["app", "-uitest-force-light"]), .light)
    }

    func testForcedColorSchemeAbsent() {
        XCTAssertNil(UITestHooks.forcedColorScheme(in: ["app"]))
    }

    func testForcedColorSchemeDarkWinsWhenBothPassed() {
        XCTAssertEqual(
            UITestHooks.forcedColorScheme(in: ["-uitest-force-light", "-uitest-force-dark"]),
            .dark)
    }

    // MARK: - seekText

    func testSeekTextReturnsFollowingArgument() {
        XCTAssertEqual(
            UITestHooks.seekText(in: ["app", "-uitest-seek-text", "after the first drink"]),
            "after the first drink")
    }

    func testSeekTextWithoutValueIsNil() {
        // Flag at the end of the argument list must not crash or match.
        XCTAssertNil(UITestHooks.seekText(in: ["app", "-uitest-seek-text"]))
    }

    func testSeekTextAbsentIsNil() {
        XCTAssertNil(UITestHooks.seekText(in: ["app"]))
    }

    // MARK: - muteAudio

    private func mute(_ arguments: [String],
                      environment: [String: String] = [:],
                      xcTestLoaded: Bool = false,
                      debugStartsMuted: Bool = false) -> Bool {
        UITestHooks.muteAudio(in: arguments, environment: environment, xcTestLoaded: xcTestLoaded,
                              debugStartsMuted: debugStartsMuted)
    }

    func testEveryUITestArgumentMutes() {
        XCTAssertTrue(mute(["-uitest-mute"]))
        XCTAssertTrue(mute(["app", "-uitest-seed-first-classic"]))
        XCTAssertTrue(mute(["-uitest-force-dark"]))
    }

    func testTestHostsPreviewsAndTheEnvironmentSwitchMute() {
        XCTAssertTrue(mute(["app"], xcTestLoaded: true))
        XCTAssertTrue(mute(["app"], environment: ["XCTestConfigurationFilePath": "/x"]))
        XCTAssertTrue(mute(["app"], environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        XCTAssertTrue(mute(["app"], environment: ["ALOUD_MUTE": "1"]))
    }

    func testOrdinaryLaunchIsNotMuted() {
        XCTAssertFalse(mute(["app", "-UIPreferredContentSizeCategoryName", "X"]))
    }

    // MARK: - ALOUD_AUDIBLE (testing.md D3)

    /// Every test condition, as (name, arguments, environment, XCTest loaded).
    private static let testConditions: [(String, [String], [String: String], Bool)] = [
        ("-uitest-mute", ["app", "-uitest-mute"], [:], false),
        ("any -uitest- argument", ["app", "-uitest-seed-first-classic"], [:], false),
        ("XCTest loaded", ["app"], [:], true),
        ("XCTestConfigurationFilePath", ["app"], ["XCTestConfigurationFilePath": "/x"], false),
        ("previews", ["app"], ["XCODE_RUNNING_FOR_PREVIEWS": "1"], false),
        ("ALOUD_MUTE", ["app"], ["ALOUD_MUTE": "1"], false),
    ]

    /// `ALOUD_AUDIBLE=1` lifts only the Mac's Debug default: every test
    /// condition still mutes beside it, with or without that default.
    func testAudibleNeverOverridesATestCondition() {
        for (name, arguments, environment, xcTestLoaded) in Self.testConditions {
            let audible = environment.merging(["ALOUD_AUDIBLE": "1"]) { current, _ in current }
            for debugStartsMuted in [false, true] {
                XCTAssertTrue(mute(arguments, environment: environment, xcTestLoaded: xcTestLoaded,
                                   debugStartsMuted: debugStartsMuted),
                              "\(name), debugStartsMuted \(debugStartsMuted)")
                XCTAssertTrue(mute(arguments, environment: audible, xcTestLoaded: xcTestLoaded,
                                   debugStartsMuted: debugStartsMuted),
                              "\(name) + ALOUD_AUDIBLE=1, debugStartsMuted \(debugStartsMuted)")
            }
        }
    }

    /// A plain Debug launch on the Mac (Spotlight, Shortcuts, `open`) is
    /// silent; only `ALOUD_AUDIBLE=1`, spelled exactly, opts it into sound.
    func testMacDebugDefaultIsMuted() {
        XCTAssertTrue(mute(["app"], debugStartsMuted: true))
        XCTAssertFalse(mute(["app"], environment: ["ALOUD_AUDIBLE": "1"], debugStartsMuted: true))
        for other in ["0", "", "true", "yes", " 1"] {
            XCTAssertTrue(mute(["app"], environment: ["ALOUD_AUDIBLE": other], debugStartsMuted: true),
                          "ALOUD_AUDIBLE=\"\(other)\" is not the opt-in")
        }
    }

    /// Without the Debug default (the iPhone's), a plain launch plays aloud
    /// and `ALOUD_AUDIBLE` changes nothing.
    func testWithoutTheDebugDefaultAudibleChangesNothing() {
        XCTAssertFalse(mute(["app"]))
        XCTAssertFalse(mute(["app"], environment: ["ALOUD_AUDIBLE": "1"]))
        XCTAssertFalse(mute(["app"], environment: ["ALOUD_AUDIBLE": "0"]))
    }

    // MARK: - suppressAutoplay

    func testUITestLaunchSuppressesAutoplay() {
        XCTAssertTrue(UITestHooks.suppressAutoplay(in: ["app", "-uitest-open-first-doc"]))
    }

    func testAllowAutoplayLiftsSuppressionButNeverUnmutes() {
        let arguments = ["-uitest-mute", "-uitest-allow-autoplay"]
        XCTAssertFalse(UITestHooks.suppressAutoplay(in: arguments))
        XCTAssertTrue(mute(arguments), "no flag un-mutes")
    }

    func testOrdinaryLaunchDoesNotSuppressAutoplay() {
        XCTAssertFalse(UITestHooks.suppressAutoplay(in: ["app"]))
    }

    // MARK: - seedClassicCount

    func testSeedClassicCount() {
        XCTAssertEqual(UITestHooks.seedClassicCount(in: ["-uitest-seed-classics", "2"]), 2)
        XCTAssertEqual(UITestHooks.seedClassicCount(in: ["-uitest-seed-first-classic"]), 1)
        XCTAssertEqual(UITestHooks.seedClassicCount(in: ["-uitest-seed-classics"]), 0)
        XCTAssertEqual(UITestHooks.seedClassicCount(in: ["-uitest-seed-classics", "x"]), 0)
    }

    // MARK: - value(after:) / values(after:)

    func testValuesAfterCollectsEveryOccurrence() {
        XCTAssertEqual(
            UITestHooks.values(after: "-uitest-seed-classic",
                               in: ["-uitest-seed-classic", "1063", "-uitest-seed-classic", "84"]),
            ["1063", "84"])
    }

    func testValueAfterTrailingFlagIsNil() {
        XCTAssertNil(UITestHooks.value(after: "-uitest-open-fixture", in: ["app", "-uitest-open-fixture"]))
    }

    func testFixtureKindParsing() {
        let value = UITestHooks.value(after: "-uitest-open-fixture",
                                      in: ["-uitest-open-fixture", "pdf-blank"])
        XCTAssertEqual(value.flatMap(UITestFixtureKind.init(rawValue:)), .pdfBlank)
        XCTAssertNil(UITestFixtureKind(rawValue: "nope"))
    }

    // MARK: - Phase 3 hooks

    func testEveryFaultKindParses() {
        let expected: [String: UITestFaultKind] = [
            "route": .route,
            "interruption": .interruption,
            "interruption-resume": .interruptionResume,
            "synthesis": .synthesis,
            "skip": .skip,
            "warmup": .warmup,
            "thermal-serious": .thermalSerious,
            "thermal-critical": .thermalCritical,
        ]
        XCTAssertEqual(expected.count, UITestFaultKind.allCases.count)
        for (raw, kind) in expected {
            XCTAssertEqual(UITestHooks.fault(in: ["app", "-uitest-fault", raw]), kind, raw)
        }
    }

    func testUnknownFaultIsNil() {
        XCTAssertNil(UITestHooks.fault(in: ["-uitest-fault", "nope"]))
        XCTAssertNil(UITestHooks.fault(in: ["-uitest-fault", "interruptionResume"]), "raw values only")
    }

    func testTrailingFaultFlagIsNil() {
        XCTAssertNil(UITestHooks.fault(in: ["app", "-uitest-fault"]))
    }

    func testFaultAfterIsNotItselfAFault() {
        XCTAssertNil(UITestHooks.fault(in: ["-uitest-fault-after", "route"]))
    }

    func testFaultAfterSeconds() {
        XCTAssertEqual(UITestHooks.faultAfterSeconds(in: ["app"]), 2, "default")
        XCTAssertEqual(UITestHooks.faultAfterSeconds(in: ["-uitest-fault-after", "0.5"]), 0.5)
        XCTAssertEqual(UITestHooks.faultAfterSeconds(in: ["-uitest-fault-after", "soon"]), 2)
        XCTAssertEqual(UITestHooks.faultAfterSeconds(in: ["-uitest-fault-after"]), 2)
    }

    func testEveryPhase3HookMutesAndSuppressesAutoplay() {
        let flags = ["-uitest-fault", "-uitest-fault-after", "-uitest-sleep-one-minute",
                     "-uitest-seed-live-session", "-uitest-haptic-log", "-uitest-low-disk",
                     "-uitest-damaged-model"]
        for flag in flags {
            XCTAssertTrue(mute(["app", flag]), flag)
            XCTAssertTrue(UITestHooks.suppressAutoplay(in: ["app", flag]), flag)
        }
    }

    // MARK: - Phase 4 shortcut hook (R26)

    func testShortcutHookParses() {
        XCTAssertEqual(UITestHooks.shortcut(in: ["app", "-uitest-shortcut", "continue"]), .continueListening)
        XCTAssertEqual(UITestHooks.shortcut(in: ["-uitest-shortcut", "sleep-30"]), .sleep(.thirty))
        XCTAssertEqual(UITestHooks.shortcut(in: ["-uitest-shortcut", "sleep-chapter"]), .sleep(.endOfChapter))
        XCTAssertEqual(UITestHooks.shortcut(in: ["-uitest-shortcut", "sleep-off"]), .sleep(.off))
    }

    func testUnknownShortcutsAreNil() {
        XCTAssertNil(UITestHooks.shortcut(in: ["-uitest-shortcut", "sleep-7"]), "not a menu option")
        XCTAssertNil(UITestHooks.shortcut(in: ["-uitest-shortcut", "sleep-thirty"]), "raw values only")
        XCTAssertNil(UITestHooks.shortcut(in: ["-uitest-shortcut", "resume"]))
        XCTAssertNil(UITestHooks.shortcut(in: ["app", "-uitest-shortcut"]), "flag last")
        XCTAssertNil(UITestHooks.shortcut(in: ["app", "continue"]), "flag absent")
    }

    /// The shortcut hook is a `-uitest-` launch like any other: muted, with
    /// autoplay off (the shortcut's own Play still runs, as the system's would).
    func testShortcutHookMutesAndSuppressesAutoplay() {
        let arguments = ["app", "-uitest-shortcut", "continue"]
        XCTAssertTrue(mute(arguments))
        XCTAssertTrue(UITestHooks.suppressAutoplay(in: arguments))
    }

    // MARK: - This process

    /// The unit-test host loads XCTest, so every sound it could make is muted.
    func testThisTestHostIsMuted() {
        XCTAssertTrue(UITestHooks.muteAudio)
    }

    /// Hosted unit tests are muted but not autoplay-suppressed, so the
    /// autoplay policy tests exercise the real gate.
    func testThisTestHostDoesNotSuppressAutoplay() {
        XCTAssertFalse(UITestHooks.suppressAutoplay)
    }

    /// The unit-test host runs no shortcut at launch.
    func testThisTestHostRunsNoShortcut() {
        XCTAssertNil(UITestHooks.shortcut)
    }
}
