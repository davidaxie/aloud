import Combine
import Foundation
import UIKit

/// Owns the on-device Kokoro model files (`model.onnx` + `voices.bin`):
/// detection, resumable background download from Hugging Face, size sanity
/// checks, and deletion. Files live in Application Support/KokoroModel,
/// excluded from backup (they are re-downloadable).
///
/// The download is Wi-Fi only unless the user confirms cellular (R5):
/// `requestDownload()` asks first on an expensive or constrained path, and
/// only `startDownload(allowingCellular: true)` uses the cellular session.
///
/// The download can't leave the user stuck (R21): free space of twice the
/// download is checked before anything is created or sent; resume data is
/// kept on disk beside the staged files; a record lets a relaunch reattach
/// to the background session and show its progress at once; and every stop
/// is one of three classified failures, announced, never an error's text.
///
/// Dev/test seeding: copy both files into the container's
/// Application Support/KokoroModel/ — `detectExisting()` (run at init)
/// flips the state to `.installed`.
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
        let expectedBytes: Int64
    }

    nonisolated static let remoteFiles: [RemoteFile] = [
        RemoteFile(
            name: "model.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/main/model.onnx")!,
            expectedBytes: 326_000_000),
        RemoteFile(
            name: "voices.bin",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/main/voices.bin")!,
            expectedBytes: 26_500_000),
    ]

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
    }

    /// R21: twice the download (705 MB), so the staged files and the final
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

    /// The engine's load-time check (R21): both files within ±5% of their
    /// expected size. Detection stays presence-based; this catches the rest.
    nonisolated static func installedFilesLookIntact(in directory: URL) -> Bool {
        remoteFiles.allSatisfy { file in
            sizeIsSane(fileSize(at: directory.appendingPathComponent(file.name)),
                       expected: file.expectedBytes)
        }
    }

    /// A Wi-Fi-only download with no Wi-Fi is waiting, not downloading.
    nonisolated static func inFlightState(progress: Double, allowsCellular: Bool,
                                          wifiAvailable: Bool) -> ModelState {
        allowsCellular || wifiAvailable ? .downloading(progress) : .waitingForWiFi(progress)
    }

    /// Two background sessions rather than one toggled config: a background
    /// session's configuration is fixed at creation, and the Wi-Fi-only one
    /// must never be able to touch cellular.
    nonisolated static func sessionConfiguration(allowingCellular: Bool) -> URLSessionConfiguration {
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

    nonisolated static func defaultPathSource() -> any NetworkPathSource {
        if UITestHooks.forceExpensiveNetwork {
            return FixedNetworkPath(isExpensiveOrConstrained: true)
        }
        return SystemNetworkPath()
    }

    // MARK: - State

    @Published private(set) var state: ModelState = .notInstalled

    let installDirectory: URL

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    var isInFlight: Bool { inFlightProgress != nil }

    var sizeOnDisk: Int64 {
        Self.remoteFiles.reduce(0) { sum, file in
            sum + Self.fileSize(at: installDirectory.appendingPathComponent(file.name))
        }
    }

    var hasActiveTask: Bool { activeTask != nil }

    /// Says what the user didn't ask for: entering `.waitingForWiFi`, and
    /// every failure. Tests replace it.
    var announce: (String) -> Void = { ModelManager.postAnnouncement($0) }

    /// Queued, so it never cuts off VoiceOver; never posted in a muted
    /// (test) process.
    static func postAnnouncement(_ text: String) {
        guard !UITestHooks.muteAudio else { return }
        UIAccessibility.post(notification: .announcement,
                             argument: NSAttributedString(string: text, attributes: [
                                 .accessibilitySpeechQueueAnnouncement: true,
                             ]))
    }

    // MARK: - Private state

    private let pathSource: any NetworkPathSource
    private let defaults: UserDefaults
    private let freeSpace: @Sendable () -> Int64?

    /// False for a `-uitest-kokoro-model-path` override: those files belong
    /// to the host, so Remove never deletes them.
    private let ownsInstallDirectory: Bool

    private let wifiCoordinator: DownloadCoordinator
    private let cellularCoordinator: DownloadCoordinator
    private lazy var wifiSession = URLSession(
        configuration: Self.sessionConfiguration(allowingCellular: false),
        delegate: wifiCoordinator, delegateQueue: nil)
    private lazy var cellularSession = URLSession(
        configuration: Self.sessionConfiguration(allowingCellular: true),
        delegate: cellularCoordinator, delegateQueue: nil)

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
    /// real (or hook-chosen) directory, standard defaults and the real free
    /// space; tests pass their own.
    init(pathSource: any NetworkPathSource = ModelManager.defaultPathSource(),
         installDirectory explicit: URL? = nil,
         defaults: UserDefaults = .standard,
         freeSpace: @escaping @Sendable () -> Int64? = { ModelManager.defaultFreeSpace() }) {
        self.pathSource = pathSource
        self.defaults = defaults
        self.freeSpace = freeSpace
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
        pathSource.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in self?.refreshInFlightState() }
        }
        detectExisting()
        if Self.shouldReattach(hasExplicitDirectory: explicit != nil, ownsDirectory: owns,
                               isUITestLaunch: UITestHooks.isUITestLaunch,
                               isXCTestHost: NSClassFromString("XCTestCase") != nil,
                               isInstalled: isInstalled) {
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
    /// that read as installed until the engine checks their size. Only this
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

    /// Both files present on disk (any nonzero size) → installed. Presence,
    /// not size, so dev seeding with local copies just works; a damaged
    /// install is caught when the engine loads it (R21).
    func detectExisting() {
        let present = Self.remoteFiles.allSatisfy { file in
            Self.fileSize(at: installDirectory.appendingPathComponent(file.name)) > 0
        }
        if present {
            state = .installed
        } else if case .installed = state {
            state = .notInstalled
        }
    }

    // MARK: - Download

    /// Every Download button's entry point. Too little space fails at once,
    /// creating nothing. On cellular or Low Data Mode it asks first and
    /// sends nothing — no staging directory, no task — until the user
    /// confirms through `startDownload(allowingCellular: true)`.
    @discardableResult
    func requestDownload() -> DownloadRequest {
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
            fail(.notEnoughSpace)
            return .notEnoughSpace
        }
        // There is room now, so the space line would be stale under the prompt.
        if state == .failed(.notEnoughSpace) { state = .notInstalled }
        if pathSource.isExpensiveOrConstrained { return .needsCellularConfirmation }
        startDownload(allowingCellular: false)
        return .started
    }

    func startDownload(allowingCellular: Bool = false) {
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
        do {
            try FileManager.default.createDirectory(at: stagingDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            fail(DownloadFailure.classify(error))
            return
        }
        completedBytes = 0
        setInFlight(progress: 0)
        startTask(forFileAt: 0)
    }

    func cancelDownload() {
        guard isInFlight else { return }
        if let activeTask { cancelKeepingResumeData(activeTask) }
        clearActiveTask()
        ModelDownloadRecord.clear(from: defaults)
        state = .notInstalled
    }

    func deleteModel() {
        if isInFlight { cancelDownload() }
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

        // A fully staged file from an earlier attempt is not re-downloaded.
        if Self.sizeIsSane(Self.fileSize(at: staged), expected: file.expectedBytes) {
            completedBytes += file.expectedBytes
            publishProgress(bytesInFlight: 0)
            startTask(forFileAt: index + 1)
            return
        }

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
        let file = Self.remoteFiles[currentFileIndex]
        guard Self.sizeIsSane(Self.fileSize(at: url), expected: file.expectedBytes) else {
            try? FileManager.default.removeItem(at: url)
            fail(.interrupted)
            return
        }
        completedBytes += file.expectedBytes
        publishProgress(bytesInFlight: 0)
        startTask(forFileAt: currentFileIndex + 1)
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

    /// Within ±5% of the expected size (ports the `download_models.py` check).
    nonisolated private static func sizeIsSane(_ size: Int64, expected: Int64) -> Bool {
        size > 0 && abs(size - expected) <= expected / 20
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
