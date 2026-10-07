import Combine
import Foundation

/// Composition root. Builds the object graph once, restores preferences,
/// and persists them as they change.
@MainActor
final class AppModel: ObservableObject {

    /// The process's one model. An App Intent can run with no scene at all
    /// (a locked phone, the Action button), so it reaches the same graph the
    /// UI uses through this. Read only by AloudApp and Intents/; views keep
    /// environment injection, and tests build their own parts.
    static let shared = AppModel()

    let documentStore: DocumentStore
    let engine: AVSpeechEngine
    let kokoroEngine: KokoroSherpaEngine
    let modelManager: ModelManager
    let clipCache: AudioClipCache
    let scheduler: SynthesisScheduler
    let audioOutput: any AudioOutputMonitoring
    let playback: PlaybackController
    let nowPlaying = NowPlayingManager()
    /// App-lifetime sleep timer. It must outlive the reader screen: audio
    /// keeps playing after the reader closes, and a timer owned by the view
    /// would die with it and let playback run all night.
    let sleepTimer = SleepTimer()
    let bookshelf: [BookshelfBook]
    /// The Library's navigation stack. Every way into a book ends in
    /// `router.open`.
    let router = LibraryRouter()
    /// The one Files / Open-in / Bookshelf add pipeline; a finished add
    /// opens the reader through `router`.
    let importer: DocumentImporter
    /// R5: the natural-voice offer, shown after a minute of listening.
    let naturalVoiceOffer: NaturalVoiceOffer
    /// Sections and search over `bookshelf`, built once.
    let bookshelfIndex: BookshelfIndex
    /// R11: heat as playback policy (the System voice while hot, a stop when
    /// critical).
    let thermalGuard: ThermalGuard
    /// R18: the neural engine loads while the Continue card shows.
    let neuralPrewarm: NeuralPrewarm
    /// R18/R26: the Continue card's load-and-play. App-lifetime, so the
    /// Continue listening shortcut and the card share one load in flight.
    let continuePlayback = ContinuePlayback()

    /// R26: what the two App Intents do, over the app's own parts.
    var shortcutActions: ShortcutActions {
        ShortcutActions(library: documentStore, playback: playback,
                        continuePlayback: continuePlayback, sleepTimer: sleepTimer)
    }

    /// Memory gate: the 800 MB neural engine is only offered on ≥6 GB devices
    /// (simulators inherit the Mac's memory and pass).
    let neuralVoiceOffered = ModelManager.deviceSupportsNeuralVoice

    /// Color-only tint of the spoken word in the reader. OFF by default —
    /// the default experience is the calm sentence pill only.
    @Published var wordHighlight: Bool {
        didSet {
            UserDefaults.standard.set(wordHighlight, forKey: PrefKey.wordHighlight)
            // The controller gates its 30 fps word-timing display link on this.
            playback.wordHighlightEnabled = wordHighlight
        }
    }

    /// The persisted app-wide speed (R7). Equals `playback.rate` except
    /// during a live slider drag, whose intermediate steps are never
    /// persisted. Published so the shelf's time-left estimates track it.
    @Published private(set) var globalRate: Double

    private var cancellables: Set<AnyCancellable> = []
    private var didRunLaunchTasks = false
    /// M19's launch interval: open from the first line of `init` until the
    /// Library's first appearance runs `performLaunchTasks`.
    private(set) var launchInterval: BudgetSignposts.Interval?

