import Combine
import Foundation

/// R5: offer the natural voice after the first minute of listening, never
/// before. Counts cumulative `.playing` time across launches, and shows the
/// offer until it is answered: by Not now, by a download starting from any
/// surface, or by the model already being installed. An answer is never
/// cleared, so a later Remove never brings the offer back.
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
    private(set) var listenedSeconds: TimeInterval
    private(set) var answer: Answer?

    private let defaults: UserDefaults
    private let deviceSupported: Bool
    private let now: () -> TimeInterval

    /// When the open `.playing` interval began; nil while not playing.
    private var playingSince: TimeInterval?
    /// The last model state seen. Nil until attach, so the offer stays hidden
    /// until we know the model isn't installed.
    private var modelState: ModelManager.ModelState?
    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard,
         deviceSupported: Bool = ModelManager.deviceSupportsNeuralVoice,
         now: @escaping () -> TimeInterval = { MonotonicClock.now }) {
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
        listenedSeconds = min(max(defaults.double(forKey: Key.listenedSeconds), 0), Self.listenThreshold)
        answer = Answer(rawValue: defaults.string(forKey: Key.answer) ?? "")
    }

    func attach(playback: PlaybackController, modelManager: ModelManager) {
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
    /// carries the space message and Download checks again (R21).
    nonisolated static func isVisible(listenedSeconds: TimeInterval,
                                      answer: Answer?,
                                      deviceSupported: Bool,
                                      modelState: ModelManager.ModelState) -> Bool {
        deviceSupported
            && answer == nil
            && (modelState == .notInstalled || modelState == .failed(.notEnoughSpace))
            && listenedSeconds >= listenThreshold
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

    /// Never depends on scene phase: a phone locked at the 60 s mark shows
    /// the offer at the next unlock.
    private func refresh() {
        let visible = modelState.map {
            Self.isVisible(listenedSeconds: listenedSeconds, answer: answer,
                           deviceSupported: deviceSupported, modelState: $0)
        } ?? false
        if visible != isVisible { isVisible = visible }
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
    static let privacyLine = "Downloads once from Hugging Face. Nothing about you is sent."
    /// Under the cellular prompt: the costly network, where the prompt
    /// doesn't name it (`DeviceCopy.meteredDetail`), then the privacy line.
    static var cellularPromptMessage: String {
        DeviceCopy.meteredDetail.map { "\($0) \(privacyLine)" } ?? privacyLine
    }
    static func downloading(_ fraction: Double) -> String {
        "Downloading natural voice · \(min(max(Int(fraction * 100), 0), 100))%"
    }
    static let unsupported = "The natural voice needs \(DeviceNoun.withArticle) with more memory."

    // R21: the download can't leave the user stuck.
    /// A Wi-Fi-only download with no free network: on the iPhone,
    /// "Download paused · waiting for Wi-Fi".
    static var waitingForWiFi: String { DeviceCopy.waitingForNetwork }
    static let installed = "Natural voice installed"
    /// On the iPhone, "353 MB on device · works offline".
    static func onDevice(_ size: String) -> String { "\(size) \(DeviceCopy.onDevice) · works offline" }

    /// A failure's line in two parts: what happened, then what to do (an
    /// action when the line itself retries, as on the card).
    static func failure(_ failure: ModelManager.DownloadFailure) -> (status: String, detail: String, detailIsAction: Bool) {
        switch failure {
        case .notEnoughSpace:
            return ("Not enough space", "need \(ModelManager.formattedSize(ModelManager.requiredFreeBytes)) free", false)
        case .interrupted:
            return ("Download failed", "Try again", true)
        case .damaged:
            return ("Voice files damaged", "Download again", true)
        }
    }

    static func failureLine(_ failure: ModelManager.DownloadFailure) -> String {
        let copy = Self.failure(failure)
        return "\(copy.status) · \(copy.detail)"
    }

    /// The offer's one line, for the chapter line's row and the Continue
    /// card alike (R5). A Download that found too little space leaves the
    /// offer up, and the line then says so (R21), still naming the voice:
    /// on the card, with no Download beside it, a bare "Not enough space"
    /// read as if the book or its storage were the problem.
    static func offerLine(modelState: ModelManager.ModelState) -> String {
        guard modelState == .failed(.notEnoughSpace) else { return offer }
        let space = failure(.notEnoughSpace)
        return "Natural voice · \(space.status.lowercased()) · \(space.detail)"
    }

    /// The visible line as VoiceOver says it.
    static func spoken(_ text: String) -> String {
        PlaybackCopy.spoken(text)
    }
}
