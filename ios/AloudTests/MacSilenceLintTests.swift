import Foundation
import XCTest

/// The Mac's silence, held in source (testing §1.2, §4.3, §5):
/// - the audible switch, the one environment value that lets a plain Debug
///   launch of the Mac app make sound, is read by the mute rule alone, is
///   set only by the AloudMac scheme's Run action, and no test sets it;
/// - nothing the Mac compiles reaches a sound API outside the muted engine
///   (alert, system speech, a second player, a notification sound), the
///   engine's one tap is the DEBUG silence meter, and neither app starts a
///   process;
/// - Mac UI tests launch only through `XCUIApplication.aloud`, press keys
///   only through `press(_:in:)`, type only into a focused search field,
///   capture only their own window, and never drive the Mac itself (its
///   appearance, Siri, another app, a URL open).
///
/// Symbol checks read code with comments and literal text removed
/// (`SwiftLiterals.code`), so a comment naming a banned API never trips
/// them. The switch's name is spelled in two halves here, so this file
/// never names it. iOS suite only: the Mac bundle excludes every
/// *LintTests file, and its sandboxed host never reads the checkout.
final class MacSilenceLintTests: XCTestCase {

    /// The audible switch's name, in halves.
    private static let audible = "ALOUD_" + "AUDIBLE"

    /// Unit tests that may name the switch: the mute truth table (it must),
    /// the project lint that reads the Run action's value, and the Mac
    /// host's own check of the Debug default. Each passes it to the pure
    /// `muteAudio(in:environment:…)` or reads it from project.yml; none
    /// puts it in an environment.
    private static let unitTestsNamingTheSwitch: Set<String> = [
        "AloudTests/UITestHooksTests.swift",
        "AloudTests/MacProjectLintTests.swift",
        "AloudMacTests/MacPlatformTests.swift",
    ]

    private static let unitTestsRoot = SourceTree.iosRoot.appendingPathComponent("AloudTests", isDirectory: true)

    // MARK: - The audible switch

    func testOnlyTheMuteRuleReadsTheAudibleSwitch() throws {
        let sources = try SourceTree.appSources()
        let readers = Set(SwiftLiterals.literals(in: sources, excluding: [])
            .filter { $0.text.contains(Self.audible) }
            .map(\.path))
        XCTAssertEqual(readers, ["App/UITestHooks.swift"], "one reader: UITestHooks.muteAudio")
    }

    func testNoTestSetsTheAudibleSwitch() throws {
        for root in [SourceTree.uiTestsRoot, SourceTree.macUITestsRoot] where SourceTree.exists(root) {
            let sources = try SourceTree.sources(in: root)
            XCTAssertEqual(SourceTree.files(containing: Self.audible, in: sources), [],
                           "\(root.lastPathComponent) never names the audible switch")
        }
        var naming: [String: String] = [:]
        for (prefix, root) in [("AloudTests/", Self.unitTestsRoot), ("AloudMacTests/", SourceTree.macTestsRoot)]
        where SourceTree.exists(root) {
            for (path, text) in try SourceTree.sources(in: root) where text.contains(Self.audible) {
                naming[prefix + path] = text
            }
        }
        XCTAssertTrue(naming.keys.contains("AloudTests/UITestHooksTests.swift"),
                      "the mute truth table covers the switch")
        XCTAssertEqual(Set(naming.keys).subtracting(Self.unitTestsNamingTheSwitch), [],
                       "a new test names the audible switch")
        for (path, text) in naming {
            let code = SwiftLiterals.code(in: text)
            for setter in ["launchEnvironment", "setenv(", "putenv("] {
                XCTAssertFalse(code.contains(setter), "\(path) sets an environment beside the audible switch")
            }
        }
    }

