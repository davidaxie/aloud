import XCTest
@testable import Aloud

/// R5: one size string, Wi-Fi-only by default, and on an expensive or
/// constrained path the download asks first and sends nothing. R21: too
/// little space fails before anything is created, damaged files are
/// reported (never deleted) until Download again, and a test directory never
/// reattaches to a download. (M3's pin and hashes: ModelVerificationTests.)
///
/// SAFETY: no test here may create a URLSession task or hash a model file.
/// Every manager sits on an expensive path with an injected free space, its
/// own defaults suite and a hasher that never reads, so requestDownload()
/// can only fail or ask, and startDownload() is never called.
@MainActor
final class ModelManagerDownloadTests: XCTestCase {

    /// Free space the test can change between taps.
    private final class FreeSpace: @unchecked Sendable {
        var bytes: Int64?
        init(_ bytes: Int64?) { self.bytes = bytes }
    }

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var announcements: [String] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelManagerDownloadTests-\(UUID().uuidString)", isDirectory: true)
        suite = "aloud.tests.modelManagerDownload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        announcements = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suite = nil
        directory = nil
        super.tearDown()
    }

    private func makeManager(freeSpace: FreeSpace = FreeSpace(2_000_000_000)) -> ModelManager {
        let manager = ModelManager(pathSource: FixedNetworkPath(isExpensiveOrConstrained: true),
                                   installDirectory: directory,
                                   defaults: defaults,
                                   freeSpace: { freeSpace.bytes },
                                   hasher: { _ in "" })
        manager.announce = { [weak self] in self?.announcements.append($0) }
        return manager
    }

    private var stagingExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path)
    }

    /// Sparse files at the pinned sizes (no real disk use) plus the record
    /// a verified install leaves, so detection trusts them by `stat` alone.
    private func writeVerifiedModel() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ModelManager.remoteFiles {
            let url = directory.appendingPathComponent(file.name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.expectedBytes))
            try handle.close()
        }
        try XCTUnwrap(ModelInstallRecord.current(in: directory)).write(to: directory)
    }

    private func modelFilesExist() -> Bool {
        ModelManager.remoteFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path)
        }
    }

    // MARK: - Size

    func testOneSizeString() {
        XCTAssertEqual(ModelManager.totalExpectedBytes, 353_309_549)
        XCTAssertEqual(ModelManager.downloadSizeText, "353 MB")
        XCTAssertEqual(ModelManager.formattedSize(706_619_098), "707 MB")
    }

    // MARK: - Sessions

    func testDefaultSessionIsWiFiOnly() {
        let config = ModelManager.sessionConfiguration(allowingCellular: false)
        XCTAssertEqual(config.identifier, "com.davidxie.aloud.kokoro-model")
        XCTAssertFalse(config.allowsExpensiveNetworkAccess)
        XCTAssertFalse(config.allowsConstrainedNetworkAccess)
    }

    func testCellularSessionAllowsBoth() {
        let config = ModelManager.sessionConfiguration(allowingCellular: true)
        XCTAssertEqual(config.identifier?.hasSuffix(".cellular"), true)
        XCTAssertTrue(config.allowsExpensiveNetworkAccess)
        XCTAssertTrue(config.allowsConstrainedNetworkAccess)
    }

    // MARK: - Gating

    func testExpensivePathAsksFirstAndSendsNothing() {
        let manager = makeManager()
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
    }

    /// A path known at the tap answers in the return value alone, at once:
    /// the published question is only for a path that lands after the tap,
    /// so one tap never opens the prompt twice.
    func testAKnownPathAnswersAtOnceWithNoLateQuestion() {
        let manager = makeManager()
        XCTAssertEqual(manager.requestDownload(asker: UUID()), .needsCellularConfirmation)
        XCTAssertNil(manager.cellularQuestion)
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
    }

    func testInstalledModelReportsStartedWithoutATask() throws {
        try writeVerifiedModel()
        // Expensive path too, so a regression could only ask, never send.
        let manager = makeManager()
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(manager.requestDownload(), .started)
        XCTAssertFalse(manager.hasActiveTask)
    }

    // MARK: - Free space (R21)

    func testTooLittleSpaceFailsBeforeAnythingIsCreated() {
        let manager = makeManager(freeSpace: FreeSpace(700_000_000))
        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace,
                       "The space check comes before the cellular question")
        XCTAssertEqual(manager.state, .failed(.notEnoughSpace))
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
        XCTAssertEqual(announcements, [NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(.notEnoughSpace))])
        XCTAssertEqual(announcements, ["Not enough space, need 707 MB free"])
    }

    func testUnknownFreeSpaceAllows() {
        let manager = makeManager(freeSpace: FreeSpace(nil))
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertEqual(announcements, [])
    }

    func testDownloadChecksTheSpaceAgain() {
        let space = FreeSpace(700_000_000)
        let manager = makeManager(freeSpace: space)
        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace)
        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace)
        XCTAssertEqual(announcements.count, 2, "Each tap says why it did nothing")

        space.bytes = ModelManager.requiredFreeBytes
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(manager.state, .notInstalled, "The space line is gone once there is room")
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
    }

    // MARK: - Damaged files (R21)

    func testDamagedFilesFailAndStayOnDisk() throws {
        try writeVerifiedModel()
        let manager = makeManager()
        XCTAssertEqual(manager.state, .installed, "A verified install reads as installed by stat alone")
        manager.markInstalledFilesDamaged()
        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertFalse(manager.isInstalled)
        XCTAssertTrue(modelFilesExist(), "Reported, never deleted")
        XCTAssertEqual(announcements, ["Voice files damaged, Download again"])
    }

    func testDamagedIsOnlyMarkedFromInstalled() {
        let manager = makeManager()
        manager.markInstalledFilesDamaged()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertEqual(announcements, [])
    }

    func testDownloadAgainRemovesTheDamagedFilesFirst() throws {
        try writeVerifiedModel()
        let manager = makeManager()
        manager.markInstalledFilesDamaged()
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertFalse(modelFilesExist())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelInstallRecord.url(in: directory).path),
                       "The record goes with the files")
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
    }

    // MARK: - Relaunch (R21)

    /// Each rule on its own: only the app's own, not-yet-installed directory
    /// in a normal launch reattaches. Pure, so no test touches the real
    /// background session (the XCTest-host rule alone would keep an
    /// integration check green whatever the other rules said).
    func testOnlyTheAppsOwnDirectoryReattaches() {
        func decide(explicit: Bool = false, owns: Bool = true, uiTest: Bool = false,
                    xcTest: Bool = false, installed: Bool = false) -> Bool {
            ModelManager.shouldReattach(hasExplicitDirectory: explicit, ownsDirectory: owns,
                                        isUITestLaunch: uiTest, isXCTestHost: xcTest,
                                        isInstalled: installed)
        }
        XCTAssertTrue(decide(), "the production directory after a relaunch")
        XCTAssertFalse(decide(explicit: true), "an explicit (test) directory")
        XCTAssertFalse(decide(owns: false), "a host-owned -uitest-kokoro-model-path override")
        XCTAssertFalse(decide(uiTest: true), "a UI-test launch")
        XCTAssertFalse(decide(xcTest: true), "an XCTest host")
        XCTAssertFalse(decide(installed: true), "a model already installed")
    }

    /// In this XCTest host, a saved record never adopts a background task.
    func testASavedRecordNeverReattachesInATestHost() {
        ModelDownloadRecord(directory: directory, allowsCellular: false, fileIndex: 0, fraction: 0.4)
            .save(to: defaults)
        let manager = makeManager()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.hasActiveTask)
    }
}
