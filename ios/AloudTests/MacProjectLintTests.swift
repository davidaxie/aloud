import Foundation
import XCTest

/// The Mac target's guard rails, read from ios/project.yml and the two
/// entitlements files (contracts §2, testing §4.3):
/// - the Debug bundle ID ends ".dev" and differs from Release, so no test can
///   reach the shipping app or its container (testing D1);
/// - the AloudMac scheme's test action lists no UI-test target (D5), and has
///   an environment of its own, so it never takes the Run action's
///   `ALOUD_AUDIBLE` (D3); both Mac test actions run Debug;
/// - every Mac target signs ad hoc: an unsigned app runs unsandboxed and
///   writes into the real ~/Documents;
/// - both entitlements files sandbox the app, and only the Debug one carries
///   the temporary exception, for the pre-placed voice model;
/// - the Mac's excludes equal `MacExclusions`, and the Mac test bundle keeps
///   the shared suite;
/// - Finder's Open With ranks Aloud Alternate for both document types.
///
/// Pure reads of the checkout, through a small reader for XcodeGen's YAML
/// (`testTheReaderReaches` pins it). Skips when the host can't see the
/// checkout, where SourceTreeReachabilityTests fails instead. iOS suite only:
/// the Mac bundle excludes every *LintTests file.
final class MacProjectLintTests: XCTestCase {

    private static let macTargets = ["AloudMac", "AloudMacTests", "AloudMacUITests"]

    /// Shared tests the Mac host must run: the mute guarantee (D2) and what
    /// it stands on.
    private static let macMustRun = ["PlaybackMuteTests.swift", "UITestHooksTests.swift",
                                     "OutputRoutePolicyTests.swift", "PlaybackTestRig.swift"]

    // MARK: - Identity and schemes

    func testDebugBundleIDIsTheDevIDAndNeverRelease() throws {
        let spec = try Self.spec()
        let debug = spec.value(["targets", "AloudMac", "settings", "configs", "Debug", "PRODUCT_BUNDLE_IDENTIFIER"])
        let release = spec.value(["targets", "AloudMac", "settings", "configs", "Release", "PRODUCT_BUNDLE_IDENTIFIER"])
        XCTAssertEqual(debug, "com.davidxie.Aloud.mac.dev")
        XCTAssertEqual(release, "com.davidxie.Aloud.mac")
        XCTAssertTrue(debug?.hasSuffix(".dev") == true, "\(debug ?? "nil")")
        XCTAssertNotEqual(debug?.lowercased(), release?.lowercased(), "the identities differ, case aside")
        XCTAssertNil(spec.value(["targets", "AloudMac", "settings", "base", "PRODUCT_BUNDLE_IDENTIFIER"]),
                     "one identity per configuration, none shared")
    }

    func testMacTestActionHasNoUITarget() throws {
        let spec = try Self.spec()
        let uiTargets = spec.keys(["targets"]).filter { spec.value(["targets", $0, "type"]) == "bundle.ui-testing" }
        XCTAssertTrue(uiTargets.contains("AloudMacUITests"), "the reader sees the UI-test targets: \(uiTargets)")
        let tested = spec.list(["schemes", "AloudMac", "test", "targets"])
        XCTAssertEqual(tested, ["AloudMacTests"])
        XCTAssertEqual(Set(tested ?? []).intersection(uiTargets), [], "the default Mac test action drives no UI")
        XCTAssertEqual(spec.list(["schemes", "AloudMacUI", "test", "targets"]), ["AloudMacUITests"])
        for scheme in ["AloudMac", "AloudMacUI"] {
            XCTAssertEqual(spec.value(["schemes", scheme, "test", "config"]), "Debug",
                           "\(scheme): every Mac test runs the dev identity (D1)")
        }
    }

