import Foundation

/// R18: the Continue card's circle plays and pauses in place, without
/// opening the reader. Built on the controller's public API: the loaded book
/// just toggles; any other book is loaded first, then played. One load is in
/// flight at a time, and a second tap on the same book stops it.
///
/// R26: the Continue listening shortcut plays through the same instance
/// (`resume`), so the card shows its load and a circle tap can stop it.
/// AppModel owns it for the app's lifetime.
@MainActor
final class ContinuePlayback: ObservableObject {

    typealias Loader = @MainActor () async throws -> (document: LibraryDocument, content: DocContent)

    /// The book being loaded for a circle tap or the shortcut. The card shows
    /// it as buffering, so the tap answers at once even while the text is
    /// still extracting.
    @Published private(set) var pendingDocumentID: UUID?

    /// The load in flight. Its value rethrows the loader's error, or throws
    /// CancellationError once a tap cancelled or replaced it.
    private var task: Task<Void, Error>?

    /// `loader` returns the live record with its content. `onLoaded` runs once
    /// the controller holds the book; `onFailure` when it couldn't be loaded.
    func toggle(_ document: LibraryDocument, playback: PlaybackController,
                loader: @escaping Loader,
                onLoaded: @escaping @MainActor (UUID) -> Void = { _ in },
                onFailure: @escaping @MainActor () -> Void = {}) {
        if playback.document?.id == document.id {
            cancel()
            playback.togglePlayPause()
            return
        }
        // The second tap on a book still loading: the arc stops, nothing plays.
        if pendingDocumentID == document.id {
            cancel()
            return
        }
        start(document, playback: playback, loader: loader, onLoaded: onLoaded, onFailure: onFailure)
    }

    /// Plays `document`, never pauses it (the shortcut). The loaded book
    /// plays unless the listener already hears it. A circle load of the same
    /// book in flight is joined, never cancelled, so the loader runs once.
    /// Any other book loads like a tap's, with the card's arc meanwhile.
    /// Rethrows the loader's error; throws CancellationError when a circle
    /// tap cancelled or replaced the load.
    func resume(_ document: LibraryDocument, playback: PlaybackController,
                loader: @escaping Loader,
                onLoaded: @escaping @MainActor (UUID) -> Void = { _ in }) async throws {
        if playback.document?.id == document.id {
            cancel()
            if !playback.isListenerPlaying { playback.play() }
            return
        }
        let load: Task<Void, Error>
        if pendingDocumentID == document.id, let pending = task {
            load = pending
        } else {
            load = start(document, playback: playback, loader: loader, onLoaded: onLoaded, onFailure: {})
        }
        try await load.value
        // The load finished, but a tap since then put another book in the
        // controller (or none): this run no longer speaks for the listener.
        guard playback.document?.id == document.id else { throw CancellationError() }
    }

    /// Drops the load in flight; its result, if it still arrives, is ignored.
    func cancel() {
        task?.cancel()
        finish()
    }

    /// A book opens in the reader: a circle or shortcut load of another
    /// book stops, so it can't take the controller from the page on screen.
    /// A load of the same book carries on, and the reader joins it.
    func readerOpens(_ documentID: UUID) {
        if let pending = pendingDocumentID, pending != documentID { cancel() }
    }

    /// Mark as finished and Delete: the controller lets go of the book, and
    /// a circle or shortcut load of it stops. Left running, that load would
    /// reopen a just-finished book at its end and play it from the top, and
    /// its progress writes would undo the mark. A shortcut waiting on it is
    /// superseded.
    func letGo(of documentID: UUID, playback: PlaybackController) {
        if pendingDocumentID == documentID { cancel() }
        if playback.document?.id == documentID { playback.unload() }
    }

    /// The one load path for a tap and the shortcut: load, `onLoaded`, then
    /// play unless the listener already hears the book. Starting a load
    /// cancels the one before it. A reader that put another book in the
    /// controller meanwhile (any open path: a grid card, a Classics add,
    /// Open in) keeps it: the late result is dropped, silently.
    @discardableResult
    private func start(_ document: LibraryDocument, playback: PlaybackController,
                       loader: @escaping Loader,
                       onLoaded: @escaping @MainActor (UUID) -> Void,
                       onFailure: @escaping @MainActor () -> Void) -> Task<Void, Error> {
        cancel()
        let id = document.id
        let heldAtStart = playback.document?.id
        pendingDocumentID = id
        // Whether the controller now holds a book that is neither this one
        // nor the one it held when the tap came.
        let takenOver = { playback.document.map { $0.id != id && $0.id != heldAtStart } ?? false }
        let load = Task { [weak self] in
            let loaded: (document: LibraryDocument, content: DocContent)
            do {
                loaded = try await loader()
            } catch {
                // Cancelled, or another tap took over while it loaded: silent.
                guard let self, !Task.isCancelled, self.pendingDocumentID == id else { throw CancellationError() }
                self.finish()
                if takenOver() { throw CancellationError() }
                if !(error is CancellationError) { onFailure() }
                throw error
            }
            guard let self, !Task.isCancelled, self.pendingDocumentID == id else { throw CancellationError() }
            self.finish()
            if takenOver() { throw CancellationError() }
            playback.load(document: loaded.document, content: loaded.content)
            onLoaded(id)
            // A reader that opened the book meanwhile may already be
            // playing it. A voice sample it started over the pause isn't
            // that: the tap still plays (the sample carries on as the book).
            if !playback.isListenerPlaying { playback.play() }
        }
        task = load
        return load
    }

    private func finish() {
        task = nil
        pendingDocumentID = nil
    }

    /// The status the card shows for `documentID`: buffering while its circle
    /// load runs, paused for any book the controller doesn't hold, else the
    /// controller's own status; Try again while `stop`, the book's own, is a
    /// playback error, as the reader bars and the Mac's Playback menu show
    /// it (`PlayButtonState.circleStatus`), so the card's circle never says
    /// "Play" beside its "Playback stopped" line.
    nonisolated static func effectiveStatus(documentID: UUID, loadedID: UUID?, status: PlayerStatus,
                                            pendingID: UUID?, stop: StopReason?) -> PlayerStatus {
        if pendingID == documentID { return .buffering }
        guard loadedID == documentID else { return PlayButtonState.circleStatus(.paused, stop: stop) }
        return PlayButtonState.circleStatus(status, stop: stop)
    }
}
