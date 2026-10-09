import Foundation

/// What the iPhone's Contents sheet remembers between openings (P029, P033,
/// R3-14).
///
/// The Mac's panel stays open beside the page, so its query and results
/// simply stay. The iPhone's sheet closes on every pick, so it remembers
/// the search instead: reopened on the same book while the listener is
/// still stepping through the hits, it shows the same query's results with
/// the last pick marked, and the next hit is a tap away. Any edit to the
/// field, Cancel, another book, or a pick of a chapter or a place forgets
/// it, and so does time and listening on: ten minutes after the pick, or
/// once the playhead has left the picked hit's chapter (in a book without
/// chapters, moved more than 40 sentences from it), Contents opens on its
/// list again.
///
/// It also carries one request across the sheet's presentation: the
/// chapter line's search action asks for the field to take focus, and its
/// Contents item asks for the list; the sheet takes each request once as it
/// appears.
///
/// In-process only, never written to disk. Platform-neutral; the Mac
/// compiles it and never uses it.
@MainActor
final class ContentsSearchMemory {

    static let shared = ContentsSearchMemory()

    /// How long after a pick the search still comes back.
    static let window: TimeInterval = 10 * 60
    /// In a book without chapters, how far (in sentences) the playhead may
    /// move from the pick before the search is stale.
    static let unchapteredReach = 40

    /// The book the remembered search belongs to; nil when nothing is
    /// remembered.
    private(set) var documentID: UUID?
    /// The query as typed.
    var query = ""
    /// The result last picked, marked on reopening.
    var lastPickedSentence: Int?
    /// When that result was picked.
    private(set) var pickedAt: Date?

    private var searchFocusRequested = false
    private var listRequested = false

    init() {}

    /// A remembered search, as the sheet restores it.
    struct Restored: Equatable {
        let query: String
        let pickedSentence: Int?
    }

    /// Keeps `query` and the picked result's sentence for `documentID`, as
    /// a result is picked at `now`.
    func remember(query: String, pickedSentence: Int, in documentID: UUID?, now: Date = Date()) {
        guard let documentID, !Self.isBlank(query) else {
            forget()
            return
        }
        self.documentID = documentID
        self.query = query
        lastPickedSentence = pickedSentence
        pickedAt = now
    }

    /// The search to restore as Contents opens on `documentID` at `now`
    /// with the playhead on `playhead`, or nil. A search remembered for
    /// another book, picked more than `window` ago, or left behind by the
    /// playhead (`isStale`) is forgotten here.
    func restore(for documentID: UUID?, playhead: Int, navigation: ReaderNavigation,
                 now: Date) -> Restored? {
        guard let remembered = self.documentID else { return nil }
        guard remembered == documentID, !Self.isBlank(query),
              !isStale(playhead: playhead, navigation: navigation, now: now) else {
            forget()
            return nil
        }
        return Restored(query: query, pickedSentence: lastPickedSentence)
    }

    /// Whether the remembered search is no longer the one being stepped
    /// through: picked more than `window` before `now`, or the playhead has
    /// left the picked hit's chapter (more than `unchapteredReach`
    /// sentences from it in a book without chapters).
    func isStale(playhead: Int, navigation: ReaderNavigation, now: Date) -> Bool {
        guard let pickedAt, now.timeIntervalSince(pickedAt) <= Self.window else { return true }
        guard let picked = lastPickedSentence else { return false }
        if navigation.isChaptered {
            return navigation.chapterIndex(containing: playhead) != navigation.chapterIndex(containing: picked)
        }
        return abs(playhead - picked) > Self.unchapteredReach
    }

    /// Asks the next Contents sheet to open at full height with its field
    /// focused.
    func requestSearchFocus() {
        searchFocusRequested = true
    }

    /// Whether a search focus was asked for since the last call; asking
    /// clears it, so one request focuses one opening.
    func consumeSearchFocus() -> Bool {
        defer { searchFocusRequested = false }
        return searchFocusRequested
    }

    /// Asks the next Contents sheet to open on its list: it skips the
    /// remembered search once, without forgetting it.
    func requestList() {
        listRequested = true
    }

    /// Whether the list was asked for since the last call; asking clears
    /// it, so one request skips one restore.
    func consumeListRequest() -> Bool {
        defer { listRequested = false }
        return listRequested
    }

    /// Drops the remembered search (not a pending focus or list request).
    func forget() {
        documentID = nil
        query = ""
        lastPickedSentence = nil
        pickedAt = nil
    }

    static func isBlank(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
