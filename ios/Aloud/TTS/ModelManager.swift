import Combine
import CryptoKit
import Foundation

/// Owns the on-device Kokoro model files (`model.onnx` + `voices.bin`):
/// detection, resumable background download from Hugging Face, verification,
/// and deletion. Files live in Application Support/KokoroModel, excluded
/// from backup (they are re-downloadable). The engine may keep a derived
/// voices file beside them (`KokoroVoiceBlends`: `voices-aloud.bin` and its
/// record), rebuilt from voices.bin whenever it's missing or stale and
/// removed along with the files.
///
/// The files are pinned (M3): one Hugging Face revision, exact sizes and a
/// SHA-256 per file, checked off the main actor as each file stages. A
/// verified install is recorded in `install.json`, so a launch trusts it
/// after two `stat`s; files the record doesn't vouch for are hashed once in
/// the background (`isVerifying`) before anything can warm the engine.
///
/// The download is Wi-Fi only unless the user confirms cellular (R5):
/// `requestDownload()` asks first on an expensive or constrained path, and
/// only `startDownload(allowingCellular: true)` uses the cellular session.
/// The first Download asks before any path is known: it returns at once,
/// and the answer comes when the first path lands (`cellularQuestion`).
///
/// The download can't leave the user stuck (R21): free space of twice the
/// download is checked before anything is created or sent; resume data is
/// kept on disk beside the staged files; a record lets a relaunch reattach
/// to the background session and show its progress at once; and every stop
/// is one of three classified failures, announced, never an error's text.
///
/// Nothing here touches the network until a download is asked for or
/// reattached (M4): both sessions are made on first use, so a launch with
/// no download in flight opens no socket. The path is the process's one
/// (`sharedNetworkPath`): a Download or a reattach starts it, and so, on
/// the Mac, does the not-installed card appearing or R5's offer coming due
/// (M17), to say whether a Download could start. Watching a path opens no
/// socket.
///
/// Dev/test seeding: copy both pinned files into the container's
/// Application Support/KokoroModel/ — `detectExisting()` (run at init)
/// hashes them once, writes the record and flips the state to `.installed`.
@MainActor
final class ModelManager: ObservableObject {

    enum ModelState: Equatable {
        case notInstalled
        case downloading(Double)      // combined 0…1 across both files
        case waitingForWiFi(Double)   // in flight, Wi-Fi only, and no Wi-Fi
        case installed
        case failed(DownloadFailure)
    }

    /// Why a download stopped, from the error's domain and code (never its
    /// text, so no system message ever reaches the screen).
    enum DownloadFailure: Equatable, CaseIterable {
        case notEnoughSpace, interrupted, damaged

