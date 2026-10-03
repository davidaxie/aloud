import XCTest
@testable import Aloud

/// M4 at run time: a launch with no download in flight creates no
/// URLSession and starts no NWPathMonitor. The first Download starts the
/// path watch once, and waits for its first path before deciding whether to
/// ask about cellular (R5). The source scan is NetworkBoundaryLintTests.
///
/// SAFETY: no test here creates a URLSession or starts a live monitor.
/// Built managers get a spy path (or the live one, never started), their
/// own directory and defaults suite, a hasher that never reads, and
/// `startsNetworkTasks` off, so a regression fails instead of fetching.
@MainActor
final class NetworkBoundaryTests: XCTestCase {

    /// Knows nothing until started, then reports `expensive`, the way a
    /// monitor's first path lands during the wait. Records every start.
    private final class SpyPath: NetworkPathSource, @unchecked Sendable {
        let expensive: Bool
        private(set) var starts: [TimeInterval] = []
        init(expensive: Bool) { self.expensive = expensive }
        var isExpensiveOrConstrained: Bool { !starts.isEmpty && expensive }
        var allowsWiFiOnlyTransfer: Bool { starts.isEmpty || !expensive }
        func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
        func start(waitingUpTo timeout: TimeInterval) { starts.append(timeout) }
    }

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        suite = "aloud.tests.networkBoundary.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suite = nil
        directory = nil
        super.tearDown()
    }

    private func makeManager(path: SpyPath, freeBytes: Int64 = 2_000_000_000) -> ModelManager {
        let manager = ModelManager(pathSource: path,
                                   installDirectory: directory,
                                   defaults: defaults,
                                   freeSpace: { freeBytes },
                                   hasher: { _ in "" })
        manager.startsNetworkTasks = false
        manager.announce = { _ in }
        return manager
    }

    // MARK: - Launch

    /// The process's own graph, as the app built it at launch.
    func testTheAppsModelTouchesNoNetworkAtLaunch() {
        let manager = AppModel.shared.modelManager
        XCTAssertFalse(manager.hasCreatedSession)
        XCTAssertFalse(manager.pathMonitorStarted)
    }

    /// A manager composed as AppModel composes it (the live path), with no
    /// download record.
    func testTheLiveCompositionStartsNothing() {
        let manager = ModelManager(installDirectory: directory, defaults: defaults,
                                   freeSpace: { 2_000_000_000 }, hasher: { _ in "" })
        XCTAssertNil(ModelDownloadRecord.load(from: defaults, directory: directory))
        XCTAssertFalse(manager.hasCreatedSession)
        XCTAssertFalse(manager.pathMonitorStarted)
        XCTAssertEqual(manager.state, .notInstalled)
    }

    /// Building the live path makes no monitor, and an unwatched path reads
    /// as unknown: not expensive, and nothing claims "waiting".
    func testTheLivePathWatchesNothingUntilStarted() {
        let path = SystemNetworkPath()
        XCTAssertFalse(path.isMonitoring)
        XCTAssertFalse(path.isExpensiveOrConstrained)
        XCTAssertTrue(path.allowsWiFiOnlyTransfer)
    }

    // MARK: - First use

    /// The path is read only after the watch started and waited, so the
    /// first tap on a cellular path still asks (R5). It starts once.
    func testTheFirstDownloadStartsThePathWatchOnceAndWaits() throws {
        let path = SpyPath(expensive: true)
        let manager = makeManager(path: path)
        XCTAssertTrue(path.starts.isEmpty)

        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(path.starts.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(path.starts.first), 0, "the first Download waits for a path")
        XCTAssertTrue(manager.pathMonitorStarted)
        XCTAssertFalse(manager.hasCreatedSession)

        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(path.starts.count, 1, "the watch starts once")
    }

    /// The prompt's Download goes straight to `startDownload`; it watches
    /// the path too, without waiting. With network tasks off it stops
    /// before any session exists.
    func testConfirmedDownloadWatchesThePathWithoutWaiting() {
        let path = SpyPath(expensive: true)
        let manager = makeManager(path: path)

        manager.startDownload(allowingCellular: true)
        XCTAssertEqual(path.starts, [0])
        XCTAssertTrue(manager.pathMonitorStarted)
        XCTAssertFalse(manager.hasCreatedSession)
        XCTAssertEqual(manager.state, .failed(.interrupted))
    }

    /// Too little space fails before anything is created, the watch
    /// included.
    func testASpaceFailureWatchesNothing() {
        let path = SpyPath(expensive: false)
        let manager = makeManager(path: path, freeBytes: 1_000)

        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace)
        XCTAssertTrue(path.starts.isEmpty)
        XCTAssertFalse(manager.pathMonitorStarted)
        XCTAssertFalse(manager.hasCreatedSession)
    }
}
