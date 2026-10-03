import XCTest
@testable import Aloud

/// M4 at run time: a launch with no download in flight creates no
/// URLSession and starts no NWPathMonitor. The first Download starts the
/// path watch once, and decides whether to ask about cellular (R5) only on
/// a path: at once when it is known, else when the first one lands, never
/// blocking the main thread for it. The source scan is
/// NetworkBoundaryLintTests.
///
/// `-uitest-offline` (DEBUG) is the plane: the path reads as unsatisfied and
/// every network request is refused. Those tests drive the refusal directly
/// and never register it, since this host isn't offline.
///
/// SAFETY: no test here creates a URLSession or starts a live monitor.
/// Built managers get a spy path (or the live one, never started), their
/// own directory and defaults suite, a hasher that never reads, and
/// `startsNetworkTasks` off, so a regression fails instead of fetching.
@MainActor
final class NetworkBoundaryTests: XCTestCase {

    /// Knows nothing until a path lands, then reports `expensive`. The path
    /// lands inside `start` when `landsOnStart` (a monitor's first update
    /// beating the question), else only at `land()`, or never. Records every
    /// start, and whether the cost was read before any path (a blind answer).
    private final class SpyPath: NetworkPathSource, @unchecked Sendable {
        let expensive: Bool
        let landsOnStart: Bool
        private(set) var starts = 0
        private(set) var hasPath = false
        private(set) var readBlind = false
        private var changeHandler: (@Sendable () -> Void)?
        init(expensive: Bool, landsOnStart: Bool = true) {
            self.expensive = expensive
            self.landsOnStart = landsOnStart
        }
        var isExpensiveOrConstrained: Bool {
            if !hasPath { readBlind = true }
            return hasPath && expensive
        }
        var allowsWiFiOnlyTransfer: Bool { !hasPath || !expensive }
        func setChangeHandler(_ handler: @escaping @Sendable () -> Void) { changeHandler = handler }
        func start() {
            starts += 1
            if landsOnStart { land() }
        }
        /// The monitor's first update, delivered as the live path delivers it.
        func land() {
            hasPath = true
            changeHandler?()
        }
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

