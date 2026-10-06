import AppKit
import Combine
import Foundation
import Observation

/// Where the window is: the root of the one navigation stack, or what was
/// pushed onto it.
enum MacPlace: Equatable {
    case library
    case classics
    case reader(UUID)

    init(path: [LibraryRouter.Route]) {
        switch path.last {
        case .bookshelf?: self = .classics
        case .reader(let id)?: self = .reader(id)
        // The Mac shows Settings in its own window; a stray route reads as
        // the Library under it.
        case .settings?, nil: self = .library
        }
    }

    var isReader: Bool {
        if case .reader = self { return true }
        return false
    }
}

/// What every menu item and key does, and when it can: over the shared
/// functions only (`PlaybackController`, `ContinuePlayback`, `SleepTimer`,
/// `LibraryRouter`, `ReaderNavigation`) and the window's `MacUIState`. The
/// menus, the key router and the player bar's tooltips all come here, so a
/// key and its button can't do different things. Every Playback item also
/// works in the Library, on the loaded (or Continue) book.
@MainActor
struct MacCommandActions {
    let playback: PlaybackController
    let router: LibraryRouter
    let store: DocumentStore
    let sleepTimer: SleepTimer
    let continuePlayback: ContinuePlayback
    let ui: MacUIState
    var defaults: UserDefaults = .standard

    /// Opens the Settings window: Voice & Speed… away from the reader.
    var openSettings: () -> Void = {}
    /// Brings the main window back, closed or minimized (M5), before a
    /// command that acts in it: the app delegate's Dock-click reopen.
    var showMainWindow: () -> Void = {}
    /// The reader's Follow the voice, while it offers one (`FocusedValues`).
    var followVoice: (() -> Void)?
    /// The focused Library card's Delete…, while one has focus.
    var deleteBook: (() -> Void)?
    /// A speed step is spoken (M10); muted processes only record it.
    var announce: (String) -> Void = { PlaybackController.postAnnouncement($0, muted: UITestHooks.muteAudio) }

    init(playback: PlaybackController, router: LibraryRouter, store: DocumentStore,
         sleepTimer: SleepTimer, continuePlayback: ContinuePlayback, ui: MacUIState) {
        self.playback = playback
        self.router = router
        self.store = store
        self.sleepTimer = sleepTimer
        self.continuePlayback = continuePlayback
        self.ui = ui
    }

    init(model: AppModel, ui: MacUIState) {
        self.init(playback: model.playback, router: model.router, store: model.documentStore,
                  sleepTimer: model.sleepTimer, continuePlayback: model.continuePlayback, ui: ui)
    }

    var place: MacPlace { MacPlace(path: router.path) }

    // MARK: - Enabled

    func isEnabled(_ command: MacCommand) -> Bool {
        switch command {
        case .playPause: return playback.document != nil || continueBook != nil
        case .back15, .forward15, .sleepTimer: return hasBook
        case .previousChapter: return chapterTarget(forward: false) != nil
        case .nextChapter: return chapterTarget(forward: true) != nil
        case .followVoice: return followVoice != nil
        case .faster: return Self.steppedRate(from: playback.rate, faster: true) != nil
        case .slower: return Self.steppedRate(from: playback.rate, faster: false) != nil
        case .undoJump: return playback.undoableJump != nil
        case .find: return place == .classics || place.isReader
        case .deleteBook: return deleteBook != nil
        case .toggleContents: return place.isReader
        case .biggerText: return Self.steppedTextSize(from: textSizeStep, bigger: true) != nil
        case .smallerText: return Self.steppedTextSize(from: textSizeStep, bigger: false) != nil
        case .back: return !router.path.isEmpty
        case .voiceAndSpeed, .appearance, .addFromFiles, .addClassic, .closeWindow: return true
        case .settings, .fullScreen, .minimize, .hide, .quit: return false   // AppKit's own items
        }
    }

    // MARK: - Perform

