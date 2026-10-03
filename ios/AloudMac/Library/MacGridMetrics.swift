import CoreGraphics

/// The Library grid's numbers (M6, mac-ux §3.2), pure so a test pins them
/// without a window: how many columns a width holds, how wide each 2:3 cover
/// is, and where an arrow key moves focus.
///
/// A column is a cell: the cover plus the hover plate that reaches 8 pt
/// past it on every side. Cells sit 24 apart, so a plate never touches its
/// neighbour, and covers run 136-168 wide. That gives 2 columns in the
/// narrowest window (520) and 5 in the default one (1000). The grid is
/// pulled out by the plate's width on both sides, so the covers, not the
/// plates, line up with the Continue card above them. The Library measures
/// its scroll view for the width, so a legacy scroller's is already off it.
struct MacGridMetrics: Equatable {

    /// The cover's width range.
    static let coverWidths: ClosedRange<CGFloat> = 136...168
    /// How far the hover plate reaches past the cover (Radius.md, inset −8).
    static let plateOutset: CGFloat = Theme.Space.xs
    /// Between cells, so between plates.
    static let columnSpacing: CGFloat = Theme.Space.xl
    /// Between rows, from one row's last line to the next row's covers
    /// (mac-ux §3.2). The plates take no layout, so two rows' plates still
    /// stand 16 apart.
    static let rowSpacing: CGFloat = Theme.Space.xxl
    /// The window's side gutter: 32, and 20 below 600 pt (mac-ux §3).
    static func gutter(forWindowWidth width: CGFloat) -> CGFloat {
        width < 600 ? Theme.Space.lg : Theme.Space.xxl
    }

    /// The cells across.
    let columns: Int
    /// One cover's width, inside `coverWidths` whenever the window is at
    /// least its 520 pt minimum.
    let coverWidth: CGFloat

    /// The cell around a cover: the cover plus its plate on both sides.
    var cellWidth: CGFloat { coverWidth + 2 * Self.plateOutset }
    /// 2:3, the one cover shape (R22).
    var coverHeight: CGFloat { coverWidth / CoverGeometry.aspectRatio }
    /// The width the grid itself spans, plates included.
    var gridWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * Self.columnSpacing
    }

    /// The grid for a window `width` wide: its gutters come off first.
    init(windowWidth width: CGFloat) {
        self.init(contentWidth: width - 2 * Self.gutter(forWindowWidth: width))
    }

    /// The grid for `width` between the gutters. As many cells as fit at the
    /// narrowest cover, then the cells share the width, up to the widest
    /// cover; any width left over trails the last column.
    init(contentWidth width: CGFloat) {
        let span = max(width, 0) + 2 * Self.plateOutset
        let narrowest = Self.coverWidths.lowerBound + 2 * Self.plateOutset
        let columns = max(1, Int(((span + Self.columnSpacing) / (narrowest + Self.columnSpacing)).rounded(.down)))
        let shared = (span - CGFloat(columns - 1) * Self.columnSpacing) / CGFloat(columns) - 2 * Self.plateOutset
        self.columns = columns
        coverWidth = max(min(shared, Self.coverWidths.upperBound), 0)
    }

    // MARK: Focus

    enum Move: Equatable {
        case left, right, up, down
    }

    /// Where an arrow key takes focus from the card at `index` in a grid of
    /// `count` cards: across a row, or to the same column one row up or
    /// down. nil at an edge, so focus stays put. ↓ on a short last row
    /// lands on the last card rather than nowhere.
    func neighbor(of index: Int, moving move: Move, count: Int) -> Int? {
        guard count > 0, (0..<count).contains(index) else { return nil }
        let target: Int
        switch move {
        case .left:
            guard index % columns > 0 else { return nil }
            target = index - 1
        case .right:
            guard index % columns < columns - 1, index + 1 < count else { return nil }
            target = index + 1
        case .up:
            target = index - columns
        case .down:
            let below = index + columns
            // A shorter last row: its last card, when there is a row below.
            let lastRowStart = (count - 1) / columns * columns
            guard below < count || index < lastRowStart else { return nil }
            target = min(below, count - 1)
        }
        return (0..<count).contains(target) ? target : nil
    }
}
