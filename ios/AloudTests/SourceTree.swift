import XCTest

/// The checkout's Swift sources, for source lints. Reads the host files next
/// to this one, so it works only where the test host can see the checkout
/// (the simulator can); anywhere else every lint skips instead of failing.
enum SourceTree {

    /// ios/Aloud, from ios/AloudTests/SourceTree.swift.
    static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Aloud", isDirectory: true)

    /// ios/AloudUITests.
    static let uiTestsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AloudUITests", isDirectory: true)

    /// Relative path → text of every .swift file under `root`, or only those
    /// at or under `subpaths` (files like "Reader/PlayerBarView.swift" or
    /// folders like "Settings"). Throws XCTSkip when nothing is readable.
    static func sources(in root: URL = appRoot, only subpaths: [String]? = nil) throws -> [String: String] {
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