    /// Only Xcode's Run action makes a Debug Mac launch audible, and a test
    /// action brings its own environment (XcodeGen hands a test action with
    /// none the Run action's).
    func testOnlyTheRunActionIsAudible() throws {
        let spec = try Self.spec()
        XCTAssertEqual(spec.value(["schemes", "AloudMac", "run", "environmentVariables", "ALOUD_AUDIBLE"]), "1")
        XCTAssertEqual(spec.lines.filter { $0.text.contains("ALOUD_AUDIBLE") }.count, 1, "nowhere else")
        for scheme in ["AloudMac", "AloudMacUI"] {
            let environment = spec.keys(["schemes", scheme, "test", "environmentVariables"])
            XCTAssertEqual(environment, ["ALOUD_MUTE"], scheme)
        }
    }

    func testMacTargetsSignAdHoc() throws {
        let spec = try Self.spec()
        for target in Self.macTargets {
            XCTAssertEqual(spec.value(["targets", target, "settings", "base", "CODE_SIGN_IDENTITY"]), "-", target)
        }
        XCTAssertFalse(spec.lines.contains { $0.text.contains("CODE_SIGNING_ALLOWED") },
                       "an unsigned Mac build runs unsandboxed")
    }

    // MARK: - Entitlements

    func testBothEntitlementsSandboxTheApp() throws {
        let spec = try Self.spec()
        let files = [
            spec.value(["targets", "AloudMac", "settings", "configs", "Debug", "CODE_SIGN_ENTITLEMENTS"]),
            spec.value(["targets", "AloudMac", "settings", "configs", "Release", "CODE_SIGN_ENTITLEMENTS"]),
        ]
        XCTAssertEqual(files, ["AloudMac/AloudMac-Debug.entitlements", "AloudMac/AloudMac.entitlements"])
        for file in files.compactMap({ $0 }) {
            let entitlements = try Self.entitlements(file)
            XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true, file)
            XCTAssertEqual(entitlements["com.apple.security.files.user-selected.read-only"] as? Bool, true, file)
            XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true, file)
        }
    }

    func testTemporaryExceptionOnlyInDebug() throws {
        let release = try Self.entitlements("AloudMac/AloudMac.entitlements")
        let debug = try Self.entitlements("AloudMac/AloudMac-Debug.entitlements")
        let exception = "com.apple.security.temporary-exception.files.absolute-path.read-only"
        XCTAssertEqual(release.keys.filter { $0.contains("temporary-exception") }, [])
        XCTAssertEqual(debug[exception] as? [String], ["/Users/Shared/AloudKokoroModel/"])
        XCTAssertEqual(Set(debug.keys).subtracting(release.keys), [exception], "the exception is Debug's only extra")
        XCTAssertEqual(Set(release.keys).subtracting(debug.keys), [])
    }

    // MARK: - Sources and Info.plist

    func testMacExcludesEqualMacExclusions() throws {
        let spec = try Self.spec()
        XCTAssertEqual(spec.sourceExcludes(target: "AloudMac", path: "Aloud"), MacExclusions.projectExcludes)
        XCTAssertEqual(spec.sourceExcludes(target: "AloudMac", path: "AloudMac"), ["Info.plist", "*.entitlements"])
    }

    /// Each Mac test exclusion names a real file, the bundle keeps the bulk
    /// of the shared suite, and the mute tests are in it.
    func testMacTestBundleKeepsTheSharedSuite() throws {
        let spec = try Self.spec()
        let excludes = try XCTUnwrap(spec.sourceExcludes(target: "AloudMacTests", path: "AloudTests"))
        let shared = try SourceTree.sources(in: SourceTree.iosRoot.appendingPathComponent("AloudTests")).keys
        func excluded(_ file: String) -> Bool { excludes.contains { fnmatch($0, file, 0) == 0 } }
        for pattern in excludes {
            XCTAssertTrue(shared.contains { fnmatch(pattern, $0, 0) == 0 }, "\(pattern) matches no shared test file")
        }
        let kept = shared.filter { !excluded($0) }
        XCTAssertGreaterThanOrEqual(kept.count, 85, "the Mac host runs the shared suite")
        XCTAssertEqual(Self.macMustRun.filter { !kept.contains($0) }, [], "present, and not excluded")
        XCTAssertTrue(excluded("MacProjectLintTests.swift"), "lints read the checkout: iOS suite only")
    }

    func testDocumentTypesRankAlternate() throws {
        let spec = try Self.spec()
        let types = try XCTUnwrap(spec.block(["targets", "AloudMac", "info", "properties", "CFBundleDocumentTypes"]))
        let entries = types.compactMap { Spec.entry(of: $0.text) }
        XCTAssertEqual(types.filter { $0.text.hasPrefix("- ") }.count, 2, "PDF and plain text")
        XCTAssertEqual(entries.filter { $0.key == "LSHandlerRank" }.map { $0.value }, ["Alternate", "Alternate"],
                       "Preview stays the default")
        XCTAssertEqual(entries.filter { $0.key == "LSItemContentTypes" }.map { $0.value },
                       ["[com.adobe.pdf]", "[public.plain-text]"])
    }

    // MARK: - The reader's reach

    func testTheReaderReaches() {
        let spec = Spec("""
        name: X   # a comment
        targets:
          App:
            type: application
            sources:
              - path: App
                excludes:                       # trailing
                  # a comment line inside the list
                  - "A.swift"
                  - "Res/**"                    # why
              - path: App/Res
                excludes: ["Info.plist", "*.x"]
            settings:
              configs:
                Debug:
                  NAME: "App Dev"
                  HOST: "$(DIR)/App Dev.app"
          UI:
            type: bundle.ui-testing
        schemes:
          App:
            test:
              targets: [AppTests]
              list:
                - one
                - two
        """)
        XCTAssertEqual(spec.value(["name"]), "X")
        XCTAssertEqual(spec.keys(["targets"]), ["App", "UI"])
        XCTAssertEqual(spec.value(["targets", "UI", "type"]), "bundle.ui-testing")
        XCTAssertEqual(spec.value(["targets", "App", "settings", "configs", "Debug", "NAME"]), "App Dev")
        XCTAssertEqual(spec.value(["targets", "App", "settings", "configs", "Debug", "HOST"]), "$(DIR)/App Dev.app")
        XCTAssertEqual(spec.sourceExcludes(target: "App", path: "App"), ["A.swift", "Res/**"])
        XCTAssertEqual(spec.sourceExcludes(target: "App", path: "App/Res"), ["Info.plist", "*.x"])
        XCTAssertNil(spec.sourceExcludes(target: "App", path: "Missing"))
        XCTAssertEqual(spec.list(["schemes", "App", "test", "targets"]), ["AppTests"])
        XCTAssertEqual(spec.list(["schemes", "App", "test", "list"]), ["one", "two"])
        XCTAssertNil(spec.value(["targets", "App", "missing"]))
        XCTAssertNil(spec.value(["schemes", "App", "type"]), "keys are found at their own level only")
    }

    // MARK: - Helpers

    private static func spec() throws -> Spec {
        guard let text = try? String(contentsOf: SourceTree.projectSpec, encoding: .utf8) else {
            throw XCTSkip("Can't read \(SourceTree.projectSpec.path) from this test host")
        }
        return Spec(text)
    }

    /// The entitlements file at `path` (relative to ios/), as a dictionary.
    private static func entitlements(_ path: String) throws -> [String: Any] {
        let url = SourceTree.iosRoot.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Can't read \(url.path) from this test host")
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], path)
    }
}

