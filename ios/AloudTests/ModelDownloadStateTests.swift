import SwiftUI
import XCTest
@testable import Aloud

/// R21's pure download rules: the fixed space requirement, the failure and
/// waiting copy, error classification, the engine's exact load-time size check,
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
        XCTAssertEqual(ModelManager.requiredFreeBytes, 706_619_098)
    }

    func testHasRoom() {
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: nil), "Unknown free space never blocks")
        XCTAssertFalse(ModelManager.hasRoom(freeBytes: 706_619_097))
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: 706_619_098))
    }

    /// F019: a retry after a cancel or a failure already holds the staged
    /// model.onnx, so it needs that much less room, never the whole 707 MB.
    func testStagedFilesCountTowardTheRoom() throws {
        let model = ModelManager.remoteFiles[0]
        XCTAssertFalse(ModelManager.hasRoom(freeBytes: 469_000_000), "nothing staged: the full 707 MB")
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: 469_000_000, stagedBytes: model.expectedBytes))
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: 380_988_269, stagedBytes: model.expectedBytes))
        XCTAssertFalse(ModelManager.hasRoom(freeBytes: 380_988_268, stagedBytes: model.expectedBytes))

        // Only a file at its exact pinned size counts.
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        XCTAssertEqual(ModelManager.stagedBytes(in: staging), 0)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeSparse("staging/" + model.name, size: model.expectedBytes)
        try writeSparse("staging/" + ModelManager.remoteFiles[1].name, size: 1_000)
        XCTAssertEqual(ModelManager.stagedBytes(in: staging), model.expectedBytes)
    }

    // MARK: - Copy

    func testFailureLinesAndWaitingCopy() {
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.notEnoughSpace), "Not enough space · need 707 MB free")
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

    /// F021: a run allowed onto cellular with no network at all (a tunnel,
    /// a plane) waits too, rather than showing a frozen live percentage.
    func testNoNetworkAtAllIsWaitingEvenOnCellular() {
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.37, allowsCellular: true, wifiAvailable: false,
                                                  networkAvailable: false),
                       .waitingForWiFi(0.37))
        XCTAssertEqual(ModelManager.inFlightState(progress: 0.37, allowsCellular: true, wifiAvailable: false,
                                                  networkAvailable: true),
                       .downloading(0.37))
        XCTAssertFalse(ModelManager.networkAvailable(on: FixedNetworkPath.unsatisfied))
        XCTAssertTrue(ModelManager.networkAvailable(on: FixedNetworkPath(isExpensiveOrConstrained: true)))
        XCTAssertTrue(ModelManager.networkAvailable(on: FixedNetworkPath(isExpensiveOrConstrained: false)))
    }

    /// F020: a task that resumed from resume data and failed leaving none
    /// (an expired CDN link's 403) starts its file once more from the pinned
    /// URL; a fresh task's failure, or one that left resume data, fails.
    func testOnlyAResumedTaskThatLeftNothingStartsOver() {
        XCTAssertTrue(ModelManager.restartsFromScratch(after: .interrupted, resumedFromData: true,
                                                       leftResumeData: false))
        XCTAssertFalse(ModelManager.restartsFromScratch(after: .interrupted, resumedFromData: false,
                                                        leftResumeData: false))
        XCTAssertFalse(ModelManager.restartsFromScratch(after: .interrupted, resumedFromData: true,
                                                        leftResumeData: true))
        XCTAssertFalse(ModelManager.restartsFromScratch(after: .notEnoughSpace, resumedFromData: true,
                                                        leftResumeData: false))
    }

    /// J005: whether a task resumed a partial file rides on the task, so a
    /// relaunched run that adopts it still starts the file once more from
    /// the pinned URL when the stale link answers 403.
    func testAResumedTaskStillStartsOverAfterARelaunch() {
        for file in ModelManager.remoteFiles {
            let resumed = ModelManager.taskDescription(for: file.name, resumedFromData: true)
            XCTAssertEqual(ModelManager.modelFileName(resumed), file.name)
            XCTAssertTrue(ModelManager.taskWasResumed(resumed))
            XCTAssertTrue(ModelManager.restartsFromScratch(after: .interrupted,
                                                           resumedFromData: ModelManager.taskWasResumed(resumed),
                                                           leftResumeData: false))
            // A fresh task, or one an earlier build made, reads as before.
            let fresh = ModelManager.taskDescription(for: file.name, resumedFromData: false)
            XCTAssertEqual(fresh, file.name)
            XCTAssertEqual(ModelManager.modelFileName(fresh), file.name)
            XCTAssertFalse(ModelManager.taskWasResumed(fresh))
        }
        // Still only the two known names.
        XCTAssertNil(ModelManager.modelFileName("../model.onnx#resumed"))
        XCTAssertNil(ModelManager.modelFileName("#resumed"))
        XCTAssertFalse(ModelManager.taskWasResumed("notes.txt#resumed"))
        XCTAssertFalse(ModelManager.taskWasResumed(nil))
    }

    /// J005: the relaunch adopts the current file's task and the queued
    /// ones with the bit their descriptions carry, never as fresh tasks.
    /// A source pin: no test host can hand a relaunch a background task.
    func testTheRelaunchAdoptsTasksWithTheirResumedBit() throws {
        let source = try XCTUnwrap(SourceTree.sources(only: ["TTS/ModelManager.swift"])["TTS/ModelManager.swift"])
        let start = try XCTUnwrap(source.range(of: "private func finishReattach("))
        let end = try XCTUnwrap(source.range(of: "private func wireCoordinator(",
                                             range: start.upperBound..<source.endIndex))
        let reattach = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(reattach.contains("track(task)"), "Adopted as fresh, it never starts over")
        XCTAssertFalse(reattach.contains("(later, false)"), "Queued tasks keep their bit too")
        XCTAssertTrue(reattach.contains("track(task, resumedFromData: Self.taskWasResumed(task.taskDescription))"))
        XCTAssertTrue(reattach.contains("Self.taskWasResumed(later.taskDescription)"))
        XCTAssertTrue(source.contains("task.taskDescription = Self.taskDescription(for: file.name, resumedFromData: resumed)"),
                      "makeTask marks the tasks it resumes")
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

    /// M3: the pinned file has one size. The old ±5% window let the
    /// 2026-09-08 `main` files (325,560,556 and 28,200,960 bytes) through.
    func testExactSizeBoundaries() throws {
        let model = ModelManager.remoteFiles[0]
        let voices = ModelManager.remoteFiles[1]
        try writeSparse(voices.name, size: voices.expectedBytes)
        let tolerance = model.expectedBytes / 20
        let cases: [(size: Int64, intact: Bool)] = [
            (model.expectedBytes, true),
            (model.expectedBytes + 1, false),
            (model.expectedBytes - 1, false),
            (model.expectedBytes + tolerance, false),
            (model.expectedBytes - tolerance, false),
            (325_560_556, false),
        ]
        for (size, intact) in cases {
            try writeSparse(model.name, size: size)
            XCTAssertEqual(ModelManager.installedFilesLookIntact(in: directory), intact, "\(size) bytes")
        }
        try writeSparse(model.name, size: model.expectedBytes)
        try writeSparse(voices.name, size: 28_200_960)
        XCTAssertFalse(ModelManager.installedFilesLookIntact(in: directory), "The 54-voice voices.bin")
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
