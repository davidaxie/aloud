import XCTest
@testable import Aloud

/// R5: one size string, Wi-Fi-only by default, and on an expensive or
/// constrained path the download asks first and sends nothing. R21: too
/// little space fails before anything is created, damaged files are
/// reported (never deleted) until Download again, and a test directory never
/// reattaches to a download.
///
/// SAFETY: no test here may create a URLSession task. Every manager sits on
/// an expensive path with an injected free space and its own defaults
/// suite, so requestDownload() can only fail or ask, and startDownload() is
/// never called.
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
                                   freeSpace: { freeSpace.bytes })
        manager.announce = { [weak self] in self?.announcements.append($0) }
        return manager
    }

    private var stagingExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging").path)
    }

    private func writeOneByteModel() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ModelManager.remoteFiles {
            try Data([0x01]).write(to: directory.appendingPathComponent(file.name))
        }
    }

    private func modelFilesExist() -> Bool {
        ModelManager.remoteFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path)
        }
    }

    // MARK: - Size

    func testOneSizeString() {
        XCTAssertEqual(ModelManager.totalExpectedBytes, 352_500_000)
        XCTAssertEqual(ModelManager.downloadSizeText, "353 MB")
        XCTAssertEqual(ModelManager.formattedSize(705_000_000), "705 MB")
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

    func testInstalledModelReportsStartedWithoutATask() throws {
        try writeOneByteModel()
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
        XCTAssertEqual(announcements, ["Not enough space, need 705 MB free"])
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

        space.bytes = 705_000_000
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(manager.state, .notInstalled, "The space line is gone once there is room")
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertFalse(stagingExists)
    }

    // MARK: - Damaged files (R21)

    func testDamagedFilesFailAndStayOnDisk() throws {
        try writeOneByteModel()
        let manager = makeManager()
        XCTAssertEqual(manager.state, .installed, "Detection stays presence-based")
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
        try writeOneByteModel()
        let manager = makeManager()
        manager.markInstalledFilesDamaged()
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertFalse(modelFilesExist())
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