        nonisolated static func classify(_ error: any Error) -> DownloadFailure {
            let nsError = error as NSError
            switch (nsError.domain, nsError.code) {
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)),
                 (NSURLErrorDomain, NSURLErrorCannotWriteToFile):
                return .notEnoughSpace
            default:
                // A file error often wraps the POSIX cause.
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    return classify(underlying)
                }
                return .interrupted
            }
        }
    }

    struct RemoteFile {
        let name: String
        let url: URL
        /// Exact: the pinned file has one size.
        let expectedBytes: Int64
        /// Lowercase hex SHA-256 of the pinned file.
        let sha256: String
    }

    /// The Hugging Face commit both files come from. `main` moved on
    /// 2026-09-08 to a 54-voice voices.bin that the 53-entry sid table
    /// doesn't match (and that failed the old ±5% check on every download),
    /// so the download never follows a branch. `ios/tools/fetch_kokoro_model.sh`
    /// pins the same revision, sizes and hashes.
    nonisolated static let revision = "7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c"

    nonisolated static let remoteFiles: [RemoteFile] = [
        RemoteFile(
            name: "model.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c/model.onnx")!,
            expectedBytes: 325_630_829,
            sha256: "c436dc6a842b62aba06af67e40bafcfb9c60ac3af895358f1974ad9a7f7c026b"),
        RemoteFile(
            name: "voices.bin",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c/voices.bin")!,
            expectedBytes: 27_678_720,
            sha256: "8a77c0d397026208d22211f37670b5b3b11e03f190756b25a1d24041fced82a9"),
    ]

    /// The pinned voices.bin: the source of the derived voices file.
    nonisolated static var voicesFile: RemoteFile { remoteFiles[1] }

    /// The whole download, summed from the files themselves so no surface
    /// can drift from what is actually fetched.
    nonisolated static var totalExpectedBytes: Int64 {
        remoteFiles.reduce(0) { $0 + $1.expectedBytes }
    }

    /// The app's only byte-count formatter: whole decimal megabytes, so the
    /// offer, the cellular prompt and the size on disk all read alike.
    nonisolated static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .decimal
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    /// The one download-size string every surface shows (R5): "353 MB".
    nonisolated static let downloadSizeText: String = formattedSize(totalExpectedBytes)

    /// Kokoro fp32 peaks near 800 MB of RAM — only offer the install on
    /// ~6 GB-or-more devices. Simulators inherit the Mac's memory and pass,
    /// so UI tests force the unsupported branch with a hook.
    nonisolated static var deviceSupportsNeuralVoice: Bool {
        !UITestHooks.forceUnsupportedDevice
            && ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
    }

    enum DownloadRequest: Equatable {
        case started
        case needsCellularConfirmation
        case notEnoughSpace
        /// The first Download, before the network path is known. When it
        /// lands the download starts, or `cellularQuestion` asks the
        /// surface that tapped.
        case awaitingNetworkPath
    }

    /// A Download asked before the path was known that landed on an
    /// expensive or constrained path. `asker` names the surface that tapped
    /// (nil for one that names none), so only its cellular prompt shows.
    struct CellularQuestion: Equatable {
        let asker: UUID?
    }

    /// R21: twice the download (707 MB), so the staged files and the final
    /// move never fill the phone.
    nonisolated static var requiredFreeBytes: Int64 { totalExpectedBytes * 2 }

    /// Unknown free space allows the download; a write that then runs out
    /// still lands as `.notEnoughSpace`.
    nonisolated static func hasRoom(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredFreeBytes
    }

    /// The space iOS would free for a download the user asked for, which is
    /// more than the plain available capacity.
    nonisolated static func defaultFreeSpace() -> Int64? {
        if UITestHooks.forceLowDiskSpace { return 100_000_000 }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The engine's load-time check (R21): both files at their exact pinned
    /// size. Detection checks this too; the hash was checked before the
    /// files ever read as installed.
    nonisolated static func installedFilesLookIntact(in directory: URL) -> Bool {
        remoteFiles.allSatisfy { file in
            sizeIsExact(fileSize(at: directory.appendingPathComponent(file.name)),
                        expected: file.expectedBytes)
        }
    }

    /// Hashes one file and returns its lowercase hex SHA-256. Blocking;
    /// always called off the main actor. Tests inject their own.
    typealias FileHasher = @Sendable (URL) throws -> String

    /// SHA-256 streamed in 4 MB reads, so 326 MB never sits in memory.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            // Each read's buffer is freed before the next one.
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) }
            guard let chunk, !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A staged file must be the pinned one: exact size (a stat), then its
    /// SHA-256 in a detached task. Nil when it is; otherwise the staged file
    /// is removed. A wrong size is a transfer that went wrong; the right
    /// size with the wrong bytes is damaged.
    nonisolated static func checkStagedFile(_ file: RemoteFile, at url: URL,
                                            hasher: @escaping FileHasher) async -> DownloadFailure? {
        guard sizeIsExact(fileSize(at: url), expected: file.expectedBytes) else {
            try? FileManager.default.removeItem(at: url)
            return .interrupted
        }
        guard await hashMatches(file, at: url, hasher: hasher) else {
            try? FileManager.default.removeItem(at: url)
            return .damaged
        }
        return nil
    }

    /// An unreadable file counts as a mismatch.
    nonisolated static func hashMatches(_ file: RemoteFile, at url: URL,
                                        hasher: @escaping FileHasher) async -> Bool {
        let digest = await Task.detached(priority: .userInitiated) { try? hasher(url) }.value
        return digest == file.sha256
    }

    /// A Wi-Fi-only download with no Wi-Fi is waiting, not downloading.
    nonisolated static func inFlightState(progress: Double, allowsCellular: Bool,
                                          wifiAvailable: Bool) -> ModelState {
        allowsCellular || wifiAvailable ? .downloading(progress) : .waitingForWiFi(progress)
    }

    /// Two background sessions rather than one toggled config: a background
    /// session's configuration is fixed at creation, and the Wi-Fi-only one
    /// must never be able to touch cellular. `-uitest-offline` (DEBUG) gets
    /// in-process sessions whose every request `OfflineURLProtocol` refuses.
    nonisolated static func sessionConfiguration(allowingCellular: Bool,
                                                 offline: Bool = UITestHooks.offline) -> URLSessionConfiguration {
        #if DEBUG
        if offline { return OfflineURLProtocol.sessionConfiguration(allowingCellular: allowingCellular) }
        #endif
        let config = URLSessionConfiguration.background(
            withIdentifier: allowingCellular
                ? "com.davidxie.aloud.kokoro-model.cellular"
                : "com.davidxie.aloud.kokoro-model")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = false
        config.allowsExpensiveNetworkAccess = allowingCellular
        config.allowsConstrainedNetworkAccess = allowingCellular
        return config
    }

    /// `-uitest-offline` wins over `-uitest-expensive-network`: on a plane
    /// there is no path at all, costly or not.
    nonisolated static func defaultPathSource(offline: Bool = UITestHooks.offline) -> any NetworkPathSource {
        if offline {
            return FixedNetworkPath.unsatisfied
        }
        if UITestHooks.forceExpensiveNetwork {
            return FixedNetworkPath(isExpensiveOrConstrained: true)
        }
        return SystemNetworkPath()
    }

    // MARK: - State

    @Published private(set) var state: ModelState = .notInstalled

    /// Files on disk that the install record doesn't vouch for are being
    /// hashed ("Checking voice files…"). Meanwhile `state` stays
    /// `.notInstalled`, so nothing engages or warms the engine on unverified
    /// bytes, and the move to `.installed` re-engages the voice as a
    /// finished download does.
    @Published private(set) var isVerifying = false

    /// The hashing in flight, launch check or staged file. Tests await it.
    private(set) var verification: Task<Void, Never>?

    /// Set when a Download asked before the first path turns out to need
    /// the cellular prompt; the prompt's answer clears it.
    @Published private(set) var cellularQuestion: CellularQuestion?

    let installDirectory: URL

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    var isInFlight: Bool { inFlightProgress != nil }

    /// What Remove frees: the pinned files, and the derived voices file
    /// once the engine has built it in the app's own directory.
    var sizeOnDisk: Int64 {
        let pinned = Self.remoteFiles.reduce(0) { sum, file in
            sum + Self.fileSize(at: installDirectory.appendingPathComponent(file.name))
        }
        guard ownsInstallDirectory else { return pinned }
        return pinned + Self.fileSize(at: installDirectory.appendingPathComponent(KokoroVoiceBlends.fileName))
    }

    var hasActiveTask: Bool { activeTask != nil }

    /// Says what the user didn't ask for: entering `.waitingForWiFi`, and
    /// every failure. Tests replace it.
    var announce: (String) -> Void = { ModelManager.postAnnouncement($0) }

    /// M19's check and verify intervals. Tests replace it.
    var budgetSignposts = BudgetSignposts.live

    /// Queued, so it never cuts off VoiceOver; never posted in a muted
    /// (test) process.
    static func postAnnouncement(_ text: String) {
        guard !UITestHooks.muteAudio else { return }
        A11yAnnounce.post(text, queued: true)
    }

    #if DEBUG
    /// M4 probes, read by NetworkBoundaryTests: a session exists only once
    /// a download started or reattached, and the path is watched only once
    /// a download, or on the Mac a surface offering one, asked for it.
    private(set) var hasCreatedSession = false
    var pathMonitorStarted: Bool { pathHub.isStarted }
    #endif

    // MARK: - Private state

    private let pathSource: any NetworkPathSource
    /// The path's one start and its every watcher: this manager first, then
    /// each `sharedNetworkPath`.
    private let pathHub: NetworkPathHub
    /// A Download asked before the first path landed: who asked, and the
    /// run it belongs to. The first path, or `firstPathWait`, answers it.
    private var pendingRequest: (asker: UUID?, epoch: Int)?
    private let defaults: UserDefaults
    private let freeSpace: @Sendable () -> Int64?
    private let hasher: FileHasher

    /// Bumped by every new run, cancel, delete and detection, so a hash
    /// that finishes after its run was replaced changes nothing.
    private var epoch = 0

    #if DEBUG
    /// Tests that drive staged files through verification turn this off, so
    /// a regression fails the run instead of fetching 353 MB.
    var startsNetworkTasks = true
    #endif

    /// False for a `-uitest-kokoro-model-path` override: those files belong
    /// to the host, so Remove never deletes them.
    private let ownsInstallDirectory: Bool

    /// Where the engine keeps the derived voices file: the app's own install
    /// directory, never a host-owned override (DEBUG: a scratch directory
    /// instead, so UI tests hear the blends too).
    var blendDirectory: URL? {
        if ownsInstallDirectory { return installDirectory }
        #if DEBUG
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("KokoroVoiceBlends-uitest", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
        #else
        return nil
        #endif
    }

    private let wifiCoordinator: DownloadCoordinator
    private let cellularCoordinator: DownloadCoordinator
    private lazy var wifiSession = makeSession(allowingCellular: false)
    private lazy var cellularSession = makeSession(allowingCellular: true)

    private var allowsCellularThisRun = false
    private var activeTask: URLSessionDownloadTask?
    /// The (session, task) pair allowed to move `state`. Task IDs are only
    /// unique within one session, so the coordinator is part of the key.
    private var activeTaskID: Int?
    private var activeCoordinatorID: ObjectIdentifier?
    private var currentFileIndex = 0
    private var completedBytes: Int64 = 0
    /// The fraction last written to the download record.
    private var recordedFraction: Double = 0

    private var stagingDirectory: URL { Self.stagingDirectory(in: installDirectory) }

    private var inFlightProgress: Double? {
        switch state {
        case .downloading(let progress), .waitingForWiFi(let progress): return progress
        case .notInstalled, .installed, .failed: return nil
        }
    }

    // MARK: - Init

    /// Existing `ModelManager()` call sites get the live network path, the
    /// real (or hook-chosen) directory, standard defaults, the real free
    /// space and the real hasher; tests pass their own.
    init(pathSource: any NetworkPathSource = ModelManager.defaultPathSource(),
         installDirectory explicit: URL? = nil,
         defaults: UserDefaults = .standard,
         freeSpace: @escaping @Sendable () -> Int64? = { ModelManager.defaultFreeSpace() },
         hasher: @escaping FileHasher = { try ModelManager.sha256Hex(of: $0) }) {
        self.pathSource = pathSource
        pathHub = NetworkPathHub(source: pathSource)
        self.defaults = defaults
        self.freeSpace = freeSpace
        self.hasher = hasher
        #if DEBUG
        OfflineURLProtocol.registerIfOffline()
        #endif
        let directory: URL
        let owns: Bool
        if let explicit {
            directory = explicit
            owns = true
        } else if let temp = Self.uiTestTemporaryDirectory() {
            directory = temp
            owns = true
        } else if let override = UITestHooks.kokoroModelPath {
            // UI-test hook (no-op in Release): `-uitest-kokoro-model-path <dir>`
            // points at a directory that already holds model.onnx + voices.bin
            // (e.g. on the host Mac, which the simulator sandbox can read), so
            // tests never download.
            directory = URL(fileURLWithPath: override, isDirectory: true)
            owns = false
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            directory = support.appendingPathComponent("KokoroModel", isDirectory: true)
            owns = true
        }
        installDirectory = directory
        ownsInstallDirectory = owns
        wifiCoordinator = DownloadCoordinator(stagingDirectory: Self.stagingDirectory(in: directory))
        cellularCoordinator = DownloadCoordinator(stagingDirectory: Self.stagingDirectory(in: directory))
        wireCoordinator(wifiCoordinator)
        wireCoordinator(cellularCoordinator)
        pathHub.addWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.answerPendingRequest()
                self?.refreshInFlightState()
            }
        }
        detectExisting()
        // Files being checked are on disk, so there is nothing to reattach.
        if Self.shouldReattach(hasExplicitDirectory: explicit != nil, ownsDirectory: owns,
                               isUITestLaunch: UITestHooks.isUITestLaunch,
                               isXCTestHost: NSClassFromString("XCTestCase") != nil,
                               isInstalled: isInstalled || isVerifying) {
            reattachIfNeeded()
        }
    }

    /// Only the app's own directory reattaches to a recorded download: never
    /// an explicit (test) directory, a host-owned override, an XCTest host or
    /// a UI-test launch, any of which would adopt the real background
    /// session's tasks. Pure, so each rule is tested without that session.
    nonisolated static func shouldReattach(hasExplicitDirectory: Bool, ownsDirectory: Bool,
                                           isUITestLaunch: Bool, isXCTestHost: Bool,
                                           isInstalled: Bool) -> Bool {
        !hasExplicitDirectory && ownsDirectory && !isUITestLaunch && !isXCTestHost && !isInstalled
    }

    /// `-uitest-temp-model-dir`: a fresh, empty directory each launch, so the
    /// model reads as absent without touching the real container.
    /// `-uitest-damaged-model` uses it too, seeded with 1-byte model files
    /// that detection reads as damaged (their size is wrong). Only this
    /// throwaway directory is ever wiped at init.
    private static func uiTestTemporaryDirectory() -> URL? {
        #if DEBUG
        guard UITestHooks.tempModelDirectory || UITestHooks.damagedModel else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KokoroModel-uitest", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if UITestHooks.damagedModel {
            for file in remoteFiles {
                try? Data([0x01]).write(to: directory.appendingPathComponent(file.name))
            }
        }
        return directory
        #else
        return nil
        #endif
    }

    /// Both files present on disk → checked by `stat` alone: a wrong size
    /// is damaged at once (reported, never deleted, R21), and a record that
    /// still vouches for both files means installed. Any file it doesn't
    /// vouch for (pre-pin installs have no record; a touched or replaced
    /// file has a new stamp) is hashed once in the background first.
    func detectExisting() {
        let check = budgetSignposts.begin(.modelCheck)
        defer { budgetSignposts.end(check) }
        epoch &+= 1
        endVerification()
        let present = Self.remoteFiles.allSatisfy { file in
            Self.fileSize(at: installDirectory.appendingPathComponent(file.name)) > 0
        }
        guard present else {
            if case .installed = state { state = .notInstalled }
            return
        }
        guard Self.installedFilesLookIntact(in: installDirectory) else {
            fail(.damaged)
            return
        }
        // A `-uitest-kokoro-model-path` override belongs to the host and was
        // checked there by `ios/tools/fetch_kokoro_model.sh`; nothing is
        // written into it.
        guard ownsInstallDirectory else {
            state = .installed
            return
        }
        let record = ModelInstallRecord.load(from: installDirectory)
        let unvouched = Self.remoteFiles.filter { record?.vouches(for: $0, in: installDirectory) != true }
        guard !unvouched.isEmpty else {
            state = .installed
            return
        }
        if case .installed = state { state = .notInstalled }
        verifyInstalledFiles(unvouched)
    }

    /// Hashes `files` in place. They match → a fresh record, then
    /// `.installed`; otherwise they stay on disk as damaged until Download
    /// again replaces them.
    private func verifyInstalledFiles(_ files: [RemoteFile]) {
        let generation = epoch
        let directory = installDirectory
        let hasher = self.hasher
        let signposts = budgetSignposts
        let verify = signposts.begin(.modelVerify)
        isVerifying = true
        verification = Task { [weak self] in
            var intact = true
            for file in files where intact {
                intact = await Self.hashMatches(file, at: directory.appendingPathComponent(file.name),
                                                hasher: hasher)
            }
            // Before any guard: a mismatch, an unreadable file or a newer
            // detection all end it here.
            signposts.end(verify)
            guard let self, self.epoch == generation else { return }
            self.endVerification()
            guard intact else {
                self.fail(.damaged)
                return
            }
            self.writeInstallRecord()
            self.state = .installed
        }
    }

    private func endVerification() {
        verification = nil
        isVerifying = false
    }

    /// Written only once both files hashed to their pins. A failed write
    /// costs one re-hash at the next launch, nothing more.
    private func writeInstallRecord() {
        try? ModelInstallRecord.current(in: installDirectory)?.write(to: installDirectory)
    }

    // MARK: - Download

    /// Every Download button's entry point. Too little space fails at once,
    /// creating nothing. On cellular or Low Data Mode it asks first and
    /// sends nothing — no staging directory, no task — until the user
    /// confirms through `startDownload(allowingCellular: true)`. It never
    /// waits: before the first path lands it returns `.awaitingNetworkPath`,
    /// and `asker` is the surface whose prompt the late answer opens.
    @discardableResult
    func requestDownload(asker: UUID? = nil) -> DownloadRequest {
        // A new tap supersedes a question its surface never showed.
        clearCellularQuestion()
        // The files are on disk and being checked: nothing to fetch.
        if isVerifying { return .started }
        switch state {
        case .downloading, .waitingForWiFi, .installed:
            return .started
        case .failed(.damaged):
            // Download again replaces them, so their space counts as free.
            removeOwnedModelFiles()
        case .notInstalled, .failed:
            break
        }
        guard Self.hasRoom(freeBytes: freeSpace()) else {
            pendingRequest = nil
            fail(.notEnoughSpace)
            return .notEnoughSpace
        }
        // There is room now, so the space line would be stale under the prompt.
        if state == .failed(.notEnoughSpace) { state = .notInstalled }
        // The first Download is where the path starts being watched (on the
        // Mac, the card or the offer may have started it already). The
        // cellular question must not be answered blind, nor hold the main
        // thread while the first path lands, so it is answered then.
        watchPath()
        guard pathSource.hasPath else {
            awaitFirstPath(asker: asker)
            return .awaitingNetworkPath
        }
        if pathSource.isExpensiveOrConstrained { return .needsCellularConfirmation }
        startDownload(allowingCellular: false)
        return .started
    }

    /// The cellular prompt was answered (Download or Cancel), or went away.
    func clearCellularQuestion() {
        if cellularQuestion != nil { cellularQuestion = nil }
    }

    func startDownload(allowingCellular: Bool = false) {
        clearCellularQuestion()
        guard !isVerifying else { return }
        switch state {
        case .downloading, .waitingForWiFi, .installed: return
        case .notInstalled, .failed: break
        }
        // Again here: the cellular prompt's Download lands here directly.
        guard Self.hasRoom(freeBytes: freeSpace()) else {
            fail(.notEnoughSpace)
            return
        }
        allowsCellularThisRun = allowingCellular
        watchPath()
        do {
            try FileManager.default.createDirectory(at: stagingDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            fail(DownloadFailure.classify(error))
            return
        }
        epoch &+= 1
        completedBytes = 0
        setInFlight(progress: 0)
        startTask(forFileAt: 0)
    }

    func cancelDownload() {
        guard isInFlight else { return }
        epoch &+= 1
        endVerification()
        if let activeTask { cancelKeepingResumeData(activeTask) }
        clearActiveTask()
        ModelDownloadRecord.clear(from: defaults)
        state = .notInstalled
    }

    func deleteModel() {
        if isInFlight { cancelDownload() }
        epoch &+= 1
        endVerification()
        ModelDownloadRecord.clear(from: defaults)
        if ownsInstallDirectory {
            try? FileManager.default.removeItem(at: installDirectory)
        }
        state = .notInstalled
    }

    /// The engine found the installed files damaged when it loaded them.
    /// They stay on disk until Download again replaces them.
    func markInstalledFilesDamaged() {
        guard case .installed = state else { return }
        fail(.damaged)
    }

    // MARK: - Sequential download machinery

    private func startTask(forFileAt index: Int) {
        guard index < Self.remoteFiles.count else {
            finalizeInstall()
            return
        }
        currentFileIndex = index
        let file = Self.remoteFiles[index]
        let staged = stagingDirectory.appendingPathComponent(file.name)

        // A fully staged file from an earlier attempt (or one that finished
        // while Aloud was gone) is not re-downloaded, but it is hashed.
        if Self.sizeIsExact(Self.fileSize(at: staged), expected: file.expectedBytes) {
            verifyStagedFile(at: staged, index: index)
            return
        }

        #if DEBUG
        guard startsNetworkTasks else {
            fail(.interrupted)
            return
        }
        #endif
        let session = allowsCellularThisRun ? cellularSession : wifiSession
        // Consumed either way: a stale copy must never resume a later attempt.
        let resumeURL = Self.resumeDataURL(for: file.name, in: stagingDirectory)
        let resumeData = try? Data(contentsOf: resumeURL)
        try? FileManager.default.removeItem(at: resumeURL)
        let task: URLSessionDownloadTask
        if let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: file.url)
        }
        // The task carries its file's name, so a relaunch (or a callback
        // for a task this run never registered) knows what it holds.
        task.taskDescription = file.name
        track(task)
        saveRecord(fraction: inFlightProgress ?? 0)
        task.resume()
    }

    private func track(_ task: URLSessionDownloadTask) {
        let coordinator = allowsCellularThisRun ? cellularCoordinator : wifiCoordinator
        coordinator.register(taskID: task.taskIdentifier,
                             destination: stagingDirectory.appendingPathComponent(
                                Self.remoteFiles[currentFileIndex].name))
        activeTask = task
        activeTaskID = task.taskIdentifier
        activeCoordinatorID = ObjectIdentifier(coordinator)
    }

    /// The partial file survives as resume data on disk, so the next
    /// Download picks up where this one stopped.
    private func cancelKeepingResumeData(_ task: URLSessionDownloadTask) {
        let fileName = task.taskDescription ?? ""
        let staging = stagingDirectory
        task.cancel(byProducingResumeData: { data in
            if let data { ModelManager.writeResumeData(data, for: fileName, in: staging) }
        })
    }

    /// A late callback from a cancelled task must not fail or advance the
    /// run that replaced it (cancel, then Download again).
    private func isActive(_ coordinatorID: ObjectIdentifier, taskID: Int) -> Bool {
        activeCoordinatorID == coordinatorID && activeTaskID == taskID
    }

    private func clearActiveTask() {
        activeTask = nil
        activeTaskID = nil
        activeCoordinatorID = nil
    }

    private func fileFinished(stagedAt url: URL) {
        guard isInFlight else { return }
        // Its task is done; a cancel while it hashes has nothing to stop.
        clearActiveTask()
        verifyStagedFile(at: url, index: currentFileIndex)
    }

    /// Each staged file is proven before the next one starts (M3). Progress
    /// holds while it hashes; a wrong file is removed and the run fails.
    private func verifyStagedFile(at url: URL, index: Int) {
        let file = Self.remoteFiles[index]
        let generation = epoch
        let hasher = self.hasher
        let signposts = budgetSignposts
        let verify = signposts.begin(.modelVerify)
        verification = Task { [weak self] in
            let failure = await Self.checkStagedFile(file, at: url, hasher: hasher)
            signposts.end(verify)
            // A cancel, delete or new run while it hashed wins.
            guard let self, self.epoch == generation, self.isInFlight,
                  self.currentFileIndex == index else { return }
            self.verification = nil
            if let failure {
                self.fail(failure)
                return
            }
            self.completedBytes += file.expectedBytes
            self.publishProgress(bytesInFlight: 0)
            self.startTask(forFileAt: index + 1)
        }
    }

    private func fileFailed(_ failure: DownloadFailure) {
        guard isInFlight else { return }   // e.g. after an explicit cancel
        fail(failure)
    }

    /// Every stop the user didn't choose: no task and no record (resume
    /// data stays on disk), then one announcement of the card's line.
    private func fail(_ failure: DownloadFailure) {
        clearActiveTask()
        ModelDownloadRecord.clear(from: defaults)
        state = .failed(failure)
        announce(NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(failure)))
    }

    private func removeOwnedModelFiles() {
        if ownsInstallDirectory {
            for file in Self.remoteFiles {
                try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(file.name))
            }
            try? FileManager.default.removeItem(at: ModelInstallRecord.url(in: installDirectory))
            KokoroVoiceBlends.removeDerivedFiles(in: installDirectory)
        }
        state = .notInstalled
    }

    private func finalizeInstall() {
        clearActiveTask()
        let fm = FileManager.default
        do {
            for file in Self.remoteFiles {
                let staged = stagingDirectory.appendingPathComponent(file.name)
                let final = installDirectory.appendingPathComponent(file.name)
                try? fm.removeItem(at: final)
                try fm.moveItem(at: staged, to: final)
            }
            try? fm.removeItem(at: stagingDirectory)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = installDirectory
            try? directory.setResourceValues(values)
            ModelDownloadRecord.clear(from: defaults)
            // Both files hashed to their pins as they staged.
            writeInstallRecord()
            state = .installed
        } catch {
            fail(DownloadFailure.classify(error))
        }
    }

    private func publishProgress(bytesInFlight: Int64) {
        let done = completedBytes + bytesInFlight
        let fraction = min(1, Double(done) / Double(Self.totalExpectedBytes))
        setInFlight(progress: fraction)
        // Often enough that a relaunch shows about where it was, seldom
        // enough to stay off the disk.
        if fraction - recordedFraction >= 0.01 { saveRecord(fraction: fraction) }
    }

    private func setInFlight(progress: Double) {
        let next = Self.inFlightState(progress: progress, allowsCellular: allowsCellularThisRun,
                                      wifiAvailable: pathSource.allowsWiFiOnlyTransfer)
        let wasWaiting: Bool
        if case .waitingForWiFi = state { wasWaiting = true } else { wasWaiting = false }
        state = next
        if case .waitingForWiFi = next, !wasWaiting {
            announce(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi))
        }
    }

    /// The path changed: a Wi-Fi-only download waits, or resumes, honestly.
    private func refreshInFlightState() {
        guard let progress = inFlightProgress else { return }
        setInFlight(progress: progress)
    }

    private func saveRecord(fraction: Double) {
        recordedFraction = fraction
        ModelDownloadRecord(directory: installDirectory, allowsCellular: allowsCellularThisRun,
                            fileIndex: currentFileIndex, fraction: fraction).save(to: defaults)
    }

    // MARK: - Relaunch

    /// After a relaunch mid-download: shows the saved progress at once, then
    /// adopts the background session's task for the current file, or starts
    /// that file again (from its resume data when there is some).
    private func reattachIfNeeded() {
        guard let record = ModelDownloadRecord.load(from: defaults, directory: installDirectory),
              Self.remoteFiles.indices.contains(record.fileIndex) else { return }
        watchPath()
        allowsCellularThisRun = record.allowsCellular
        currentFileIndex = record.fileIndex
        completedBytes = Self.remoteFiles[..<record.fileIndex].reduce(0) { $0 + $1.expectedBytes }
        recordedFraction = record.fraction
        setInFlight(progress: min(max(record.fraction, 0), 1))

        let fileIndex = record.fileIndex
        let fileName = Self.remoteFiles[fileIndex].name
        let session = allowsCellularThisRun ? cellularSession : wifiSession
        session.getAllTasks { [weak self] tasks in
            let task = tasks.lazy
                .compactMap { $0 as? URLSessionDownloadTask }
                .first { $0.taskDescription == fileName && ($0.state == .running || $0.state == .suspended) }
            Task { @MainActor [weak self] in
                self?.finishReattach(adopting: task, fileIndex: fileIndex)
            }
        }
    }

    private func finishReattach(adopting task: URLSessionDownloadTask?, fileIndex: Int) {
        // A cancel, delete or new run while the session answered wins.
        guard isInFlight, activeTask == nil, currentFileIndex == fileIndex else {
            if let task { cancelKeepingResumeData(task) }
            return
        }
        guard let task else {
            startTask(forFileAt: fileIndex)
            return
        }
        track(task)
        let expected = Self.remoteFiles[fileIndex].expectedBytes
        publishProgress(bytesInFlight: min(task.countOfBytesReceived, expected))
        task.resume()
    }

    private func wireCoordinator(_ coordinator: DownloadCoordinator) {
        let source = ObjectIdentifier(coordinator)
        coordinator.onProgress = { [weak self] taskID, written in
            Task { @MainActor [weak self] in
                guard let self, self.isActive(source, taskID: taskID), self.isInFlight else { return }
                let expected = Self.remoteFiles[self.currentFileIndex].expectedBytes
                self.publishProgress(bytesInFlight: min(written, expected))
            }
        }
        coordinator.onSuccess = { [weak self] taskID, stagedURL in
            Task { @MainActor [weak self] in
                guard let self, self.isActive(source, taskID: taskID) else { return }
                self.fileFinished(stagedAt: stagedURL)
            }
        }
        coordinator.onFailure = { [weak self] taskID, failure in
            Task { @MainActor [weak self] in
                guard let self, self.isActive(source, taskID: taskID) else { return }
                self.fileFailed(failure)
            }
        }
    }

    // MARK: - Network, on first use (M4)

    /// How long the first Download's answer waits for the path it just
    /// started watching. The first path usually lands within milliseconds.
    private static let firstPathWait: Duration = .milliseconds(250)

    /// Starts the path source once. Reached from a Download, a reattach
    /// after relaunch, or a `sharedNetworkPath` started by a surface that
    /// shows one could start, so a launch with no record never watches.
    private func watchPath() {
        pathHub.start()
    }

    /// The download's own path for a surface that says whether a Download
    /// could start (M17: the Mac's card and R5's offer), so the process
    /// watches one path, never a second monitor beside this one (M4). It
    /// reads this path, its `start` is `watchPath`, and its change handler
    /// is its own, called after this manager has heard the change. Building
    /// it watches nothing. Watching opens no socket: the sessions are still
    /// made only by a Download or a reattach.
    func sharedNetworkPath() -> any NetworkPathSource {
        SharedNetworkPath(hub: pathHub)
    }

    /// Holds the Download asked before the first path, for the path to
    /// answer. A second tap meanwhile only moves the prompt to its surface.
    private func awaitFirstPath(asker: UUID?) {
        let isFirst = pendingRequest == nil
        pendingRequest = (asker, epoch)
        guard isFirst else { return }
        // Past the wait the path still reads unknown, the safe direction
        // (see `SystemNetworkPath.isExpensiveOrConstrained`): the Wi-Fi-only
        // download starts, which never moves a byte on a costly network.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstPathWait)
            self?.answerPendingRequest()
        }
    }

    /// The first path landed, or the wait for it ran out: the Download asked
    /// meanwhile is answered as `requestDownload` answers a known path. A
    /// detection, cancel or delete since, or a download already under way,
    /// drops it.
    private func answerPendingRequest() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        guard request.epoch == epoch, !isVerifying else { return }
        switch state {
        case .downloading, .waitingForWiFi, .installed: return
        case .notInstalled, .failed: break
        }
        if pathSource.isExpensiveOrConstrained {
            cellularQuestion = CellularQuestion(asker: request.asker)
        } else {
            startDownload(allowingCellular: false)
        }
    }

    /// Made on first use by the lazy `wifiSession` and `cellularSession`,
    /// so only a started or reattached download creates one.
    private func makeSession(allowingCellular: Bool) -> URLSession {
        #if DEBUG
        hasCreatedSession = true
        #endif
        return URLSession(configuration: Self.sessionConfiguration(allowingCellular: allowingCellular),
                          delegate: allowingCellular ? cellularCoordinator : wifiCoordinator,
                          delegateQueue: nil)
    }

    // MARK: - Helpers

    nonisolated private static func stagingDirectory(in installDirectory: URL) -> URL {
        installDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    nonisolated private static func resumeDataURL(for fileName: String, in staging: URL) -> URL {
        staging.appendingPathComponent(fileName + ".resume")
    }

    /// The model file a task description names; nil for anything else, so
    /// no callback can write outside the two known names.
    nonisolated fileprivate static func modelFileName(_ description: String?) -> String? {
        remoteFiles.first { $0.name == description }?.name
    }

    /// Never creates the staging directory: after Remove, a late callback
    /// must not bring it back.
    nonisolated fileprivate static func writeResumeData(_ data: Data, for fileName: String, in staging: URL) {
        guard let name = modelFileName(fileName) else { return }
        try? data.write(to: resumeDataURL(for: name, in: staging), options: .atomic)
    }

    /// The pinned file has one size (M3); ±5% once let a different file in.
    nonisolated private static func sizeIsExact(_ size: Int64, expected: Int64) -> Bool {
        size == expected
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }
}