    /// One line of project.yml, under schemes › AloudMac › run; and in the
    /// generated schemes, only AloudMac's launch action.
    func testOnlyTheRunActionSetsTheAudibleSwitch() throws {
        try SourceTree.requireCheckoutAccess()
        guard let spec = try? String(contentsOf: SourceTree.projectSpec, encoding: .utf8) else {
            throw XCTSkip("Can't read project.yml from this test host")
        }
        let lines = spec.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].contains(Self.audible) }
        XCTAssertEqual(hits.count, 1, "one line in project.yml")
        if let hit = hits.first {
            XCTAssertEqual(Array(Self.yamlAncestors(ofLine: hit, in: lines).prefix(4)),
                           ["environmentVariables", "run", "AloudMac", "schemes"])
        }

        let schemes = SourceTree.iosRoot.appendingPathComponent("Aloud.xcodeproj/xcshareddata/xcschemes")
        let files = (try? FileManager.default.contentsOfDirectory(at: schemes, includingPropertiesForKeys: nil)) ?? []
        for scheme in files where scheme.pathExtension == "xcscheme" {
            guard let text = try? String(contentsOf: scheme, encoding: .utf8), text.contains(Self.audible) else {
                continue
            }
            XCTAssertEqual(scheme.lastPathComponent, "AloudMac.xcscheme", "only the AloudMac scheme")
            let pieces = text.components(separatedBy: Self.audible)
            for before in pieces.dropLast() {
                let opened = before.range(of: "<LaunchAction", options: .backwards)
                let closed = before.range(of: "</LaunchAction>", options: .backwards)
                XCTAssertTrue(opened != nil && (closed == nil || closed!.lowerBound < opened!.lowerBound),
                              "\(scheme.lastPathComponent): only inside the Run (launch) action")
            }
        }
    }

    // MARK: - Sound and processes

    /// What would sound past the muted engine, or start another program.
    private static let soundAPIs = [
        "NSSound": #"\bNSSound\b"#,
        "NSBeep": #"\bNSBeep\b"#,
        ".beep()": #"\.beep\(\)"#,
        "NSSpeechSynthesizer": #"\bNSSpeechSynthesizer\b"#,
        "AVSpeechSynthesizer.speak": #"\.speak\("#,
        "AVAudioPlayer": #"\bAVAudioPlayer\b"#,
        "AVPlayer": #"\bAVPlayer\b"#,
        "AVQueuePlayer": #"\bAVQueuePlayer\b"#,
        "AudioServicesPlay": #"\bAudioServicesPlay\w*"#,
        "UNNotificationSound": #"\bUNNotificationSound\b"#,
    ]

    private static let processAPIs = [
        "Process(": #"\bProcess\s*\("#,
        "NSTask": #"\bNSTask\b"#,
    ]

    func testMacCompiledCodeMakesNoSoundOutsideTheEngine() throws {
        let compiled = try SourceTree.macCompiledSources(excluding: MacExclusions.projectExcludes)
        guard compiled.keys.contains(where: { $0.hasPrefix(SourceTree.macPrefix) }) else {
            throw XCTSkip("AloudMac not created yet")
        }
        let code = compiled.mapValues(SwiftLiterals.code(in:))
        for (api, pattern) in Self.soundAPIs.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(try Self.files(matching: pattern, in: code), [],
                           "\(api) would sound past the muted engine on the Mac")
        }
    }

    /// The measured-silence meter reads the muted engine through its taps;
    /// it is test plumbing, so the taps live in the controller's DEBUG
    /// block and nowhere else (testing §4.3).
    func testOnlyTheDebugMeterTapsTheEngine() throws {
        let code = try SourceTree.appSources().mapValues(SwiftLiterals.code(in:))
        let controller = "Playback/PlaybackController.swift"
        XCTAssertEqual(SourceTree.files(containing: "installTap(", in: code), [controller], "one file taps the engine")
        let lines = (code[controller] ?? "").components(separatedBy: "\n")
        let debugOnly = Self.debugOnly(lines)
        var taps = 0
        for index in lines.indices where lines[index].contains("installTap(") {
            taps += 1
            XCTAssertTrue(debugOnly[index], "\(controller):\(index + 1) taps the engine outside #if DEBUG")
        }
        XCTAssertGreaterThan(taps, 0, "the scan finds the meter's taps")
    }

    func testNeitherAppStartsAProcess() throws {
        let code = try SourceTree.appSources().mapValues(SwiftLiterals.code(in:))
        for (api, pattern) in Self.processAPIs.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(try Self.files(matching: pattern, in: code), [], "\(api): Aloud runs no other program")
        }
    }

    // MARK: - Mac UI tests

    func testMacUITestsLaunchOnlyThroughTheHelper() throws {
        let code = try Self.macUITestCode()
        let helpers = "XCUIHelpers.swift"
        // The muted launch, the one key path and the guarded activate.
        for needle in ["XCUIApplication(", "launchArguments", "launchEnvironment", "typeKey(", ".activate()"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: code).filter { $0 != helpers }, [],
                           "\(needle) belongs to \(helpers)")
        }
        // LaunchServices picks the app (maybe a stale or the shipping one),
        // and an open launches it without the mute arguments.
        for needle in ["XCUIApplication(bundleIdentifier", "XCUIApplication(url", ".open("] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: code), [], "\(needle) launches unmuted")
        }
        // Letters typed at a window are keys nothing takes: text goes only
        // into the search field, through the guard that it has the keys.
        for (path, text) in code.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(text.components(separatedBy: ".typeText(").count,
                           text.components(separatedBy: "searchField.typeText(").count,
                           "\(path) types somewhere other than the search field")
        }
    }

    func testMacUITestsCaptureOnlyTheirOwnWindowAndLeaveTheMacAlone() throws {
        let code = try Self.macUITestCode()
        XCTAssertEqual(try Self.files(matching: #"\bXCUIScreen\b"#, in: code), [],
                       "a screenshot is the app's window element, never the screen")
        // Appearance, Siri, hardware buttons: the user's Mac, not the app's.
        XCTAssertEqual(try Self.files(matching: #"\bXCUIDevice\b"#, in: code), [], "XCUIDevice changes the Mac")
        let sources = try SourceTree.sources(in: SourceTree.macUITestsRoot)
        let capturing = SwiftLiterals.literals(in: sources, excluding: [])
            .filter { $0.text.contains("screencapture") }.map(\.path)
        XCTAssertEqual(capturing + SourceTree.files(containing: "screencapture", in: code), [],
                       "no whole-screen or audible capture")
        for (api, pattern) in [("NSWorkspace open", #"NSWorkspace\.shared\.(open|launch)"#),
                               ("siriService", #"\bsiriService\b"#), ("osascript", #"osascript"#),
                               ("NSAppleScript", #"\bNSAppleScript\b"#)] {
            XCTAssertEqual(try Self.files(matching: pattern, in: code), [], "\(api) drives another app")
        }
    }

    // MARK: - Helpers

    /// ios/AloudMacUITests with comments and literal text removed.
    private static func macUITestCode() throws -> [String: String] {
        guard SourceTree.exists(SourceTree.macUITestsRoot) else { throw XCTSkip("AloudMacUITests not created yet") }
        return try SourceTree.sources(in: SourceTree.macUITestsRoot).mapValues(SwiftLiterals.code(in:))
    }

    private static func files(matching pattern: String, in sources: [String: String]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return sources.filter { _, text in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.map(\.key).sorted()
    }

    /// For each line, whether it compiles in DEBUG only: inside a `DEBUG`
    /// (or `DEBUG && …`) branch of an `#if`, not its `#else`, at any depth.
    static func debugOnly(_ lines: [String]) -> [Bool] {
        func isDebug(_ directive: String, after keyword: String) -> Bool {
            let condition = directive.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            return condition == "DEBUG" || condition.hasPrefix("DEBUG &&")
        }
        var branches: [Bool] = []   // per open #if: whether this branch is DEBUG-only
        return lines.map { line in
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                branches.append(isDebug(directive, after: "#if "))
            } else if directive.hasPrefix("#elseif ") {
                if !branches.isEmpty { branches[branches.count - 1] = isDebug(directive, after: "#elseif ") }
            } else if directive.hasPrefix("#else") {
                if !branches.isEmpty { branches[branches.count - 1] = false }
            } else if directive.hasPrefix("#endif") {
                _ = branches.popLast()
            }
            return branches.contains(true)
        }
    }

    /// The keys enclosing `line` in a YAML file, innermost first, by
    /// indentation (block mappings only, which project.yml uses here).
    static func yamlAncestors(ofLine line: Int, in lines: [String]) -> [String] {
        func indent(_ text: String) -> Int { text.prefix { $0 == " " }.count }
        var keys: [String] = []
        var depth = indent(lines[line])
        for index in stride(from: line - 1, through: 0, by: -1) {
            let text = lines[index]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent(text) < depth else { continue }
            depth = indent(text)
            keys.append(String(trimmed.prefix { $0 != ":" }))
            if depth == 0 { break }
        }
        return keys
    }
}