/// XcodeGen's YAML as these lints need it: nested mappings by indentation,
/// block lists ("- item"), inline lists ("[a, b]"), double-quoted scalars and
/// comments. Flow mappings ("{ a: b }") are read as plain values.
private struct Spec {
    struct Line {
        let indent: Int
        /// Trimmed, with any comment removed.
        let text: String
    }

    /// The non-blank, non-comment lines.
    let lines: [Line]

    init(_ text: String) {
        lines = text.components(separatedBy: .newlines).compactMap { raw in
            let code = Self.withoutComment(raw)
            let text = code.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return Line(indent: code.prefix { $0 == " " }.count, text: text)
        }
    }

    /// The lines nested under the mapping keys `path`, each a direct child of
    /// the one before; nil when one is missing.
    func block(_ path: [String]) -> ArraySlice<Line>? {
        var scope = lines[...]
        for key in path {
            guard let level = scope.map(\.indent).min(),
                  let index = scope.firstIndex(where: { $0.indent == level && Self.key(of: $0.text) == key })
            else { return nil }
            let end = scope[(index + 1)...].firstIndex { $0.indent <= level } ?? scope.endIndex
            scope = scope[(index + 1)..<end]
        }
        return scope
    }

    /// The direct child keys of the mapping at `path`, in order.
    func keys(_ path: [String]) -> [String] {
        guard let scope = block(path), let level = scope.map(\.indent).min() else { return [] }
        return scope.filter { $0.indent == level }.compactMap { Self.key(of: $0.text) }
    }

