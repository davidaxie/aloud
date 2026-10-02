import XCTest

/// R26 source lints (and R23's "no custom Live Activity"): two intents in one
/// file, no widgets or Live Activities, shortcuts that never open the app,
/// the shared model read only at the edges, and no test that launches the
/// app through the system. Reads the checkout through SourceTree; skips when
/// the test host can't see it.
final class ShortcutsLintTests: XCTestCase {

    private static let intentsFile = "Intents/AloudShortcuts.swift"

    /// Exactly the two intents, side by side, behind one shortcuts provider.
    func testTwoIntentsInOneFile() throws {
        let app = try SourceTree.sources()
        let perform = "func perform() async"
        XCTAssertEqual(SourceTree.occurrences(of: perform, in: app), 2)
        XCTAssertEqual(SourceTree.files(containing: perform, in: app), [Self.intentsFile])
        XCTAssertEqual(SourceTree.files(containing: "AppShortcutsProvider", in: app), [Self.intentsFile])
    }

    /// R26: no widgets. R23: the Dynamic Island is the system's Now Playing
    /// activity, never one of ours.
    func testNoWidgetsOrLiveActivities() throws {
        let app = try SourceTree.sources()
        for needle in ["import WidgetKit", "import ActivityKit", "ActivityConfiguration", "WidgetBundle",
                       "ActivityAttributes", "Activity<"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: app), [], "'\(needle)' should not exist")
        }
        let infoPlist = SourceTree.appRoot.appendingPathComponent("Info.plist")
        let projectSpec = SourceTree.appRoot.deletingLastPathComponent().appendingPathComponent("project.yml")
        for url in [infoPlist, projectSpec] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("Can't read \(url.path) from this test host")
            }
            XCTAssertFalse(text.contains("NSSupportsLiveActivities"), "\(url.lastPathComponent) declares Live Activities")
        }
    }

    /// The shortcuts work without looking: neither one brings the app
    /// forward, opens a screen or buzzes the phone in a pocket.
    func testShortcutsNeverOpenTheApp() throws {
        let app = try SourceTree.sources()
        for needle in ["openAppWhenRun", "supportedModes", "ForegroundContinuableIntent"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: app), [], "'\(needle)' should not exist")
        }
        let intents = try SourceTree.sources(only: ["Intents"])
        XCTAssertEqual(intents.keys.sorted(), ["Intents/AloudShortcuts.swift", "Intents/ShortcutActions.swift"])
        for needle in ["router", "TransportHaptics"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: intents), [],
                           "Intents/ never touches '\(needle)'")
        }
    }

    /// The process singleton is read only where no environment exists: the
    /// App's root and the intents. Views keep environment injection.
    func testSingletonOnlyAtTheEdges() throws {
        let app = try SourceTree.sources()
        XCTAssertEqual(SourceTree.files(containing: "AppModel.shared", in: app),
                       ["App/AloudApp.swift", Self.intentsFile])
    }

    /// A system-launched Aloud has no mute hook and would play aloud on the
    /// Mac: UI tests reach the shortcuts only through the muted launch hook.
    func testNoSystemLaunchedTestRuns() throws {
        let uiTests = try SourceTree.sources(in: SourceTree.uiTestsRoot)
        XCTAssertEqual(SourceTree.files(containing: "siriService", in: uiTests), [])
    }
}
