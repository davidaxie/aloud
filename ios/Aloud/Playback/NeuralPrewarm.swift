import Combine
import Foundation

/// R18: the neural engine loads while the Library shows the Continue card,
/// so a tap on it speaks in about the time a System sentence takes rather
/// than after a multi-second model load. A book loaded in the neural voice
/// asks for it too (`PlatformTuning.prewarmsForLoadedBook`): the reader
/// LaunchRestore reopens at launch shows no card. So does Classics on
/// screen (`PlatformTuning.prewarmsOnClassics`), where a book is about to
/// be picked, and a book opening from the Library (`bookIsOpening(_:)`),
/// so neither starts cold behind the preparing-voice notice
/// (`PlaybackController.isPreparingVoice`). On a Mac the launch asks
/// as well (`PlatformTuning.prewarmsAtLaunch`), until a warm-up first
/// starts.
///
/// It warms only for the neural voice with the model installed, while the
/// app is in the foreground, never under Low Power Mode (the system's own
/// setting, on a Mac as on an iPhone: M19) and never while the device is
/// hot (`.serious` or hotter, as ThermalGuard reports it). A memory warning
/// cancels a load and keeps the engine cold until the card next appears,
/// another book loads, or (on an iPhone) the app comes back to the
/// foreground; it frees an idle engine, and at `.critical` a paused one
/// too (`releasesEngine`). Hiding the card or turning on Low Power Mode
/// never releases a warm engine: the next tap would only pay for the load
/// again.
///
/// It warms Kokoro directly and never touches the controller's status,
/// `isPreparingVoice`, the schedule or the mixer. A load holds
/// `PlatformActivity`, so App Nap doesn't stretch it behind a hidden window.
@MainActor
final class NeuralPrewarm {

    var isWarming: Bool { warmTask != nil }

    /// M19's warm-up interval. Tests replace it.
    var budgetSignposts = BudgetSignposts.live

    /// Held from a load's start to its end. Tests replace it.
    var activity = Activity.platform

    struct Activity {
        let begin: (_ reason: String) -> PlatformActivity.Token?
        let end: (PlatformActivity.Token?) -> Void

        static let platform = Activity(begin: { PlatformActivity.begin(reason: $0) },
                                       end: { PlatformActivity.end($0) })
    }

    private let playback: PlaybackController
    private let kokoro: any WarmableTtsEngine
    private let isModelInstalled: @MainActor () -> Bool
    private let isLowPowerMode: () -> Bool
    /// A loaded book asks for a warm-up too.
    private let warmsForLoadedBook: Bool
    /// The launch asks for one too (a Mac).
    private let warmsAtLaunch: Bool
    /// Classics on screen asks for one too.
    private let warmsOnClassics: Bool
    /// The app coming back to the foreground ends a memory warning's hold
    /// (an iPhone).
    private let memoryHoldEndsOnReturn: Bool
    /// In the background a paused engine goes at either level (an iPhone,
    /// which ends background apps for their memory first).
    private let releasesPausedInBackground: Bool

