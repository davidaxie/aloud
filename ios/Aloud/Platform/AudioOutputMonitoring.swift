import AVFoundation
import Foundation

/// Something took the app's audio (a call, Siri, another app), or gave it
/// back. Only an iPhone has these: a Mac never takes an app's audio.
enum AudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

/// What playback needs from the platform's audio output: the interruptions
/// and route losses that stop it, the session it activates, the device the
/// engine plays to, and what to do when the engine's output configuration
/// changes under it. (S7)
@MainActor
protocol AudioOutputMonitoring: AnyObject {
    var onInterruption: ((AudioInterruption) -> Void)? { get set }
    /// The output playback was using went away (headphones unplugged).
    var onRouteRequiresPause: (() -> Void)? { get set }
    func activate() throws
    /// Gives the audio back once the engine has stopped. Only when
    /// listening is over (`notifyingOthers`) may an app Aloud interrupted
    /// take it back up on its own.
    func deactivate(notifyingOthers: Bool)
    /// Points the engine's output at the device playback follows. Called
    /// only while the engine is stopped, and never while it renders offline.
    func bindOutput(of engine: AVAudioEngine)
    /// Asked once per `.AVAudioEngineConfigurationChange`: the engine has
    /// stopped itself because its output device or format changed.
    func decisionAfterConfigurationChange() -> RouteDecision
}

/// The platform's monitor, for the app model to hand its controller.
enum PlatformAudioOutput {
    #if os(iOS)
    @MainActor static func makeMonitor() -> any AudioOutputMonitoring {
        AudioSessionManager()
    }
    #elseif os(macOS)
    @MainActor static func makeMonitor() -> any AudioOutputMonitoring {
        MacAudioOutputMonitor()
    }
    #endif
}

#if DEBUG
/// The output faults a UI test injects (`-uitest-fault`), delivered as the
/// system delivers them, so they travel the monitor's real path. (S8)
enum AudioOutputFaults {

    enum Fault: Equatable, Sendable {
        /// The device playback was using went away.
        case routeLost
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
    }

    #if os(iOS)
    static func post(_ fault: Fault) {
        let (name, userInfo) = notification(for: fault)
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    /// The `AVAudioSession` notification `fault` arrives as, apart so a test
    /// can read it back through `AudioSessionManager` without posting it.
    static func notification(for fault: Fault) -> (Notification.Name, [AnyHashable: Any]) {
        switch fault {
        case .routeLost:
            return (AVAudioSession.routeChangeNotification, [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ])
        case .interruptionBegan:
            return (AVAudioSession.interruptionNotification, [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ])
        case .interruptionEnded(let shouldResume):
            var info: [AnyHashable: Any] = [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            ]
            if shouldResume {
                info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
            }
            return (AVAudioSession.interruptionNotification, info)
        }
    }
    #elseif os(macOS)
    /// A lost route goes through the live monitor as a private device
    /// giving way to a public one. A Mac never takes an app's audio, so an
    /// interruption fault is a test bug.
    @MainActor static func post(_ fault: Fault) {
        switch fault {
        case .routeLost:
            MacAudioOutputMonitor.current?.simulate(.privateToPublic)
        case .interruptionBegan, .interruptionEnded:
            assertionFailure("a Mac has no audio interruptions: \(fault)")
        }
    }
    #endif
}
#endif
