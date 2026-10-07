import Combine
import Foundation

/// R5: offer the natural voice after the first minute of listening, never
/// before. Counts cumulative `.playing` time across launches, and shows the
/// offer until it is answered: by Not now, by a download starting from any
/// surface, or by the model already being installed. An answer is never
/// cleared, so a later Remove never brings the offer back.
///
/// On the Mac (M17) it also knows whether a download could start: with no
/// usable network path the offer hides, since it could only fail, and comes
/// back unanswered when a path returns; the card disables its Download. The
/// path is the download's own (`ModelManager.sharedNetworkPath`), so the
/// process watches one, and only once there is a download to offer.
@MainActor
final class NaturalVoiceOffer: ObservableObject {

    enum Answer: String {
        case download, notNow
    }

    nonisolated static let listenThreshold: TimeInterval = 60

    enum Key {
        static let listenedSeconds = "aloud.naturalVoice.listenedSeconds.v1"
        static let answer = "aloud.naturalVoice.offerAnswer.v1"
    }

    @Published private(set) var isVisible = false
    /// Whether a download could reach the network: nil until the watch's
    /// first path lands, and always nil on the iPhone, which never watches
    /// here.
    @Published private(set) var hasUsablePath: Bool?
    /// A path landed and no download can use it: the Mac card's offline state.
    var isOffline: Bool { hasUsablePath == false }
    private(set) var listenedSeconds: TimeInterval
    private(set) var answer: Answer?

    private let defaults: UserDefaults
    private let deviceSupported: Bool
    private let now: () -> TimeInterval
    /// The download's path, from `attach` on the Mac (or a test's own);
    /// nil on the iPhone and in a hosted test.
    private var pathSource: (any NetworkPathSource)?
    /// Whether `attach` adopts the download's path.
    private let adoptsDownloadPath: Bool
    private var isWatchingPath = false

