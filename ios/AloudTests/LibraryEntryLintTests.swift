import XCTest

/// R4 and R10 source lints: the retired import surfaces stay gone, add and
/// open paths never wait on a timer, failures never show an error's own
/// text, and nothing speaks outside the muted graph. Reads the source tree
/// next to this file; skips when the host can't read it.
final class LibraryEntryLintTests: XCTestCase {

    private static let thisFile = URL(fileURLWithPath: #filePath)
    private static let appRoot = thisFile.appendingPathComponent("../../Aloud").standardizedFileURL
    private static let uiRoot = thisFile.appendingPathComponent("../../AloudUITests").standardizedFileURL

    /// A Swift file, its path relative to the scanned root, and its text.
    private struct Source {
        let path: String
        let text: String
    }

    /// Every Swift file under `root`, or under the given folders or files
    /// inside it. Throws XCTSkip when the root can't be read.
    private func sources(in root: URL, only subpaths: [String]? = nil) throws -> [Source] {
        let fileManager = FileManager.default
        guard (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil else {
            throw XCTSkip("Can't read \(root.path) from this test host")
        }
        let starts = (subpaths ?? [""]).map { root.appendingPathComponent($0) }
        let prefix = root.path + "/"
        var found: [Source] = []
        for start in starts {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: start.path, isDirectory: &isDirectory) else { continue }
            let files: [URL]
            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(at: start, includingPropertiesForKeys: nil)
                files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            } else {
                files = [start]
            }
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let full = file.standardizedFileURL.path
                let path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
                found.append(Source(path: path, text: text))
            }
        }
        return found
    }

    /// The files containing `needle`, with how often, for the failure message.
    private func occurrences(of needle: String, in sources: [Source]) -> [String] {
        sources.compactMap { source in
            let count = source.text.components(separatedBy: needle).count - 1
            return count > 0 ? "\(source.path) ×\(count)" : nil
        }
    }

    // MARK: - Retired import surfaces

    func testImportSheetIsDeleted() throws {
        _ = try sources(in: Self.appRoot)   // skips when the tree is unreadable
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Self.appRoot.appendingPathComponent("Import/ImportSheet.swift").path))
    }

    // The retired copy ('Soon', 'Add a document', 'Couldn't import', …) is
    // linted in CopyLintTests, which reads string literals only, so a
    // comment can no longer trip it.

    func testAccentCapsuleStyleIsGone() throws {
        XCTAssertEqual(occurrences(of: "AccentCapsuleButtonStyle", in: try sources(in: Self.appRoot)), [])
    }

    // MARK: - Failure copy

    func testNoErrorTextInLibraryEntryPaths() throws {
        let entry = try sources(in: Self.appRoot, only: ["Import", "Library", "Bookshelf"])
        XCTAssertEqual(occurrences(of: "localizedDescription", in: entry), [],
                       "Failures use ImportFailure's fixed copy, never an error's own text")
    }

    // MARK: - Fixed waits

    /// The sanctioned sleeps in these folders, neither of which holds up an
    /// add or an open:
    /// - DocumentStore's 2 s throttle of the index write, which is persistence.
    /// - LibraryView's VoiceOver handoff after a Delete or a Mark as finished
    ///   (P022): SwiftUI's confirmation dialog and context menu say nothing
    ///   when they have finished leaving, and VoiceOver's own return of focus
    ///   as they go would undo an earlier move. The shelf has already changed.
    /// App/UITestLaunchActions.swift (DEBUG only) is outside the scan, and so
    /// is RootView, which owns the import overlay's display delay (P015).
    private static let sanctionedSleeps: Set<String> = ["Library/DocumentStore.swift#scheduleDebouncedSave",
                                                        "Library/LibraryView.swift#moveVoiceOverFocus",
                                                        // The VoiceOver hand-off's second step: the lazy grid
                                                        // gives no signal when the scrolled-to card exists.
                                                        "Library/LibraryView.swift#landVoiceOverFocus"]

    func testNoFixedWaitsInAddOrOpenPaths() throws {
        let scanned = try sources(in: Self.appRoot,
                                  only: ["Library", "Bookshelf", "Import", "App/LibraryRouter.swift"])
        var offenders: [String] = []
        for source in scanned {
            let lines = source.text.components(separatedBy: .newlines)
            for (number, line) in lines.enumerated() where line.contains("Task.sleep") {
                let function = Self.enclosingFunction(of: number, in: lines)
                if !Self.sanctionedSleeps.contains("\(source.path)#\(function)") {
                    offenders.append("\(source.path):\(number + 1) in \(function)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Add and open paths never wait on a timer")
    }

    /// The name of the nearest `func` declared at or above `line`.
    private static func enclosingFunction(of line: Int, in lines: [String]) -> String {
        for candidate in lines[...line].reversed() {
            guard let range = candidate.range(of: "func ") else { continue }
            let rest = candidate[range.upperBound...]
            return String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        }
        return "<top level>"
    }

    // MARK: - Silence

    /// Both apps' sources: ios/Aloud, plus ios/AloudMac (as "AloudMac/…")
    /// once it exists.
    private func appSources() throws -> [Source] {
        try SourceTree.appSources().map { Source(path: $0.key, text: $0.value) }
    }

    func testNothingCallsSpeak() throws {
        XCTAssertEqual(occurrences(of: ".speak(", in: try appSources()), [],
                       "Speech goes through write() into the muted mixer, never speak()")
    }

    /// The Mac's system synthesizer speaks straight to the device, past the
    /// muted engine; the System voice is AVSpeechSynthesizer.write().
    func testNoMacSpeechSynthesizer() throws {
        XCTAssertEqual(occurrences(of: "NSSpeechSynthesizer", in: try appSources()), [],
                       "NSSpeechSynthesizer speaks past the muted mixer")
    }

    func testBareAppLaunchOnlyInHelpers() throws {
        let hits = occurrences(of: "XCUIApplication()", in: try sources(in: Self.uiRoot))
        XCTAssertEqual(hits.map { $0.components(separatedBy: " ×").first ?? $0 }, ["XCUIHelpers.swift"],
                       "UI tests launch only through XCUIApplication.aloud, which always mutes")
    }
}
