import Combine
import CryptoKit
import XCTest
@testable import Aloud

/// M3: the voice files are pinned and verified. One Hugging Face revision,
/// exact sizes and a SHA-256 per file; a staged file that fails is removed;
/// `install.json` lets a launch trust a verified install by `stat` alone;
/// files it doesn't vouch for are hashed once, in the background, before
/// anything can engage or warm the engine.
///
/// SAFETY: no test here hashes a model file for real or creates a
/// URLSession task. Model files are sparse (no disk use), every manager
/// gets a counting hasher that answers from a table, and a manager driven
/// through staged files has `startsNetworkTasks` off, so a regression fails
/// the run instead of downloading 353 MB.
@MainActor
final class ModelVerificationTests: XCTestCase {

    /// Counts hash reads by file name and answers from a table: the pinned
    /// hashes unless a test overrides one.
    private final class CountingHasher: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private let answers: [String: String]

        init(overriding overrides: [String: String] = [:]) {
            var answers = Dictionary(uniqueKeysWithValues: ModelManager.remoteFiles.map { ($0.name, $0.sha256) })
            answers.merge(overrides) { $1 }
            self.answers = answers
        }

        var reads: [String] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func hash(_ url: URL) throws -> String {
            lock.lock(); defer { lock.unlock() }
            log.append(url.lastPathComponent)
            return answers[url.lastPathComponent] ?? ""
        }
    }

    private static let wrongHash = String(repeating: "0", count: 64)

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var announcements: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    private var staging: URL { directory.appendingPathComponent("staging", isDirectory: true) }
    private var model: ModelManager.RemoteFile { ModelManager.remoteFiles[0] }
    private var voices: ModelManager.RemoteFile { ModelManager.remoteFiles[1] }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "aloud.tests.modelVerification.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        announcements = []
    }

    override func tearDown() {
        cancellables.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        suite = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A file time APFS can hold at either end of its range: after 2262 it
    /// clamps to Int64.max nanoseconds, which fits; before 1677 to
    /// Int64.min, whose seconds overflow. The record then vouches for
    /// nothing and the file is hashed again, never a trap at launch.
    func testFileTimesAtAPFSsClampsNeverTrap() {
        XCTAssertEqual(ModelInstallRecord.nanoseconds(seconds: 1_759_500_000, nanoseconds: 5),
                       1_759_500_000_000_000_005)
        XCTAssertEqual(ModelInstallRecord.nanoseconds(seconds: 9_223_372_036, nanoseconds: 854_775_807), .max)
        XCTAssertNil(ModelInstallRecord.nanoseconds(seconds: -9_223_372_037, nanoseconds: 145_224_192))
        XCTAssertNil(ModelInstallRecord.nanoseconds(seconds: .max, nanoseconds: 0))
    }

    /// The same, through a real file dated 1500: no entry, no vouching.
    func testAModelFileDatedBefore1677IsHashedAgain() throws {
        let file = directory.appendingPathComponent(model.name)
        try writeSparse(file, size: model.expectedBytes)
        var times = [timeval(tv_sec: -14_831_769_600, tv_usec: 0), timeval(tv_sec: -14_831_769_600, tv_usec: 0)]
        XCTAssertEqual(file.withUnsafeFileSystemRepresentation { path in path.map { utimes($0, &times) } ?? -1 }, 0)
        XCTAssertNil(ModelInstallRecord.entry(for: model, in: directory))
        // A record with the file in it, so vouching reaches the file's time.
        let recorded = ModelInstallRecord.File(name: model.name, bytes: model.expectedBytes, sha256: model.sha256,
                                               inode: 0, mtime: 0)
        let record = ModelInstallRecord(revision: ModelManager.revision, files: [recorded])
        XCTAssertFalse(record.vouches(for: model, in: directory))
    }

    private func makeManager(_ hasher: CountingHasher,
                             path: any NetworkPathSource = FixedNetworkPath(isExpensiveOrConstrained: false),
                             freeBytes: Int64 = 2_000_000_000) -> ModelManager {
        let manager = ModelManager(pathSource: path,
                                   installDirectory: directory,
                                   defaults: defaults,
                                   freeSpace: { freeBytes },
                                   hasher: { try hasher.hash($0) })
        manager.startsNetworkTasks = false
        manager.announce = { [weak self] in self?.announcements.append($0) }
        return manager
    }

    /// A sparse file of `size` bytes: no real disk use.
    private func writeSparse(_ url: URL, size: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    /// Both files at their pinned sizes in `folder`.
    private func writePinnedSizes(in folder: URL) throws {
        for file in ModelManager.remoteFiles {
            try writeSparse(folder.appendingPathComponent(file.name), size: file.expectedBytes)
        }
    }

    private func writeRecord() throws {
        try XCTUnwrap(ModelInstallRecord.current(in: directory)).write(to: directory)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Awaits each hashing step in turn (a staged run chains one per file).
    private func drain(_ manager: ModelManager) async {
        for _ in 0..<4 {
            guard let task = manager.verification else { return }
            await task.value
        }
    }

    /// What AppModel and NeuralPrewarm act on: the move into `.installed` is
    /// the only signal that engages the natural voice or warms the engine
    /// (which is what creates `SherpaOnnxOfflineTtsWrapper`).
    private final class EngineGate { var opened = 0 }

    private func watchEngineGate(_ manager: ModelManager) -> EngineGate {
        let gate = EngineGate()
        manager.$state
            .map { state -> Bool in
                if case .installed = state { return true }
                return false
            }
            .removeDuplicates()
            .dropFirst()
            .sink { if $0 { gate.opened += 1 } }
            .store(in: &cancellables)
        return gate
    }

    // MARK: - The pin

    func testOneRevisionExactSizesAndHashes() {
        let revision = "7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c"
        XCTAssertEqual(ModelManager.revision, revision)
        for file in ModelManager.remoteFiles {
            XCTAssertEqual(file.url.absoluteString,
                           "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/\(revision)/\(file.name)")
            XCTAssertFalse(file.url.absoluteString.contains("/resolve/main/"), "never a branch")
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression), file.name)
        }
        XCTAssertEqual(model.name, "model.onnx")
        XCTAssertEqual(model.expectedBytes, 325_630_829)
        XCTAssertEqual(model.sha256, "c436dc6a842b62aba06af67e40bafcfb9c60ac3af895358f1974ad9a7f7c026b")
        XCTAssertEqual(voices.name, "voices.bin")
        XCTAssertEqual(voices.expectedBytes, 27_678_720)
        XCTAssertEqual(voices.sha256, "8a77c0d397026208d22211f37670b5b3b11e03f190756b25a1d24041fced82a9")
        XCTAssertEqual(ModelManager.totalExpectedBytes, 353_309_549)
        XCTAssertEqual(ModelManager.downloadSizeText, "353 MB")
        XCTAssertEqual(ModelManager.requiredFreeBytes, 706_619_098)
        XCTAssertEqual(ModelManager.formattedSize(ModelManager.requiredFreeBytes), "707 MB")
    }

    /// The real hasher, on files small enough to hash: one read, and several
    /// 4 MB reads, against CryptoKit's one-shot digest.
    func testSHA256StreamsInChunks() throws {
        let small = directory.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        XCTAssertEqual(try ModelManager.sha256Hex(of: small),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let large = directory.appendingPathComponent("large")
        try writeSparse(large, size: 9_000_001)
        let expected = SHA256.hash(data: Data(count: 9_000_001)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ModelManager.sha256Hex(of: large), expected)
    }

    // MARK: - A staged file

    func testAPinnedStagedFilePasses() async throws {
        let hasher = CountingHasher()
        let url = staging.appendingPathComponent(model.name)
        try writeSparse(url, size: model.expectedBytes)
        let failure = await ModelManager.checkStagedFile(model, at: url, hasher: { try hasher.hash($0) })
        XCTAssertNil(failure)
        XCTAssertTrue(exists(url))
        XCTAssertEqual(hasher.reads, [model.name])
    }

    func testAWrongHashIsDamagedAndTheStagedFileRemoved() async throws {
        let hasher = CountingHasher(overriding: [model.name: Self.wrongHash])
        let url = staging.appendingPathComponent(model.name)
        try writeSparse(url, size: model.expectedBytes)
        let failure = await ModelManager.checkStagedFile(model, at: url, hasher: { try hasher.hash($0) })
        XCTAssertEqual(failure, .damaged)
        XCTAssertFalse(exists(url), "A wrong file never stays staged")
        XCTAssertEqual(hasher.reads, [model.name])
    }

    /// Hugging Face `main` since 2026-09-08: a 54-voice voices.bin of
    /// 28,200,960 bytes and a model.onnx of 325,560,556. Both fail on size
    /// alone, before any hashing.
    func testMainBranchSizesAreRejectedWithoutHashing() async throws {
        let hasher = CountingHasher()
        for (file, size) in [(voices, Int64(28_200_960)), (model, Int64(325_560_556))] {
            let url = staging.appendingPathComponent(file.name)
            try writeSparse(url, size: size)
            let failure = await ModelManager.checkStagedFile(file, at: url, hasher: { try hasher.hash($0) })
            XCTAssertEqual(failure, .interrupted, "\(file.name) at \(size) bytes")
            XCTAssertFalse(exists(url))
        }
        XCTAssertEqual(hasher.reads, [])
    }

    // MARK: - A download run (staged files, no network)

    func testAWrongStagedHashFailsTheRunAndNeverReachesTheEngine() async throws {
        try writePinnedSizes(in: staging)
        let hasher = CountingHasher(overriding: [model.name: Self.wrongHash])
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)
        XCTAssertEqual(manager.state, .notInstalled)

        manager.startDownload()
        await drain(manager)

        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertEqual(hasher.reads, [model.name], "The run stops at the first wrong file")
        XCTAssertFalse(exists(staging.appendingPathComponent(model.name)), "The staged file is removed")
        XCTAssertFalse(exists(directory.appendingPathComponent(model.name)), "Never moved into place")
        XCTAssertFalse(ModelManager.installedFilesLookIntact(in: directory), "The engine's own check refuses too")
        XCTAssertFalse(exists(ModelInstallRecord.url(in: directory)))
        XCTAssertEqual(gate.opened, 0, "Nothing engaged or warmed the engine")
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertEqual(announcements, ["Voice files damaged, Download again"])
    }

    func testVerifiedStagedFilesInstallWithARecord() async throws {
        try writePinnedSizes(in: staging)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)

        manager.startDownload()
        await drain(manager)

        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(hasher.reads, [model.name, voices.name])
        XCTAssertFalse(exists(staging))
        XCTAssertTrue(ModelManager.installedFilesLookIntact(in: directory))
        let record = try XCTUnwrap(ModelInstallRecord.load(from: directory))
        XCTAssertEqual(record.revision, ModelManager.revision)
        XCTAssertTrue(ModelManager.remoteFiles.allSatisfy { record.vouches(for: $0, in: directory) })
        XCTAssertEqual(gate.opened, 1)
        XCTAssertFalse(manager.hasActiveTask)
        XCTAssertEqual(announcements, [])

        let relaunch = CountingHasher()
        XCTAssertEqual(makeManager(relaunch).state, .installed)
        XCTAssertEqual(relaunch.reads, [], "A relaunch trusts the record")
    }

    /// A hash that lands after Cancel changes nothing; the next run hashes
    /// the staged file again rather than trusting or re-fetching it.
    func testCancelDuringAStagedHashWins() async throws {
        try writePinnedSizes(in: staging)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)

        manager.startDownload()
        let check = try XCTUnwrap(manager.verification)
        manager.cancelDownload()
        await check.value

        XCTAssertEqual(manager.state, .notInstalled, "A late hash changes nothing")
        XCTAssertNil(manager.verification)
        XCTAssertEqual(hasher.reads, [model.name])
        XCTAssertFalse(exists(directory.appendingPathComponent(model.name)), "Never moved into place")
        XCTAssertFalse(exists(ModelInstallRecord.url(in: directory)))
        XCTAssertEqual(gate.opened, 0)
        XCTAssertEqual(announcements, [])

        manager.startDownload()
        await drain(manager)
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(hasher.reads, [model.name, model.name, voices.name])
        XCTAssertEqual(gate.opened, 1)
    }

    /// F019: a failed attempt's staged model.onnx counts toward the room a
    /// retry needs, is out of backups from the run's start, and Remove
    /// takes it.
    func testStagedFilesCountTowardTheRoomAndStayOutOfBackups() async throws {
        try writeSparse(staging.appendingPathComponent(model.name), size: model.expectedBytes)
        // Less than the full 707 MB, more than what voices.bin still needs.
        let manager = makeManager(CountingHasher(), freeBytes: 469_000_000)
        XCTAssertEqual(manager.stagedBytes, model.expectedBytes)

        XCTAssertEqual(manager.requestDownload(), .started, "The staged file is already on disk")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, "Staged files are never backed up")
        await drain(manager)

        // voices.bin would need the network, which this manager never uses.
        XCTAssertEqual(manager.state, .failed(.interrupted))
        XCTAssertEqual(manager.stagedBytes, model.expectedBytes, "The verified file stays for the next attempt")
        XCTAssertEqual(manager.requestDownload(), .started, "and the retry still has room")
        await drain(manager)

        manager.deleteModel()
        XCTAssertEqual(manager.stagedBytes, 0)
        XCTAssertFalse(exists(staging))
    }

    /// F018: a run starts every later file not yet staged with its first,
    /// so a suspended app's background session fetches both.
    func testARunQueuesEveryLaterFileNotYetStaged() throws {
        XCTAssertEqual(ModelManager.filesQueuedAhead(of: 0, in: staging).map(\.name), [voices.name])
        XCTAssertEqual(ModelManager.filesQueuedAhead(of: 1, in: staging).map(\.name), [])
        try writeSparse(staging.appendingPathComponent(voices.name), size: voices.expectedBytes)
        XCTAssertEqual(ModelManager.filesQueuedAhead(of: 0, in: staging).map(\.name), [], "Staged is hashed, not fetched")
    }

    /// F021: a run allowed onto cellular with no network at all waits, and
    /// says it waits for a connection rather than for Wi-Fi.
    func testACellularRunWithNoNetworkWaits() async throws {
        try writePinnedSizes(in: staging)
        let manager = makeManager(CountingHasher(), path: FixedNetworkPath.unsatisfied)

        manager.startDownload(allowingCellular: true)
        XCTAssertEqual(manager.state, .waitingForWiFi(0), "Nothing can move: never a frozen live percentage")
        XCTAssertEqual(manager.waitingLine, NaturalVoiceCopy.waitingForConnection)
        XCTAssertEqual(announcements, [NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForConnection)])
        XCTAssertFalse(manager.canContinueOnCellular, "Already allowed: nothing to offer")

        await drain(manager)
        XCTAssertEqual(manager.state, .installed, "Staged files hash offline")
    }

    /// F023: a Wi-Fi-only run waiting on a costly network offers the
    /// cellular prompt again, and confirming moves the run there.
    func testAWaitingWiFiOnlyRunCanContinueOnCellular() async throws {
        try writePinnedSizes(in: staging)
        let manager = makeManager(CountingHasher(), path: FixedNetworkPath(isExpensiveOrConstrained: true))

        manager.startDownload()
        XCTAssertEqual(manager.state, .waitingForWiFi(0))
        XCTAssertEqual(manager.waitingLine, NaturalVoiceCopy.waitingForWiFi)
        XCTAssertTrue(manager.canContinueOnCellular)
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation, "The prompt, not a silent no-op")
        XCTAssertEqual(manager.cellularPrompt, NaturalVoiceCopy.cellularPrompt, "Over cellular, it says cellular")
        XCTAssertEqual(manager.cellularPromptMessage, NaturalVoiceCopy.cellularPromptMessage)

        manager.startDownload(allowingCellular: true)
        XCTAssertEqual(manager.state, .downloading(0))
        XCTAssertFalse(manager.canContinueOnCellular)
        XCTAssertEqual(ModelDownloadRecord.load(from: defaults, directory: directory)?.allowsCellular, true,
                       "A relaunch reattaches to the cellular session")

        await drain(manager)
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(announcements, [NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi)])
    }

    // MARK: - Launch

    func testAValidRecordMeansNoHashReads() throws {
        try writePinnedSizes(in: directory)
        try writeRecord()
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        XCTAssertEqual(manager.state, .installed, "Two stats, at once")
        XCTAssertFalse(manager.isVerifying)
        XCTAssertNil(manager.verification)
        XCTAssertEqual(hasher.reads, [])
    }

    /// An iPhone installed before the pin has the pinned files and no record.
    func testAPrePinInstallIsHashedOnceAndKept() async throws {
        try writePinnedSizes(in: directory)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)
        XCTAssertTrue(manager.isVerifying)
        XCTAssertFalse(manager.isInstalled, "Nothing engages the natural voice on unverified bytes")

        await drain(manager)

        XCTAssertFalse(manager.isVerifying)
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(hasher.reads.sorted(), [model.name, voices.name])
        XCTAssertEqual(gate.opened, 1)
        XCTAssertTrue(exists(ModelInstallRecord.url(in: directory)))
        XCTAssertEqual(announcements, [])

        let relaunch = CountingHasher()
        XCTAssertEqual(makeManager(relaunch).state, .installed)
        XCTAssertEqual(relaunch.reads, [])
    }

    func testATouchedFileIsHashedOnceBeforeAnyWarmUp() async throws {
        try writePinnedSizes(in: directory)
        try writeRecord()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                              ofItemAtPath: directory.appendingPathComponent(model.name).path)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)
        XCTAssertTrue(manager.isVerifying, "The card reads \(NaturalVoiceCopy.verifying)")
        XCTAssertFalse(manager.isInstalled)
        XCTAssertEqual(gate.opened, 0)

        await drain(manager)

        XCTAssertEqual(hasher.reads, [model.name], "Only the touched file")
        XCTAssertEqual(manager.state, .installed)
        XCTAssertEqual(gate.opened, 1)

        let relaunch = CountingHasher()
        XCTAssertEqual(makeManager(relaunch).state, .installed)
        XCTAssertEqual(relaunch.reads, [], "The new stamp was recorded")
    }

    func testARecordForAnotherRevisionVouchesForNothing() async throws {
        try writePinnedSizes(in: directory)
        let current = try XCTUnwrap(ModelInstallRecord.current(in: directory))
        try ModelInstallRecord(revision: "f7b96bb6bef5c5da4d3aa4f4e0498fbbf62dc78b", files: current.files)
            .write(to: directory)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        XCTAssertTrue(manager.isVerifying)
        await drain(manager)
        XCTAssertEqual(hasher.reads.sorted(), [model.name, voices.name])
        XCTAssertEqual(manager.state, .installed)
    }

    /// H006: a costly Wi-Fi (Low Data Mode, another phone's Personal
    /// Hotspot) holds a Wi-Fi-only run back, but Wi-Fi isn't missing: the
    /// line names what holds it, and the prompt never says cellular.
    func testACostlyWiFiIsNamedNeverCalledCellular() async throws {
        try writePinnedSizes(in: staging)
        let manager = makeManager(CountingHasher(),
                                  path: FixedNetworkPath(isExpensiveOrConstrained: true, usesCellular: false))

        manager.startDownload()
        XCTAssertEqual(manager.state, .waitingForWiFi(0))
        XCTAssertEqual(manager.waitingLine, NaturalVoiceCopy.waitingOnMeteredNetwork)
        XCTAssertEqual(announcements, [NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingOnMeteredNetwork)])
        XCTAssertTrue(manager.canContinueOnCellular)
        XCTAssertEqual(manager.requestDownload(), .needsCellularConfirmation)
        XCTAssertEqual(manager.cellularPrompt, NaturalVoiceCopy.cellularPrompt(onCellular: false))
        XCTAssertEqual(manager.cellularPromptMessage, NaturalVoiceCopy.cellularPromptMessage(onCellular: false))
        XCTAssertFalse(manager.cellularPrompt.contains("cellular"), manager.cellularPrompt)
        await drain(manager)
    }

    /// H042: installed files found damaged stay on disk, and Settings' card
    /// can remove them without starting a download: nothing is staged, so
    /// the staged size alone hid its Remove.
    func testDamagedFilesAreRemovableWithoutADownload() throws {
        try writeSparse(directory.appendingPathComponent(model.name), size: model.expectedBytes)
        try writeSparse(directory.appendingPathComponent(voices.name), size: 28_200_960)
        let manager = makeManager(CountingHasher())
        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertEqual(manager.stagedBytes, 0)
        XCTAssertEqual(manager.removableBytes, model.expectedBytes + 28_200_960)

        manager.deleteModel()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(manager.isInFlight, "Remove fetches nothing")
        XCTAssertFalse(exists(directory.appendingPathComponent(model.name)))
        XCTAssertFalse(exists(directory.appendingPathComponent(voices.name)))
        XCTAssertEqual(manager.removableBytes, 0)
    }

    /// H043: the space line names the check's own figure. With model.onnx
    /// staged a retry needs 381 MB, not the whole 707 MB; once Remove takes
    /// the staged file, the whole 707 MB again.
    func testTheSpaceLineNamesWhatTheCheckAskedFor() throws {
        try writeSparse(staging.appendingPathComponent(model.name), size: model.expectedBytes)
        let manager = makeManager(CountingHasher(), freeBytes: 350_000_000)

        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace)
        XCTAssertEqual(manager.state, .failed(.notEnoughSpace))
        XCTAssertEqual(manager.spaceNeeded, 380_988_269)
        XCTAssertEqual(manager.spaceNeeded, ModelManager.freeBytesNeeded(stagedBytes: model.expectedBytes))
        XCTAssertFalse(ModelManager.hasRoom(freeBytes: manager.spaceNeeded - 1, stagedBytes: model.expectedBytes))
        XCTAssertTrue(ModelManager.hasRoom(freeBytes: manager.spaceNeeded, stagedBytes: model.expectedBytes))
        XCTAssertEqual(announcements, ["Not enough space, need 381 MB free"])
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.notEnoughSpace, need: manager.spaceNeeded),
                       "Not enough space · need 381 MB free")
        XCTAssertEqual(NaturalVoiceCopy.offerLine(modelState: manager.state, need: manager.spaceNeeded),
                       "Natural voice · not enough space · need 381 MB free")

        manager.deleteModel()
        XCTAssertEqual(manager.requestDownload(), .notEnoughSpace)
        XCTAssertEqual(manager.spaceNeeded, ModelManager.requiredFreeBytes)
        XCTAssertEqual(announcements.last, "Not enough space, need 707 MB free")
    }

    func testAWrongHashAtLaunchIsDamagedAndStaysOnDisk() async throws {
        try writePinnedSizes(in: directory)
        let hasher = CountingHasher(overriding: [voices.name: Self.wrongHash])
        let manager = makeManager(hasher)
        let gate = watchEngineGate(manager)
        await drain(manager)

        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertFalse(manager.isVerifying)
        XCTAssertEqual(gate.opened, 0)
        XCTAssertTrue(ModelManager.remoteFiles.allSatisfy { exists(directory.appendingPathComponent($0.name)) },
                      "Reported, never deleted, until Download again")
        XCTAssertFalse(exists(ModelInstallRecord.url(in: directory)))
        XCTAssertEqual(announcements, ["Voice files damaged, Download again"])
    }

    func testWrongSizesAtLaunchAreDamagedWithoutHashing() throws {
        try writeSparse(directory.appendingPathComponent(model.name), size: model.expectedBytes)
        try writeSparse(directory.appendingPathComponent(voices.name), size: 28_200_960)
        let hasher = CountingHasher()
        let manager = makeManager(hasher)
        XCTAssertEqual(manager.state, .failed(.damaged))
        XCTAssertFalse(manager.isVerifying)
        XCTAssertEqual(hasher.reads, [])
        XCTAssertTrue(exists(directory.appendingPathComponent(voices.name)))
    }

    // MARK: - While checking

    func testDownloadWaitsForTheCheck() async throws {
        try writePinnedSizes(in: directory)
        let manager = makeManager(CountingHasher())
        XCTAssertTrue(manager.isVerifying)
        XCTAssertEqual(manager.requestDownload(), .started)
        manager.startDownload()
        XCTAssertFalse(exists(staging), "Nothing is fetched for files being checked")
        XCTAssertFalse(manager.hasActiveTask)
        await drain(manager)
        XCTAssertEqual(manager.state, .installed)
    }

    func testRemoveDuringTheCheckWins() async throws {
        try writePinnedSizes(in: directory)
        let manager = makeManager(CountingHasher())
        let check = try XCTUnwrap(manager.verification)
        manager.deleteModel()
        XCTAssertFalse(manager.isVerifying)
        await check.value
        XCTAssertEqual(manager.state, .notInstalled, "A late hash changes nothing")
        XCTAssertFalse(exists(directory))
    }

    /// The engine keeps Aloud's blended voices beside the pinned files: the
    /// card's size counts them, and Remove takes them along.
    func testTheDerivedVoicesFileIsCountedAndRemoved() async throws {
        try writePinnedSizes(in: directory)
        let manager = makeManager(CountingHasher())
        await drain(manager)
        XCTAssertEqual(manager.blendDirectory, directory, "the app's own folder")
        XCTAssertEqual(manager.sizeOnDisk, ModelManager.totalExpectedBytes)
        let derived = directory.appendingPathComponent(KokoroVoiceBlends.fileName)
        try writeSparse(derived, size: Int64(KokoroVoiceBlends.expectedBytes))
        try Data("{}".utf8).write(to: KokoroBlendRecord.url(in: directory))
        XCTAssertEqual(manager.sizeOnDisk, ModelManager.totalExpectedBytes + Int64(KokoroVoiceBlends.expectedBytes))
        manager.deleteModel()
        XCTAssertFalse(exists(derived))
        XCTAssertFalse(exists(KokoroBlendRecord.url(in: directory)))
    }
}