    /// When the open `.playing` interval began; nil while not playing.
    private var playingSince: TimeInterval?
    /// The last model state seen. Nil until attach, so the offer stays hidden
    /// until we know the model isn't installed.
    private var modelState: ModelManager.ModelState?
    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard,
         deviceSupported: Bool = ModelManager.deviceSupportsNeuralVoice,
         now: @escaping () -> TimeInterval = { MonotonicClock.now },
         pathSource: (any NetworkPathSource)? = nil,
         watchesDownloadPath: Bool = NaturalVoiceOffer.watchesDownloadPath()) {
        #if DEBUG
        if UITestHooks.resetNaturalVoiceOffer {
            defaults.removeObject(forKey: Key.listenedSeconds)
            defaults.removeObject(forKey: Key.answer)
        }
        if let seconds = UITestHooks.listenedSeconds {
            defaults.set(min(max(seconds, 0), Self.listenThreshold), forKey: Key.listenedSeconds)
        }
        #endif
        self.defaults = defaults
        self.deviceSupported = deviceSupported
        self.now = now
        adoptsDownloadPath = watchesDownloadPath
        listenedSeconds = min(max(defaults.double(forKey: Key.listenedSeconds), 0), Self.listenThreshold)
        answer = Answer(rawValue: defaults.string(forKey: Key.answer) ?? "")
        if let pathSource { use(pathSource) }
    }

    /// The Mac's app watches the download's path (`-uitest-offline`
    /// included). The iPhone doesn't, and neither does a hosted unit test,
    /// so no test ever starts a live monitor: tests pass a path of their own.
    nonisolated static func watchesDownloadPath(
        preparesForFlight: Bool = PlatformVoiceSetup.preparesForFlight,
        isXCTestHost: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        preparesForFlight && !isXCTestHost
    }

    /// A known path a download can use: satisfied, costly or not (a costly
    /// one asks first). Nil before the first path lands.
    nonisolated static func hasUsablePath(_ source: any NetworkPathSource) -> Bool? {
        guard source.hasPath else { return nil }
        return source.allowsWiFiOnlyTransfer || source.isExpensiveOrConstrained
    }

    /// Starts the Mac's path watch once: from a not-installed card, or an
    /// offer that would show. Does nothing on the iPhone.
    func watchNetworkPath() {
        guard let pathSource, !isWatchingPath else { return }
        isWatchingPath = true
        pathSource.start()
        // A fixed path is known at once and never calls back.
        pathChanged()
    }

    func attach(playback: PlaybackController, modelManager: ModelManager) {
        // Adopted, not started: the card or the 60 s mark starts it.
        if pathSource == nil, adoptsDownloadPath { use(modelManager.sharedNetworkPath()) }
        cancellables.removeAll()
        playback.$status
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.playbackStatusChanged($0) }
            .store(in: &cancellables)
        // Each new sentence folds the running interval in, so the 60 s mark
        // lands mid-book rather than at the next pause.
        playback.$currentSentence
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.heartbeat() }
            .store(in: &cancellables)
        modelManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.modelStateChanged($0) }
            .store(in: &cancellables)
        // Persist before a possible termination in the background.
        PlatformLifecycle.publisher(for: .didEnterBackground)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.heartbeat() }
            .store(in: &cancellables)
    }

    func notNow() {
        record(.notNow)
    }

    /// Closes any open listening interval, then opens one only for
    /// `.playing`: buffering, paused and error time never count.
    func playbackStatusChanged(_ status: PlayerStatus) {
        foldOpenInterval()
        playingSince = status == .playing ? now() : nil
        refresh()
    }

    /// Folds the open interval in and restarts it.
    func heartbeat() {
        guard playingSince != nil else { return }
        foldOpenInterval()
        playingSince = now()
        refresh()
    }

    func modelStateChanged(_ state: ModelManager.ModelState) {
        modelState = state
        // A download started from any surface answers the offer (waiting
        // for Wi-Fi is one in flight), and so does a model found installed.
        // A cancelled download stays answered.
        switch state {
        case .downloading, .waitingForWiFi, .installed:
            if answer == nil { record(.download) }
        case .notInstalled, .failed:
            break
        }
        refresh()
    }

    /// A Download that found too little space leaves the offer up: its row
    /// carries the space message and Download checks again (R21). The Mac
    /// passes what its path watch knows, so an unknown or unusable path
    /// keeps the offer down; the iPhone never gates on the path.
    nonisolated static func isVisible(listenedSeconds: TimeInterval,
                                      answer: Answer?,
                                      deviceSupported: Bool,
                                      modelState: ModelManager.ModelState,
                                      usablePath: Bool? = true) -> Bool {
        deviceSupported
            && answer == nil
            && (modelState == .notInstalled || modelState == .failed(.notEnoughSpace))
            && listenedSeconds >= listenThreshold
            && usablePath == true
    }

    // MARK: - Private

    private func foldOpenInterval() {
        guard let start = playingSince else { return }
        let delta = max(0, now() - start)
        playingSince = nil
        guard listenedSeconds < Self.listenThreshold else { return }
        listenedSeconds = min(listenedSeconds + delta, Self.listenThreshold)
        defaults.set(listenedSeconds, forKey: Key.listenedSeconds)
    }

    private func record(_ newAnswer: Answer) {
        answer = newAnswer
        defaults.set(newAnswer.rawValue, forKey: Key.answer)
        refresh()
    }

    private func use(_ source: any NetworkPathSource) {
        pathSource = source
        source.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in self?.pathChanged() }
        }
    }

    private func pathChanged() {
        guard let pathSource else { return }
        let usable = Self.hasUsablePath(pathSource)
        if usable != hasUsablePath { hasUsablePath = usable }
        refresh()
    }

    /// Never depends on scene phase: a phone locked at the 60 s mark shows
    /// the offer at the next unlock. On the Mac, the first time the offer
    /// would show is when its path starts being watched; it shows once a
    /// usable path lands (milliseconds, online).
    private func refresh() {
        guard let modelState else {
            if isVisible { isVisible = false }
            return
        }
        func visible(usablePath: Bool?) -> Bool {
            Self.isVisible(listenedSeconds: listenedSeconds, answer: answer, deviceSupported: deviceSupported,
                           modelState: modelState, usablePath: usablePath)
        }
        // Read after the watch starts: a fixed path lands inside it.
        if visible(usablePath: true) { watchNetworkPath() }
        let shown = visible(usablePath: pathSource == nil ? true : hasUsablePath)
        if shown != isVisible { isVisible = shown }
    }
}

