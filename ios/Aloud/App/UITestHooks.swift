import Foundation
import SwiftUI

/// The single home for every `-uitest-*` launch-argument hook.
///
/// The gate is structural, not per-call-site discipline: the whole parsing
/// surface lives inside one `#if DEBUG` block, and Release builds get no-op
/// accessors — no `-uitest` string even exists in a Release binary, so no
/// launch context can flip test behavior in the shipped app.
///
/// Silence and autoplay:
/// - Every `-uitest-` launch is muted (`muteAudio`) and starts with autoplay
///   off (`suppressAutoplay`).
/// - `-uitest-mute` is the explicit spelling every UI test passes.
/// - `-uitest-allow-autoplay` lifts the autoplay suppression only. Nothing
///   un-mutes.
/// - Hosted unit tests are muted but not autoplay-suppressed.
/// - Where `PlatformAudio.debugBuildsStartMuted` (the Mac), a plain Debug
///   launch is muted too, so a system launch of the dev build stays silent.
///   `ALOUD_AUDIBLE=1` (set only by Xcode's Run action) lifts that default
///   and nothing else: it never overrides a test condition.
/// - Every new hook must start with `-uitest-` so that it implies both.
///
/// Phase 3 fault and probe hooks (each also mutes and suppresses autoplay):
/// - `-uitest-fault <kind>` injects one `UITestFaultKind`, after
///   `-uitest-fault-after <s>` seconds (default 2).
/// - `-uitest-sleep-one-minute` adds a 1 min sleep-timer option.
/// - `-uitest-seed-live-session` leaves a live-session marker, as if iOS
///   closed Aloud while it was speaking.
/// - `-uitest-restore-session` reopens the last reader at launch.
/// - `-uitest-haptic-log` exposes the transport haptic log (debug.haptics).
/// - `-uitest-seed-places <n>` records n places, spread through the first
///   document, in its place history (Contents' places list).
/// - `-uitest-low-disk` reports 100 MB free to the download's space check.
/// - `-uitest-damaged-model` installs 1-byte model files in the temporary
///   model directory, which launch-time detection reads as damaged.
/// - `-uitest-fail-reader-load` fails the reader's text load, so the
///   reader shows its failure state.
///
/// Phase 4 (R26): `-uitest-shortcut continue` or `-uitest-shortcut
/// sleep-<raw>` runs that App Shortcut's action as the last launch step, the
/// way the system would, but muted. No test runs a real intent.
///
/// The Mac's hooks (each also mutes and suppresses autoplay; the Mac app
/// reads them):
/// - `-uitest-window-size <w>x<h>` sizes the main window before it shows.
/// - `-uitest-force-light` / `-uitest-force-dark` (above) set the app's
///   appearance before the first window draws.
/// - `-uitest-offline`: the network path reads as unsatisfied and every
///   request is refused, as on a plane.
/// - `-uitest-kokoro-model-path <dir>` (above) reads the natural voice from
///   /Users/Shared/AloudKokoroModel, so no test downloads it.
/// - `-uitest-reduce-motion` / `-uitest-increase-contrast` stand in for the
///   system settings, which tests never flip.
/// - `-uitest-open <absolute path>` opens that file as Finder's Open With
///   would.
///
/// Adding a hook means adding an accessor here (inside the DEBUG block) and a
/// matching no-op in the Release block; call sites never touch ProcessInfo.
enum UITestHooks {

    #if DEBUG

    /// Jump straight into the first library document once it exists.
    static var openFirstDoc: Bool { arguments.contains("-uitest-open-first-doc") }

    /// Removes the listening preferences: voice, speed and bracketed asides.
    static var resetVoicePref: Bool { arguments.contains("-uitest-reset-voice-pref") }

    /// Wipe the on-disk library (documents, content caches, index, thumbnails)
    /// before the store loads — leftover container state (e.g. listening
    /// progress that materializes the Continue Listening hero) can never
    /// leak into a test that assumes a fresh shelf.
    static var resetLibrary: Bool { arguments.contains("-uitest-reset-library") }

    /// `-uitest-force-dark` / `-uitest-force-light` pin the color scheme
    /// (simctl's appearance flip is unreliable on this runtime).
    static var forcedColorScheme: ColorScheme? {
        Self.forcedColorScheme(in: arguments)
    }

    /// `-uitest-seek-text <substring>` cues the playhead at the first
    /// sentence containing the substring.
    static var seekText: String? {
        Self.seekText(in: arguments)
    }

