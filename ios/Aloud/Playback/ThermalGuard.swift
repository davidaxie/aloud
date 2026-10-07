import Combine
import Foundation

/// R11, heat as playback policy. The neural voice is the app's heaviest
/// work, so heat changes what plays rather than leaving iOS to throttle it:
/// - crossing up to `.serious` while a Kokoro voice reads hands off to the
///   System voice at the next sentence (gapless, with the cooling notice);
/// - crossing back down to `.fair` or below returns to `preferredVoice()`;
///   heating up again before that switch lands drops it, and the next
///   cool-down tries again;
/// - entering `.critical` while audio plays stops it (`.tooHot`); stopped or
///   already paused, the neural engine is freed.
///
/// Rules compare raw values and act on transitions only, so a Play or a
/// voice pick made while the phone is still hot is honoured, never undone.
@MainActor
final class ThermalGuard {

    /// The voice to come back to once the phone cools: AppModel answers with
    /// the engaged preference, so a pick or a model removal made meanwhile
    /// wins.
    var preferredVoice: @MainActor () -> TtsVoice

    /// `.serious` or hotter.
    var isHot: Bool { state.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

    private let playback: PlaybackController
    private let systemVoice: TtsVoice
    private var state: ProcessInfo.ThermalState = .nominal
    /// The System voice is standing in for the preference until the phone
    /// cools.
    private var isCooling = false
    /// The cooling switch is still waiting for its splice, 1–3 sentences
    /// ahead, with Kokoro reading until then. Any voice change ends the
    /// wait: the switch landing, or a pick or a fallback that replaced it.
    private var isSwitchPending = false
    private var subscription: AnyCancellable?
    private var voiceChanges: AnyCancellable?

    /// Starts from `.nominal` and applies `initialState`: a launch while hot
    /// is quietly System (no book is loaded yet, so nothing is announced).
    init(playback: PlaybackController,
         systemVoice: TtsVoice,
         initialState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) {
        self.playback = playback
        self.systemVoice = systemVoice
        self.preferredVoice = { systemVoice }
        // Before the first state: a switch that lands at once must clear the flag.
        voiceChanges = playback.$voice
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.isSwitchPending = false }
        thermalStateChanged(initialState)
    }

    /// The system posts the change on an arbitrary thread; the state is read
    /// again on the main queue.
    func observe(_ center: NotificationCenter = .default) {
        subscription = center.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.thermalStateChanged(ProcessInfo.processInfo.thermalState)
            }
    }

    func thermalStateChanged(_ newState: ProcessInfo.ThermalState) {
        let old = state.rawValue
        let new = newState.rawValue
        state = newState
        let serious = ProcessInfo.ThermalState.serious.rawValue
        let critical = ProcessInfo.ThermalState.critical.rawValue

        // The stop first: its reason is what the listener most needs to hear.
        if new >= critical, old < critical {
            if playback.isActive {
                playback.stop(because: .tooHot)
                // Stopped, the pending switch lands at once, so Play reads
                // the System voice the notice names.
                if isSwitchPending {
                    playback.switchVoiceAtSentenceBoundary(to: systemVoice, notice: .coolingDown)
                }
            }
            dropIncomingNaturalVoice()
            // Stopped or already paused (a switch to System still pending
            // included), nothing needs the engine's memory now.
            playback.releaseNeuralEngineIfIdle()
        }
        if new >= serious, old < serious, playback.voice.engine == .kokoro {
            isCooling = true
            isSwitchPending = true   // before the call: a switch that lands at once clears it
            playback.switchVoiceAtSentenceBoundary(to: systemVoice, notice: .coolingDown)
        } else if new >= serious, old < serious {
            dropIncomingNaturalVoice()
        } else if new < serious, old >= serious, isCooling {
            isCooling = false
            isSwitchPending = false
            playback.switchVoiceAtSentenceBoundary(to: preferredVoice())
        }
    }

    /// The model finished installing while the phone is hot: the natural
    /// voice waits for the cool-down instead of loading now.
    func holdNaturalVoiceUntilCool() {
        isCooling = true
    }

    /// A natural voice still on its way in behind the System voice (the
    /// cool-down's switch back, an install switch) is the heaviest work of
    /// all, its engine loading or its first clips synthesizing: heating up
    /// drops it, the System voice reads on, and the cool-down brings it back.
    /// Clips already queued past its splice go too (only then does the
    /// current sentence reload, in System), so none plays under the System
    /// chip; with none queued yet, the sentence reading goes on uncut.
    private func dropIncomingNaturalVoice() {
        guard playback.voice.engine != .kokoro, playback.incomingVoice?.engine == .kokoro else { return }
        isCooling = true
        playback.cancelVoiceHandoff()
    }
}
