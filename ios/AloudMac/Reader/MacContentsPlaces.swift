import SwiftUI

// "Where you stopped" in the Mac's Contents panel (MacContentsPanel): the
// iPhone's section, drawn the Mac way, with the panel's keyboard cursor
// walking it before the chapters.

extension MacContents {

    /// A row of the panel's list, by its flat index. The keyboard's cursor
    /// and every row's scroll id count the places shown, then "Show N
    /// earlier stops", then the chapters, so ↑/↓ walk them as one list.
    enum ListRow: Equatable {
        case place(Int)
        case showEarlier
        case chapter(Int)
    }

    /// Where each kind of row sits in the flat list.
    struct ListLayout: Equatable {
        /// Places shown (`PlaceHistory.visibleCount`).
        let placeCount: Int
        let hasShowEarlier: Bool
        /// Zero in a book without a chapter list.
        let chapterCount: Int
        /// Every place's sentence, newest first, shown or not: how the
        /// cursor finds its place again when a stop lands above it.
        var placeSentences: [Int] = []

        var chapterOffset: Int { placeCount + (hasShowEarlier ? 1 : 0) }
        var count: Int { chapterOffset + chapterCount }

        func row(at index: Int) -> ListRow? {
            guard index >= 0, index < count else { return nil }
            if index < placeCount { return .place(index) }
            if hasShowEarlier, index == placeCount { return .showEarlier }
            return .chapter(index - chapterOffset)
        }

        func index(of row: ListRow) -> Int {
            switch row {
            case .place(let index): return index
            case .showEarlier: return placeCount
            case .chapter(let index): return chapterOffset + index
            }
        }

        /// Where the keyboard enters: the newest place, else the current
        /// chapter.
        func entry(currentChapter: Int?) -> Int? {
            guard count > 0 else { return nil }
            return placeCount > 0 ? 0 : index(of: .chapter(currentChapter ?? 0))
        }
    }

    /// The keyboard cursor found again after the list changed under it (a
    /// stop recorded while Contents is open, the toggle coming or going): a
    /// chapter stays on its chapter, the toggle on the toggle, a place on
    /// its sentence (a stop recorded above it, such as the one its own jump
    /// left, pushes it down a row; pushed behind the toggle, the cursor
    /// waits on the toggle), else on its position, clamped into the new
    /// list. `cursor` counts in `old`: the panel sets it before the change,
    /// and this moves it once. Only the list in `.chapters` counts the
    /// places: in any other mode the cursor is a result's index (or none),
    /// which a stop recorded never moves, and it stays.
    static func remap(_ cursor: Int?, from old: ListLayout, to new: ListLayout, in mode: Mode) -> Int? {
        guard mode == .chapters else { return cursor }
        guard let cursor else { return nil }
        guard new.count > 0 else { return nil }
        guard let row = old.row(at: cursor) else { return min(cursor, new.count - 1) }
        let lastPlace: ListRow? = new.placeCount > 0 ? .place(new.placeCount - 1) : nil
        let target: ListRow
        switch row {
        case .chapter(let index):
            target = .chapter(min(index, max(new.chapterCount - 1, 0)))
        case .showEarlier:
            target = new.hasShowEarlier ? .showEarlier : (lastPlace ?? .chapter(0))
        case .place(let index):
            let sentence = old.placeSentences.indices.contains(index) ? old.placeSentences[index] : nil
            if let moved = sentence.flatMap({ new.placeSentences.firstIndex(of: $0) }) {
                target = moved < new.placeCount ? .place(moved)
                    : (new.hasShowEarlier ? .showEarlier : (lastPlace ?? .chapter(0)))
            } else {
                target = index < new.placeCount ? .place(index)
                    : (lastPlace ?? (new.hasShowEarlier ? .showEarlier : .chapter(0)))
            }
        }
        return min(new.index(of: target), new.count - 1)
    }

    /// The list for `placeCount` places (expanded or not) over
    /// `chapterCount` chapters; `placeSentences`, the places' sentences.
    static func listLayout(placeCount total: Int, expanded: Bool,
                           chapterCount: Int, hasChapterList: Bool, placeSentences: [Int] = []) -> ListLayout {
        ListLayout(placeCount: PlaceHistory.visibleCount(total: total, hasChapterList: hasChapterList,
                                                         expanded: expanded),
                   hasShowEarlier: PlaceHistory.offersEarlier(total: total, hasChapterList: hasChapterList),
                   chapterCount: hasChapterList ? chapterCount : 0,
                   placeSentences: placeSentences)
    }

    /// "Show N earlier stops" (or "Show fewer") pressed: a keyboard cursor
    /// goes onto the toggle, counted in the list `before` the press, and
    /// the remap that follows the change carries it to the toggle's new
    /// row. Counted in the list after, it was carried twice: onto a chapter
    /// as the list grew, onto the third stop as it shrank.
    static func cursorOnToggle(_ cursor: Int?, before: ListLayout) -> Int? {
        cursor == nil ? nil : before.index(of: .showEarlier)
    }
}

/// A place: when and where, over two lines from the stop: its sentence and
/// the ones after it, read on past its paragraph within its chapter
/// (`PlaceRow.snippet`), in the reading serif (`Theme.excerpt`), as on the
/// iPhone. The place at the playhead keeps the snippet as the reader set
/// it; its detail line is semibold and the panel adds its bar.
struct MacContentsPlaceLabel: View {
    let row: PlaceRow
    let scale: ChromeScale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(row.detail)
                .font(Theme.font(row.isCurrent ? .subhead : .footnote, scale: scale))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)

            Text(row.snippet)
                .font(Theme.excerpt(scale: scale))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: 44)
    }
}
