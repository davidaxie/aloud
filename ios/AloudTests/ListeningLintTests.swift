import XCTest

/// R7/R8 source lints: one app-wide voice and speed (no scopes, no per-book
/// pins applied), and one audio path (no second AVAudioEngine, no
/// VoicePreviewer). Reads the app's sources from the host checkout next to
/// this file; skips when the simulator can't read them.
final class ListeningLintTests: XCTestCase {

    /// ios/Aloud, from ios/AloudTests/ListeningLintTests.swift.
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Aloud", isDirectory: true)

    func testRemovedListeningSymbolsAreGone() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        for symbol in ["PreferenceScope", "pinTarget", "VoicePreviewer",
                       "selectGlobalRate", "selectGlobalVoice", "effectiveRate(",
                       "downloadSizeLabel"] {
            let hits = Self.files(in: sources, containing: symbol)
            XCTAssertTrue(hits.isEmpty, "'\(symbol)' should be gone from ios/Aloud, found in \(hits)")
        }
    }

    /// Every sound the app makes goes through PlaybackController's one muted
    /// graph, so the mute and "only one voice speaks" hold everywhere.
    func testOnlyPlaybackControllerOwnsAnAudioEngine() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        let count = sources.values.reduce(0) { $0 + $1.components(separatedBy: "AVAudioEngine()").count - 1 }
        XCTAssertEqual(count, 1, "Exactly one AVAudioEngine() in ios/Aloud")
        XCTAssertEqual(Self.files(in: sources, containing: "AVAudioEngine()"),
                       ["Playback/PlaybackController.swift"])
    }

    /// The legacy per-book fields are decoded, re-encoded and read once by
    /// the R7 migration; nothing else may apply them.
    func testLegacyPerBookFieldsStayInTheModelAndMigration() throws {
        let sources = try Self.swiftSources(in: Self.appRoot)
        let allowed: Set<String> = ["Models/LibraryDocument.swift", "App/AppModel.swift"]
        for field in ["preferredRate", "preferredVoiceID"] {
            let outside = Self.files(in: sources, containing: field).filter { !allowed.contains($0) }
            XCTAssertTrue(outside.isEmpty, "'\(field)' should only appear in \(allowed.sorted()), found in \(outside)")
        }
    }

    /// No scoped pickers: Settings and the reader edit the same values.
    func testSettingsHasNoScopeParameters() throws {
        let sources = try Self.swiftSources(in: Self.appRoot.appendingPathComponent("Settings", isDirectory: true))
        let hits = Self.files(in: sources, containing: "scope:")
        XCTAssertTrue(hits.isEmpty, "No 'scope:' in Settings/*.swift, found in \(hits)")
    }

    // MARK: - Source scan

    /// Relative path → contents of every .swift file under `root`.
    private static func swiftSources(in root: URL) throws -> [String: String] {
        // The path form yields paths relative to `root`.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw XCTSkip("Can't read \(root.path) from this test host")
        }
        var sources: [String: String] = [:]
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                throw XCTSkip("Can't read \(relative) from this test host")
            }
            sources[relative] = text
        }
        if sources.isEmpty { throw XCTSkip("No Swift sources readable under \(root.path)") }
        return sources
    }

    private static func files(in sources: [String: String], containing needle: String) -> [String] {
        sources.filter { $0.value.contains(needle) }.map(\.key).sorted()
    }
}
