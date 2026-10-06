import Combine
import Foundation
import Observation
import SwiftUI

/// "Where you stopped" on disk: every book's kept places in one small
/// versioned file beside library.json (`Library/places.json`), so it goes
/// with the library — the reset hook's wipe removes it too — and never
/// touches a book's DocContent or its *.content.json cache.
///
/// Places belong to the content they index: a book re-extracted under a new
/// content hash shows none (its saved progress resets to the start the same
/// way), and its next stop replaces the old list. Books that leave the shelf
/// are swept (`retain(only:)`).
///
/// Writes are synchronous and atomic, at each recorded stop: a few an hour,
/// a few KB, and one may come from willTerminate, where a deferred write
/// would die with the process. A file that fails to decode, or comes from a
/// newer version, reads as empty and the next write replaces it. Tests point
/// `fileURL` at a temp directory.
@MainActor
@Observable
final class PlaceHistoryStore {

    /// The app's store, over the real file. Built on first use, which
    /// AppModel makes after the reset hook's wipe.
    static let shared = PlaceHistoryStore()

    static let version = 1

    let fileURL: URL
    private(set) var books: [UUID: BookPlaces]

    /// The shelf observation `AppModel.observePlaceHistory()` sets up.
    @ObservationIgnored var shelfObservation: AnyCancellable?
    /// Whether the shelf has been seen with a book on it this launch; an
    /// empty shelf before that (a library that failed to load) sweeps
    /// nothing.
    @ObservationIgnored private var hasSeenShelf = false

    /// Nil `fileURL` is Library/places.json, beside library.json.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? DocumentStore.libraryDir.appendingPathComponent("places.json")
        self.fileURL = url
        books = Self.read(url)
    }

    /// `documentID`'s places, newest first; none for another content hash.
    func places(for documentID: UUID?, contentHash: String) -> [PlaceHistoryEntry] {
        guard let documentID, let book = books[documentID], book.contentHash == contentHash else { return [] }
        return book.places
    }

    /// Applies the rules (`PlaceHistory.recording`) to the book's list — a
    /// fresh one when `contentHash` differs from the list's — and writes
    /// before returning. A stop the rules drop writes nothing.
    func record(_ stop: PlaceStop, contentHash: String) {
        let existing = books[stop.documentID].flatMap { $0.contentHash == contentHash ? $0.places : nil } ?? []
        let places = PlaceHistory.recording(stop, into: existing)
        guard places != existing else { return }
        books[stop.documentID] = BookPlaces(documentID: stop.documentID, contentHash: contentHash, places: places)
        write()
    }

    func forget(_ documentID: UUID) {
        guard books.removeValue(forKey: documentID) != nil else { return }
        write()
    }

    /// Drops every book not in `ids` (the shelf).
    func retain(only ids: Set<UUID>) {
        let gone = books.keys.filter { !ids.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { books.removeValue(forKey: id) }
        write()
    }

    /// The shelf changed: sweep the books that left it. An empty shelf
    /// before any book was seen sweeps nothing.
    func shelfChanged(to ids: Set<UUID>) {
        if !ids.isEmpty { hasSeenShelf = true }
        guard hasSeenShelf else { return }
        retain(only: ids)
    }

    // MARK: - File

    private struct File: Codable {
        var version: Int
        var books: [BookPlaces]
    }

    private static func read(_ url: URL) -> [UUID: BookPlaces] {
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(File.self, from: data),
              file.version <= version else { return [:] }
        return Dictionary(file.books.map { ($0.documentID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func write() {
        let sorted = books.values.sorted { $0.documentID.uuidString < $1.documentID.uuidString }
        guard let data = try? Self.encoder.encode(File(version: Self.version, books: sorted)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// ISO 8601 dates, as library.json writes them.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Environment

/// The store Contents reads "Where you stopped" from. Nil by default, so a
/// test host that injects only the controller shows Contents as before;
/// both app roots inject `PlaceHistoryStore.shared`.
private struct PlaceHistoryKey: EnvironmentKey {
    static let defaultValue: PlaceHistoryStore? = nil
}

extension EnvironmentValues {
    var placeHistory: PlaceHistoryStore? {
        get { self[PlaceHistoryKey.self] }
        set { self[PlaceHistoryKey.self] = newValue }
    }
}
