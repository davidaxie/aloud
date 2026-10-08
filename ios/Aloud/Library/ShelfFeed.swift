import CoreGraphics
import Foundation

// MARK: - Shelf feed

/// The Library's shelf (`ShelfLayout`), rebuilt only while the Library
/// shows. Under the reader (or Classics) the Library stays in the stack,
/// and the controller saves progress every sentence: a hidden shelf rebuilt
/// for each save is work nobody sees. A publish while covered marks the
/// shelf stale; the Library showing again rebuilds it once, from the store
/// as it is then. Both apps' Libraries feed their shelf through it.
struct ShelfFeed {
    private(set) var layout = ShelfLayout.empty
    /// A publish arrived while the Library was covered.
    private(set) var isStale = false
    /// Layouts built (tests).
    private(set) var builds = 0

    /// A publish of the store or of the loaded book. False when the feed is
    /// unchanged (covered and already stale), so the view writes no state.
    /// `stop` is the controller's unattended stop, which keeps a book
    /// stopped in its last minute on offer (`DocumentStore.isAtItsEnd`).
    mutating func publish(_ documents: [LibraryDocument], loadedID: UUID?, stop: PlaybackStop? = nil,
                          libraryShows: Bool) -> Bool {
        guard libraryShows else {
            guard !isStale else { return false }
            isStale = true
            return true
        }
        layout = ShelfLayout(for: documents, loadedID: loadedID, stop: stop)
        isStale = false
        builds += 1
        return true
    }

    /// The Library shows again: a stale shelf is rebuilt, once; a current
    /// one is left alone.
    mutating func libraryShown(_ documents: [LibraryDocument], loadedID: UUID?, stop: PlaybackStop? = nil) -> Bool {
        guard isStale else { return false }
        return publish(documents, loadedID: loadedID, stop: stop, libraryShows: true)
    }
}

// MARK: - Focus after a removal

extension ShelfLayout {
    /// Where focus goes when `removed` leaves the shelf: the next grid
    /// card, else the one before it, else the Continue card; from the
    /// Continue card, the grid's first. nil: no card is left. The Mac's
    /// keyboard focus and the iPhone's VoiceOver focus both follow it.
    static func focusAfterRemoving(_ removed: UUID, hero: UUID?, grid: [UUID]) -> UUID? {
        if let index = grid.firstIndex(of: removed) {
            if index + 1 < grid.count { return grid[index + 1] }
            if index > 0 { return grid[index - 1] }
            return hero
        }
        return removed == hero ? grid.first : nil
    }

    /// The same, read off a built shelf (before the removal).
    static func focusAfterRemoving(_ removed: UUID, in layout: ShelfLayout) -> UUID? {
        focusAfterRemoving(removed, hero: layout.hero?.id, grid: layout.grid.map(\.id))
    }
}

// MARK: - Phone shelf metrics

/// The iPhone shelf's rhythm, pure so a test pins it without a screen: two
/// columns (one at the accessibility sizes), a column gap that opens up
/// above the narrowest phones, and a row gap wide enough that a caption
/// never runs into the covers below it (the Mac's 32, `MacGridMetrics`).
struct PhoneShelfMetrics: Equatable {
    /// The widest screen that keeps the tighter column gap.
    static let compactWidth: CGFloat = 375

    /// From one row's last caption line to the next row's covers.
    static let rowSpacing: CGFloat = Theme.Space.xxl
    /// From the bar to the first card.
    static let topPadding: CGFloat = Theme.Space.lg
    /// From the Continue card to the grid.
    static let heroToGrid: CGFloat = Theme.Space.xxl
    /// The screen's side margin, as every iPhone screen has it.
    static let gutter: CGFloat = Theme.Space.screenGutter

    let columns: Int
    let columnSpacing: CGFloat

    /// `width` is the screen's (the shelf's scroll view); `isAccessibilitySize`
    /// is the Dynamic Type size's.
    init(width: CGFloat, isAccessibilitySize: Bool) {
        columns = isAccessibilitySize ? 1 : 2
        columnSpacing = width > Self.compactWidth ? Theme.Space.lg : Theme.Space.md
    }

    /// One column's width, which a grid card's cover fills below the
    /// accessibility sizes.
    func columnWidth(forWidth width: CGFloat) -> CGFloat {
        let inner = width - 2 * Self.gutter - CGFloat(columns - 1) * columnSpacing
        return max(0, inner / CGFloat(columns))
    }
}

// MARK: - Edge rule

/// The hairline under an opaque paper bar (`ShelfScrollEdge`): none at
/// rest, where the bar and the page are one sheet, and shown once anything
/// has scrolled under the bar, so a cover never slides beneath a bar of
/// its own colour unmarked (the Mac's `MacEdgeScrollView`).
enum ShelfEdgeRule {
    /// Half a point of travel: a rubber-band settle never flickers it.
    static let threshold: CGFloat = 0.5

    /// `contentOffsetY` and `topInset` are the scroll view's, so the
    /// resting offset (minus the bar's inset) reads as zero.
    static func shows(contentOffsetY: CGFloat, topInset: CGFloat) -> Bool {
        contentOffsetY + topInset > threshold
    }
}