    private var cardVisible = false
    /// Classics is the top of the stack.
    private var browsingClassics = false
    /// A book is opening from the Library (`bookIsOpening(_:)`): asks once,
    /// until a warm-up starts, the loaded book changes or the Library's
    /// root shows again, so the ask ends with the open.
    private var openingBook = false
    private var loadedBookID: UUID?
    /// The launch asks until a warm-up first starts.
    private var launchPending: Bool
    /// Set at creation, then kept by RootView's scene phase.
    private var sceneActive: Bool
    private var suppressedByMemoryWarning = false
    /// `.serious` or hotter, as the heat publisher last said.
    private var isHot = false
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
    /// `loadedBook` is the id of the book playback holds, which warms where
    /// `warmsForLoadedBook`. `heat` is whether the device is `.serious` or
    /// hotter (ThermalGuard's `isHot`); never hot unless given.
    /// `browsingClassics` is whether Classics is the top of the stack, which
    /// warms where `warmsOnClassics`; leaving it never cancels or releases.
    /// `atLibraryRoot` is whether nothing is pushed over the Library: its
    /// return ends an open's ask (`bookIsOpening(_:)`) whose book never
    /// loaded. Never at the root unless given.
    init(playback: PlaybackController,
         kokoro: any WarmableTtsEngine,
         cardVisible: AnyPublisher<Bool, Never>,
         browsingClassics: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher(),
         loadedBook: AnyPublisher<UUID?, Never> = Just(nil).eraseToAnyPublisher(),
         atLibraryRoot: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher(),
         isModelInstalled: @escaping @MainActor () -> Bool,
         isLowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         heat: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher(),
         sceneActive: Bool? = nil,
         warmsForLoadedBook: Bool = PlatformTuning.prewarmsForLoadedBook,
         warmsAtLaunch: Bool = PlatformTuning.prewarmsAtLaunch,
         warmsOnClassics: Bool = PlatformTuning.prewarmsOnClassics,
         memoryHoldEndsOnReturn: Bool = PlatformTuning.memoryHoldEndsOnReturn,
         releasesPausedInBackground: Bool = PlatformTuning.releasesNeuralOnBackground,
         notifications: NotificationCenter = .default) {
        self.playback = playback
        self.kokoro = kokoro
        self.isModelInstalled = isModelInstalled
        self.isLowPowerMode = isLowPowerMode
        self.warmsForLoadedBook = warmsForLoadedBook
        self.warmsAtLaunch = warmsAtLaunch
        self.warmsOnClassics = warmsOnClassics
        self.memoryHoldEndsOnReturn = memoryHoldEndsOnReturn
        self.releasesPausedInBackground = releasesPausedInBackground
        launchPending = warmsAtLaunch
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

        // Classics on screen asks; it is no return to the card, so a memory
        // warning's hold stays, and going back never cancels or releases.
        browsingClassics
            .removeDuplicates()
            .sink { [weak self] browsing in
                guard let self else { return }
                self.browsingClassics = browsing
                self.reevaluate()
            }
            .store(in: &subscriptions)

        loadedBook
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self else { return }
                // Another book is the listener returning too, where it asks
                // for a warm-up.
                if self.warmsForLoadedBook, let id, id != self.loadedBookID {
                    self.suppressedByMemoryWarning = false
                }
                // Any change of book ends an open's ask: the book that was
                // opening has loaded (and asks for itself where the platform
                // says so), or playback let go of one, which no open waits on.
                self.openingBook = false
                self.loadedBookID = id
                self.reevaluate()
            }
            .store(in: &subscriptions)

        // Back at the Library's root, an open whose book never loaded (its
        // load failed, say) asks no more: the bare root never warms on its
        // account. Only ends an ask, so it needs no reevaluation.
        atLibraryRoot
            .removeDuplicates()
            .sink { [weak self] atRoot in
                if atRoot { self?.openingBook = false }
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

        // Cooling down asks again; heating up never cancels or releases.
        heat
            .removeDuplicates()
            .sink { [weak self] hot in
                self?.isHot = hot
                self?.reevaluate()
            }
            .store(in: &subscriptions)

        PlatformLifecycle.memoryPressure(in: notifications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.memoryWarning($0) }
            .store(in: &subscriptions)
    }

    /// From RootView's scene phase: false only in the background. Coming
    /// back to the foreground is the listener returning, where the platform
    /// says so: a memory warning's hold ends there.
    func sceneActivityChanged(_ active: Bool) {
        if active, !sceneActive, memoryHoldEndsOnReturn { suppressedByMemoryWarning = false }
        sceneActive = active
        reevaluate()
    }

    /// The Library is opening book `id` (`LibraryView.open`): one ask, under
    /// every gate, that ends once a warm-up starts, the loaded book changes
    /// or the Library's root shows again. A book opened from a shelf with no
    /// Continue card otherwise loads the model cold behind the
    /// preparing-voice notice (`PlaybackController.isPreparingVoice`). The
    /// book playback already holds asks nothing more where the platform
    /// warms for a loaded book: no load follows to end the ask.
    func bookIsOpening(_ id: UUID) {
        if warmsForLoadedBook, id == loadedBookID { return }
        openingBook = true
        reevaluate()
    }

    /// Starts a warm-up when every condition holds and none is warm or in
    /// flight. Never cancels or releases.
    func reevaluate() {
        let asked = Self.asksForWarmUp(cardVisible: cardVisible,
                                       bookLoaded: loadedBookID != nil,
                                       launchPending: launchPending,
                                       warmsForLoadedBook: warmsForLoadedBook,
                                       warmsAtLaunch: warmsAtLaunch,
                                       browsingClassics: browsingClassics,
                                       warmsOnClassics: warmsOnClassics,
                                       bookOpening: openingBook)
        guard Self.shouldWarm(asked: asked,
                              sceneActive: sceneActive,
                              modelInstalled: isModelInstalled(),
                              voiceIsNeural: playback.voice.engine == .kokoro,
                              lowPowerMode: isLowPowerMode(),
                              hot: isHot,
                              suppressedByMemoryWarning: suppressedByMemoryWarning),
              !kokoro.isWarm, warmTask == nil else { return }
        launchPending = false
        openingBook = false
        warmGeneration &+= 1
        let generation = warmGeneration
        let kokoro = kokoro
        let signposts = budgetSignposts
        let activity = activity
        warmTask = Task { [weak self] in
            // Cancelled before it began (a memory warning): never load.
            if !Task.isCancelled {
                // Both end however the load comes back: warm, thrown, or
                // after a memory warning's cancel.
                let held = activity.begin("Loading the natural voice")
                let warmup = signposts.begin(.kokoroWarmup)
                try? await kokoro.warmUp()
                signposts.end(warmup)
                activity.end(held)
            }
            guard let self, self.warmGeneration == generation else { return }
            self.warmTask = nil
        }
    }

