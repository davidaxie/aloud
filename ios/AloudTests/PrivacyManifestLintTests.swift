import Foundation
import XCTest

/// Each app's PrivacyInfo.xcprivacy declares exactly the required-reason API
/// categories its code calls, each with the one reason that fits, and no
/// tracking or collected data (App Store Connect refuses an upload that
/// calls one undeclared, ITMS-91053):
/// - UserDefaults, CA92.1: settings and listening state the app reads back
///   itself, in UserDefaults.standard only;
/// - FileTimestamp, C617.1: `stat` and `attributesOfItem` on the voice model
///   files in the app's own container (ModelManager), and the `stat`/`fstat`
///   the statically linked sherpa-onnx and onnxruntime make on the bundled
///   and downloaded model data;
/// - DiskSpace, E174.1: the model download checks for room first and says
///   so when there isn't (ModelManager.defaultFreeSpace);
/// - SystemBootTime, 35F9.1, the Mac only: the reader times a click against
///   the end of a scroll's coast with `systemUptime`.
///
/// Scans each app's compiled Swift, comments left out, so a new call to one
/// of these APIs fails here until its manifest declares it, and a dropped
/// one fails until the declaration goes. iOS suite only (it reads the
/// checkout).
final class PrivacyManifestLintTests: XCTestCase {

    /// The categories this lint knows: the APIs that put code in each, and
    /// the reasons Aloud declares for it (none known: the lint fails).
    private struct Category {
        let name: String
        let calls: [String]
        let reasons: [String]
    }

    private static let categories = [
        Category(name: "NSPrivacyAccessedAPICategoryUserDefaults",
                 calls: [#"\bUserDefaults\b"#, #"@AppStorage\b"#],
                 reasons: ["CA92.1"]),
        Category(name: "NSPrivacyAccessedAPICategoryFileTimestamp",
                 calls: [#"\b(f|l)?stat(at)?\("#, #"\bgetattrlist(bulk|at)?\("#, #"\bfgetattrlist\("#,
                         #"\battributesOfItem\b"#, #"\.(creationDate|modificationDate)\b"#,
                         #"\bfileModificationDate\b"#, #"\b(contentModification|creation)DateKey\b"#],
                 reasons: ["C617.1"]),
        Category(name: "NSPrivacyAccessedAPICategorySystemBootTime",
                 calls: [#"\bsystemUptime\b"#, #"\bmach_absolute_time\b"#],
                 reasons: ["35F9.1"]),
        Category(name: "NSPrivacyAccessedAPICategoryDiskSpace",
                 calls: [#"\bvolume(Available|Total)Capacity"#, #"\.system(Free)?Size\b"#,
                         #"\bf?statv?fs\("#],
                 reasons: ["E174.1"]),
        Category(name: "NSPrivacyAccessedAPICategoryActiveKeyboards",
                 calls: [#"\bactiveInputModes\b"#],
                 reasons: []),
    ]

    /// What the statically linked sherpa-onnx and onnxruntime archives call,
    /// whatever the Swift does.
    private static let linked: Set<String> = ["NSPrivacyAccessedAPICategoryFileTimestamp"]

    func testTheiPhoneManifestMatchesItsCode() throws {
        let sources = try SourceTree.sources(in: SourceTree.appRoot)
        try check(manifest: SourceTree.appRoot.appendingPathComponent("Resources/PrivacyInfo.xcprivacy"),
                  against: sources, app: "iPhone")
    }

    func testTheMacManifestMatchesItsCode() throws {
        let sources = try SourceTree.macCompiledSources(excluding: MacExclusions.projectExcludes)
        try check(manifest: SourceTree.macRoot.appendingPathComponent("Resources/PrivacyInfo.xcprivacy"),
                  against: sources, app: "Mac")
    }

    /// The scan sees a call, and never a comment about one.
    func testTheScanReadsCodeNotComments() {
        let code = """
        /// Unlike `ProcessInfo.systemUptime`, it keeps counting.
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC) // not systemUptime
        var info = stat()
        """
        XCTAssertEqual(Self.used(in: ["A.swift": code]), ["NSPrivacyAccessedAPICategoryFileTimestamp"])
        XCTAssertEqual(Self.used(in: ["B.swift": "let d = UserDefaults.standard"]),
                       ["NSPrivacyAccessedAPICategoryUserDefaults"])
        XCTAssertEqual(Self.used(in: ["C.swift": "let t = ProcessInfo.processInfo.systemUptime"]),
                       ["NSPrivacyAccessedAPICategorySystemBootTime"])
        XCTAssertEqual(Self.used(in: ["D.swift": "[.volumeAvailableCapacityForImportantUsageKey]"]),
                       ["NSPrivacyAccessedAPICategoryDiskSpace"])
        XCTAssertEqual(Self.used(in: ["E.swift": "let status = statusText(isStat: true)"]), [])
    }

    // MARK: - Helpers

    private func check(manifest url: URL, against sources: [String: String], app: String) throws {
        let data = try XCTUnwrap(try? Data(contentsOf: url), "\(app): no manifest at \(url.path)")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
                                  as? [String: Any], app)
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, "\(app): no tracking")
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, "\(app): no tracking domains")
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "\(app): nothing collected")

        let entries = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]], app)
        let declared = entries.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertEqual(declared.count, Set(declared).count, "\(app): each category once")
        let expected = Self.used(in: sources).union(Self.linked)
        XCTAssertEqual(Set(declared), expected, "\(app): declared vs. called")
        for entry in entries {
            let name = entry["NSPrivacyAccessedAPIType"] as? String ?? "?"
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
            let known = Self.categories.first { $0.name == name }?.reasons ?? []
            XCTAssertFalse(known.isEmpty, "\(app): \(name) needs a reason this lint knows")
            XCTAssertEqual(reasons, known, "\(app): \(name)")
        }
    }

    /// The categories whose APIs the Swift in `sources` calls.
    private static func used(in sources: [String: String]) -> Set<String> {
        let code = sources.values.map(withoutComments).joined(separator: "\n")
        return Set(categories.filter { category in
            category.calls.contains { code.range(of: $0, options: .regularExpression) != nil }
        }.map(\.name))
    }

    /// `text` without its // and /* */ comments (a "//" inside a string goes
    /// too, which only ever drops text a call can't be in).
    private static func withoutComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
    }
}
