import Observation

/// The field ⌘F focuses: "Search this book" in the reader's Contents panel,
/// or the Classics search in the toolbar.
enum SearchTarget: Hashable, Sendable {
    case contents
    case classics
}

/// The window's transient UI state: which panels and popovers are up, and
/// which search field ⌘F asked for. One instance, owned by `AloudMacApp` and
/// read through the environment, so a menu command and a toolbar button
/// change the same flag. Nothing here persists; preferences live in the
/// shared stores.
@MainActor
@Observable
final class MacUIState {
    /// The reader's Contents panel (⌃⌘S, the toolbar button, a click on the
    /// chapter line).
    var isContentsShown = false
    /// The Listening popover (voice and speed).
    var isListeningShown = false
    /// The Aa popover (text size and appearance).
    var isAppearanceShown = false
    /// Set by ⌘F; the view that owns the field focuses it and clears this.
    var searchFocus: SearchTarget?

    init() {}
}