    /// `-uitest-kokoro-model-path <dir>` points at a directory that already
    /// holds model.onnx + voices.bin (e.g. on the host Mac, which the
    /// simulator sandbox can read), so tests never download. Single-dash
    /// launch arguments land in UserDefaults under the dashless key; a value
    /// persisted there acts only in a UI-test launch, which is muted.
    static var kokoroModelPath: String? {
        guard isUITestLaunch,
              let override = UserDefaults.standard.string(forKey: "uitest-kokoro-model-path"),
              !override.isEmpty else { return nil }
        return override
    }

    /// Any `-uitest-` argument at all.
    static var isUITestLaunch: Bool { isUITestLaunch(in: arguments) }

    /// Zero the app's audio output. True for every UI-test launch, hosted
    /// unit tests, SwiftUI previews and `ALOUD_MUTE=1`; no flag un-mutes.
    /// On the Mac a Debug build also starts muted unless `ALOUD_AUDIBLE=1`.
    static var muteAudio: Bool {
        muteAudio(in: arguments,
                  environment: ProcessInfo.processInfo.environment,
                  xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                  debugStartsMuted: PlatformAudio.debugBuildsStartMuted)
    }

    /// Keep `PlaybackController.startAutoplay()` from playing. UI tests that
    /// assert autoplay pass `-uitest-allow-autoplay`.
    static var suppressAutoplay: Bool { suppressAutoplay(in: arguments) }

    /// `-uitest-seed-classics <n>` (or the older `-uitest-seed-first-classic`,
    /// meaning 1) adds the first n bookshelf classics on launch.
    static var seedClassicCount: Int { seedClassicCount(in: arguments) }

    /// Each `-uitest-seed-classic <gutenbergID>` adds that classic on launch.
    static var seedClassicIDs: [Int] { values(after: "-uitest-seed-classic", in: arguments).compactMap { Int($0) } }

    /// Seed the first classic and mark it Finished.
    static var seedFinished: Bool { arguments.contains("-uitest-seed-finished") }

    /// `-uitest-seed-places <n>`: n places in the first document's history.
    static var seedPlaceCount: Int {
        value(after: "-uitest-seed-places", in: arguments).flatMap { Int($0) }.map { max($0, 0) } ?? 0
    }

    /// Hold every Files/Open-in import for 10 s so the overlay and Cancel
    /// can be exercised.
    static var slowImport: Bool { arguments.contains("-uitest-slow-import") }

    /// `-uitest-open-fixture <kind>` writes a fixture into Documents/Inbox
    /// and routes it through the Open-in path.
    static var openFixture: UITestFixtureKind? {
        value(after: "-uitest-open-fixture", in: arguments).flatMap(UITestFixtureKind.init(rawValue:))
    }

    /// `-uitest-pick-fixture <kind>` routes a fixture through the Files
    /// picker's completion, as if the user had picked it.
    static var pickFixture: UITestFixtureKind? {
        value(after: "-uitest-pick-fixture", in: arguments).flatMap(UITestFixtureKind.init(rawValue:))
    }

    /// `-uitest-listened-seconds <s>` presets the natural-voice offer's
    /// cumulative listening time.
    static var listenedSeconds: TimeInterval? {
        value(after: "-uitest-listened-seconds", in: arguments).flatMap { Double($0) }
    }

    /// Forget any earlier answer to the natural-voice offer.
    static var resetNaturalVoiceOffer: Bool { arguments.contains("-uitest-reset-natural-voice-offer") }

    /// Install the Kokoro model into a fresh temporary directory, so the
    /// model reads as absent and the System voice is used.
    static var tempModelDirectory: Bool { arguments.contains("-uitest-temp-model-dir") }

    /// Treat the network path as expensive (cellular).
    static var forceExpensiveNetwork: Bool { arguments.contains("-uitest-expensive-network") }

    /// Treat the device as below the natural voice's memory floor.
    static var forceUnsupportedDevice: Bool { arguments.contains("-uitest-unsupported-device") }

    /// `-uitest-fault <kind>`: the one fault this launch injects.
    static var fault: UITestFaultKind? { fault(in: arguments) }

    /// `-uitest-fault-after <s>`: seconds before the fault fires (default 2).
    static var faultAfterSeconds: TimeInterval { faultAfterSeconds(in: arguments) }

    /// Offer a 1 min sleep timer, so R19's fade and stop fit in a UI test.
    static var sleepOneMinuteOption: Bool { arguments.contains("-uitest-sleep-one-minute") }