    /// The scalar at `path`, unquoted.
    func value(_ path: [String]) -> String? {
        guard let key = path.last, let line = line(at: path) else { return nil }
        return Self.unquoted(String(line.text.dropFirst(key.count + 1)))
    }

    /// The list at `path`: inline on the key's line, or the block beneath it.
    func list(_ path: [String]) -> [String]? {
        guard let key = path.last, let line = line(at: path), let parent = block(Array(path.dropLast())) else {
            return nil
        }
        return Self.list(after: line, key: key, in: parent)
    }

    /// The `excludes` of the `- path: <path>` entry in a target's `sources`.
    func sourceExcludes(target: String, path: String) -> [String]? {
        guard let sources = block(["targets", target, "sources"]), let level = sources.map(\.indent).min(),
              let start = sources.firstIndex(where: { $0.indent == level && $0.text == "- path: " + path })
        else { return nil }
        let end = sources[(start + 1)...].firstIndex { $0.indent <= level } ?? sources.endIndex
        let item = sources[(start + 1)..<end]
        guard let keyLevel = item.map(\.indent).min(),
              let excludes = item.first(where: { $0.indent == keyLevel && Self.key(of: $0.text) == "excludes" })
        else { return nil }
        return Self.list(after: excludes, key: "excludes", in: item)
    }

    /// A mapping line's key and raw value, a list item's "- " dropped.
    static func entry(of text: String) -> (key: String, value: String)? {
        let body = text.hasPrefix("- ") ? String(text.dropFirst(2)) : text
        guard let key = key(of: body) else { return nil }
        return (key, unquoted(String(body.dropFirst(key.count + 1))))
    }

    private func line(at path: [String]) -> Line? {
        guard let key = path.last, let parent = block(Array(path.dropLast())),
              let level = parent.map(\.indent).min() else { return nil }
        return parent.first { $0.indent == level && Self.key(of: $0.text) == key }
    }

    private static func list(after line: Line, key: String, in scope: ArraySlice<Line>) -> [String] {
        let inline = line.text.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("[") {
            return inline.dropFirst().dropLast().split(separator: ",").map { unquoted(String($0)) }
        }
        guard let index = scope.firstIndex(where: { $0.indent == line.indent && $0.text == line.text }) else {
            return []
        }
        let end = scope[(index + 1)...].firstIndex { $0.indent <= line.indent } ?? scope.endIndex
        return scope[(index + 1)..<end].filter { $0.text.hasPrefix("- ") }.map { unquoted(String($0.text.dropFirst(2))) }
    }

    /// "KEY: value" → "KEY". A list item ("- …") has no key.
    private static func key(of text: String) -> String? {
        guard !text.hasPrefix("- "), let colon = text.firstIndex(of: ":") else { return nil }
        let after = text[text.index(after: colon)...]
        guard after.isEmpty || after.first == " " else { return nil }
        return unquoted(String(text[..<colon]))
    }

    private static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// `raw` before a `#` that opens a comment: at the start or after a
    /// space, outside double quotes.
    private static func withoutComment(_ raw: String) -> String {
        var quoted = false
        var previous: Character = " "
        for (offset, character) in raw.enumerated() {
            if character == "\"" {
                quoted.toggle()
            } else if character == "#", !quoted, previous.isWhitespace {
                return String(raw.prefix(offset))
            }
            previous = character
        }
        return raw
    }
}
