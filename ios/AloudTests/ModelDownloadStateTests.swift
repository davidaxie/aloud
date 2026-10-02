import SwiftUI
import XCTest
@testable import Aloud

/// R21's pure download rules: the fixed space requirement, the failure and
/// waiting copy, error classification, the engine's load-time size check,
/// the relaunch record and the 44pt cancel. Nothing here creates a session
/// or a task.
@MainActor
final class ModelDownloadStateTests: XCTestCase {

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "aloud.tests.modelDownloadState.\(UUID().uuidString)"
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

    // MARK: - Space

    func testRequiredFreeSpaceIsTwiceTheDownload() {
        XCTAssertEqual(ModelManager.requiredFreeBytes, 705_000_000)
    }

    func testHasRoom() {
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: nil), "Unknown free space never blocks")
        XCTAssertFalse(ModelManager.hasRoom(freeBytes: 704_999_999))
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: 705_000_000))
    }

    // MARK: - Copy

    func testFailureLinesAndWaitingCopy() {
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.notEnoughSpace), "Not enough space · need 705 MB free")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.interrupted), "Download failed · Try again")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.damaged), "Voice files damaged · Download again")
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, "Download paused · waiting for Wi-Fi")
    }

    // MARK: - Waiting for Wi-Fi

    func testWiFiOnlyWithoutWiFiIsWaiting() {
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.4, allowsCellular: false, wifiAvailable: false),
                       .waitingForWiFi(0.4))
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.4, allowsCellular: true, wifiAvailable: false),
                       .downloading(0.4))
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.4, allowsCellular: false, wifiAvailable: true),
                       .downloading(0.4))
    }

    func testFixedPathWiFiFollowsTheCostUnlessGiven() {
        XCTAssertFalse(FixedNetworkPath(isExpensiveOrConstrained: true).allowsWiFiOnlyTransfer)
        XCTAssertTrue(FixedNetworkPath(isExpensiveOrConstrained: false).allowsWiFiOnlyTransfer)
        XCTAssertTrue(FixedNetworkPath(isExpensiveOrConstrained: true, wifiAvailable: true).allowsWiFiOnlyTransfer)
        XCTAssertFalse(FixedNetworkPath(isExpensiveOrConstrained: false, wifiAvailable: false).allowsWiFiOnlyTransfer)
    }

    // MARK: - Classification

    func testOutOfSpaceErrorsClassifyAsNotEnoughSpace() {
        typealias Failure = ModelManager.DownloadFailure
        XCTAssertEqual(Failure.classify(CocoaError(.fileWriteOutOfSpace)), .notEnoughSpace)
        XCTAssertEqual(Failure.classify(POSIXError(.ENOSPC)), .notEnoughSpace)
        XCTAssertEqual(Failure.classify(URLError(.cannotWriteToFile)), .notEnoughSpace)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        XCTAssertEqual(Failure.classify(wrapped), .notEnoughSpace, "A file error wrapping ENOSPC")
    }

    func testEveryOtherErrorIsInterrupted() {
        typealias Failure = ModelManager.DownloadFailure
        XCTAssertEqual(Failure.classify(URLError(.badServerResponse)), .interrupted)
        XCTAssertEqual(Failure.classify(URLError(.networkConnectionLost)), .interrupted)
        XCTAssertEqual(Failure.classify(CocoaError(.fileWriteNoPermission)), .interrupted)
    }

    // MARK: - The engine's size check

    /// A sparse file of `size` bytes: no real disk use.
    private func writeSparse(_ name: String, size: Int64) throws {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    func testOneByteFilesDoNotLookIntact() throws {
        for file in ModelManager.remoteFiles {
            try Data([0x01]).write(to: directory.appendingPathComponent(file.name))
        }
        XCTAssertFalse(ModelManager.installedFilesLookIntact(in: directory))
    }

    func testExpectedSizesLookIntact() throws {
        for file in ModelManager.remoteFiles {
            try writeSparse(file.name, size: file.expectedBytes)
        }
        XCTAssertTrue(ModelManager.installedFilesLookIntact(in: directory))
    }

    func testAMissingFileDoesNotLookIntact() throws {
        let model = ModelManager.remoteFiles[0]
        try writeSparse(model.name, size: model.expectedBytes)
        XCTAssertFalse(ModelManager.installedFilesLookIntact(in: directory))
    }

    func testFivePercentBoundaries() throws {
        let model = ModelManager.remoteFiles[0]
        let voices = ModelManager.remoteFiles[1]
        try writeSparse(voices.name, size: voices.expectedBytes)
        let tolerance = model.expectedBytes / 20
        let cases: [(size: Int64, intact: Bool)] = [
            (model.expectedBytes + tolerance, true),
            (model.expectedBytes + tolerance + 1, false),
            (model.expectedBytes - tolerance, true),
            (model.expectedBytes - tolerance - 1, false),
        ]
        for (size, intact) in cases {
            try writeSparse(model.name, size: size)
            XCTAssertEqual(ModelManager.installedFilesLookIntact(in: directory), intact, "\(size) bytes")
        }
    }

    // MARK: - Relaunch record

    func testRecordRoundTripsAndClears() {
        XCTAssertEqual(ModelDownloadRecord.key, "aloud.naturalVoice.download.v1")
        let record = ModelDownloadRecord(directory: directory, allowsCellular: true, fileIndex: 1, fraction: 0.42)
        record.save(to: defaults)
        XCTAssertEqual(ModelDownloadRecord.load(from: defaults, directory: directory), record)
        ModelDownloadRecord.clear(from: defaults)
        XCTAssertNil(ModelDownloadRecord.load(from: defaults, directory: directory))
    }

    func testRecordForAnotherDirectoryIsIgnored() {
        ModelDownloadRecord(directory: directory, allowsCellular: false, fileIndex: 0, fraction: 0.3)
            .save(to: defaults)
        let other = directory.appendingPathComponent("other", isDirectory: true)
        XCTAssertNil(ModelDownloadRecord.load(from: defaults, directory: other))
    }

    func testGarbageRecordIsIgnored() {
        defaults.set(Data("not json".utf8), forKey: ModelDownloadRecord.key)
        XCTAssertNil(ModelDownloadRecord.load(from: defaults, directory: directory))
        defaults.set("a string", forKey: ModelDownloadRecord.key)
        XCTAssertNil(ModelDownloadRecord.load(from: defaults, directory: directory))
    }

    // MARK: - Cancel target

    func testCancelButtonIsAtLeast44AtEverySize() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let button = CancelDownloadButton(onCancel: {})
                .environment(\.dynamicTypeSize, size)
            let fitted = UIHostingController(rootView: button)
                .sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(fitted.width, 44, "\(size)")
            XCTAssertGreaterThanOrEqual(fitted.height, 44, "\(size)")
        }
    }
}