    init() {
        launchInterval = BudgetSignposts.live.begin(.launch)
        // UI-test hook (compiled out of Release): start from an empty shelf so
        // leftover container state never leaks into a test run. Destructive,
        // so it happens here at the composition root — before the store is
        // built — next to the other launch-argument hooks, never as a side
        // effect of constructing a store.
        #if DEBUG
        if UITestHooks.resetLibrary {
            DocumentStore.wipeAllData()
            PlaybackStopStore().clearAll()
        }
        #endif

        let store = DocumentStore()
        documentStore = store
        #if DEBUG
        // Simulates iOS closing Aloud while it was speaking ten minutes ago:
        // the controller built below reads the marker as a closed-by-iOS stop,
        // ahead of the stale-stop sweep.
        if UITestHooks.seedLiveSession, var document = store.documents.first {
            // A book iOS closed mid-speech was opened and started: a freshly
            // seeded classic is neither, so the Continue card would skip it.
            if document.progressFraction == 0, document.sentenceCount > 1 {
                let sentence = min(40, document.sentenceCount - 1)
                store.saveProgress(id: document.id, sentence: sentence,
                                   fraction: Double(sentence) / Double(document.sentenceCount))
                let id = document.id
                document = store.documents.first { $0.id == id } ?? document
            }
            PlaybackStopStore().markLive(LiveSession(documentID: document.id,
                                                     sentenceIndex: document.progressSentence,
                                                     wallClock: Date().addingTimeInterval(-600)))
        }
        let adder: any LibraryAdding = UITestHooks.slowImport ? SlowLibraryAdding(base: store) : store
        #else
        let adder: any LibraryAdding = store
        #endif
        importer = DocumentImporter(library: adder)

        engine = AVSpeechEngine()
        modelManager = ModelManager()
        kokoroEngine = KokoroSherpaEngine(modelDirectory: modelManager.installDirectory,
                                          blendDirectory: modelManager.blendDirectory)
        // R21: files that fail the engine's load-time check read as damaged
        // on the card. Called on the engine's queue.
        kokoroEngine.onModelDamaged = { [weak manager = modelManager] in
            Task { @MainActor [weak manager] in manager?.markInstalledFilesDamaged() }
        }
        clipCache = AudioClipCache()
        let engineRouter = EngineRouter(system: engine, kokoro: kokoroEngine)
        #if DEBUG
        // `-uitest-fault`: the scheduler and the controller share the engine
        // that fails on cue.
        let synthesisEngine: any TtsEngine = UITestHooks.fault != nil
            ? UITestFaultEngine(base: engineRouter) : engineRouter
        #else
        let synthesisEngine: any TtsEngine = engineRouter
        #endif
        scheduler = SynthesisScheduler(engine: synthesisEngine, cache: clipCache)
        audioOutput = PlatformAudioOutput.makeMonitor()
        // outputMuted and autoplaySuppressed take their UITestHooks defaults.
        playback = PlaybackController(engine: synthesisEngine,
                                      kokoro: kokoroEngine,
                                      defaultVoice: engine.defaultVoice,
                                      scheduler: scheduler,
                                      cache: clipCache,
                                      audioSession: audioOutput)
        // A stop that names no book on the shelf (deleted elsewhere, or a
        // wiped library) has nothing to show it. Not while library.json is
        // unreadable: the book may be one of the records it kept.
        if store.isIndexReadable, let stop = playback.stopped,
           !store.documents.contains(where: { $0.id == stop.documentID }) {
            playback.discardStop(for: stop.documentID)
        }

        let catalog = BookshelfCatalog.load(from: .main)
        bookshelf = catalog
        bookshelfIndex = BookshelfIndex(books: catalog)
        store.backfillGutenbergIDsIfNeeded(catalog: catalog)
        store.backfillSourceHashesIfNeeded()

        naturalVoiceOffer = NaturalVoiceOffer()

        nowPlaying.configure(playback: playback, store: store)
        sleepTimer.attach(to: playback)
        naturalVoiceOffer.attach(playback: playback, modelManager: modelManager)

        // Both exist before the preference restore below, which needs every
        // property set. The guard starts cool: the real thermal state is
        // applied once the voice preference is engaged.
        thermalGuard = ThermalGuard(playback: playback, systemVoice: engine.defaultVoice,
                                    initialState: .nominal)
        neuralPrewarm = NeuralPrewarm(
            playback: playback,
            kokoro: kokoroEngine,
            // The card's hero by the same rule as Continue: the controller's
            // unattended stop keeps a book stopped in its last minute on offer.
            cardVisible: router.$path.map(\.isEmpty)
                .combineLatest(store.$documents, playback.$document.map { $0?.id }, playback.$stopped)
                .map { NeuralPrewarm.continueCardVisible(pathIsEmpty: $0, documents: $1, loadedID: $2, stop: $3) }
                .removeDuplicates()
                .eraseToAnyPublisher(),
            // A Mac also warms for the book loaded in the natural voice
            // (PlatformTuning.prewarmsBeyondTheContinueCard); an iPhone
            // ignores it.
            loadedBook: playback.$document.map { $0?.id }.eraseToAnyPublisher(),
            isModelInstalled: { [unowned modelManager] in modelManager.isInstalled })

        let defaults = UserDefaults.standard
        // UI-test hook (no-op in Release): start from clean listening prefs.
        // Before the migrations, so a reset install migrates like a fresh one.
        if UITestHooks.resetVoicePref {
            defaults.removeObject(forKey: PrefKey.voiceID)
            defaults.removeObject(forKey: PrefKey.rate)
            defaults.removeObject(forKey: PrefKey.skipBrackets)
        }
        AppModel.migratePreferences(defaults)
        AppModel.runListeningMigrationIfNeeded(defaults, documents: store.documents,
                                               modelInstalled: AppModel.migrationSeesModel(modelManager))
        AppModel.runCalmFollowMigrationIfNeeded(defaults)

        globalRate = PlaybackController.clampedRate(
            defaults.object(forKey: PrefKey.rate) as? Double ?? 1.0)
        wordHighlight = defaults.object(forKey: PrefKey.wordHighlight) as? Bool ?? false
        playback.wordHighlightEnabled = wordHighlight   // didSet doesn't fire in init

        ReaderTextSize.seedIfNeeded(defaults, step: ReaderTextSize.platformDefaultStep)
        restorePreferences(from: defaults)
        // A launch while hot is quietly System (no book is loaded yet).
        thermalGuard.thermalStateChanged(ProcessInfo.processInfo.thermalState)
        thermalGuard.observe()
        persistPreferenceChanges(to: defaults)
        observeModelState()
        observeTermination()
        restoreLastReader(LastReaderStore(defaults: defaults), enabled: LaunchRestore.isEnabled)
        flushProgressWhenListeningStops()
        // Play from the lock screen, headphones or media keys with no book
        // open continues the Continue card's book, as the shortcut does; a
        // Pause or second Play/Pause while it loads stops the load.
        nowPlaying.continuePlayback = continuePlayback
        nowPlaying.onPlayWithNoBook = { [weak self] in
            Task { @MainActor [weak self] in _ = await self?.shortcutActions.continueListening() }
        }
        // "Where you stopped": each stop is recorded per book.
        observePlaceHistory()

        // Persist progress even when playback continues outside the reader.
        // The controller's onProgress is the only progress writer.
        playback.onProgress = { [weak store] id, sentence, fraction in
            store?.saveProgress(id: id, sentence: sentence, fraction: fraction)
        }
        // R4/R10: a finished add (Files, Open-in, Bookshelf) opens the reader,
        // which starts it speaking, unless the user moved on meanwhile (the
        // importer's open rule reads the router for that).
        importer.navigation = router
        importer.onAdded = { [weak self] document in
            self?.router.open(document)
        }
        let systemVoice = engine.defaultVoice
        thermalGuard.preferredVoice = { [weak self] in self?.engagedVoicePreference() ?? systemVoice }
    }

