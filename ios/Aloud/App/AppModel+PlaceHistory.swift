import Combine
import Foundation

// "Where you stopped": AppModel's side. The controller reports every end of
// listening (`onPlaceStop`); the store keeps what the rules keep, for the
// content the library holds; books that leave the shelf take their places
// with them.

extension AppModel {

    /// The app's place history (both app roots inject it for Contents).
    var placeHistory: PlaceHistoryStore { PlaceHistoryStore.shared }

    /// Wires "Where you stopped". Call once, at the end of `init`, after
    /// `onProgress` is set: the stop then lands on the sentence progress
    /// was just saved at. Takes the session iOS ended at the last launch,
    /// if any, and sweeps books no longer on the shelf now and whenever it
    /// changes.
    func observePlaceHistory() {
        let history = placeHistory
        let store = documentStore
        playback.onPlaceStop = { [weak history, weak store] stop in
            guard let history, let store else { return }
            Self.record(stop, in: history, shelf: store.documents)
        }
        if let recovered = playback.takeRecoveredPlaceStop() {
            Self.record(recovered, in: history, shelf: store.documents)
        }
        history.shelfObservation = store.$documents
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .sink { [weak history] ids in history?.shelfChanged(to: ids) }
    }

    /// Records `stop` for a book on the shelf, under the stop's content hash
    /// or, for a recovered stop that has none, the library record's. A stop
    /// for a book that has left the shelf is dropped.
    static func record(_ stop: PlaceStop, in history: PlaceHistoryStore, shelf: [LibraryDocument]) {
        guard let document = shelf.first(where: { $0.id == stop.documentID }) else { return }
        history.record(stop, contentHash: stop.contentHash ?? document.contentHash)
    }
}
