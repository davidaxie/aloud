import XCTest

/// Every source lint skips when its tree is unreadable, so this file makes
/// unreadability a failure: a lint that skipped can never pass as green
/// (testing.md §5.11). It runs only in the iOS suite, on the simulator,
/// which reads the host checkout; the Mac target excludes it. It also pins
/// SourceTree's merged views: iOS keys unchanged, Mac keys under "AloudMac/",
/// and the Mac's compiled set as ios/Aloud minus its exclusion list.
final class SourceTreeReachabilityTests: XCTestCase {

    // MARK: - Reachability

    /// Each root a lint reads, read without SourceTree's skip.
    func testTheCheckoutIsReadable() {
        let roots = [SourceTree.appRoot, SourceTree.uiTestsRoot,
                     SourceTree.iosRoot.appendingPathComponent("AloudTests", isDirectory: true)]
        for root in roots {
            do {
                _ = try SourceTree.sources(in: root)
            } catch {
                XCTFail("\(root.path) is unreadable here, so every lint over it skips: \(error)")
            }
        }
        XCTAssertNotNil(try? String(contentsOf: SourceTree.projectSpec, encoding: .utf8),
                        "\(SourceTree.projectSpec.path) is unreadable here")
    }

    /// The roots are the real trees, not some readable folder that happens
    /// to hold Swift files, so an empty lint result means something.
    func testTheScanSeesTheRealTree() throws {
        let app = try SourceTree.sources()
        for known in ["Playback/PlaybackController.swift", "App/UITestHooks.swift", "Platform/PlatformTuning.swift"] {
            XCTAssertNotNil(app[known], "\(known) should be under \(SourceTree.appRoot.path)")
        }
        let tests = try SourceTree.sources(in: SourceTree.iosRoot.appendingPathComponent("AloudTests"))
        XCTAssertTrue(tests["SourceTree.swift"]?.contains("enum SourceTree") == true)
        let uiTests = try SourceTree.sources(in: SourceTree.uiTestsRoot)
        XCTAssertNotNil(uiTests["XCUIHelpers.swift"])
    }

    /// From phase 1, project.yml declares the AloudMac target and ios/AloudMac
    /// holds its Swift files; before, neither. A tree the project names but
    /// the host can't see fails here instead of skipping the Mac lints.
    func testMacTreeExists() throws {
        let targets = try declaredTargets()
        assertTree(SourceTree.macRoot, matches: targets.contains("AloudMac"), target: "AloudMac")
    }

    /// The same for the Mac test bundles: each folder exists exactly when its
    /// target does, so the test-root lints scan what the project compiles.
    func testMacTestTreesExist() throws {
        let targets = try declaredTargets()
        assertTree(SourceTree.macTestsRoot, matches: targets.contains("AloudMacTests"), target: "AloudMacTests")
        assertTree(SourceTree.macUITestsRoot, matches: targets.contains("AloudMacUITests"), target: "AloudMacUITests")
    }

    /// The target reader sees today's three targets, so a missing AloudMac
    /// above is the project's answer, not a parsing miss.
    func testTheProjectSpecReadsItsTargets() throws {
        let targets = try declaredTargets()
        XCTAssertTrue(targets.isSuperset(of: ["Aloud", "AloudTests", "AloudUITests"]), "\(targets.sorted())")
    }

    // MARK: - Merged views

    func testAppSourcesKeepIOSKeysAndPrefixMacKeys() throws {
        let iOS = try SourceTree.sources()
        let all = try SourceTree.appSources()
        for (path, text) in iOS {
            XCTAssertEqual(all[path], text, path)
        }
        let others = all.keys.filter { iOS[$0] == nil }
        XCTAssertEqual(others.filter { !$0.hasPrefix(SourceTree.macPrefix) }, [], "only AloudMac/ keys are added")
        if !SourceTree.exists(SourceTree.macRoot) {
            XCTAssertEqual(others, [], "before ios/AloudMac exists, appSources is the iOS tree")
        }
    }

