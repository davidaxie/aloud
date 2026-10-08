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
    /// even with this screen under the reader, and only this set matters.
    @State private var libraryIDs: Set<Int> = []

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
        .modifier(ShelfScrollEdge())
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Title or author"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
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

    /// One VoiceOver element: a Button already merges its label's text.
    private func row(_ book: BookshelfBook) -> some View {
        let inLibrary = libraryIDs.contains(book.id)
        let adding = importer.addingClassicID == book.id
        let label = Self.rowLabel(for: book, rate: model.globalRate)
        return Button { listen(to: book) } label: {
            BookshelfRow(book: book, rate: model.globalRate, inLibrary: inLibrary, adding: adding,
                         stacked: dynamicTypeSize.isAccessibilitySize)
        }
        .buttonStyle(ShelfRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(adding ? "Adding" : inLibrary ? "In library" : "")
        .accessibilityHint("Double-tap to listen")
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

    /// "Edgar Allan Poe · 7 min" at 2×.
    nonisolated static func rowSubtitle(for book: BookshelfBook, rate: Double) -> String {
        "\(book.author) · \(ListeningEstimate.phrase(minutes: rowMinutes(of: book, rate: rate)))"
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
}

// MARK: - Row

/// Text only: the title, then the author and length; the status trails, or
/// drops under the author at accessibility sizes, where a trailing column
/// would squeeze the title.
private struct BookshelfRow: View {
    let book: BookshelfBook
    /// The app-wide speed the length is shown at.
    let rate: Double
    let inLibrary: Bool
    let adding: Bool
    let stacked: Bool

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    lines
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: Theme.Space.sm) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        lines
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    status
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

    @ViewBuilder
    private var lines: some View {
        Text(book.title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
        Text(BookshelfView.rowSubtitle(for: book, rate: rate))
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
    }

    /// Words, not a spinner: it holds still under Reduce Motion and says
    /// what the row's spoken value says.
    @ViewBuilder
    private var status: some View {
        if adding || inLibrary {
            Text(adding ? "Adding\u{2026}" : "In library")
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
