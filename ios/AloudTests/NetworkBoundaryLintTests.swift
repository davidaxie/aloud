import XCTest

/// M4 as a source lint: only the natural-voice download's two files may
/// name a network API. Everything else in ios/Aloud, and in ios/AloudMac
/// once it exists, is offline by construction, which is what a plane
/// needs. The run-time half is NetworkBoundaryTests. Skips when the host
/// can't read the tree.
final class NetworkBoundaryLintTests: XCTestCase {

    /// The download (its two sessions) and its path (the monitor).
    private static let allowed: Set<String> = ["TTS/ModelManager.swift", "TTS/NetworkPathSource.swift"]

    private static let networkAPIs = ["URLSession", "URLRequest", "NWPathMonitor", "NWConnection",
                                      "WKWebView", "\"http"]

    /// ios/AloudMac: Mac-only files, none of which may touch the network
    /// (the shared download files live in ios/Aloud).
    private static let macRoot = SourceTree.appRoot.deletingLastPathComponent()
        .appendingPathComponent("AloudMac", isDirectory: true)

    func testOnlyTheDownloadNamesANetworkAPI() throws {
        let sources = try SourceTree.sources()
        for needle in Self.networkAPIs {
            let elsewhere = SourceTree.files(containing: needle, in: sources).filter { !Self.allowed.contains($0) }
            XCTAssertEqual(elsewhere, [], "'\(needle)' belongs only to \(Self.allowed.sorted())")
        }
    }

    /// The scan sees the real ones, so an empty result above means
    /// something.
    func testTheScanFindsTheDownloadsOwnAPIs() throws {
        let sources = try SourceTree.sources()
        XCTAssertTrue(SourceTree.files(containing: "URLSession", in: sources).contains("TTS/ModelManager.swift"))
        XCTAssertTrue(SourceTree.files(containing: "NWPathMonitor", in: sources)
            .contains("TTS/NetworkPathSource.swift"))
    }

    /// One place makes a session, reached only through the lazy sessions,
    /// so `hasCreatedSession` can't miss one; and the shared session, which
    /// would bypass it, is never used.
    func testOneSessionFactory() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.occurrences(of: "URLSession(", in: sources), 1)
        XCTAssertEqual(SourceTree.occurrences(of: "URLSession.shared", in: sources), 0)
    }

    /// One path per process: only the download builds the live path, so
    /// every other watcher (the Mac's card and R5's offer) reads the
    /// download's own through `ModelManager.sharedNetworkPath`.
    func testOnlyTheDownloadBuildsThePath() throws {
        let sources = try SourceTree.appSources()
        XCTAssertEqual(SourceTree.occurrences(of: "SystemNetworkPath(", in: sources), 1)
        XCTAssertEqual(SourceTree.files(containing: "defaultPathSource(", in: sources), ["TTS/ModelManager.swift"])
    }

    func testTheMacAppNamesNoNetworkAPI() throws {
        guard FileManager.default.fileExists(atPath: Self.macRoot.path) else {
            throw XCTSkip("ios/AloudMac doesn't exist yet")
        }
        let sources = try SourceTree.sources(in: Self.macRoot)
        for needle in Self.networkAPIs {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), [],
                           "'\(needle)' belongs only to the shared download files")
        }
    }
}
