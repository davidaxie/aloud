import Combine
import Foundation

/// R18: the neural engine loads while the Library shows the Continue card,
/// so a tap on it speaks in about the time a System sentence takes rather
/// than after a multi-second model load.
///
/// It warms only for the neural voice with the model installed, while the
/// app is in the foreground, and never under Low Power Mode (the system's
/// own setting, on a Mac as on an iPhone: M19). A memory warning cancels a
/// load and keeps the engine cold until the card next appears; it frees an
/// idle engine, and at `.critical` a paused one too (`releasesEngine`).
/// Hiding the card or turning on Low Power Mode never releases a warm
/// engine: the next tap would only pay for the load again.
///
/// It warms Kokoro directly and never touches the controller's status,
/// "Preparing voice…", the schedule or the mixer.
@MainActor
final class NeuralPrewarm {

    var isWarming: Bool { warmTask != nil }

    private let playback: PlaybackController
    private let kokoro: any WarmableTtsEngine
    private let isModelInstalled: @MainActor () -> Bool
    private let isLowPowerMode: () -> Bool

    private var cardVisible = false
    /// Set at creation, then kept by RootView's scene phase.
    private var sceneActive: Bool
    private var suppressedByMemoryWarning = false
    private var warmTask: Task<Void, Never>?
    /// Tells a finished warm-up whether it is still the current one.
    private var warmGeneration = 0
    private var subscriptions: Set<AnyCancellable> = []

    /// `sceneActive` (nil: the app's state now, a test seam otherwise) is
    /// never an assumed foreground: an App Intent can cold-launch Aloud in
    /// the background and build the app model there, and warming would
    /// load the 800 MB model for nobody. A foreground launch may not be
    /// `.active` yet here, so RootView reports its scene phase from its
    /// first appearance.
    init(playback: PlaybackController,
         kokoro: any WarmableTtsEngine,
         cardVisible: AnyPublisher<Bool, Never>,
         isModelInstalled: @escaping @MainActor () -> Bool,
         isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         sceneActive: Bool? = nil,
         notifications: NotificationCenter = .default) {
        self.playback = playback
        self.kokoro = kokoro
        self.isModelInstalled = isModelInstalled
        self.isLowPowerMode = isLowPowerMode
        // Here, not as the default argument, which isn't on the main actor.
        self.sceneActive = sceneActive ?? PlatformApp.isActive

        cardVisible
            .sink { [weak self] visible in
                guard let self else { return }
                // The card coming back is the listener returning: a memory
                // warning's hold ends there.
                if visible, !self.cardVisible { self.suppressedByMemoryWarning = false }
                self.cardVisible = visible
                self.reevaluate()
            }
            .store(in: &subscriptions)

        // On the next main-queue turn: a voice restored at launch and then
        // swapped for System by the heat policy is judged once, as System.
        playback.$voice
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reevaluate() }
            .store(in: &subscriptions)

        // Posted on whichever thread changed the setting.
        notifications.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reevaluate() }
            .store(in: &subscriptions)

        PlatformLifecycle.publisher(for: .memoryWarning, in: notifications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.memoryWarning(PlatformLifecycle.MemoryPressure(of: $0)) }
            .store(in: &subscriptions)
    }

    /// From RootView's scene phase: false only in the background.
    func sceneActivityChanged(_ active: Bool) {
        sceneActive = active
        reevaluate()
    }

    /// Starts a warm-up when every condition holds and none is warm or in
    /// flight. Never cancels or releases.
    func reevaluate() {
        guard Self.shouldWarm(cardVisible: cardVisible,
                              sceneActive: sceneActive,
                              modelInstalled: isModelInstalled(),
                              voiceIsNeural: playback.voice.engine == .kokoro,
                              lowPowerMode: isLowPowerMode(),
                              suppressedByMemoryWarning: suppressedByMemoryWarning),
              !kokoro.isWarm, warmTask == nil else { return }
        warmGeneration &+= 1
        let generation = warmGeneration
        let kokoro = kokoro
        warmTask = Task { [weak self] in
            // Cancelled before it began (a memory warning): never load.
            if !Task.isCancelled { try? await kokoro.warmUp() }
            guard let self, self.warmGeneration == generation else { return }
            self.warmTask = nil
        }
    }

    nonisolated static func shouldWarm(cardVisible: Bool,
                                       sceneActive: Bool,
                                       modelInstalled: Bool,
                                       voiceIsNeural: Bool,
                                       lowPowerMode: Bool,
                                       suppressedByMemoryWarning: Bool) -> Bool {
        cardVisible && sceneActive && modelInstalled && voiceIsNeural
            && !lowPowerMode && !suppressedByMemoryWarning
    }

    /// The Library is the root of the stack and has a Continue card to show.
    nonisolated static func continueCardVisible(pathIsEmpty: Bool,
                                                documents: [LibraryDocument],
                                                loadedID: UUID?) -> Bool {
        pathIsEmpty && ShelfLayout(for: documents, loadedID: loadedID).hero != nil
    }

    /// Whether a memory warning at `pressure` frees the engine behind
    /// `status` (M19). Never one that is reading. One that nothing waits on
    /// (no book cued, or one that ended or failed) goes at `.warning`; a
    /// paused one only at `.critical`, since Play would pay the load again.
    /// The iPhone's warning reads as critical (`MemoryPressure(of:)`), so
    /// it frees a paused engine as it always has.
    nonisolated static func releasesEngine(under pressure: PlatformLifecycle.MemoryPressure,
                                           status: PlayerStatus) -> Bool {
        switch status {
        case .playing, .buffering: return false
        case .paused: return pressure == .critical
        case .idle, .ended, .error: return true
        }
    }

    /// On a Mac the warning is the kernel's memory-pressure source, whose
    /// level the relay carries (`MemoryPressureRelay`).
    private func memoryWarning(_ pressure: PlatformLifecycle.MemoryPressure) {
        suppressedByMemoryWarning = true
        // A load in flight began on a cold engine, so freeing what it loads
        // finishes cancelling it at either level, a paused book's included.
        let cancelledLoad = warmTask != nil
        warmTask?.cancel()
        warmTask = nil
        guard cancelledLoad || Self.releasesEngine(under: pressure, status: playback.status) else { return }
        // Kokoro's serial queue runs this release after a load already in
        // progress, so a warm-up the cancel came too late for is freed too.
        // It never frees a reading engine, whatever the level.
        playback.releaseNeuralEngineIfIdle()
    }
}
