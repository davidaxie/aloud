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

    /// R4: the one way into the reader. The reader starts the book speaking on
    /// arrival. A reader already on top is replaced, never stacked; the same
    /// book is a no-op. R20 can attach its user-started-playback haptic here.
    func open(_ document: LibraryDocument) {
        let route = Route.reader(document.id)
        guard path.last != route else { return }
        if case .reader = path.last {
            path[path.count - 1] = route
        } else {
            path.append(route)
        }
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
