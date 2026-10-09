import AppKit
import SwiftUI

/// The bundled classics (M7, mac-ux §3.4), pushed into the window. Rows are
/// the action: one click, or Return on a focused row, adds the book if
/// needed, opens it and plays it; a book already in the library opens the
/// copy on the shelf. Three sections by listening length under the shared
/// `BookshelfIndex`; the toolbar search (⌘F) spans all three, matches title
/// or author and ignores diacritics. Return in the search field opens the
/// top result, ↓ there moves focus to the first row (`MacSearchHandoff`),
/// the arrows walk focused rows, and Esc clears the field.
struct MacClassicsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(MacUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    /// nil shows the sections. Searched once per query change, never per body run.
    @State private var results: [BookshelfBook]?
    /// The classics already in the library. Read through the model rather
    /// than observed: the store republishes on every progress save, and only
    /// this set matters here.
    @State private var libraryIDs: Set<Int> = []
    /// The classics whose library copy (the one a row opens) is finished.
    @State private var finishedIDs: Set<Int> = []
    /// The classic the player is voicing, if any: one value followed, not
    /// the controller, which republishes many times a second.
    @State private var playingClassicID: Int?
    @State private var isSearchFocused = false
    @FocusState private var focusedRow: Int?
    /// Whose ↓ handoff is offered: this screen's, until it goes.
    @State private var handoffOwner = UUID()

    /// The row column's widest: rows past it would scatter title and length.
    private static let columnMaxWidth: CGFloat = 720

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noResultsMessage: String {
        "No classics match \u{201C}\(trimmedQuery)\u{201D}"
    }

    /// The rows in the order they're drawn, for the arrows and Return.
    private var visibleBooks: [BookshelfBook] {
        results ?? shelves.flatMap(\.books)
    }

    /// Shelved by the time each row shows, at the app-wide speed (L019).
    private var shelves: [BookshelfShelf] {
        model.bookshelfIndex.shelves(rate: model.globalRate)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                MacEdgeScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Color.clear.frame(height: 0).id("top")
                        content(scroller)
                    }
                    .frame(maxWidth: Self.columnMaxWidth)
                    .padding(.horizontal, MacGridMetrics.gutter(forWindowWidth: proxy.size.width))
                    .padding(.bottom, Theme.Space.xxl)
                    .frame(maxWidth: .infinity)
                    .onMoveCommand(perform: moveFocus)
                }
                .accessibilityIdentifier("bookshelf.list")
                // Each keystroke reshapes the list; start it from the top.
                .onChange(of: query) { scroller.scrollTo("top", anchor: .top) }
                .onAppear {
                    MacSearchHandoff.shared.offer(by: handoffOwner) { focusFirstRow(scroller) }
                }
                .onDisappear { MacSearchHandoff.shared.withdraw(by: handoffOwner) }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Classics")
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .searchable(text: $query, placement: .toolbar, prompt: Text("Title or author"))
        .modifier(MacSearchFocus(isFocused: $isSearchFocused))
        .onSubmit(of: .search) { openTopResult() }
        .onChange(of: query, initial: true) {
            let found = model.bookshelfIndex.search(query)
            // Once, as the list empties; typing on into nothing stays quiet.
            if found?.isEmpty == true, results?.isEmpty != true {
                PlaybackController.postAnnouncement(noResultsMessage, muted: model.playback.isOutputMuted)
            }
            results = found
        }
        .onReceive(model.documentStore.$documents) { documents in
            let ids = Set(documents.compactMap(\.gutenbergID))
            if ids != libraryIDs { libraryIDs = ids }
            let finished = BookshelfCatalog.finishedClassicIDs(in: documents)
            if finished != finishedIDs { finishedIDs = finished }
        }
        .onReceive(BookshelfCatalog.playingClassicIDs(of: model.playback)) { id in
            if id != playingClassicID { playingClassicID = id }
        }
        // ⌘F (Edit ▸ Find) names this field; the request is spent once read.
        .onChange(of: ui.searchFocus, initial: true) { _, target in
            guard target == .classics else { return }
            isSearchFocused = true
            ui.searchFocus = nil
        }
    }

    @ViewBuilder
    private func content(_ scroller: ScrollViewProxy) -> some View {
        if let results {
            if results.isEmpty {
                Text(noResultsMessage)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.xxl)
                    .accessibilityIdentifier("bookshelf.noResults")
            } else {
                ForEach(results) { row($0) }
            }
        } else {
            // R3-05: the shelf map, unpinned, above the first heading.
            shelfMap(scroller)
            ForEach(shelves) { shelf in
                shelfAnchor(shelf.section)
                Section {
                    ForEach(shelf.books) { row($0) }
                } header: {
                    header(shelf.section)
                }
            }
        }
    }

    private func header(_ section: BookshelfSection) -> some View {
        Text(section.title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .textCase(.uppercase)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xs)
            // Pinned: rows scroll under it.
            .background(Theme.bg)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("bookshelf.section.\(section.rawValue)")
    }

    /// The shelf map's target (`jump(to:_:)`), as on the iPhone: a
    /// zero-height mark just above the shelf's heading, never the pinned
    /// heading, which sits at the top anywhere in its shelf and so reads
    /// as already there wherever a far jump lands.
    private func shelfAnchor(_ section: BookshelfSection) -> some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .id(section.rawValue)
    }

    // MARK: Shelf map

    /// R3-05, as on the iPhone: one button per shelf at the app-wide
    /// speed, its title and a quiet count, jumping to its heading. No
    /// selected state: the pinned heading says where the list is. No
    /// identifier on the row, which would land on the buttons' own.
    private func shelfMap(_ scroller: ScrollViewProxy) -> some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(ShelfJump.jumps(in: model.bookshelfIndex, rate: model.globalRate)) { jump in
                Button {
                    self.jump(to: jump.section, scroller)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        Text(jump.title)
                            .font(Theme.font(.callout).weight(.medium))
                            .foregroundStyle(Theme.accentStrong)
                        Text(jump.countText)
                            .font(Theme.font(.callout))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize()
                    }
                    // No line limit, as on the iPhone: a title wraps in a
                    // narrow column rather than being cut; the count never
                    // breaks.
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, Theme.Space.xxs)
                    .frame(minHeight: 44)
                }
                .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.md))
                .accessibilityLabel(jump.accessibilityLabel)
                .accessibilityHint(ShelfJump.hint)
                .accessibilityIdentifier(jump.identifier)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.sm)
    }

    /// To the shelf's heading, by the mark above it (`shelfAnchor(_:)`),
    /// animated unless Reduce Motion is on, settling as on the iPhone once
    /// the lazy rows above a far heading are measured: a scroll when the
    /// animation completes (at once without one) and another on the next
    /// turn of the run loop; never on a timer.
    private func jump(to section: BookshelfSection, _ scroller: ScrollViewProxy) {
        let id = section.rawValue
        let settle = {
            scroller.scrollTo(id, anchor: .top)
            DispatchQueue.main.async { scroller.scrollTo(id, anchor: .top) }
        }
        if reduceMotion {
            settle()
        } else {
            withAnimation(.smooth, completionCriteria: .logicallyComplete) {
                scroller.scrollTo(id, anchor: .top)
            } completion: {
                settle()
            }
        }
    }

    /// One VoiceOver element: a Button already merges its label's text.
    private func row(_ book: BookshelfBook) -> some View {
        let inLibrary = libraryIDs.contains(book.id)
        let adding = importer.addingClassicID == book.id
        let finished = finishedIDs.contains(book.id)
        let playing = playingClassicID == book.id
        let label = Self.rowLabel(for: book, rate: model.globalRate)
        return Button { listen(to: book) } label: {
            MacClassicsRow(book: book, rate: model.globalRate, inLibrary: inLibrary, adding: adding,
                           finished: finished, playing: playing)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.sm))
        .focused($focusedRow, equals: book.id)
        .onKeyPress(.return) {
            listen(to: book)
            return .handled
        }
        .accessibilityLabel(label)
        .accessibilityValue(Self.rowValue(inLibrary: inLibrary, adding: adding,
                                          finished: finished, playing: playing))
        .accessibilityHint(Self.rowHint(finished: finished, playing: playing))
        .accessibilityIdentifier("bookshelf.row.\(book.gutenbergID)")
    }

    // MARK: Row copy

    /// A book's length at the app-wide speed, as the featured card and
    /// every Library card show it (R7). The shelves group by the same
    /// measure (`BookshelfIndex.shelves(rate:)`), so a heading never
    /// disagrees with the times under it (L019).
    nonisolated static func rowMinutes(of book: BookshelfBook, rate: Double) -> Int {
        book.listeningMinutes(rate: rate)
    }

    /// "The Cask of Amontillado, by Edgar Allan Poe, about 7 minutes" at 2×.
    nonisolated static func rowLabel(for book: BookshelfBook, rate: Double) -> String {
        "\(book.title), by \(book.author), "
            + ListeningEstimate.aboutPhrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The row's trailing column, in the iPhone's order: the add in
    /// progress, the copy the player is voicing, a finished copy, the
    /// library copy, else the length at the app-wide speed (7 min at 2×).
    nonisolated static func rowStatus(for book: BookshelfBook, rate: Double,
                                      inLibrary: Bool, adding: Bool,
                                      finished: Bool = false, playing: Bool = false) -> String {
        if adding { return "Adding\u{2026}" }
        if playing { return "Playing" }
        if finished { return "Finished" }
        if inLibrary { return "In library" }
        return ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The row's spoken value: its status, and nothing for a book not yet
    /// added (the label already says its length).
    nonisolated static func rowValue(inLibrary: Bool, adding: Bool,
                                     finished: Bool = false, playing: Bool = false) -> String {
        if adding { return "Adding" }
        if playing { return "Playing" }
        if finished { return "Finished" }
        if inLibrary { return "In library" }
        return ""
    }

    /// What the row does, as the iPhone's Classics row says it
    /// (`BookshelfView.rowHint`). A finished copy opens paused at its end, so
    /// it promises nothing; the copy already playing goes on as it is, so the
    /// row only brings up its reader (`PlaybackController.opensPlaying`).
    nonisolated static func rowHint(finished: Bool, playing: Bool = false) -> String {
        if playing { return "Opens the reader" }
        return finished ? "" : "Opens and starts reading aloud"
    }

    /// The only add path. The importer adds the book if needed (or finds the
    /// copy already linked to it, renamed or not); onAdded then opens it on
    /// top of this screen and the reader autoplays. A click while anything
    /// is adding is ignored, so a double click adds one copy.
    private func listen(to book: BookshelfBook) {
        guard importer.addingClassicID == nil, importer.phase == .idle else { return }
        importer.addClassic(book)
    }

    /// Return in the search field: the top result, as Spotlight does.
    private func openTopResult() {
        guard let first = results?.first else { return }
        listen(to: first)
    }

    /// ↓ in the search field: the first row drawn, of the results or of the
    /// shelf, takes focus, as Spotlight's list does. A row is a button, which
    /// takes focus only under keyboard navigation; without it, or with no
    /// row, false, and the field keeps the key.
    private func focusFirstRow(_ scroller: ScrollViewProxy) -> Bool {
        guard NSApp.isFullKeyboardAccessEnabled, let first = visibleBooks.first else { return false }
        scroller.scrollTo("top", anchor: .top)
        focusedRow = first.id
        return true
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let books = visibleBooks
        guard let focusedRow, let index = books.firstIndex(where: { $0.id == focusedRow }) else { return }
        switch direction {
        case .up where index > 0: self.focusedRow = books[index - 1].id
        case .down where index + 1 < books.count: self.focusedRow = books[index + 1].id
        default: break
        }
    }
}

// MARK: - Row

/// Text only (R9, R22): the title over "by Author" on the left, and a fixed
/// trailing column with the length, or "In library", or "Adding…" while it
/// adds. Words, not a spinner, so it holds still under Reduce Motion.
private struct MacClassicsRow: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    let finished: Bool
    /// The player is voicing the library copy: the status reads in the
    /// accent text colour behind a speaker glyph VoiceOver skips.
    let playing: Bool

    /// Fits "In library" and "13 hr 20 min" in the caption style.
    private static let statusWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(book.title)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                Text("by \(book.author)")
                    .font(Theme.font(.callout))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusLine
                .font(Theme.font(.caption))
                .lineLimit(1)
                .frame(width: Self.statusWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .hairlineHeight()
                .padding(.horizontal, Theme.Space.sm)
                .accessibilityHidden(true)
        }
    }

    private var status: String {
        MacClassicsView.rowStatus(for: book, rate: rate, inLibrary: inLibrary, adding: adding,
                                  finished: finished, playing: playing)
    }

    @ViewBuilder
    private var statusLine: some View {
        if playing && !adding {
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: "speaker.wave.2.fill")
                    .accessibilityHidden(true)
                Text(status)
            }
            .foregroundStyle(Theme.accentStrong)
        } else {
            Text(status)
                .foregroundStyle(Theme.textMuted)
        }
    }
}

// MARK: - ⌘F

/// Focuses the toolbar search field when `isFocused` turns on. macOS 15
/// gives `searchFocused`; on 14 the field takes focus from a click or Tab,
/// and the flag just resets.
private struct MacSearchFocus: ViewModifier {
    @Binding var isFocused: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: isFocused) { _, wants in
                    guard wants else { return }
                    focused = true
                    isFocused = false
                }
        } else {
            content
                .onChange(of: isFocused) { _, wants in
                    if wants { isFocused = false }
                }
        }
    }
}
