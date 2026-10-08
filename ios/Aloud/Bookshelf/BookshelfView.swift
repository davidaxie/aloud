import SwiftUI

/// The bundled classics (R9), pushed full height on the Library's stack.
/// Rows are the action: one tap adds the book if needed, opens it and plays
/// it. Three shelves by listening length; the pinned search spans all three.
struct BookshelfView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var query = ""
    /// nil shows the shelves. Searched once per query change, never per body run.
    @State private var results: [BookshelfBook]?
    /// The classics already in the library. The store is read through the
    /// model rather than observed: it republishes on every progress save,
    /// even with this screen under the reader, and only these sets matter.
    @State private var libraryIDs: Set<Int> = []
    /// The classics whose library copy is finished: those rows open paused,
    /// so their hint promises nothing, as a finished grid card's doesn't.
    @State private var finishedIDs: Set<Int> = []

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noResultsMessage: String {
        "No classics match \u{201C}\(trimmedQuery)\u{201D}"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 0).id("top")
                    content
                }
            }
            .accessibilityIdentifier("bookshelf.list")
            // Each keystroke reshapes the list; start it from the top.
            .onChange(of: query) { proxy.scrollTo("top", anchor: .top) }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .modifier(ShelfScrollEdge(showsScrollRule: true))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Title or author"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // The keyboard's Search key takes the top result, as a tap on it
        // would: the same haptic and busy guard. With nothing found it does
        // nothing; the no-results line already says why.
        .onSubmit(of: .search) { openTopResult() }
        .onChange(of: query, initial: true) {
            let found = model.bookshelfIndex.search(query)
            // Once, as the list empties; typing on into nothing stays quiet.
            // Through the one announcement path, so a muted launch only logs it.
            if found?.isEmpty == true, results?.isEmpty != true {
                PlaybackController.postAnnouncement(noResultsMessage, muted: model.playback.isOutputMuted)
            }
            results = found
        }
        .onReceive(model.documentStore.$documents) { documents in
            let ids = Set(documents.compactMap(\.gutenbergID))
            if ids != libraryIDs { libraryIDs = ids }
            let finished = Self.finishedClassicIDs(in: documents)
            if finished != finishedIDs { finishedIDs = finished }
        }
        .navigationTitle("Classics")
        .navigationBarTitleDisplayMode(.inline)
        // The bar's system content (back chevron, title rendering) follows
        // the app's scheme, not the phone's: under an in-app Dark override
        // on a Light phone it otherwise drew dark-on-dark.
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Classics")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    // The bar caps text scaling; at accessibility sizes a
                    // long press shows the title large instead.
                    .accessibilityShowsLargeContentViewer()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let results {
            if results.isEmpty {
                Text(noResultsMessage)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Space.screenGutter)
                    .padding(.top, Theme.Space.xxl)
                    .accessibilityIdentifier("bookshelf.noResults")
            } else {
                ForEach(results) { row($0) }
            }
        } else {
            ForEach(model.bookshelfIndex.shelves(rate: model.globalRate)) { shelf in
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
            // Capitals, as the shelf's other eyebrows are drawn; VoiceOver
            // and Voice Control keep the title as written.
            .textCase(.uppercase)
            .accessibilityLabel(Text(section.title))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenGutter)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xs)
            // Pinned: rows scroll under it.
            .background(Theme.bg)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("bookshelf.section.\(section.rawValue)")
    }

    private func row(_ book: BookshelfBook) -> some View {
        ClassicsRowButton(book: book, rate: model.globalRate,
                          inLibrary: libraryIDs.contains(book.id),
                          adding: importer.addingClassicID == book.id,
                          finished: finishedIDs.contains(book.id),
                          stacked: dynamicTypeSize.isAccessibilitySize) { listen(to: book) }
    }

    // MARK: Row copy

    /// A book's length at the app-wide speed, as the featured card and
    /// every Library card show it (R7). The shelves group by the same
    /// measure (`BookshelfIndex.shelves(rate:)`), so a heading never
    /// disagrees with the times under it (L019).
    nonisolated static func rowMinutes(of book: BookshelfBook, rate: Double) -> Int {
        book.listeningMinutes(rate: rate)
    }

    /// The stacked row's second line at accessibility sizes: the author and
    /// the length at the app-wide speed, as the featured card shows them.
    nonisolated static func rowSubtitle(for book: BookshelfBook, rate: Double) -> String {
        "\(book.author) · \(ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate)))"
    }

    /// The side-by-side row's line under the title: the author alone, with
    /// the length in the trailing column.
    nonisolated static func rowByline(for book: BookshelfBook) -> String {
        "by \(book.author)"
    }

    /// The side-by-side row's trailing column, never empty, so the lengths
    /// line up down the list: the add in progress, else the library copy,
    /// else the length at the app-wide speed.
    nonisolated static func rowStatus(for book: BookshelfBook, rate: Double,
                                      inLibrary: Bool, adding: Bool) -> String {
        if adding { return "Adding\u{2026}" }
        if inLibrary { return "In library" }
        return ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The trailing column's width at the default text size; it scales with
    /// the caption style. It fits the widest status, a three-digit hour count
    /// with minutes in tabular digits (the longest classic runs past 100
    /// hours at 1×, and past 50 hours a half-speed row reaches three digits),
    /// in bold as well, since Bold Text draws the medium caption heavier.
    nonisolated static let statusColumnWidth: CGFloat = 88

    /// What the row does, as the grid cards say it. A finished library copy
    /// opens paused at its end, so it promises nothing.
    nonisolated static func rowHint(finished: Bool) -> String {
        finished ? "" : "Opens and starts reading aloud"
    }

    /// The classics whose library copy is finished. The copy is the one a
    /// row opens: the first in store order, as `DocumentStore` finds it.
    nonisolated static func finishedClassicIDs(in documents: [LibraryDocument]) -> Set<Int> {
        var seen: Set<Int> = []
        var finished: Set<Int> = []
        for document in documents {
            guard let id = document.gutenbergID, seen.insert(id).inserted else { continue }
            if document.isFinished { finished.insert(id) }
        }
        return finished
    }

    /// "The Cask of Amontillado, by Edgar Allan Poe, about 7 minutes" at 2×.
    nonisolated static func rowLabel(for book: BookshelfBook, rate: Double) -> String {
        "\(book.title), by \(book.author), "
            + ListeningEstimate.aboutPhrase(minutes: rowMinutes(of: book, rate: rate))
    }

    /// The only tap handler. The importer adds the book if needed (or finds
    /// the copy already linked to it, renamed or not), then onAdded opens it
    /// on top of this screen and the reader autoplays. The soft haptic (R20)
    /// answers only a tap that will start a voice: the importer ignores taps
    /// while it is busy, and the copy already on the shelf follows the same
    /// rule as a grid card.
    private func listen(to book: BookshelfBook) {
        guard importer.addingClassicID == nil, importer.phase == .idle else { return }
        let playback = model.playback
        let startsPlaying = model.documentStore.document(forGutenbergID: book.gutenbergID)
            .map { playback.opensPlaying($0) } ?? !playback.isAutoplaySuppressed
        if startsPlaying { TransportHaptics.emit(.play) }
        importer.addClassic(book)
    }

    /// The keyboard's Search key: the top result, through the tap's path.
    private func openTopResult() {
        guard let first = results?.first else { return }
        listen(to: first)
    }
}

