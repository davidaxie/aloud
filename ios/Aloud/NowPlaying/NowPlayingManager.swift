import Combine
import Foundation
import MediaPlayer

/// Lock screen, Control Center and Dynamic Island (R23): tells the system
/// the truth about what is playing, and routes its transport back.
///
/// - What it says is a `NowPlayingSnapshot`: the author as artist ("Aloud"
///   when there is none), the chapter as album (none for PDFs and
///   chapterless text), and a timeline over the in-app scrub span whose
///   (duration - elapsed) / rate is the in-app time left.
/// - Pushes are coalesced to one per main-actor turn, from the loaded
///   book, status, sentence and rate, plus the library (a rename
///   republishes the title). An unchanged snapshot is not pushed again.
/// - ReaderNavigation is built off the main actor once per content hash;
///   until it lands the push carries only title, artist, rate and art.
/// - The art is the one cover (`NowPlayingArtwork`), keyed by id, title and
///   author: a new book clears the old art at once, a rename keeps it until
///   the new render lands, and a progress change renders nothing.
/// - Skips are R14's one skip (`perform`). The lock-screen scrubber is on,
///   and lands on the nearest sentence start: the current sentence
///   restarts or re-cues (at the end of the book it stays the end, R24),
///   any other is a scrub jump that keeps play or pause and offers Undo
///   jump. No haptic: nothing was touched in the app.
/// - It is the app's only writer of the system's now-playing info, and its
///   deinit removes only its own command targets. A muted process where
///   the platform forbids it (`PlatformNowPlaying.publishesWhenMuted`)
///   writes nothing and takes no commands, so a test run never becomes the
///   system's Now Playing app.
@MainActor
final class NowPlayingManager {

    typealias Publish = @MainActor ([String: Any]?) -> Void
    typealias ArtworkRenderer = @MainActor (LibraryDocument) async -> MPMediaItemArtwork?

    /// The last push; nil when nothing is loaded.
    private(set) var snapshot: NowPlayingSnapshot?

    private let publish: Publish
    private let renderArtwork: ArtworkRenderer
    /// Whether this manager writes the system's now-playing info and takes
    /// its transport commands; false only in a muted process on a platform
    /// that keeps those quiet.
    let takesSystemNowPlaying: Bool
    private weak var playback: PlaybackController?
    /// The store's records, so a rename reaches the title before the
    /// controller's copy of the document hears of it.
    private var library: [LibraryDocument] = []
    private var cancellables: Set<AnyCancellable> = []
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var configured = false
    private var refreshScheduled = false

    /// One slot, keyed by content hash and kind, like SleepTimer's.
    private var navigation: (hash: String, kind: DocKind, value: ReaderNavigation)?
    private var buildingHash: String?

    private struct ArtworkKey: Equatable {
        let id: UUID
        let title: String
        let author: String?
    }
    private var artwork: MPMediaItemArtwork?
    private var artworkKey: ArtworkKey?
    private var artworkTask: Task<Void, Never>?

    /// `publish` nil is the system's info center, or a sink that drops
    /// every push when `outputMuted` and the platform doesn't publish then.
    init(publish: Publish? = nil,
         renderArtwork: @escaping ArtworkRenderer = NowPlayingArtwork.artwork(for:),
         outputMuted: Bool = UITestHooks.muteAudio,
         publishesWhenMuted: Bool = PlatformNowPlaying.publishesWhenMuted) {
        let takesSystem = Self.takesSystemNowPlaying(outputMuted: outputMuted,
                                                     publishesWhenMuted: publishesWhenMuted)
        takesSystemNowPlaying = takesSystem
        self.publish = publish ?? (takesSystem ? Self.publishToInfoCenter : { _ in })
        self.renderArtwork = renderArtwork
    }

    /// Everything takes the system's Now Playing except a muted process on
    /// a platform where publishing would capture the user's media keys.
    static func takesSystemNowPlaying(outputMuted: Bool, publishesWhenMuted: Bool) -> Bool {
        !outputMuted || publishesWhenMuted
    }

    /// The app's wiring, once: observe the controller and the library, then
    /// take the system's transport commands (unless kept off the system).
    func configure(playback: PlaybackController, store: DocumentStore) {
        guard !configured else { return }
        configured = true
        observe(playback: playback, documents: store.$documents.eraseToAnyPublisher())
        if takesSystemNowPlaying { registerCommands() }
    }