    /// `asked`: something wants the engine (`asksForWarmUp`).
    nonisolated static func shouldWarm(asked: Bool,
                                       sceneActive: Bool,
                                       modelInstalled: Bool,
                                       voiceIsNeural: Bool,
                                       lowPowerMode: Bool,
                                       hot: Bool,
                                       suppressedByMemoryWarning: Bool) -> Bool {
        asked && sceneActive && modelInstalled && voiceIsNeural
            && !lowPowerMode && !hot && !suppressedByMemoryWarning
    }

    /// The Continue card and a book opening from the Library ask everywhere;
    /// Classics on screen, a loaded book and the launch ask where the
    /// platform warms for them. The bare Library root asks for nothing.
    nonisolated static func asksForWarmUp(cardVisible: Bool,
                                          bookLoaded: Bool,
                                          launchPending: Bool,
                                          warmsForLoadedBook: Bool,
                                          warmsAtLaunch: Bool,
                                          browsingClassics: Bool = false,
                                          warmsOnClassics: Bool = false,
                                          bookOpening: Bool = false) -> Bool {
        cardVisible || bookOpening || (warmsOnClassics && browsingClassics)
            || (warmsForLoadedBook && bookLoaded) || (warmsAtLaunch && launchPending)
    }

    /// The Library is the root of the stack and has a Continue card to show,
    /// by the shelf's own rule: `stop`, the controller's unattended stop,
    /// keeps a book Finished by the slack rule on the card (F045).
    nonisolated static func continueCardVisible(pathIsEmpty: Bool,
                                                documents: [LibraryDocument],
                                                loadedID: UUID?,
                                                stop: PlaybackStop? = nil) -> Bool {
        pathIsEmpty && ShelfLayout(for: documents, loadedID: loadedID, stop: stop).hero != nil
    }

    /// Whether a memory warning at `pressure` frees the engine behind
    /// `status` (M19). Never one that is reading. One that nothing waits on
    /// (no book cued, or one that ended or failed) goes at `.warning`; a
    /// paused one only at `.critical`, since Play would pay the load again.
    /// UIKit's own warning, which names no level, reads as critical
    /// (`PlatformLifecycle.memoryPressure`), so it frees a paused engine as
    /// it always has; the relay's `.warning` keeps one warm.
    nonisolated static func releasesEngine(under pressure: PlatformLifecycle.MemoryPressure,
                                           status: PlayerStatus) -> Bool {
        switch status {
        case .playing, .buffering: return false
        case .paused: return pressure == .critical
        case .idle, .ended, .error: return true
        }
    }

    /// The level is the kernel's memory-pressure source's, as the relay
    /// carries it (`MemoryPressureRelay`), or critical for UIKit's own.
    private func memoryWarning(_ warned: PlatformLifecycle.MemoryPressure) {
        suppressedByMemoryWarning = true
        // A backgrounded app is the first iOS ends for its memory: there a
        // paused engine goes at either level.
        let pressure: PlatformLifecycle.MemoryPressure = !sceneActive && releasesPausedInBackground ? .critical : warned
        // A load in flight began on a cold engine, so freeing what it loads
        // finishes cancelling it at either level, a paused book's included.
        let cancelledLoad = warmTask != nil
        warmTask?.cancel()
        warmTask = nil
        // Loaded behind a voice that isn't natural (heat's switch to System,
        // the fallback after three failures), nothing reads the engine, so
        // it goes at either level whatever is playing. It stays for a
        // natural voice reading or one a pending switch is moving to.
        playback.releaseNeuralEngineIfUnused()
        guard cancelledLoad || Self.releasesEngine(under: pressure, status: playback.status) else { return }
        // Kokoro's serial queue runs this release after a load already in
        // progress, so a warm-up the cancel came too late for is freed too.
        // It never frees a reading engine, whatever the level.
        playback.releaseNeuralEngineIfIdle()
    }
}
