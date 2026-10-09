import SwiftUI

/// The Library's navigation stack as data. RootView binds its NavigationStack
/// to `path`; every screen reaches the Bookshelf, Settings and the reader by
/// asking the router rather than owning a presentation flag of its own, so an
/// Open-in or a finished import can rewrite the whole stack in one assignment.
@MainActor
final class LibraryRouter: ObservableObject {

    enum Route: Hashable {
        case bookshelf
        case settings
        case reader(UUID)
    }

    /// The Library root's own modals, one at a time. They live here rather
    /// than in LibraryView's @State so Open-in can close them: the import
    /// overlay and its failure alert hang off the root, and neither can show
    /// over a picker or alert left up.
    enum RootPresentation: Equatable {
        case filePicker
        case rename
        case deleteConfirmation
        /// Why a confirmed Delete didn't happen (`DeleteFailure`).
        case deleteFailed
    }

    @Published var path: [Route] = [] {
        didSet { if path != oldValue { navigationGeneration &+= 1 } }
    }

    @Published var rootPresentation: RootPresentation? {
        // Opening one counts as moving away (the screen is covered); closing
        // one does not, since the user is back where they were. SwiftUI may
        // clear a picker's flag after its pick is handled, so a close must
        // never make that pick's import look stale.
        didSet {
            if let rootPresentation, rootPresentation != oldValue { navigationGeneration &+= 1 }
        }
    }

    /// Bumped by every real change to `path`, made by the router or by the
    /// NavigationStack itself (Back, the edge swipe), and by opening a root
    /// modal. An add records it when it starts; a different value when it
    /// ends means the user moved on, so the add must not open its book.
    private(set) var navigationGeneration: UInt64 = 0

    /// The book a reader opened by `open` starts speaking (R4), asked once by
    /// that reader. A reader shown any other way (reopened at launch, or
    /// rebuilt when the Mac's window comes back) stays paused at its place.
    private(set) var autoplayRequest: UUID?

    /// R4: the one way into the reader. The reader starts the book speaking on
    /// arrival, unless `autoplay` is false (R4-10, a card menu's silent
    /// open): then no request is left, not even an earlier book's, so the
    /// reader rests paused at its place. A reader already on top is
    /// replaced, never stacked; the same book is a no-op. R20 can attach its
    /// user-started-playback haptic here.
    func open(_ document: LibraryDocument, autoplay: Bool = true) {
        let route = Route.reader(document.id)
        guard path.last != route else { return }
        autoplayRequest = autoplay ? document.id : nil
        if case .reader = path.last {
            path[path.count - 1] = route
        } else {
            path.append(route)
        }
    }

    /// Whether the reader for `id` was opened to play; true once.
    func takeAutoplayRequest(for id: UUID) -> Bool {
        guard autoplayRequest == id else { return false }
        autoplayRequest = nil
        return true
    }

    /// Launch: the reader that was showing when Aloud last closed, over the
    /// Library, paused at its place. Only onto an untouched stack: an
    /// Open-in or anything the listener did first wins.
    func restoreReader(_ id: UUID) {
        guard path.isEmpty, rootPresentation == nil else { return }
        path = [.reader(id)]
    }

    func showBookshelf() {
        guard path.last != .bookshelf else { return }
        path.append(.bookshelf)
    }

    /// R24's More classics: the Bookshelf takes the reader's place, so the
    /// stack never holds two Bookshelves and Back from it is the Library,
    /// where the finished book stays the hero. One assignment, so
    /// `navigationGeneration` moves once.
    func showBookshelfFromReader() {
        guard case .reader = path.last else {
            showBookshelf()
            return
        }
        var next = path
        next.removeLast()
        if next.last != .bookshelf { next.append(.bookshelf) }
        path = next
    }

    func showSettings() {
        guard path.last != .settings else { return }
        path.append(.settings)
    }

    func popToRoot() {
        path.removeAll()
    }

    /// Closes `presentation` if it is the one up; a stale close is a no-op.
    func dismissRootPresentation(_ presentation: RootPresentation) {
        if rootPresentation == presentation { rootPresentation = nil }
    }

    /// Open-in: the bare Library root, before the import starts, so its
    /// overlay and any failure alert have the screen. Without animation: the
    /// user is arriving from another app and never saw what was up, and an
    /// instant dismissal is done before the import can fail.
    func clearForOpenIn() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rootPresentation = nil
            popToRoot()
        }
    }
}