    /// Runs `command` when it is enabled. False when it isn't: a key with
    /// nothing to do is swallowed by the caller, never beeped.
    @discardableResult
    func perform(_ command: MacCommand) -> Bool {
        guard isEnabled(command) else { return false }
        // Its window first: a panel, a pushed screen or a focused field in
        // a closed or minimized window would wait there unseen.
        if needsMainWindow(command) { showMainWindow() }
        switch command {
        case .playPause: togglePlayback()
        case .back15: playback.skip(seconds: -PlaybackController.skipInterval)
        case .forward15: playback.skip(seconds: PlaybackController.skipInterval)
        case .previousChapter: stepChapter(forward: false)
        case .nextChapter: stepChapter(forward: true)
        case .followVoice: followVoice?()
        case .faster: stepRate(faster: true)
        case .slower: stepRate(faster: false)
        case .voiceAndSpeed:
            if place.isReader { ui.isListeningShown = true } else { openSettings() }
        case .sleepTimer: break   // a submenu: `selectSleep(_:)`
        case .undoJump: playback.undoJump()
        case .find:
            // The reader's Find is Contents search (`MacContentsPanel`):
            // shown if it wasn't, with "Search this book" focused. Classics'
            // is its toolbar search.
            if place.isReader {
                ui.isContentsShown = true
                ui.searchFocus = .contents
            } else {
                ui.searchFocus = .classics
                focusClassicsSearchOn14()
            }
        case .deleteBook: deleteBook?()
        case .toggleContents: ui.isContentsShown.toggle()
        case .biggerText: stepTextSize(bigger: true)
        case .smallerText: stepTextSize(bigger: false)
        case .appearance: break   // a submenu over the shared preference
        case .back: router.path.removeLast()
        case .addFromFiles: router.rootPresentation = .filePicker
        case .addClassic:
            showClassics()
            ui.searchFocus = .classics
            focusClassicsSearchOn14()
        case .closeWindow: NSApp.keyWindow?.performClose(nil)
        case .settings, .fullScreen, .minimize, .hide, .quit: return false
        }
        return true
    }

    // MARK: - Titles

    /// The menu item's title now: Play becomes Pause, Try Again or Listen
    /// Again; chapters are pages in a PDF; Contents shows or hides.
    func title(for command: MacCommand) -> String {
        switch command {
        case .playPause:
            switch PlayButtonState(status: toggleStatus, isPreparingVoice: false, reduceMotion: false).glyph {
            case .play: return MacMenuCopy.play
            case .pause: return MacMenuCopy.pause
            case .retry: return MacMenuCopy.tryAgain
            case .listenAgain: return MacMenuCopy.listenAgain
            }
        case .previousChapter: return listsPages ? MacMenuCopy.previousPage : MacMenuCopy.previousChapter
        case .nextChapter: return listsPages ? MacMenuCopy.nextPage : MacMenuCopy.nextChapter
        case .toggleContents: return ui.isContentsShown ? MacMenuCopy.hideContents : MacMenuCopy.showContents
        default: return command.title
        }
    }

    // MARK: - Sleep timer

    /// Playback ▸ Sleep Timer: the chip's options, most recent first, with
    /// Off kept apart (shown only while armed).
    var sleepOptions: [SleepTimer.Option] { sleepTimer.menuOptions.filter { $0 != .off } }

    func sleepTitle(for option: SleepTimer.Option) -> String {
        switch option {
        case .off: return MacMenuCopy.off
        case .minutes(let minutes): return ListeningEstimate.phrase(minutes: minutes)
        case .endOfChapter: return endsAtChapter ? MacMenuCopy.endOfChapter : MacMenuCopy.endOfBook
        }
    }

    func selectSleep(_ option: SleepTimer.Option) {
        sleepTimer.select(option)
    }

    // MARK: - Pure rules

    /// One preset step (M10): the next preset above or below `rate`, so an
    /// off-preset speed moves to the nearest preset that way. nil at or past
    /// the end (Faster at 2.5× and up, Slower at 1× and down).
    nonisolated static func steppedRate(from rate: Double, faster: Bool) -> Double? {
        let epsilon = 0.001
        return faster
            ? SpeedScale.presets.first { $0 > rate + epsilon }
            : SpeedScale.presets.last { $0 < rate - epsilon }
    }

    /// One reader size step (⌘+ / ⌘−), nil past either end.
    nonisolated static func steppedTextSize(from step: Int, bigger: Bool) -> Int? {
        let next = min(max(step, 0), ReaderTextSize.steps.count - 1) + (bigger ? 1 : -1)
        return ReaderTextSize.steps.indices.contains(next) ? next : nil
    }

    /// The commands that act in the main window: File's adds, Find,
    /// Contents, Back, and Voice & Speed… in the reader. The rest act on
    /// playback, wherever the window is.
    func needsMainWindow(_ command: MacCommand) -> Bool {
        switch command {
        case .addFromFiles, .addClassic, .find, .toggleContents, .back: return true
        case .voiceAndSpeed: return place.isReader
        default: return false
        }
    }

    // MARK: - Private

    /// macOS 14 has no `searchFocused`, so Classics' toolbar field is
    /// focused through its window once Classics shows (`MacToolbarSearch`).
    private func focusClassicsSearchOn14() {
        if #unavailable(macOS 15) { MacToolbarSearch.focusSoon() }
    }