    /// Seed a live-session marker before the controller is built: the next
    /// init reads it as iOS having closed Aloud while it spoke.
    static var seedLiveSession: Bool { arguments.contains("-uitest-seed-live-session") }

    /// `-uitest-restore-session`: reopen the last reader at launch, as a
    /// normal launch does (UI-test launches start on the bare Library).
    static var restoreSession: Bool { arguments.contains("-uitest-restore-session") }

    /// Expose TransportHaptics' log through the debug.haptics probe.
    static var hapticLog: Bool { arguments.contains("-uitest-haptic-log") }

    /// Report 100 MB free, below the download's 707 MB requirement.
    static var forceLowDiskSpace: Bool { arguments.contains("-uitest-low-disk") }

    /// Use the temporary model directory with 1-byte model files: their
    /// sizes are off, so launch-time detection reads them as damaged.
    static var damagedModel: Bool { arguments.contains("-uitest-damaged-model") }

    /// The reader's text fails to load, as a damaged document's would: the
    /// reader shows its failure state and the way back to the Library.
    static var failReaderLoad: Bool { arguments.contains("-uitest-fail-reader-load") }

    /// `-uitest-text-size <step>`: the reader's text size step, written to
    /// the app's own defaults at launch with no size marked as seeded, so
    /// the stepper can still change it. A `-aloud.prefs.v1.textSize`
    /// argument would sit in the argument domain over every write.
    static var textSizeStep: Int? { value(after: "-uitest-text-size", in: arguments).flatMap { Int($0) } }

    /// `-uitest-shortcut <name>`: the shortcut action this launch runs.
    static var shortcut: UITestShortcut? { shortcut(in: arguments) }

    /// `-uitest-window-size <w>x<h>`: the Mac's main window size, in points.
    static var windowSize: CGSize? { windowSize(in: arguments) }

    /// Work as on a plane: no path, and no request leaves the process.
    static var offline: Bool { arguments.contains("-uitest-offline") }

    /// Reduce Motion on, whatever the system says.
    static var forceReduceMotion: Bool { arguments.contains("-uitest-reduce-motion") }

    /// Increase Contrast on, whatever the system says.
    static var forceIncreaseContrast: Bool { arguments.contains("-uitest-increase-contrast") }

    /// `-uitest-open <absolute path>`: the file this launch opens.
    static var openPath: URL? { openPath(in: arguments) }

    // MARK: - Parsing (argument-injectable for unit tests)

    /// "1280x800" → 1280 × 800. Anything else (a missing side, a zero,
    /// negative or infinite one, the flag last) is nil.
    static func windowSize(in arguments: [String]) -> CGSize? {
        guard let value = value(after: "-uitest-window-size", in: arguments) else { return nil }
        let sides = value.split(separator: "x", omittingEmptySubsequences: false).compactMap { Double($0) }
        guard sides.count == 2, sides.allSatisfy({ $0 > 0 && $0.isFinite }) else { return nil }
        return CGSize(width: sides[0], height: sides[1])
    }

    /// Only an absolute path counts, so a following flag or a path relative
    /// to wherever the runner started is never opened.
    static func openPath(in arguments: [String]) -> URL? {
        guard let path = value(after: "-uitest-open", in: arguments), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// "continue" → Continue listening; "sleep-<raw>" → Set sleep timer with
    /// the SleepTimerChoice of that raw value ("sleep-30", "sleep-chapter",
    /// "sleep-off"). Anything else, or the flag absent or last, is nil.
    static func shortcut(in arguments: [String]) -> UITestShortcut? {
        guard let name = value(after: "-uitest-shortcut", in: arguments) else { return nil }
        if name == "continue" { return .continueListening }
        let sleepPrefix = "sleep-"
        guard name.hasPrefix(sleepPrefix) else { return nil }
        return SleepTimerChoice(rawValue: String(name.dropFirst(sleepPrefix.count))).map(UITestShortcut.sleep)
    }

    static func fault(in arguments: [String]) -> UITestFaultKind? {
        value(after: "-uitest-fault", in: arguments).flatMap(UITestFaultKind.init(rawValue:))
    }

    static func faultAfterSeconds(in arguments: [String]) -> TimeInterval {
        value(after: "-uitest-fault-after", in: arguments).flatMap { Double($0) } ?? 2
    }

    static func isUITestLaunch(in arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("-uitest-") }
    }