    private var stagingExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path)
    }

    /// Turns the main actor until `condition` holds, for the answer the
    /// path's change handler hops back with.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
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

    /// The path is read only once the watch started and a path landed, so
    /// the first tap on a cellular path still asks (R5). It starts once.
    func testTheFirstDownloadStartsThePathWatchOnceAndReadsALandedPath() {
        let path = SpyPath(expensive: true)
        let manager = makeManager(path: path)
        XCTAssertEqual(path.starts, 0)

        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(path.starts, 1)
        XCTAssertFalse(path.readBlind, "the first Download answers on a path, never blind")
        XCTAssertTrue(manager.pathMonitorStarted)
        XCTAssertFalse(manager.hasCreatedSession)

        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(path.starts, 1, "the watch starts once")
    }

    /// The first tap returns at once while the path is unknown, and the
    /// answer comes when the path lands: on a cellular path, the prompt for
    /// the surface that tapped, still with nothing sent.
    func testTheFirstDownloadReturnsWithoutWaitingForThePath() async {
        let path = SpyPath(expensive: true, landsOnStart: false)
        let manager = makeManager(path: path)
        let asker = UUID()

        let tapped = ContinuousClock.now
        XCTAssertEqual(manager.requestDownload(asker: asker), .awaitingNetworkPath)
        XCTAssertLessThan(ContinuousClock.now - tapped, .milliseconds(100), "the tap never waits for the network")
        XCTAssertEqual(path.starts, 1)
        XCTAssertFalse(path.readBlind, "nothing is decided before a path")
        XCTAssertNil(manager.cellularQuestion)
        XCTAssertEqual(manager.state, .notInstalled)

        path.land()
        let asked = await waitUntil { manager.cellularQuestion != nil }
        XCTAssertTrue(asked, "the landed path never answered")
        XCTAssertEqual(manager.cellularQuestion, ModelManager.CellularQuestion(asker: asker))
        XCTAssertFalse(path.readBlind)
        XCTAssertEqual(manager.state, .notInstalled, "asking sends nothing")
        XCTAssertFalse(manager.hasCreatedSession)
        XCTAssertFalse(stagingExists)

        manager.clearCellularQuestion()
        XCTAssertNil(manager.cellularQuestion)
    }

    /// A free first path starts the Wi-Fi-only download, with no prompt.
    /// With network tasks off it stops before any session exists.
    func testAFreeFirstPathStartsTheDownloadWhenItLands() async {
        let path = SpyPath(expensive: false, landsOnStart: false)
        let manager = makeManager(path: path)

        XCTAssertEqual(manager.requestDownload(), .awaitingNetworkPath)
        XCTAssertEqual(manager.state, .notInstalled)
        path.land()
        let started = await waitUntil { manager.state != .notInstalled }
        XCTAssertTrue(started, "the landed path never started the download")
        XCTAssertEqual(manager.state, .failed(.interrupted))
        XCTAssertNil(manager.cellularQuestion)
        XCTAssertFalse(path.readBlind)
        XCTAssertFalse(manager.hasCreatedSession)
    }

    /// A second tap before the path lands moves the prompt to its surface;
    /// the watch still starts once.
    func testATapWhileWaitingMovesTheQuestionToItsSurface() async {
        let path = SpyPath(expensive: true, landsOnStart: false)
        let manager = makeManager(path: path)
        let first = UUID(), second = UUID()

        XCTAssertEqual(manager.requestDownload(asker: first), .awaitingNetworkPath)
        XCTAssertEqual(manager.requestDownload(asker: second), .awaitingNetworkPath)
        XCTAssertEqual(path.starts, 1)
        path.land()
        let asked = await waitUntil { manager.cellularQuestion != nil }
        XCTAssertTrue(asked)
        XCTAssertEqual(manager.cellularQuestion, ModelManager.CellularQuestion(asker: second))
    }

    /// No path by the end of the short wait: answered as the unknown path,
    /// the safe direction, as the old blocking wait did. The Wi-Fi-only
    /// download starts (it never moves a byte on a costly network).
    func testNoPathByTheWaitStartsTheWiFiOnlyDownload() async {
        let path = SpyPath(expensive: true, landsOnStart: false)
        let manager = makeManager(path: path)

        XCTAssertEqual(manager.requestDownload(), .awaitingNetworkPath)
        let started = await waitUntil { manager.state != .notInstalled }
        XCTAssertTrue(started, "an absent path left the Download hanging")
        XCTAssertEqual(manager.state, .failed(.interrupted))
        XCTAssertNil(manager.cellularQuestion)
        XCTAssertTrue(path.readBlind, "answered as the unknown path")
        XCTAssertFalse(manager.hasCreatedSession)
    }

    /// Nothing on the way to the network blocks a thread for the first
    /// path: no semaphore and no timed wait in either file.
    func testNoBlockingWaitForThePath() throws {
        let sources = try SourceTree.sources(only: ["TTS/ModelManager.swift", "TTS/NetworkPathSource.swift"])
        XCTAssertEqual(sources.count, 2)
        for needle in ["DispatchSemaphore", ".wait(timeout", "waitingUpTo"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), [], needle)
        }
    }

    /// The prompt's Download goes straight to `startDownload`; it watches
    /// the path too, without waiting. With network tasks off it stops
    /// before any session exists.
    func testConfirmedDownloadWatchesThePathWithoutWaiting() {
        let path = SpyPath(expensive: true)
        let manager = makeManager(path: path)

        manager.startDownload(allowingCellular: true)
        XCTAssertEqual(path.starts, 1)
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
        XCTAssertEqual(path.starts, 0)
        XCTAssertFalse(manager.pathMonitorStarted)
        XCTAssertFalse(manager.hasCreatedSession)
    }

    // MARK: - Offline (`-uitest-offline`)

    /// Records what a loader tells the URL loading system. The loader calls
    /// it synchronously, on the test's own thread.
    private final class LoaderSpy: NSObject, URLProtocolClient, @unchecked Sendable {
        private(set) var failures: [URLError.Code] = []
        private(set) var responses = 0
        private(set) var bytes = 0
        private(set) var finishes = 0
        private(set) var redirects = 0
        func urlProtocol(_ loader: URLProtocol, didFailWithError error: any Error) {
            failures.append((error as? URLError)?.code ?? .unknown)
        }
        func urlProtocol(_ loader: URLProtocol, didReceive response: URLResponse,
                         cacheStoragePolicy policy: URLCache.StoragePolicy) { responses += 1 }
        func urlProtocol(_ loader: URLProtocol, didLoad data: Data) { bytes += data.count }
        func urlProtocolDidFinishLoading(_ loader: URLProtocol) { finishes += 1 }
        func urlProtocol(_ loader: URLProtocol, wasRedirectedTo request: URLRequest,
                         redirectResponse: URLResponse) { redirects += 1 }
        func urlProtocol(_ loader: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {
            responses += 1
        }
        func urlProtocol(_ loader: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
        func urlProtocol(_ loader: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
    }

    /// Offline reports a path at once, and it is the unsatisfied one: nothing
    /// costly to ask about, and the Wi-Fi-only download waits. No monitor
    /// is made for it.
    func testOfflineReportsAnUnsatisfiedPath() {
        let path = ModelManager.defaultPathSource(offline: true)
        XCTAssertFalse(path is SystemNetworkPath, "nothing to watch on a plane")
        XCTAssertTrue(path.hasPath, "known from the start, so a Download never waits to decide")
        XCTAssertFalse(path.isExpensiveOrConstrained, "no path costs nothing: no cellular prompt")
        XCTAssertFalse(path.allowsWiFiOnlyTransfer, "no path moves no bytes")
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.3, allowsCellular: false,
                                                  wifiAvailable: path.allowsWiFiOnlyTransfer),
                       .waitingForWiFi(0.3), "an in-flight download reads as waiting")
        // This host isn't offline: it keeps the live, unstarted path.
        XCTAssertTrue(ModelManager.defaultPathSource() is SystemNetworkPath)
    }

    /// The refusal itself: a request for the model fails as "not connected"
    /// the moment it starts, with no response, no byte and no redirect. A
    /// file or data URL is left to load, as it would on a plane.
    func testOfflineRefusesARequest() throws {
        for file in ModelManager.remoteFiles {
            XCTAssertTrue(OfflineURLProtocol.canInit(with: URLRequest(url: file.url)), file.name)
        }
        for local in [URL(fileURLWithPath: NSTemporaryDirectory()), try XCTUnwrap(URL(string: "data:,a"))] {
            XCTAssertFalse(OfflineURLProtocol.canInit(with: URLRequest(url: local)), "\(local.scheme ?? "")")
        }
        let request = URLRequest(url: try XCTUnwrap(ModelManager.remoteFiles.first).url)
        let spy = LoaderSpy()
        let loader = OfflineURLProtocol(request: request, cachedResponse: nil, client: spy)
        loader.startLoading()
        XCTAssertEqual(spy.failures, [.notConnectedToInternet])
        XCTAssertEqual(spy.responses, 0)
        XCTAssertEqual(spy.bytes, 0)
        XCTAssertEqual(spy.redirects, 0)
        XCTAssertEqual(spy.finishes, 0)
        loader.stopLoading()
        XCTAssertEqual(ModelManager.DownloadFailure.classify(URLError(.notConnectedToInternet)), .interrupted,
                       "a refused download fails as interrupted, never with an error's text")
    }

    /// Offline sessions are in-process, since a background session ignores
    /// protocol classes, and carry the refusal alone, so no built-in loader
    /// ever sees a request. The cost rules are the live sessions'. This
    /// host's sessions stay the background ones.
    func testOfflineSessionsCarryOnlyTheRefusal() {
        for cellular in [false, true] {
            let config = ModelManager.sessionConfiguration(allowingCellular: cellular, offline: true)
            XCTAssertNil(config.identifier, "not a background session")
            XCTAssertEqual(config.protocolClasses?.map { ObjectIdentifier($0) },
                           [ObjectIdentifier(OfflineURLProtocol.self)])
            XCTAssertEqual(config.allowsExpensiveNetworkAccess, cellular)
            XCTAssertEqual(config.allowsConstrainedNetworkAccess, cellular)
        }
        XCTAssertEqual(ModelManager.sessionConfiguration(allowingCellular: false).identifier,
                       "com.davidxie.aloud.kokoro-model")
    }
}