    func testIOSAppSourcesAreTheIOSTree() throws {
        XCTAssertEqual(try SourceTree.appSources(platforms: [.iOS]), try SourceTree.sources())
    }

    /// The Mac tree alone skips (never passes empty) until it exists, and
    /// afterwards holds only AloudMac/ keys.
    func testMacAppSourcesAloneAreTheMacTree() throws {
        _ = try SourceTree.sources()   // the checkout is readable, so a missing folder is really missing
        guard SourceTree.exists(SourceTree.macRoot) else {
            XCTAssertThrowsError(try SourceTree.appSources(platforms: [.macOS])) { error in
                XCTAssertTrue(error is XCTSkip, "\(error)")
            }
            return
        }
        let mac = try SourceTree.appSources(platforms: [.macOS])
        XCTAssertFalse(mac.isEmpty)
        XCTAssertEqual(mac.keys.filter { !$0.hasPrefix(SourceTree.macPrefix) }, [])
    }

    func testMacCompiledSourcesDropTheExclusions() throws {
        let exclusions = ["App/AloudApp.swift", "Reader/ReaderScreen.swift", "Settings/**"]
        let iOS = try SourceTree.sources()
        let compiled = try SourceTree.macCompiledSources(excluding: exclusions)
        XCTAssertNotNil(iOS["Settings/SettingsView.swift"], "the folder exclusion has something to drop")
        XCTAssertNil(compiled["App/AloudApp.swift"])
        XCTAssertNil(compiled["Reader/ReaderScreen.swift"])
        XCTAssertEqual(compiled.keys.filter { $0.hasPrefix("Settings/") }, [])
        XCTAssertNotNil(compiled["Playback/PlaybackController.swift"], "shared files stay")
        let kept = iOS.keys.filter { !SourceTree.isExcluded($0, by: exclusions) }
        let mac = try SourceTree.exists(SourceTree.macRoot) ? SourceTree.appSources(platforms: [.macOS]) : [:]
        XCTAssertEqual(Set(compiled.keys), Set(kept).union(mac.keys))
    }

    func testExclusionEntriesMatchFilesAndFolders() {
        XCTAssertTrue(SourceTree.isExcluded("App/RootView.swift", by: ["App/RootView.swift"]))
        XCTAssertFalse(SourceTree.isExcluded("App/RootViewModel.swift", by: ["App/RootView.swift"]))
        XCTAssertFalse(SourceTree.isExcluded("Old/App/RootView.swift", by: ["App/RootView.swift"]))
        XCTAssertTrue(SourceTree.isExcluded("Resources/Bookshelf/x.swift", by: ["Resources/**"]))
        XCTAssertFalse(SourceTree.isExcluded("ResourcesKit.swift", by: ["Resources/**"]))
        XCTAssertFalse(SourceTree.isExcluded("App/RootView.swift", by: []))
    }

    // MARK: - Helpers

    /// The names under project.yml's top-level `targets:` (two-space keys).
    private func declaredTargets() throws -> Set<String> {
        let spec = try String(contentsOf: SourceTree.projectSpec, encoding: .utf8)
        var targets: Set<String> = []
        var inTargets = false
        for line in spec.components(separatedBy: .newlines) {
            if let first = line.first, !first.isWhitespace, first != "#" {
                inTargets = line.hasPrefix("targets:")
                continue
            }
            guard inTargets, line.hasPrefix("  "), !line.hasPrefix("   "),
                  let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.index(line.startIndex, offsetBy: 2)..<colon]
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                targets.insert(String(name))
            }
        }
        return targets
    }

    /// The folder exists exactly when the target is declared, and a
    /// declared one is readable.
    private func assertTree(_ root: URL, matches declared: Bool, target: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SourceTree.exists(root), declared,
                       declared ? "project.yml declares \(target) but \(root.path) is missing"
                                : "\(root.path) exists but project.yml declares no \(target) target",
                       file: file, line: line)
        guard declared else { return }
        do {
            _ = try SourceTree.sources(in: root)
        } catch {
            XCTFail("\(root.path) is unreadable here, so every lint over it skips: \(error)", file: file, line: line)
        }
    }
}
