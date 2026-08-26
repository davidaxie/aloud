import SwiftUI

/// The single home for every `-uitest-*` launch-argument hook.
///
/// The gate is structural, not per-call-site discipline: the whole parsing
/// surface lives inside one `#if DEBUG` block, and Release builds get no-op
/// accessors — no `-uitest` string even exists in a Release binary, so no
/// launch context can flip test behavior in the shipped app.
///
/// Adding a hook means adding an accessor here (inside the DEBUG block) and a
/// matching no-op in the Release block; call sites never touch ProcessInfo.
enum UITestHooks {

    #if DEBUG

    /// Seed the library with the first bookshelf classic on launch.
    static var seedFirstClassic: Bool { arguments.contains("-uitest-seed-first-classic") }

    /// Jump straight into the first library document once it exists.
    static var openFirstDoc: Bool { arguments.contains("-uitest-open-first-doc") }

    /// Start from a clean (removed) voice preference — fresh-install default.
    static var resetVoicePref: Bool { arguments.contains("-uitest-reset-voice-pref") }

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
    /// launch arguments land in UserDefaults under the dashless key.
    static var kokoroModelPath: String? {
        guard let override = UserDefaults.standard.string(forKey: "uitest-kokoro-model-path"),
              !override.isEmpty else { return nil }
        return override
    }

    // MARK: - Parsing (argument-injectable for unit tests)

    static func forcedColorScheme(in arguments: [String]) -> ColorScheme? {
        if arguments.contains("-uitest-force-dark") { return .dark }
        if arguments.contains("-uitest-force-light") { return .light }
        return nil
    }

    static func seekText(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "-uitest-seek-text"),
              arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    #else

    // Release: the entire hook surface is compiled away.
    static var seedFirstClassic: Bool { false }
    static var openFirstDoc: Bool { false }
    static var resetVoicePref: Bool { false }
    static var forcedColorScheme: ColorScheme? { nil }
    static var seekText: String? { nil }
    static var kokoroModelPath: String? { nil }

    #endif
}