// MARK: - Download record

/// What a relaunch needs to reattach to an in-flight download (R21): saved
/// at each task start and every 1% of progress, cleared on install, cancel,
/// delete and failure.
struct ModelDownloadRecord: Codable, Equatable {

    static let key = "aloud.naturalVoice.download.v1"

    /// The install directory's path: a record reattaches only the directory
    /// it was written for.
    let directory: String
    let allowsCellular: Bool
    let fileIndex: Int
    let fraction: Double

    init(directory: URL, allowsCellular: Bool, fileIndex: Int, fraction: Double) {
        self.directory = directory.standardizedFileURL.path
        self.allowsCellular = allowsCellular
        self.fileIndex = fileIndex
        self.fraction = fraction
    }

    /// Nil for another directory or anything undecodable.
    static func load(from defaults: UserDefaults, directory: URL) -> ModelDownloadRecord? {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(ModelDownloadRecord.self, from: data),
              record.directory == directory.standardizedFileURL.path else { return nil }
        return record
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Install record

/// What a verified install looked like on disk (M3), kept beside the files
/// as `install.json`. A launch trusts a file the record still vouches for
/// after one `stat`, and never reads 353 MB to find out. A copy, a restore
/// or a touch changes the file's inode or mtime, and that file is hashed
/// again.
struct ModelInstallRecord: Codable, Equatable {

    static let fileName = "install.json"

    struct File: Codable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
        let inode: UInt64
        /// Nanoseconds since 1970, so a touch within the same second counts.
        let mtime: Int64
    }

    let revision: String
    let files: [File]

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// The record for the pinned files as they sit in `directory` now; nil
    /// if one is missing. Only written once both hashed to their pins.
    static func current(in directory: URL) -> ModelInstallRecord? {
        var files: [File] = []
        for remote in ModelManager.remoteFiles {
            guard let entry = entry(for: remote, in: directory) else { return nil }
            files.append(entry)
        }
        return ModelInstallRecord(revision: ModelManager.revision, files: files)
    }

    /// `remote`'s entry as it would be recorded now, from one `stat`.
    static func entry(for remote: ModelManager.RemoteFile, in directory: URL) -> File? {
        stamp(at: directory.appendingPathComponent(remote.name), name: remote.name, sha256: remote.sha256)
    }

    /// The file at `url` as it sits now, from one `stat`, recorded with the
    /// hash `sha256` (taken on trust: the caller hashed it, or pinned it).
    static func stamp(at url: URL, name: String, sha256: String) -> File? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        guard result == 0,
              let mtime = nanoseconds(seconds: Int64(info.st_mtimespec.tv_sec),
                                      nanoseconds: Int64(info.st_mtimespec.tv_nsec)) else { return nil }
        return File(name: name, bytes: Int64(info.st_size), sha256: sha256,
                    inode: UInt64(info.st_ino), mtime: mtime)
    }