    /// Mirrors `playback` (and `documents`, for renames) into pushes. Tests
    /// call this directly, never `configure`, so no system command target
    /// is ever added.
    func observe(playback: PlaybackController,
                 documents: AnyPublisher<[LibraryDocument], Never> = Empty().eraseToAnyPublisher()) {
        self.playback = playback
        cancellables = []
        // @Published emits on willSet: each source only schedules a refresh,
        // which reads the controller's settled state a turn later.
        playback.$document
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        playback.$status
            .removeDuplicates()
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        playback.$currentSentence
            .removeDuplicates()
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        playback.$rate
            .removeDuplicates()
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        documents
            .sink { [weak self] documents in
                self?.library = documents
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)
    }

    deinit {
        // Only our own targets; the info center is left alone (it may
        // already describe whatever replaced us).
        for target in commandTargets {
            target.command.removeTarget(target.token)
        }
        artworkTask?.cancel()
    }

    // MARK: - Remote commands

    /// Every transport a lock screen, Control Center or headphone button can
    /// send. Skips are R14's one skip unit; next/previous track are the same
    /// 15 s skips, so every surface lands on the same sentence.
    enum RemoteTransportCommand: CaseIterable, Sendable {
        case play, pause, togglePlayPause, skipForward, skipBackward, nextTrack, previousTrack
    }

    /// Runs `command` on `playback`. Returns the landed sentence for a skip,
    /// nil otherwise.
    @discardableResult
    static func perform(_ command: RemoteTransportCommand, on playback: PlaybackController) -> Int? {
        switch command {
        case .play:
            // A car or headset sends Play on connect, often mid-sentence:
            // play() from .playing would cut and restart the sentence and
            // cancel a sleep timer's fade. A voice sample isn't the book
            // playing, so Play over one still continues it as the book.
            // At the end (R24) Play would start the book over and undo its
            // Finished: a car's Play on connect isn't Listen again, so a
            // finished book is never restarted from a pocket (as Continue
            // listening refuses it); Listen again is in the app.
            if !playback.isListenerPlaying && !playback.isAtEnd { playback.play() }
            return nil
        case .pause:
            playback.pause()
            return nil
        case .togglePlayPause:
            // At the end only a voice sample over it has anything to pause.
            if playback.isAtEnd && !playback.isActive { return nil }
            playback.togglePlayPause()
            return nil
        case .skipForward, .nextTrack:
            return playback.skip(seconds: PlaybackController.skipInterval)
        case .skipBackward, .previousTrack:
            return playback.skip(seconds: -PlaybackController.skipInterval)
        }
    }

    /// Play from the lock screen, headphones or media keys with no book
    /// loaded (a fresh launch): the app continues the Continue card's book.
    var onPlayWithNoBook: (() -> Void)?

    /// The Continue card's loads (AppModel's one ContinuePlayback), which
    /// `onPlayWithNoBook` starts: a Pause, or a second Play/Pause, while one
    /// runs stops it, as a second tap on the card's circle does.
    weak var continuePlayback: ContinuePlayback?

    /// A system transport command, then a push at once: a skip can land on
    /// the sentence already showing (a restart), which no source reports.
    func handle(_ command: RemoteTransportCommand) {
        guard let playback else { return }
        let hasBook = playback.document != nil
        if Self.stopsLoadWithNoBook(command, hasBook: hasBook,
                                    loading: continuePlayback?.pendingDocumentID != nil) {
            continuePlayback?.cancel()
            return
        }
        if Self.continuesWithNoBook(command, hasBook: hasBook) {
            onPlayWithNoBook?()
            return
        }
        Self.perform(command, on: playback)
        refresh(force: true)
    }

    /// Play and Play/Pause with nothing loaded continue the last book; Pause
    /// and the skips have nothing to act on.
    static func continuesWithNoBook(_ command: RemoteTransportCommand, hasBook: Bool) -> Bool {
        !hasBook && (command == .play || command == .togglePlayPause)
    }

    /// With nothing loaded yet but a Continue load running (the first
    /// press's), Pause and Play/Pause stop the load: the book never starts
    /// speaking after the listener pressed Pause. Play joins it.
    static func stopsLoadWithNoBook(_ command: RemoteTransportCommand, hasBook: Bool, loading: Bool) -> Bool {
        !hasBook && loading && (command == .pause || command == .togglePlayPause)
    }

    /// A lock-screen scrub to `position` (1x seconds into the published
    /// span), landed on the nearest sentence start. Returns the landed
    /// sentence, or nil with no book or before the timeline exists.
    @discardableResult
    func changePlaybackPosition(to position: TimeInterval) -> Int? {
        guard let playback,
              let span = snapshot?.span, snapshot?.duration != nil,
              let content = playback.content,
              let navigation, navigation.hash == content.contentHash else { return nil }
        let target = NowPlayingSnapshot.sentence(atElapsed: position, in: span, navigation: navigation.value)
        if target == max(playback.currentSentence, 0) {
            // At the end (R24) the last sentence is already where the book
            // stopped: a re-cue would leave the end with no Undo back, and
            // the next Play would finish it, and announce it, a second time.
            // The republish below snaps the scrubber back to the end.
            if !playback.isAtEnd {
                // Back to the start of the sentence already cued or playing.
                playback.seek(to: target, andPlay: false)
            }
        } else {
            // Keeps play or pause, offers Undo jump, and the reader follows.
            playback.jump(to: target, origin: .scrub)
        }
        refresh(force: true)
        return playback.currentSentence
    }