// MARK: - Row button

/// One VoiceOver element: a Button already merges its label's text. Plain
/// values in, so a hosted test can read what VoiceOver hears without the
/// app's models.
struct ClassicsRowButton: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    /// The library copy is finished, so the row opens it paused.
    let finished: Bool
    let stacked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BookshelfRow(book: book, rate: rate, inLibrary: inLibrary, adding: adding, stacked: stacked)
        }
        .buttonStyle(ShelfRowButtonStyle())
        .accessibilityLabel(BookshelfView.rowLabel(for: book, rate: rate))
        .accessibilityValue(adding ? "Adding" : inLibrary ? "In library" : "")
        .accessibilityHint(BookshelfView.rowHint(finished: finished))
        .accessibilityIdentifier("bookshelf.row.\(book.gutenbergID)")
    }
}

// MARK: - Row

/// Text only: the title over the author, and a trailing column that always
/// holds one status (the length, the library copy or the add in progress),
/// so the lengths line up down the list. At accessibility sizes, where a
/// trailing column would squeeze the title, the row stacks: the author and
/// length share a line, and any status drops under them.
private struct BookshelfRow: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    let stacked: Bool

    @ScaledMetric(relativeTo: .caption) private var statusWidth = BookshelfView.statusColumnWidth

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    title
                    detail(BookshelfView.rowSubtitle(for: book, rate: rate))
                    stackedStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        title
                        detail(BookshelfView.rowByline(for: book))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(BookshelfView.rowStatus(for: book, rate: rate, inLibrary: inLibrary, adding: adding))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .frame(width: statusWidth, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Theme.Space.screenGutter)
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .frame(height: Theme.Stroke.hairlineWidth)
                .padding(.leading, Theme.Space.screenGutter)
                .accessibilityHidden(true)
        }
    }

    private var title: some View {
        Text(book.title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
    }

    /// Words, not a spinner: it holds still under Reduce Motion and says
    /// what the row's spoken value says. The length is already on the line
    /// above it, so only a status shows here.
    @ViewBuilder
    private var stackedStatus: some View {
        if adding || inLibrary {
            Text(BookshelfView.rowStatus(for: book, rate: rate, inLibrary: inLibrary, adding: adding))
                .font(Theme.font(.subhead))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
        }
    }
}

/// Rows press to surface2; no scale, so the column of text stays still.
private struct ShelfRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Theme.bg)
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
    }
}