    /// One-time work on first appearance of the root view.
    func performLaunchTasks() async {
        guard !didRunLaunchTasks else { return }
        didRunLaunchTasks = true
        // The Library is up and taking input (iPhone and Mac roots alike).
        BudgetSignposts.live.end(&launchInterval)
        await UITestLaunchActions.run(self)
        sceneBecameActive()
    }

    /// Scene-phase hook (from RootView): a stop recorded while VoiceOver
    /// couldn't hear it (backgrounded, or a relaunch after iOS ended the app
    /// mid-listen) is announced now.
    func sceneBecameActive() {
        playback.sceneDidBecomeActive()
    }

    /// Open-in and Share to Aloud.
    func handleOpenURL(_ url: URL) {
        Self.routeOpenIn(url, router: router, importer: importer)
    }

    /// The import overlay and its failure alert belong to the Library root,
    /// so the stack pops to the root and the root's own picker, Rename alert
    /// or Delete dialog closes first; left up, it would hide the overlay,
    /// block the failure alert and cover the reader that then opens and
    /// speaks. The importer opens the reader when the add finishes (or finds
    /// the copy already on the shelf). Static so tests drive it without the
    /// whole app graph.
    static func routeOpenIn(_ url: URL, router: LibraryRouter, importer: DocumentImporter) {
        guard url.isFileURL else { return }
        router.clearForOpenIn()
        importer.importFile(at: url)
    }

