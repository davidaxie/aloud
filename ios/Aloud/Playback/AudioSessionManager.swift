import AVFoundation
import Foundation

/// Owns the shared `AVAudioSession`: spoken-audio playback category,
/// interruption handling, pause-on-unplug route changes, and following the
/// engine onto a new output once the change settles. The iPhone's
/// `AudioOutputMonitoring`.
@MainActor
final class AudioSessionManager: AudioOutputMonitoring {

    var onInterruption: ((AudioInterruption) -> Void)?
    var onRouteRequiresPause: (() -> Void)?

    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// How long an engine's output change is left to settle before playback
    /// follows it.
    private let settleInterval: TimeInterval
    /// The engine playback starts (`bindOutput`), whose changes are followed.
    private weak var engine: AVAudioEngine?
    private var followPending = false
    /// The settled change this monitor posted is on its way to the
    /// controller, which follows it.
    private var followSettled = false

    /// `center` is where the session's notifications arrive: the app's
    /// default center, or a private one in tests. A zero `settleInterval`
    /// follows at once.
    init(center: NotificationCenter = .default, settleInterval: TimeInterval = 0.5) {
        self.center = center
        self.settleInterval = settleInterval

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let event = Self.interruption(from: note.userInfo) else { return }
            Task { @MainActor in self?.onInterruption?(event) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard Self.routeRequiresPause(note.userInfo) else { return }
            Task { @MainActor in self?.onRouteRequiresPause?() }
        })

        // A media-services reset takes the category along with the session:
        // the next claim sets it again.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.categoryIsSet = false }
        })

        // Set once, never activated here: a claim then only activates.
        setCategoryIfNeeded()
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// The spoken-audio playback category is on the session: set at init,
    /// and again on the next claim after a reset (or a failed first set).
    private var categoryIsSet = false

    private func setCategoryIfNeeded() {
        guard !categoryIsSet else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            categoryIsSet = true
        } catch {
            // Tried again on the next claim.
        }
    }

    /// Claims the audio: activation only, the category already set (R1-40).
    /// A call, or an app that outranks Aloud, holding it throws
    /// `AudioOutputHeldElsewhere`, so playback pauses as interrupted rather
    /// than failed.
    func activate() throws {
        setCategoryIfNeeded()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch where Self.isHeldElsewhere(error) {
            throw AudioOutputHeldElsewhere()
        }
    }

    /// Gives the audio back once the engine has stopped (the idle stop), so
    /// iOS can suspend a paused Aloud. An app it interrupted (Music, a
    /// podcast) is told it may resume only once listening is over
    /// (`notifyingOthers`): after a pause, that app would start by itself a
    /// minute later.
    func deactivate(notifyingOthers: Bool) {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: notifyingOthers ? .notifyOthersOnDeactivation : [])
    }

    /// The session already plays to the route iOS picked; the engine is
    /// remembered, so its output changes can be followed.
    func bindOutput(of engine: AVAudioEngine) {
        self.engine = engine
    }

    /// The engine stopped itself: a new output (a car's Bluetooth, AirPods,
    /// AirPlay) or a new format on this one. iOS reports an unplug apart, as
    /// a route change (`onRouteRequiresPause`), in no fixed order with this
    /// one, so the change settles first: following at once could race that
    /// pause and blip through the speaker. Once settled, this monitor posts
    /// the change again and playback follows the output as it is then: a
    /// paused controller only rewires, a playing one reads on from the
    /// sentence start. Before anything has played there is nothing to follow.
    func decisionAfterConfigurationChange() -> RouteDecision {
        if followSettled {
            followSettled = false
            return .follow
        }
        guard engine != nil else { return .ignore }
        guard settleInterval > 0 else { return .follow }
        guard !followPending else { return .ignore }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval) { [weak self] in
            MainActor.assumeIsolated { self?.followSettledChange() }
        }
        return .ignore
    }

    /// The change, settled. An engine running again was started on the
    /// output as it is now (a Play in the meantime): nothing to follow.
    private func followSettledChange() {
        followPending = false
        guard let engine, !engine.isRunning else { return }
        followSettled = true
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    // MARK: - Reading the notifications

    nonisolated static func interruption(from userInfo: [AnyHashable: Any]?) -> AudioInterruption? {
        guard let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// Only the device playback was using going away pauses it.
    nonisolated static func routeRequiresPause(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let rawReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return false }
        return reason == .oldDeviceUnavailable
    }

    /// A call or a higher-priority session holds the audio: activation is
    /// refused (`insufficientPriority`), or Aloud may not interrupt it
    /// (`cannotInterruptOthers`).
    nonisolated static func isHeldElsewhere(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == AVAudioSession.ErrorCode.insufficientPriority.rawValue
            || code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
    }
}