    private var hasBook: Bool { !(playback.content?.sentences.isEmpty ?? true) && playback.document != nil }

    /// The book Space plays when none is loaded: the Continue card's.
    private var continueBook: LibraryDocument? {
        DocumentStore.continueListeningCandidate(in: store.documents, loadedID: playback.document?.id)
    }

    /// What Play/Pause would act on: the loaded book, else the Continue
    /// book as its card shows it.
    private var toggleStatus: PlayerStatus {
        if playback.document != nil { return playback.status }
        guard let book = continueBook else { return .idle }
        return ContinuePlayback.effectiveStatus(documentID: book.id, loadedID: playback.document?.id,
                                                status: playback.status,
                                                pendingID: continuePlayback.pendingDocumentID)
    }

    /// The loaded book toggles; otherwise the Continue book loads and plays
    /// through the card's own path (and a second press stops the load).
    private func togglePlayback() {
        if playback.document != nil {
            playback.togglePlayPause()
            return
        }
        guard let book = continueBook else { return }
        let store = store
        let router = router
        continuePlayback.toggle(book, playback: playback,
                                loader: { try await store.liveContent(for: book) },
                                onLoaded: { store.noteOpened(id: $0) },
                                onFailure: { router.open(book) })
    }

    private var navigation: ReaderNavigation? {
        guard let document = playback.document, let content = playback.content else { return nil }
        return MacNavigationCache.navigation(for: content, kind: document.kind)
    }

    private var isPDF: Bool { playback.document?.kind == .pdf }

    /// A PDF whose Contents lists pages (no chapters found): the chapter
    /// steps are page steps.
    private var listsPages: Bool { navigation.map { $0.rowKind == .pages } ?? isPDF }

    /// What End of Chapter does: a real chapter's end, never a page row's
    /// (SleepTimer stops at chapters only in a chaptered book).
    private var endsAtChapter: Bool {
        sleepTimer.isArmed ? sleepTimer.endsAtChapter : (navigation?.isChaptered ?? false)
    }

    /// ⌘← / ⌘→ (R14's rule for chapters): back goes to the current chapter's
    /// start, or restarts it when more than 3 s of its first sentence has
    /// played, else the previous chapter's start. In a PDF that lists pages
    /// the step is one page, even where Contents groups pages into rows.
    /// nil without a chapter list or past either end.
    private func chapterTarget(forward: Bool) -> Int? {
        guard let navigation, navigation.hasChapterList else { return nil }
        let current = max(playback.currentSentence, 0)
        if !forward, navigation.stepStart(containing: current) == current,
           playback.isActive, playback.currentSentenceElapsed > PlaybackController.restartThreshold {
            return current
        }
        return navigation.stepTarget(from: current, forward: forward, rate: playback.rate)
    }

    /// A chapter step is a jump: it keeps play or pause and offers Undo
    /// jump. Restarting the chapter re-cues its first sentence instead.
    private func stepChapter(forward: Bool) {
        guard let target = chapterTarget(forward: forward) else { return }
        if target == max(playback.currentSentence, 0) {
            playback.seek(to: target, andPlay: false)
        } else {
            playback.jump(to: target, origin: .chapter)
        }
    }

    /// Add a Classic… lands in Classics. From a reader opened from Classics
    /// it goes back to that Classics, never a second one on top: the stack
    /// holds one Classics, as R24's More classics keeps it. One assignment,
    /// so the navigation generation moves once. Elsewhere it pushes one.
    private func showClassics() {
        guard let index = router.path.lastIndex(of: .bookshelf) else {
            router.showBookshelf()
            return
        }
        guard index < router.path.count - 1 else { return }
        router.path = Array(router.path.prefix(through: index))
    }

    private func stepRate(faster: Bool) {
        guard let target = Self.steppedRate(from: playback.rate, faster: faster) else { return }
        playback.selectRate(target)
        announce(ListeningCopy.spokenRate(target))
    }

    private var textSizeStep: Int {
        (defaults.object(forKey: ReaderTextSize.prefKey) as? Int) ?? ReaderTextSize.platformDefaultStep
    }

    private func stepTextSize(bigger: Bool) {
        guard let next = Self.steppedTextSize(from: textSizeStep, bigger: bigger) else { return }
        defaults.set(next, forKey: ReaderTextSize.prefKey)
    }
}