    /// Deletes a book everywhere it is live: playback and any Continue load
    /// let go of it (so no later progress write can resurrect it, and the
    /// card's arc stops at once), its reader leaves the stack, then the
    /// store removes the record and its files.
    func deleteDocument(_ document: LibraryDocument) {
        continuePlayback.letGo(of: document.id, playback: playback)
        playback.discardStop(for: document.id)
        router.path.removeAll { $0 == .reader(document.id) }
        documentStore.delete(document)
    }

    /// Scene-phase hook (from RootView): a backgrounded, non-playing app
    /// never pre-warms the neural engine, and gives back its memory where
    /// the platform ends background processes for it.
    func handleScenePhaseChange(toBackground: Bool) {
        neuralPrewarm.sceneActivityChanged(!toBackground)
        guard toBackground, PlatformTuning.releasesNeuralOnBackground else { return }
        playback.releaseNeuralEngineIfIdle()
    }

    // MARK: - Model lifecycle

    /// Tracks install-state transitions both ways. Model deleted (or download
    /// reverted) while a Kokoro voice is active → drop back to the system
    /// voice (a stand-in — the stored pref survives) and free the engine.
    /// Model installed mid-session → re-engage the voice preference so the
    /// neural default speaks without a relaunch.
    private func observeModelState() {
        modelManager.$state
            .map { state -> Bool in
                if case .installed = state { return true }
                return false
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] installed in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if installed {
                        self.handleModelInstalled()
                        self.neuralPrewarm.reevaluate()
                    } else {
                        if self.playback.voice.engine == .kokoro {
                            self.playback.voice = self.engine.defaultVoice   // stand-in; pref kept
                        }
                        // The install's switch to the removed voice goes
                        // too, while System still reads ahead of its splice.
                        self.playback.cancelVoiceHandoff()
                        self.kokoroEngine.release()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// R5: the engine warms while the current voice keeps speaking, then
    /// switches at a sentence boundary; an explicit stored System choice
    /// stays put. A retired Kokoro id's upgrade to the current default
    /// becomes final now, so that resolution is persisted once. On a hot
    /// phone (R11) the switch waits for the cool-down.
    private func handleModelInstalled() {
        let defaults = UserDefaults.standard
        let resolved = resolvedVoicePreference(from: defaults)
        if let stored = defaults.string(forKey: PrefKey.voiceID), stored != resolved.id {
            defaults.set(resolved.id, forKey: PrefKey.voiceID)
        }
        if thermalGuard.isHot {
            thermalGuard.holdNaturalVoiceUntilCool()
            return
        }
        playback.switchVoiceAtSentenceBoundary(to: resolved)
    }

    /// An orderly exit ends the live session, so the next launch doesn't
    /// report a closed-by-iOS stop. Synchronous: the process is going away
    /// (the notification is posted on the main thread).
    /// Launch: reopens the reader that was showing when Aloud last closed,
    /// paused at its place (`LaunchRestore`), then keeps the slot in step
    /// with the stack.
    func restoreLastReader(_ lastReader: LastReaderStore, enabled: Bool) {
        if let id = LaunchRestore.readerToReopen(lastReaderID: lastReader.load(),
                                                 documents: documentStore.documents,
                                                 stop: playback.stopped, enabled: enabled) {
            router.restoreReader(id)
        }
        router.$path
            .map(LaunchRestore.readerID(in:))
            .removeDuplicates()
            .sink { lastReader.save($0) }
            .store(in: &cancellables)
    }

    /// Every pause and stop writes the place to disk at once, not within the
    /// store's 2 s: a suspended iPhone app can be ended without notice.
    /// After the controller's own progress write (a natural end reports its
    /// 1.0 just after the status changes), so on the next main-queue turn.
    private func flushProgressWhenListeningStops() {
        playback.$status
            .map { $0 == .playing || $0 == .buffering }
            .removeDuplicates()
            .filter { !$0 }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak documentStore] _ in documentStore?.flushPendingProgress() }
            .store(in: &cancellables)
    }

