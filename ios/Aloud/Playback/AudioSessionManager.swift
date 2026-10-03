import AVFoundation
import Foundation

/// Owns the shared `AVAudioSession`: spoken-audio playback category,
/// interruption handling, and pause-on-unplug route changes. The iPhone's
/// `AudioOutputMonitoring`.
@MainActor
final class AudioSessionManager: AudioOutputMonitoring {

    var onInterruption: ((AudioInterruption) -> Void)?
    var onRouteRequiresPause: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default

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
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The session already plays to the route iOS picked.
    func bindOutput(of engine: AVAudioEngine) {}

    /// iOS reports an unplug as a route change (`onRouteRequiresPause`), so
    /// the engine's own configuration change is left alone, as it always
    /// was: a restart racing that pause could blip through the speaker.
    func decisionAfterConfigurationChange() -> RouteDecision { .ignore }

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
}