    /// A file time in nanoseconds, or nil when it doesn't fit: APFS clamps
    /// a time before 1677 to Int64.min nanoseconds, whose seconds overflow
    /// the product. Nil means the record vouches for nothing, so the file
    /// is hashed again; never a trap at launch.
    static func nanoseconds(seconds: Int64, nanoseconds: Int64) -> Int64? {
        let (scaled, overflowedScale) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (total, overflowedSum) = scaled.addingReportingOverflow(nanoseconds)
        return overflowedScale || overflowedSum ? nil : total
    }

    /// True while `remote` is still the file this record verified: the
    /// pinned revision and hash, and the same size, inode and mtime.
    func vouches(for remote: ModelManager.RemoteFile, in directory: URL) -> Bool {
        guard revision == ModelManager.revision,
              let recorded = files.first(where: { $0.name == remote.name }),
              recorded.sha256 == remote.sha256,
              recorded.bytes == remote.expectedBytes else { return false }
        return Self.entry(for: remote, in: directory) == recorded
    }

    /// Nil when missing or undecodable: the files are hashed again.
    static func load(from directory: URL) -> ModelInstallRecord? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(ModelInstallRecord.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }
}

// MARK: - One network path

/// One path's start and its watchers (M4): the source starts once,
/// whichever watcher asks first, and each change reaches every watcher in
/// the order they were added. Called on any queue.
private final class NetworkPathHub: @unchecked Sendable {

