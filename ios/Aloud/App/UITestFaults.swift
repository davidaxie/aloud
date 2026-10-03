#if DEBUG
import Combine
import Foundation
import SwiftUI

/// What `-uitest-fault` makes synthesis do (R11's fault-injection UI tests).
/// Read from the scheduler's tasks and written from the main actor, so it
/// is lock-guarded. DEBUG only.
final class UITestFaultSwitch: @unchecked Sendable {

    enum Mode: Equatable, Sendable {
        case off
        case failAll
        /// Fails one sentence, every time: the first text asked for after
        /// the mode is set.
        case failOneSentence
        /// Fails only the neural engine, as a broken model would.
        case failNeural
    }

    static let shared = UITestFaultSwitch()

    private let lock = NSLock()
    private var currentMode = Mode.off
    private var pinnedText: String?

    /// Setting a mode forgets the pinned sentence.
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue; pinnedText = nil } }
    }

    func shouldFail(text: String, engine: EngineKind) -> Bool {
        lock.withLock {
            switch currentMode {
            case .off: return false
            case .failAll: return true
            case .failNeural: return engine == .kokoro
            case .failOneSentence:
                if pinnedText == nil { pinnedText = text }
                return text == pinnedText
            }
        }
    }
}

/// Throws `TtsError.voiceUnavailable` when the switch says so, as a failed
/// synthesis would; forwards everything else.
final class UITestFaultEngine: TtsEngine {

    private let base: any TtsEngine
    private let faults: UITestFaultSwitch

    init(base: any TtsEngine, faults: UITestFaultSwitch = .shared) {
        self.base = base
        self.faults = faults
    }

    var voices: [TtsVoice] { base.voices }

    func synthesize(_ text: String, voice: TtsVoice) async throws -> SynthesizedAudio {
        if faults.shouldFail(text: text, engine: voice.engine) { throw TtsError.voiceUnavailable }
        return try await base.synthesize(text, voice: voice)
    }
}

/// Arms the one fault a UI-test launch asked for. `warmup` fails the neural
/// voice from launch; every other kind fires once playback has been
/// `.playing` for the delay. Synthesis faults switch themselves off once
/// they have done their job, so one tap can recover. Route changes and
/// interruptions are posted as the system would post them
/// (`AudioOutputFaults`), so they travel the output monitor's real path.
@MainActor
enum UITestFaultInjector {

    private static var subscriptions: Set<AnyCancellable> = []
    private static var timer: Task<Void, Never>?
    private static var fired = false

    static func arm(_ kind: UITestFaultKind, afterPlayingSeconds delay: TimeInterval, model: AppModel) {
        let playback = model.playback
        if kind == .warmup {
            UITestFaultSwitch.shared.mode = .failNeural
            switchOff(when: playback.$notice) { $0 == .fellBackToSystem }
            return
        }
        // @Published emits before the value lands, so the emitted status is
        // the one to judge; any change restarts the clock.
        playback.$status
            .sink { status in
                timer?.cancel()
                guard !fired, status == .playing else { return }
                timer = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, !fired else { return }
                    fired = true
                    fire(kind, model: model)
                }
            }
            .store(in: &subscriptions)
    }

    private static func fire(_ kind: UITestFaultKind, model: AppModel) {
        let playback = model.playback
        switch kind {
        case .route:
            AudioOutputFaults.post(.routeLost)
        case .interruption:
            interrupt(resuming: false)
        case .interruptionResume:
            interrupt(resuming: true)
        case .synthesis:
            UITestFaultSwitch.shared.mode = .failAll
            switchOff(when: playback.$status) { $0 == .error }
        case .skip:
            UITestFaultSwitch.shared.mode = .failOneSentence
            switchOff(when: playback.$skippedSentences) { !$0.isEmpty }
        case .thermalSerious:
            model.thermalGuard.thermalStateChanged(.serious)
        case .thermalCritical:
            model.thermalGuard.thermalStateChanged(.critical)
        case .warmup:
            break   // armed at launch
        }
    }

    /// A call that takes the audio and ends a second later, giving it back
    /// only when `resuming`.
    private static func interrupt(resuming: Bool) {
        AudioOutputFaults.post(.interruptionBegan)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            AudioOutputFaults.post(.interruptionEnded(shouldResume: resuming))
        }
    }

    private static func switchOff<Value>(when publisher: Published<Value>.Publisher,
                                         _ done: @escaping (Value) -> Bool) {
        publisher
            .first(where: done)
            .sink { _ in UITestFaultSwitch.shared.mode = .off }
            .store(in: &subscriptions)
    }
}

/// The DEBUG probes UI tests read (XCUIHelpers' announcements(_:) and
/// hapticLog(_:)): 1×1 elements that never take a touch. Present only in a
/// UI-test launch; nothing here changes what the app plays or says.
struct UITestProbeOverlay: View {

    @ObservedObject private var announcements = UITestAnnouncementLog.shared
    @ObservedObject private var haptics = TransportHaptics.shared

    var body: some View {
        if UITestHooks.isUITestLaunch {
            ZStack {
                probe("Announcements", value: announcements.entries.joined(separator: "\n"),
                      identifier: "debug.announcements")
                if UITestHooks.hapticLog {
                    probe("Haptics", value: haptics.logText, identifier: "debug.haptics")
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// The constant label keeps SwiftUI from dropping an element that has
    /// nothing visible to say.
    private func probe(_ label: String, value: String, identifier: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}
#endif