/// Focuses a window's toolbar search field: Classics' Find (⌘F) and Add a
/// Classic… on macOS 14, where SwiftUI's `searchFocused` doesn't exist.
@MainActor
enum MacToolbarSearch {
    /// The search field among a toolbar's items: a search item's own, or
    /// one inside an item's view.
    static func field(in items: [NSToolbarItem]) -> NSSearchField? {
        for item in items {
            if let search = item as? NSSearchToolbarItem { return search.searchField }
            if let view = item.view, let field = searchField(in: view) { return field }
        }
        return nil
    }

    /// Puts the caret in `window`'s toolbar search field. False with none.
    @discardableResult
    static func focus(in window: NSWindow?) -> Bool {
        guard let window, let items = window.toolbar?.items, let field = field(in: items) else { return false }
        if let search = items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first(where: { $0.searchField === field }) {
            search.beginSearchInteraction()
            return true
        }
        return window.makeFirstResponder(field)
    }

    /// Focuses the field once the toolbar has it: a pushed Classics brings
    /// its toolbar a moment later, so a few short tries, then none.
    static func focusSoon(tries: Int = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard !focus(in: NSApp.keyWindow ?? NSApp.mainWindow), tries > 1 else { return }
                focusSoon(tries: tries - 1)
            }
        }
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}

/// The loaded book's navigation, built once per content: chapter steps and
/// the menus ask on every refresh, and a build is a pass over the book.
@MainActor
enum MacNavigationCache {
    private static var cached: (hash: String, kind: DocKind, value: ReaderNavigation)?

    static func navigation(for content: DocContent, kind: DocKind) -> ReaderNavigation {
        if let cached, cached.hash == content.contentHash, cached.kind == kind { return cached.value }
        let built = ReaderNavigation(content: content, kind: kind)
        cached = (content.contentHash, kind, built)
        return built
    }
}

/// What the menus show, as one value: SwiftUI rebuilds the menu bar only
/// when it changes, never on a word or a frame.
struct MacMenuSnapshot: Equatable {
    var titles: [MacCommand: String] = [:]
    var enabled: Set<MacCommand> = []
    var sleepOptions: [SleepTimer.Option] = []
    var sleepTitles: [String] = []
    var sleepSelection: SleepTimer.Option = .off

    func title(_ command: MacCommand) -> String { titles[command] ?? command.title }
    func isEnabled(_ command: MacCommand) -> Bool { enabled.contains(command) }
}

/// The menu bar's model: the shared actions, and a snapshot of their titles
/// and enabled states, refreshed after anything they read changes. One
/// instance, owned by the app delegate, for the menus and the key router.
@MainActor
final class MacCommandState: ObservableObject {
    @Published private(set) var snapshot = MacMenuSnapshot()
    let actions: MacCommandActions
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

    init(actions: MacCommandActions) {
        self.actions = actions
        refresh()
        observe()
    }

    /// Rebuilds the snapshot now; published only when it differs.
    func refresh() {
        refreshScheduled = false
        var next = MacMenuSnapshot()
        for command in MacCommand.allCases {
            next.titles[command] = actions.title(for: command)
            if actions.isEnabled(command) { next.enabled.insert(command) }
        }
        next.sleepOptions = actions.sleepOptions
        next.sleepTitles = next.sleepOptions.map(actions.sleepTitle(for:))
        next.sleepSelection = actions.sleepTimer.option
        if next != snapshot { snapshot = next }
    }

    /// `@Published` fires before the value lands, so every change schedules
    /// one refresh on the next main-queue turn, coalesced.
    private func observe() {
        let playback = actions.playback
        let changes: [AnyPublisher<Void, Never>] = [
            playback.$status.map { _ in () }.eraseToAnyPublisher(),
            playback.$document.map { _ in () }.eraseToAnyPublisher(),
            playback.$currentSentence.map { _ in () }.eraseToAnyPublisher(),
            playback.$rate.map { _ in () }.eraseToAnyPublisher(),
            playback.$undoableJump.map { _ in () }.eraseToAnyPublisher(),
            actions.router.$path.map { _ in () }.eraseToAnyPublisher(),
            actions.store.$documents.map { _ in () }.eraseToAnyPublisher(),
            actions.sleepTimer.$option.map { _ in () }.eraseToAnyPublisher(),
            actions.sleepTimer.$endsAtChapter.map { _ in () }.eraseToAnyPublisher(),
            actions.continuePlayback.$pendingDocumentID.map { _ in () }.eraseToAnyPublisher(),
            // The text size, written by the Aa popover, Settings or ⌘+.
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            // UserDefaults posts from whichever thread wrote.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } }
            .store(in: &cancellables)
        observeUI()
    }

    /// Show/Hide Contents follows `MacUIState`, an `@Observable`.
    private func observeUI() {
        withObservationTracking {
            _ = actions.ui.isContentsShown
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                self?.observeUI()
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