    let source: any NetworkPathSource
    private let lock = NSLock()
    private var started = false
    private var watchers: [@Sendable () -> Void] = []

    init(source: any NetworkPathSource) {
        self.source = source
        source.setChangeHandler { [weak self] in self?.changed() }
    }

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func addWatcher(_ watcher: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        watchers.append(watcher)
    }

    /// Outside the lock: a fixed path, or a monitor's first update, may
    /// call back inside `start`.
    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        if first { source.start() }
    }

    private func changed() {
        lock.lock()
        let watchers = self.watchers
        lock.unlock()
        for watcher in watchers { watcher() }
    }
}

/// `ModelManager.sharedNetworkPath`: the hub's path, read and started
/// through it, with a change handler of its own.
private final class SharedNetworkPath: NetworkPathSource, @unchecked Sendable {

    private let hub: NetworkPathHub
    private let lock = NSLock()
    private var changeHandler: (@Sendable () -> Void)?

    init(hub: NetworkPathHub) {
        self.hub = hub
        hub.addWatcher { [weak self] in self?.changed() }
    }

    var isExpensiveOrConstrained: Bool { hub.source.isExpensiveOrConstrained }
    var allowsWiFiOnlyTransfer: Bool { hub.source.allowsWiFiOnlyTransfer }
    var hasPath: Bool { hub.source.hasPath }

    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        changeHandler = handler
    }

    func start() {
        hub.start()
    }

    private func changed() {
        lock.lock()
        let handler = changeHandler
        lock.unlock()
        handler?()
    }
}

