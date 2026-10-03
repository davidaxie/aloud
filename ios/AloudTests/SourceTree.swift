import XCTest

/// The checkout's Swift sources, for source lints. Reads the host files next
/// to this one, so it works only where the test host can see the checkout
/// (the simulator can); anywhere else every lint skips instead of failing,
/// and SourceTreeReachabilityTests (iOS suite only) fails, so a skip never
/// passes as green.
enum SourceTree {

    /// The app trees a lint can scan: ios/Aloud (iOS, and the core the Mac
    /// shares) and ios/AloudMac (the Mac's own files).
    enum Platform: CaseIterable, Hashable {
        case iOS, macOS
    }

    /// ios/, from ios/AloudTests/SourceTree.swift.
    static let iosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// ios/Aloud.
    static let appRoot = iosRoot.appendingPathComponent("Aloud", isDirectory: true)

    /// ios/AloudUITests.
    static let uiTestsRoot = iosRoot.appendingPathComponent("AloudUITests", isDirectory: true)

    /// ios/AloudMac: the Mac app's own files (phase 1 on).
    static let macRoot = iosRoot.appendingPathComponent("AloudMac", isDirectory: true)

    /// ios/AloudMacTests: the Mac-hosted unit tests (phase 1 on).
    static let macTestsRoot = iosRoot.appendingPathComponent("AloudMacTests", isDirectory: true)

    /// ios/AloudMacUITests: the Mac UI tests (phase 1 on).
    static let macUITestsRoot = iosRoot.appendingPathComponent("AloudMacUITests", isDirectory: true)

    /// ios/project.yml, the XcodeGen spec, read as text.
    static let projectSpec = iosRoot.appendingPathComponent("project.yml", isDirectory: false)

    /// The key prefix of ios/AloudMac files in `appSources` and
    /// `macCompiledSources`.
    static let macPrefix = "AloudMac/"

    /// Whether `root` is a folder on this host. Before phase 1, ios/AloudMac
    /// and its test folders are not.
    static func exists(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The app trees of `platforms`, merged: ios/Aloud with its keys unchanged
    /// (e.g. "Playback/PlaybackController.swift"), and ios/AloudMac with keys
    /// prefixed "AloudMac/". A missing ios/AloudMac contributes nothing beside
    /// iOS, and asked for alone it skips ("AloudMac not created yet").
    static func appSources(platforms: Set<Platform> = [.iOS, .macOS]) throws -> [String: String] {
        try requireCheckoutAccess()
        var merged: [String: String] = [:]
        if platforms.contains(.iOS) {
            merged = try sources(in: appRoot)
        }
        if platforms.contains(.macOS) {
            if exists(macRoot) {
                for (path, text) in try sources(in: macRoot) {
                    merged[macPrefix + path] = text
                }
            } else if !platforms.contains(.iOS) {
                throw XCTSkip("AloudMac not created yet")
            }
        }
        return merged
    }

    /// What the Mac target compiles: ios/Aloud minus `iOSOnly` (the Mac
    /// exclusion list, as project.yml spells it, relative to ios/Aloud: a
    /// file, or a folder as "Folder/**"), plus ios/AloudMac under
    /// "AloudMac/" once it exists. The list is passed in, because its one
    /// Swift copy (MacExclusions, pinned against project.yml) is a later
    /// slice's.
    static func macCompiledSources(excluding iOSOnly: [String]) throws -> [String: String] {
        let shared = try sources(in: appRoot).filter { path, _ in !isExcluded(path, by: iOSOnly) }
        guard exists(macRoot) else { return shared }
        return try appSources(platforms: [.macOS]).merging(shared) { mac, _ in mac }
    }

    /// Whether an exclusion entry ("App/RootView.swift" or "Resources/**")
    /// covers `path`.
    static func isExcluded(_ path: String, by exclusions: [String]) -> Bool {
        exclusions.contains { entry in
            if entry.hasSuffix("/**") {
                return path.hasPrefix(String(entry.dropLast(2)))
            }
            return path == entry
        }
    }

    /// The sandboxed Mac test host never reads the checkout: it sits in
    /// OneDrive, and the first read raises a system prompt for OneDrive
    /// access that waits on the user. Source lints run in the iOS suite,
    /// whose simulator host reads the checkout directly.
    static func requireCheckoutAccess() throws {
        #if os(macOS)
        throw XCTSkip("Source lints run in the iOS suite; the sandboxed Mac host never reads the checkout")
        #endif
    }

    /// Relative path → text of every .swift file under `root`, or only those
    /// at or under `subpaths` (files like "Reader/PlayerBarView.swift" or
    /// folders like "Settings"). Throws XCTSkip when nothing is readable.
    static func sources(in root: URL = appRoot, only subpaths: [String]? = nil) throws -> [String: String] {
        try requireCheckoutAccess()
        // The path form yields paths relative to `root`.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw XCTSkip("Can't read \(root.path) from this test host")
        }
        var sources: [String: String] = [:]
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            if let subpaths, !subpaths.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                continue
            }
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                throw XCTSkip("Can't read \(relative) from this test host")
            }
            sources[relative] = text
        }
        if sources.isEmpty { throw XCTSkip("No Swift sources readable under \(root.path)") }
        return sources
    }

    /// The files whose text contains `needle`, sorted.
    static func files(containing needle: String, in sources: [String: String]) -> [String] {
        sources.filter { $0.value.contains(needle) }.map(\.key).sorted()
    }

    /// How many times `needle` appears across all `sources`.
    static func occurrences(of needle: String, in sources: [String: String]) -> Int {
        guard !needle.isEmpty else { return 0 }
        return sources.values.reduce(0) { $0 + $1.components(separatedBy: needle).count - 1 }
    }
}