    private func observeTermination() {
        PlatformLifecycle.publisher(for: .willTerminate)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.playback.applicationWillTerminate() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Preferences

    enum PrefKey {
        static let voiceID = "aloud.prefs.v1.voiceID"
        static let rate = "aloud.prefs.v1.rate"
        static let skipBrackets = "aloud.prefs.v1.skipBrackets"
        /// LEGACY: read by nothing; the V4 migration removes it once.
        static let autoScroll = "aloud.prefs.v1.autoScroll"
        static let wordHighlight = "aloud.prefs.v1.wordHighlight"
        static let migratedV2 = "aloud.prefs.migratedV2"
        static let migratedV3 = "aloud.prefs.migratedV3"
        static let migratedV4 = "aloud.prefs.migratedV4"
    }

    /// The voice ids a stored preference may name: the curated Kokoro voices
    /// (stock speakers and Aloud's blends) plus the stable System id. Nonisolated because it is a default
    /// argument of `runListeningMigrationIfNeeded`.
    nonisolated static var curatedVoiceIDs: Set<String> {
        Set(KokoroVoiceCatalog.curatedVoices.map(\.id) + [AVSpeechEngine.systemVoiceID])
    }

    /// One-shot versioned migrations, guarded by `migratedV2`.
    /// V2: skip-brackets became the default — an install that had explicitly
    /// turned it OFF flips to ON once (an unset value keeps following the
    /// compiled-in default, so future default changes still flow), and the
    /// system roster collapsed to the single stable "system" id — a stored
    /// concrete AVSpeech identifier becomes "system" so the pref survives
    /// installed-voice changes. Retired Kokoro ids are deliberately NOT
    /// rewritten here: `resolveVoicePreference` maps them per launch, and the
    /// upgrade to the current default only persists once a model install
    /// makes it final (`handleModelInstalled`).
    private static func migratePreferences(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: PrefKey.migratedV2) else { return }
        if defaults.object(forKey: PrefKey.skipBrackets) != nil {
            defaults.set(true, forKey: PrefKey.skipBrackets)
        }
        if let voiceID = defaults.string(forKey: PrefKey.voiceID),
           !voiceID.hasPrefix(KokoroVoiceCatalog.voiceIDPrefix),
           voiceID != AVSpeechEngine.systemVoiceID {
            defaults.set(AVSpeechEngine.systemVoiceID, forKey: PrefKey.voiceID)
        }
        defaults.set(true, forKey: PrefKey.migratedV2)
    }

    /// R7: the most recently opened book's own pins, so nobody hears their
    /// current book change when per-book pinning goes away. The rate is
    /// clamped; a voice counts only while it is still curated. Unpinned
    /// values stay nil, so the migration never writes a resolved default or
    /// the System stand-in (which would block R5's switch to Michael).
    ///
    /// Without the model, a "system" pin is that stand-in too: the old voice
    /// sheet then listed only System, already checked, and tapping it still
    /// pinned "system". Every book already plays System until the install,
    /// so skipping the pin changes nothing now and lets R5 switch to Michael.
    nonisolated static func migratedListeningGlobals(documents: [LibraryDocument],
                                                     curatedVoiceIDs: Set<String>,
                                                     modelInstalled: Bool) -> (rate: Double?, voiceID: String?) {
        let opened = documents.compactMap { document in
            document.lastOpenedAt.map { (document, $0) }
        }
        guard let recent = opened.max(by: { $0.1 < $1.1 })?.0 else { return (nil, nil) }
        let voiceID = recent.preferredVoiceID.flatMap { id -> String? in
            guard curatedVoiceIDs.contains(id) else { return nil }
            return !modelInstalled && id == AVSpeechEngine.systemVoiceID ? nil : id
        }
        return (recent.preferredRate.map(PlaybackController.clampedRate), voiceID)
    }

    /// The launch migration's `modelInstalled`. Verifying counts as
    /// installed: an install from before the pinned files re-hashes once at
    /// launch, and its files are on disk meanwhile, so an explicit System
    /// voice choice must survive the migration.
    static func migrationSeesModel(_ manager: ModelManager) -> Bool {
        manager.isInstalled || manager.isVerifying
    }