    /// The test conditions mute unconditionally. `ALOUD_AUDIBLE=1` appears
    /// only in the last term, so it can lift the Debug default
    /// (`debugStartsMuted`, the Mac's) and never a test condition.
    static func muteAudio(in arguments: [String], environment: [String: String], xcTestLoaded: Bool,
                          debugStartsMuted: Bool = false) -> Bool {
        isUITestLaunch(in: arguments)
            || xcTestLoaded
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["ALOUD_MUTE"] == "1"
            || (debugStartsMuted && environment["ALOUD_AUDIBLE"] != "1")
    }

    static func suppressAutoplay(in arguments: [String]) -> Bool {
        isUITestLaunch(in: arguments) && !arguments.contains("-uitest-allow-autoplay")
    }

    static func seedClassicCount(in arguments: [String]) -> Int {
        if let count = value(after: "-uitest-seed-classics", in: arguments).flatMap({ Int($0) }), count > 0 {
            return count
        }
        return arguments.contains("-uitest-seed-first-classic") ? 1 : 0
    }

    static func forcedColorScheme(in arguments: [String]) -> ColorScheme? {
        if arguments.contains("-uitest-force-dark") { return .dark }
        if arguments.contains("-uitest-force-light") { return .light }
        return nil
    }

    static func seekText(in arguments: [String]) -> String? {
        value(after: "-uitest-seek-text", in: arguments)
    }

    /// The argument after the first exact match; nil when the flag is absent
    /// or last.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// The argument after every exact match (a trailing flag contributes
    /// nothing).
    static func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    #else

    // Release: the entire hook surface is compiled away.
    static var openFirstDoc: Bool { false }
    static var resetVoicePref: Bool { false }
    static var resetLibrary: Bool { false }
    static var restoreSession: Bool { false }
    static var forcedColorScheme: ColorScheme? { nil }
    static var seekText: String? { nil }
    static var kokoroModelPath: String? { nil }
    static var isUITestLaunch: Bool { false }
    static var muteAudio: Bool { false }
    static var suppressAutoplay: Bool { false }
    static var seedClassicCount: Int { 0 }
    static var seedClassicIDs: [Int] { [] }
    static var seedFinished: Bool { false }
    static var textSizeStep: Int? { nil }
    static var seedPlaceCount: Int { 0 }
    static var slowImport: Bool { false }
    static var openFixture: UITestFixtureKind? { nil }
    static var pickFixture: UITestFixtureKind? { nil }
    static var listenedSeconds: TimeInterval? { nil }
    static var resetNaturalVoiceOffer: Bool { false }
    static var tempModelDirectory: Bool { false }
    static var forceExpensiveNetwork: Bool { false }
    static var forceUnsupportedDevice: Bool { false }
    static var fault: UITestFaultKind? { nil }
    static var faultAfterSeconds: TimeInterval { 0 }
    static var sleepOneMinuteOption: Bool { false }
    static var seedLiveSession: Bool { false }
    static var hapticLog: Bool { false }
    static var forceLowDiskSpace: Bool { false }
    static var damagedModel: Bool { false }
    static var failReaderLoad: Bool { false }
    static var shortcut: UITestShortcut? { nil }
    static var windowSize: CGSize? { nil }
    static var offline: Bool { false }
    static var forceReduceMotion: Bool { false }
    static var forceIncreaseContrast: Bool { false }
    static var openPath: URL? { nil }

    #endif
}

/// A shortcut action a UI-test launch runs, standing in for Siri or the
/// Action button. Outside the DEBUG block so Release keeps the accessor
/// type; it carries no hook string itself.
enum UITestShortcut: Equatable {
    case continueListening
    case sleep(SleepTimerChoice)
}

/// The faults `-uitest-fault` injects. Outside the DEBUG block so Release
/// keeps the accessor type; it carries no hook string itself.
enum UITestFaultKind: String, CaseIterable {
    case route, interruption, interruptionResume = "interruption-resume", synthesis, skip, warmup,
         thermalSerious = "thermal-serious", thermalCritical = "thermal-critical", willSleep = "will-sleep"
}

/// The launch fixtures `-uitest-open-fixture` and `-uitest-pick-fixture`
/// name. Outside the DEBUG block so Release keeps the accessor types; it
/// carries no hook string itself.
enum UITestFixtureKind: String {
    case text, pdf, pdfBlank = "pdf-blank", pdfCorrupt = "pdf-corrupt"
}
