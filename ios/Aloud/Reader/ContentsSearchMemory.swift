import Foundation

/// What the iPhone's Contents sheet remembers between openings (P029, P033).
///
/// The Mac's panel stays open beside the page, so its query and results
/// simply stay. The iPhone's sheet closes on every pick, so it remembers
/// the search instead: reopened on the same book, it shows the same query's
/// results with the last pick marked, and the next hit is a tap away. Any
/// edit to the field, Cancel, or another book forgets it.
///
/// It also carries one request across the sheet's presentation: the
/// chapter line's search action asks for the field to take focus, and the
/// sheet takes that request once as it appears.
///
/// In-process only, never written to disk. Platform-neutral; the Mac
/// compiles it and never uses it.
@MainActor
final class ContentsSearchMemory {

    static let shared = ContentsSearchMemory()

    /// The book the remembered search belongs to; nil when nothing is
    /// remembered.
    private(set) var documentID: UUID?
    /// The query as typed.
    var query = ""
    /// The result last picked, marked on reopening.
    var lastPickedSentence: Int?

    private var searchFocusRequested = false

    init() {}

    /// A remembered search, as the sheet restores it.
    struct Restored: Equatable {
        let query: String
        let pickedSentence: Int?
    }

    /// Keeps `query` and the picked result's sentence for `documentID`, as
    /// a result is picked.
    func remember(query: String, pickedSentence: Int, in documentID: UUID?) {
        guard let documentID, !Self.isBlank(query) else {
            forget()
            return
        }
        self.documentID = documentID
        self.query = query
        lastPickedSentence = pickedSentence
    }

    /// The search to restore as Contents opens on `documentID`, or nil.
    /// A search remembered for another book is forgotten here.
    func restore(for documentID: UUID?) -> Restored? {
        guard let remembered = self.documentID else { return nil }
        guard remembered == documentID, !Self.isBlank(query) else {
            forget()
            return nil
        }
        return Restored(query: query, pickedSentence: lastPickedSentence)
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

    /// Drops the remembered search (not a pending focus request).
    func forget() {
        documentID = nil
        query = ""
        lastPickedSentence = nil
    }

    static func isBlank(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