    /// Copies `migratedListeningGlobals` into the two app-wide keys, once
    /// (guarded by `migratedV3`). It never touches skipBrackets or the
    /// documents: the per-book values stay on disk for one release.
    /// Without the model it also drops a stored global "system": the old
    /// Settings picker had the same single checked System row, so that value
    /// is no choice either.
    static func runListeningMigrationIfNeeded(_ defaults: UserDefaults,
                                              documents: [LibraryDocument],
                                              modelInstalled: Bool,
                                              curatedVoiceIDs: Set<String> = AppModel.curatedVoiceIDs) {
        guard !defaults.bool(forKey: PrefKey.migratedV3) else { return }
        if !modelInstalled, defaults.string(forKey: PrefKey.voiceID) == AVSpeechEngine.systemVoiceID {
            defaults.removeObject(forKey: PrefKey.voiceID)
        }
        let globals = migratedListeningGlobals(documents: documents, curatedVoiceIDs: curatedVoiceIDs,
                                               modelInstalled: modelInstalled)
        if let rate = globals.rate { defaults.set(rate, forKey: PrefKey.rate) }
        if let voiceID = globals.voiceID { defaults.set(voiceID, forKey: PrefKey.voiceID) }
        defaults.set(true, forKey: PrefKey.migratedV3)
    }

    /// V4, once (guarded by `migratedV4`): calm follow (R16) replaced the
    /// scroll-following toggle, so its stored value goes. No other key is
    /// touched.
    static func runCalmFollowMigrationIfNeeded(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: PrefKey.migratedV4) else { return }
        defaults.removeObject(forKey: PrefKey.autoScroll)
        defaults.set(true, forKey: PrefKey.migratedV4)
    }

    private func restorePreferences(from defaults: UserDefaults) {
        playback.rate = globalRate
        if let skip = defaults.object(forKey: PrefKey.skipBrackets) as? Bool {
            playback.skipBrackets = skip
        }
        applyVoicePreference()
    }

    // MARK: - Voice preference

    /// Pure resolution of a stored voice id against the curated roster:
    /// a curated id maps to its voice; a retired Kokoro speaker maps to the
    /// neural default; any other id (a legacy concrete AVSpeech identifier)
    /// maps to the stable system voice; nothing stored means the preferred
    /// default for the device. Static so it's unit-testable.
    nonisolated static func resolveVoicePreference(storedID: String?,
                                                   curated: [TtsVoice],
                                                   neuralDefault: TtsVoice,
                                                   systemDefault: TtsVoice,
                                                   modelInstalled: Bool) -> TtsVoice {
        guard let storedID else { return modelInstalled ? neuralDefault : systemDefault }
        if let voice = curated.first(where: { $0.id == storedID }) { return voice }
        return storedID.hasPrefix(KokoroVoiceCatalog.voiceIDPrefix)
            ? neuralDefault : systemDefault
    }

    private func resolvedVoicePreference(from defaults: UserDefaults) -> TtsVoice {
        Self.resolveVoicePreference(storedID: defaults.string(forKey: PrefKey.voiceID),
                                    curated: kokoroEngine.voices + engine.voices,
                                    neuralDefault: kokoroEngine.defaultVoice,
                                    systemDefault: engine.defaultVoice,
                                    modelInstalled: modelManager.isInstalled)
    }

    /// The voice the stored preference engages now: a Kokoro voice only
    /// while the model is installed — otherwise the system voice silently
    /// stands in and the stored pref survives (`handleModelInstalled`
    /// re-engages it). Also what the heat policy returns to after cooling.
    private func engagedVoicePreference() -> TtsVoice {
        let voice = resolvedVoicePreference(from: .standard)
        return voice.engine == .kokoro && !modelManager.isInstalled ? engine.defaultVoice : voice
    }

    private func applyVoicePreference() {
        playback.voice = engagedVoicePreference()
    }

    /// Two deliberate-pick seams, one app-wide scope. Programmatic writes
    /// (launch restore, the System stand-in, neural fallback, live slider
    /// steps) never reach these subjects, so they are never persisted.
    private func persistPreferenceChanges(to defaults: UserDefaults) {
        playback.rateSelections
            .sink { [weak self] rate in
                defaults.set(rate, forKey: PrefKey.rate)
                self?.globalRate = rate
            }
            .store(in: &cancellables)

        playback.voiceSelections
            .sink { defaults.set($0.id, forKey: PrefKey.voiceID) }
            .store(in: &cancellables)

        playback.$skipBrackets
            .dropFirst()
            .removeDuplicates()
            .sink { defaults.set($0, forKey: PrefKey.skipBrackets) }
            .store(in: &cancellables)
    }
}