    /// The app's only write of the system's now-playing info, and the
    /// transport state beside it where the platform reads one.
    static func publishToInfoCenter(_ info: [String: Any]?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        PlatformNowPlaying.setState(state(for: info))
    }

    /// Stopped when nothing is published; playing while the published rate
    /// moves (the snapshot pushes 0 whenever it isn't playing); else paused.
    static func state(for info: [String: Any]?) -> NowPlayingState {
        guard let info else { return .stopped }
        let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
        return rate > 0 ? .playing : .paused
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        let commands: [(MPRemoteCommand, RemoteTransportCommand)] = [
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.skipForwardCommand, .skipForward),
            (center.skipBackwardCommand, .skipBackward),
            (center.nextTrackCommand, .nextTrack),
            (center.previousTrackCommand, .previousTrack),
        ]
        // The same 15 s skip as the in-app buttons (R14).
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: PlaybackController.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: PlaybackController.skipInterval)]
        for (command, transport) in commands {
            addHandler(command) { $0.handle(transport) }
        }

        // R23: the scrubber, landing on the nearest sentence start.
        center.changePlaybackPositionCommand.isEnabled = true
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in
                self?.changePlaybackPosition(to: position)
            }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, token))
    }

    private func addHandler(_ command: MPRemoteCommand,
                            _ action: @escaping @MainActor (NowPlayingManager) -> Void) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        commandTargets.append((command, token))
    }

    // MARK: - Pushing

    /// One push per main-actor turn, however many sources fired in it.
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh(force: Bool = false) {
        guard let playback, let loaded = playback.document else {
            if snapshot != nil {
                snapshot = nil
                artwork = nil
                artworkKey = nil
                artworkTask?.cancel()
                artworkTask = nil
                navigation = nil
                buildingHash = nil
                publish(nil)
            }
            return
        }
        // The store's record is the live one: it carries a rename first.
        let live = library.first { $0.id == loaded.id } ?? loaded
        updateArtworkIfNeeded(live)
        let next = NowPlayingSnapshot(title: live.title,
                                      author: live.author,
                                      navigation: navigationIfReady(),
                                      sentence: playback.currentSentence,
                                      status: playback.status,
                                      rate: playback.rate,
                                      sentenceElapsed: playback.currentSentenceElapsed)
        guard force || next != snapshot else { return }
        snapshot = next
        var info = next.nowPlayingInfo
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        publish(info)
    }

    // MARK: - Navigation

    /// The loaded book's navigation when it is built; otherwise starts the
    /// build (once per hash) and returns nil.
    private func navigationIfReady() -> ReaderNavigation? {
        guard let playback, let document = playback.document, let content = playback.content else { return nil }
        if let navigation, navigation.hash == content.contentHash, navigation.kind == document.kind {
            return navigation.value
        }
        guard buildingHash != content.contentHash else { return nil }
        let hash = content.contentHash
        let kind = document.kind
        buildingHash = hash
        // A pass over every word: off the main actor, while the reader opens
        // (and builds its own).
        Task.detached(priority: .utility) { [weak self] in
            let built = ReaderNavigation(content: content, kind: kind)
            await self?.adopt(built, hash: hash, kind: kind)
        }
        return nil
    }

    private func adopt(_ built: ReaderNavigation, hash: String, kind: DocKind) {
        if buildingHash == hash { buildingHash = nil }
        // A build for a book that has since been replaced is dropped.
        guard let playback, playback.content?.contentHash == hash, playback.document?.kind == kind else { return }
        navigation = (hash, kind, built)
        refresh(force: true)
    }

    // MARK: - Artwork

    private func updateArtworkIfNeeded(_ live: LibraryDocument) {
        let key = ArtworkKey(id: live.id, title: live.title, author: live.author)
        guard key != artworkKey else { return }
        // Another book's art never shows under this one; a rename keeps the
        // old art until the new render lands.
        if artworkKey?.id != key.id { artwork = nil }
        artworkKey = key
        artworkTask?.cancel()
        let render = renderArtwork
        artworkTask = Task { @MainActor [weak self] in
            let rendered = await render(live)
            guard let self, !Task.isCancelled, self.artworkKey == key else { return }
            self.artwork = rendered
            self.refresh(force: true)
        }
    }
}
