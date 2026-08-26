import Combine
import Foundation

/// Owns the on-device Kokoro model files (`model.onnx` + `voices.bin`):
/// detection, resumable background download from Hugging Face, size sanity
/// checks, and deletion. Files live in Application Support/KokoroModel,
/// excluded from backup (they are re-downloadable).
///
/// Dev/test seeding: copy both files into the container's
/// Application Support/KokoroModel/ — `detectExisting()` (run at init)
/// flips the state to `.installed`.
@MainActor
final class ModelManager: ObservableObject {

    enum ModelState: Equatable {
        case notInstalled
        case downloading(Double)   // combined 0…1 across both files
        case installed
        case failed(String)
    }

    struct RemoteFile {
        let name: String
        let url: URL
        let expectedBytes: Int64
    }

    static let remoteFiles: [RemoteFile] = [
        RemoteFile(
            name: "model.onnx",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/main/model.onnx")!,
            expectedBytes: 326_000_000),
        RemoteFile(
            name: "voices.bin",
            url: URL(string: "https://huggingface.co/csukuangfj/kokoro-multi-lang-v1_0/resolve/main/voices.bin")!,
            expectedBytes: 26_500_000),
    ]

    static let downloadSizeLabel = "333 MB"

    /// Kokoro fp32 peaks near 800 MB of RAM — only offer the install on
    /// ~6 GB-or-more devices. Simulators inherit the Mac's memory and pass.
    nonisolated static var deviceSupportsNeuralVoice: Bool {
        ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
    }

    // MARK: - State

    @Published private(set) var state: ModelState = .notInstalled

    let installDirectory: URL

    var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    var sizeOnDisk: Int64 {
        Self.remoteFiles.reduce(0) { sum, file in
            sum + Self.fileSize(at: installDirectory.appendingPathComponent(file.name))
        }
    }

    // MARK: - Private state

    private let coordinator = DownloadCoordinator()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.davidxie.aloud.kokoro-model")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = false
        return URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
    }()

    private var activeTask: URLSessionDownloadTask?
    private var currentFileIndex = 0
    private var completedBytes: Int64 = 0
    private var resumeData: [String: Data] = [:]

    private var stagingDirectory: URL {
        installDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    // MARK: - Init

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        var directory = support.appendingPathComponent("KokoroModel", isDirectory: true)
        // UI-test hook (no-op in Release): `-uitest-kokoro-model-path <dir>`
        // points at a directory that already holds model.onnx + voices.bin
        // (e.g. on the host Mac, which the simulator sandbox can read), so
        // tests never download.
        if let override = UITestHooks.kokoroModelPath {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        }
        installDirectory = directory
        wireCoordinator()
        detectExisting()
    }

    /// Both files present on disk (any nonzero size) → installed. Presence,
    /// not size, so dev seeding with local copies just works.
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

    func startDownload() {
        switch state {
        case .downloading, .installed: return
        case .notInstalled, .failed: break
        }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        completedBytes = 0
        state = .downloading(0)
        startTask(forFileAt: 0)
    }

    func cancelDownload() {
        guard case .downloading = state else { return }
        let fileName = Self.remoteFiles[currentFileIndex].name
        activeTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                if let data { self?.resumeData[fileName] = data }
            }
        })
        activeTask = nil
        state = .notInstalled
    }

    func deleteModel() {
        if case .downloading = state { cancelDownload() }
        resumeData = [:]
        try? FileManager.default.removeItem(at: installDirectory)
        state = .notInstalled
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

        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: file.name) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: file.url)
        }
        coordinator.register(taskID: task.taskIdentifier, destination: staged)
        activeTask = task
        task.resume()
    }

    private func fileFinished(stagedAt url: URL) {
        guard case .downloading = state else { return }
        let file = Self.remoteFiles[currentFileIndex]
        let size = Self.fileSize(at: url)
        guard Self.sizeIsSane(size, expected: file.expectedBytes) else {
            try? FileManager.default.removeItem(at: url)
            state = .failed("The downloaded file looks incomplete. Please try again.")
            return
        }
        completedBytes += file.expectedBytes
        publishProgress(bytesInFlight: 0)
        startTask(forFileAt: currentFileIndex + 1)
    }

    private func fileFailed(message: String, resume: Data?) {
        guard case .downloading = state else { return }   // e.g. after an explicit cancel
        if let resume {
            resumeData[Self.remoteFiles[currentFileIndex].name] = resume
        }
        activeTask = nil
        state = .failed(message)
    }

    private func finalizeInstall() {
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
            activeTask = nil
            resumeData = [:]
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func publishProgress(bytesInFlight: Int64) {
        let total = Self.remoteFiles.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let done = completedBytes + bytesInFlight
        state = .downloading(min(1, Double(done) / Double(total)))
    }

    private func wireCoordinator() {
        coordinator.onProgress = { [weak self] _, written in
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.state else { return }
                let expected = Self.remoteFiles[self.currentFileIndex].expectedBytes
                self.publishProgress(bytesInFlight: min(written, expected))
            }
        }
        coordinator.onSuccess = { [weak self] _, stagedURL in
            Task { @MainActor [weak self] in
                self?.fileFinished(stagedAt: stagedURL)
            }
        }
        coordinator.onFailure = { [weak self] _, message, resume in
            Task { @MainActor [weak self] in
                self?.fileFailed(message: message, resume: resume)
            }
        }
    }

    // MARK: - Helpers

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

// MARK: - URLSession delegate bridge

/// Non-isolated delegate for the background session. Moves each finished
/// download into its registered destination synchronously (the temp file dies
/// when the delegate method returns), then reports back on the main actor.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    var onProgress: (@Sendable (_ taskID: Int, _ bytesWritten: Int64) -> Void)?
    var onSuccess: (@Sendable (_ taskID: Int, _ stagedURL: URL) -> Void)?
    var onFailure: (@Sendable (_ taskID: Int, _ message: String, _ resumeData: Data?) -> Void)?

    private let lock = NSLock()
    private var destinations: [Int: URL] = [:]
    private var lastReported: [Int: Int64] = [:]

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
        let destination = destinations.removeValue(forKey: id)
        lastReported.removeValue(forKey: id)
        lock.unlock()
        guard let destination else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            onFailure?(id, "Server error (\(http.statusCode)).", nil)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onSuccess?(id, destination)
        } catch {
            onFailure?(id, error.localizedDescription, nil)
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
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        onFailure?(id, nsError.localizedDescription, resume)
    }
}