/// The natural voice's copy, in one place so every surface reads the same.
/// The voice-switch notices live with R11's other copy in PlaybackNotice.
enum NaturalVoiceCopy {
    static var offer: String { "Natural voice · \(ModelManager.downloadSizeText), once" }
    static let download = "Download"
    static let notNow = "Not now"
    /// The confirmation before a download on a costly network: on the
    /// iPhone, "Download 353 MB on cellular?".
    static var cellularPrompt: String { DeviceCopy.meteredPrompt }
    /// The prompt for the path the download would take: "on cellular?"
    /// only over cellular. A costly Wi-Fi (Low Data Mode, another phone's
    /// Personal Hotspot) is asked about as metered, never as cellular.
    /// `size` is what is left to fetch (J007): less after a staged file.
    static func cellularPrompt(onCellular: Bool, size: String = ModelManager.downloadSizeText) -> String {
        onCellular ? DeviceCopy.meteredPrompt(size: size) : DeviceCopy.meteredNetworkPrompt(size: size)
    }
    static let privacyLine = "Downloads once from Hugging Face. Nothing about you is sent."
    /// The Mac card's promise under the offer (M17).
    static let beforeFlight = "Download before you fly. After that, everything works offline."
    /// The not-installed card's line under the offer: on the Mac, the
    /// promise, or with no usable path what to do first. None on the
    /// iPhone, whose card reads as it always has.
    static func promoDetail(offline: Bool) -> String? {
        guard PlatformVoiceSetup.preparesForFlight else { return nil }
        return offline ? DeviceCopy.connectToDownload : beforeFlight
    }
    /// Under the cellular prompt: the costly network, where the prompt
    /// doesn't name it (`DeviceCopy.meteredDetail`), then the privacy line.
    static var cellularPromptMessage: String { cellularPromptMessage(onCellular: true) }
    /// Under `cellularPrompt(onCellular:)`: a costly Wi-Fi is named, as the
    /// prompt doesn't name it.
    static func cellularPromptMessage(onCellular: Bool) -> String {
        let detail = onCellular ? DeviceCopy.meteredDetail : DeviceCopy.meteredNetworkDetail
        return detail.map { "\($0) \(privacyLine)" } ?? privacyLine
    }
    static func downloading(_ fraction: Double) -> String {
        "Downloading natural voice · \(min(max(Int(fraction * 100), 0), 100))%"
    }
    static let unsupported = "The natural voice needs \(DeviceNoun.withArticle) with more memory."

    // R21: the download can't leave the user stuck.
    /// A Wi-Fi-only download with no free network: on the iPhone,
    /// "Download paused · waiting for Wi-Fi".
    static var waitingForWiFi: String { DeviceCopy.waitingForNetwork }
    /// A Wi-Fi-only download held back by a costly Wi-Fi: Wi-Fi isn't
    /// missing, so the line names what holds it.
    static let waitingOnMeteredNetwork = "Download paused · Low Data Mode or hotspot"
    /// A download allowed onto a costly network, with no network at all.
    static let waitingForConnection = "Download paused · waiting for a connection"
    /// Beside the Wi-Fi wait on a costly network: raises the cellular prompt.
    static let continueNow = "Continue Now"
    /// Removing what a cancelled or failed download staged.
    static let removePartialTitle = "Remove the partial download?"
    /// Removing installed files found damaged, which stay on disk until
    /// Download again replaces them.
    static let removeDamagedTitle = "Remove the damaged voice files?"
    static func removePartialMessage(_ size: String) -> String {
        "Frees \(size). The next download starts over."
    }
    static let installed = "Natural voice installed"
    /// On the iPhone, "353 MB on device · works offline".
    static func onDevice(_ size: String) -> String { "\(size) \(DeviceCopy.onDevice) · works offline" }

    /// A failure's line in two parts: what happened, then what to do (an
    /// action when the line itself retries, as on the card). Too little
    /// space names `need`, the free space the check asked for
    /// (`ModelManager.spaceNeeded`): less than the whole requirement once
    /// an earlier attempt staged files.
    static func failure(_ failure: ModelManager.DownloadFailure,
                        need: Int64 = ModelManager.requiredFreeBytes) -> (status: String, detail: String, detailIsAction: Bool) {
        switch failure {
        case .notEnoughSpace:
            return ("Not enough space", "need \(ModelManager.formattedSize(need)) free", false)
        case .interrupted:
            return ("Download failed", "Try again", true)
        case .damaged:
            return ("Voice files damaged", "Download again", true)
        }
    }

    static func failureLine(_ failure: ModelManager.DownloadFailure,
                            need: Int64 = ModelManager.requiredFreeBytes) -> String {
        let copy = Self.failure(failure, need: need)
        return "\(copy.status) · \(copy.detail)"
    }

    /// The offer's one line, for the chapter line's row and the Continue
    /// card alike (R5). A Download that found too little space leaves the
    /// offer up, and the line then says so (R21), still naming the voice:
    /// on the card, with no Download beside it, a bare "Not enough space"
    /// read as if the book or its storage were the problem.
    static func offerLine(modelState: ModelManager.ModelState,
                          need: Int64 = ModelManager.requiredFreeBytes) -> String {
        guard modelState == .failed(.notEnoughSpace) else { return offer }
        let space = failure(.notEnoughSpace, need: need)
        return "Natural voice · \(space.status.lowercased()) · \(space.detail)"
    }

    /// The visible line as VoiceOver says it.
    static func spoken(_ text: String) -> String {
        PlaybackCopy.spoken(text)
    }
}