// MARK: - URLSession delegate bridge

/// Non-isolated delegate for the background session. Moves each finished
/// download into its registered destination synchronously (the temp file dies
/// when the delegate method returns), then reports back on the main actor.
/// Reports classified failures only, never an error's text.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    var onProgress: (@Sendable (_ taskID: Int, _ bytesWritten: Int64) -> Void)?
    var onSuccess: (@Sendable (_ taskID: Int, _ stagedURL: URL) -> Void)?
    var onFailure: (@Sendable (_ taskID: Int, _ failure: ModelManager.DownloadFailure) -> Void)?

    /// Where tasks this run never registered stage their files and resume
    /// data, by file name (a relaunch delivers the previous run's events).
    private let stagingDirectory: URL

    private let lock = NSLock()
    private var destinations: [Int: URL] = [:]
    private var lastReported: [Int: Int64] = [:]

    init(stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
    }

    func register(taskID: Int, destination: URL) {
        lock.lock(); defer { lock.unlock() }
        destinations[taskID] = destination
        lastReported[taskID] = 0
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        lock.lock()
        let last = lastReported[id] ?? 0
        let shouldReport = totalBytesWritten - last >= 2_000_000
        if shouldReport { lastReported[id] = totalBytesWritten }
        lock.unlock()
        if shouldReport { onProgress?(id, totalBytesWritten) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        lock.lock()
        let registered = destinations.removeValue(forKey: id)
        lastReported.removeValue(forKey: id)
        lock.unlock()
        // A file finished while Aloud was gone still stages, so the next
        // attempt skips it.
        let unregistered = ModelManager.modelFileName(downloadTask.taskDescription)
            .map { stagingDirectory.appendingPathComponent($0) }
        guard let destination = registered ?? unregistered else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            onFailure?(id, .interrupted)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onSuccess?(id, destination)
        } catch {
            onFailure?(id, .classify(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        lock.lock()
        destinations.removeValue(forKey: id)
        lastReported.removeValue(forKey: id)
        lock.unlock()
        // Whichever run started the task, its partial file is kept for the
        // next attempt.
        if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let fileName = task.taskDescription {
            ModelManager.writeResumeData(resume, for: fileName, in: stagingDirectory)
        }
        onFailure?(id, .classify(error))
    }
}

// MARK: - Offline (DEBUG)

#if DEBUG
/// `-uitest-offline`, as on a plane: every network request fails at once
/// with "not connected to the internet", before a lookup, a socket or a
/// byte, while a file or data URL still loads. The download's sessions
/// carry it, and it is registered for any other loading in the process. A
/// background session runs outside the process and ignores protocol
/// classes, so an offline launch's sessions are in-process and ephemeral.
/// Release has no such class and no such launch.
final class OfflineURLProtocol: URLProtocol {

    /// Registered once, and only for an offline launch.
    private static let registration: Void = {
        if UITestHooks.offline { URLProtocol.registerClass(OfflineURLProtocol.self) }
    }()

    static func registerIfOffline() {
        _ = registration
    }

    /// The download's configuration with this protocol alone, so no network
    /// request reaches a built-in loader. The cost rules match the live
    /// sessions'.
    static func sessionConfiguration(allowingCellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.allowsExpensiveNetworkAccess = allowingCellular
        config.allowsConstrainedNetworkAccess = allowingCellular
        config.protocolClasses = [OfflineURLProtocol.self]
        return config
    }

    /// Registered for the whole process, so it takes only what would leave
    /// the device: a refused file or data URL would fail a check that a real
    /// plane passes.
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return true }
        return !localSchemes.contains(scheme)
    }

    private static let localSchemes: Set<String> = ["file", "data"]

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    /// Nothing started, so nothing to stop.
    override func stopLoading() {}
}
#endif
