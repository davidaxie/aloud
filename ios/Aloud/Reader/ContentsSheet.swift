import SwiftUI

/// Contents (R6), opened from the chapter line: "Search this book" pinned
/// above the chapter list, and typing replaces the list with results. A book
/// with fewer than two chapters shows search only, opens full height and
/// focuses the field.
///
/// Text books list their derived chapters — serif title, estimated listening
/// time trailing (stacked beneath at accessibility sizes); PDFs (whose pages
/// carry no headings) list pages, whose rows name a page or a run of them
/// ("Pages 12–14") because prose flowing across a page break leaves that
/// break with no block of its own. The current chapter carries a 3pt
/// accentStrong leading bar (and the `.isSelected` trait), completed chapters
/// mute. Chapters under a Part, Book, Act or Epilogue heading are grouped
/// beneath it as a pinned section header (R17); the heading itself is
/// folded into the chapter after it, so it is never a row of its own.
///
/// Search is a case/diacritic-insensitive scan of the sentences (debounced
/// 200 ms, off the main thread); a curly quote or dash in the query matches
/// the ASCII the sentences store (`DocContent.searchNeedles`). Result rows
/// show the matching sentence, cut to start a few words before the match so
/// the match is always on the first line (`ContentsResultLabel`), with the
/// match tinted accent (color only — no weight change in reading contexts)
/// and a chapter/page context line.
///
/// A row or result tap jumps there, preserving play/pause, offers Undo
/// jump (R15) and closes the sheet. A result names its place with its
/// section ("BOOK ONE: 1805 · CHAPTER I").
///
/// "Where you stopped" leads the list when the book has places
/// (`PlaceHistoryStore`, from the environment): the newest three, then
/// "Show N earlier stops", each its time and chapter over two lines of the
/// sentence (`PlaceHistoryRows`). A row is the chapter row's jump; the one
/// at the playhead carries the current bar and `.isSelected`. With places
/// the sheet opens at the top, not on the current chapter, and a book
/// without a chapter list lists them instead of focusing the field.
///
/// Chapters and labels are derived once per loaded document by the reader and
/// handed in — deriving them here would rerun a whole-book scan on every
/// parent body evaluation (word-highlight cadence during playback).
struct ContentsSheet: View {

    let content: DocContent
    let navigation: ReaderNavigation

    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.placeHistory) private var placeHistory

    @State private var query = ""
    @State private var results: [SentenceMatch] = []
    /// The trimmed query `results` answer; nil until one has been scanned, so
    /// "No matches" never shows before the user has typed. A new scan leaves
    /// the previous answer on screen until it lands.
    @State private var searchedQuery: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var scanTask: Task<[SentenceMatch], Never>?
    @FocusState private var fieldFocused: Bool
    @State private var detent: PresentationDetent
    /// "Show N earlier stops" pressed; reset each time the sheet opens.
    @State private var showsEarlierPlaces = false

    private static let debounceNanoseconds: UInt64 = 200_000_000

    init(content: DocContent, navigation: ReaderNavigation) {
        self.content = content
        self.navigation = navigation
        // Search only has nothing to show at half height.
        _detent = State(initialValue: navigation.hasChapterList ? .medium : .large)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()

            Text("Contents")
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("contents.title")
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)

            // Pinned: the field never scrolls away with the list.
            searchField
                .padding(.bottom, Theme.Space.xs)

            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        // Search only gets one full-height detent: with the keyboard up, a
        // two-detent sheet springs back to full height on every drag, so it
        // could never be swiped closed.
        .sheetChrome(hasList ? [.medium, .large] : [.large],
                     selection: $detent)
        // Typing at half height leaves the results under the keyboard.
        .onChange(of: fieldFocused) { _, focused in
            if focused { detent = .large }
        }
        // Dragging down to half height means "back to the list": drop the
        // keyboard so the sheet can rest there, or close on the next drag.
        .onChange(of: detent) { _, newDetent in
            if newDetent != .large { fieldFocused = false }
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onAppear {
            guard !hasList else { return }
            // Focus after the sheet's presentation settles; an immediate set
            // is dropped by the transition on some runtimes.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                fieldFocused = true
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            scanTask?.cancel()
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if navigation.hasChapterList {
                chapterList
            } else if !placeRows.isEmpty {
                placesOnlyList
            } else {
                Spacer(minLength: 0)
            }
        } else if let searchedQuery {
            if results.isEmpty {
                emptyState(for: searchedQuery)
            } else {
                resultsList
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: Theme.Space.xs) {
            // Decorative: the field names itself ("Search this book").
            Image(systemName: "magnifyingglass")
                .font(Theme.font(.body))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)

            TextField("Search this book", text: $query)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.font(.body))
                        .foregroundStyle(Theme.textFaint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("search.clear")
            }
        }
        .padding(.leading, Theme.Space.sm)
        .padding(.trailing, Theme.Space.xxs)
        .frame(minHeight: 44)
        .background(Theme.surface2,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
        .padding(.horizontal, Theme.Space.sheetGutter)
    }

    // MARK: - Chapters

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    let rows = placeRows
                    if !rows.isEmpty {
                        placesSection(rows)
                        // A titled first section (Part, Book) names itself.
                        if navigation.sections.first?.title == nil {
                            eyebrow(PlaceHistoryRows.listsPages(navigation)
                                        ? PlaceHistoryCopy.pagesHeader : PlaceHistoryCopy.chaptersHeader,
                                    identifier: "contents.section.list")
                        }
                    }
                    ForEach(navigation.sections) { section in
                        if let title = section.title {
                            Section {
                                chapterRows(section)
                            } header: {
                                sectionHeader(title, id: section.id)
                            }
                        } else {
                            Section {
                                chapterRows(section)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .scrollDismissesKeyboard(.immediately)
            // With places the sheet opens at the top, on the newest one.
            .onAppear { if placeRows.isEmpty { scrollToCurrent(proxy) } }
        }
    }

    private func chapterRows(_ section: ContentsSection) -> some View {
        ForEach(section.chapterRange, id: \.self) { index in
            chapterRow(navigation.chapters[index], index: index)
        }
    }

    /// Opaque, so the rows scrolling beneath a pinned header never show
    /// through it.
    private func sectionHeader(_ title: String, id: Int) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .background(Theme.surface)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("contents.section.\(id)")
    }

    /// The chapter holding the playhead, by binary search: this is read for
    /// every row on every playhead tick while the sheet is open.
    private var currentIndex: Int? {
        navigation.chapterIndex(containing: playback.currentSentence)
    }

    /// Land on the current chapter without animation (nothing to soften;
    /// Reduce Motion needs no gate). A LazyVStack has not laid out its rows
    /// when `onAppear` fires during sheet presentation, so the scroll happens
    /// after the first layout pass and repeats once when the presentation has
    /// settled — a hundreds-of-rows page list otherwise opens at the top.
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let currentIndex else { return }
        let id = navigation.chapters[currentIndex].id
        Task { @MainActor in
            proxy.scrollTo(id, anchor: .center)
            try? await Task.sleep(nanoseconds: 150_000_000)
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func chapterRow(_ chapter: DerivedChapter, index: Int) -> some View {
        let current = currentIndex
        let isCurrent = index == current
        let isCompleted = current.map { index < $0 } ?? false
        let title = navigation.title(ofChapter: index)
        // Rate-aware, like the shelf cards and the chapter line's time left: at
        // 2× a chapter takes half as long, and Contents says so. Computed once,
        // so the visible "8 min" and the spoken "8 minutes" are one number.
        let minutes = chapter.estimatedMinutes(
            wordsPerMinute: LibraryDocument.spokenWordsPerMinute * playback.rate)

        return Button {
            playback.jump(to: chapter.startSentence, origin: .chapter)
            dismiss()
        } label: {
            chapterRowContent(title: title,
                              estimate: ListeningEstimate.phrase(minutes: minutes),
                              isCompleted: isCompleted)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .frame(minHeight: 52)
            // The current chapter's marker: a bar on the row's leading edge,
            // outside the gutter so every title stays aligned.
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle()
                        .fill(Theme.accentStrong)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(chapter.id)
        .accessibilityLabel(ContentsSearch.chapterAccessibilityLabel(title: title, minutes: minutes,
                                                                     isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(navigation.rowIdentifier(at: index))
    }

    /// Title with its listening time trailing. At accessibility sizes a
    /// trailing time left the title almost no width (every row read
    /// "CHAPT…"), so the title wraps to three lines and the time stacks
    /// beneath it.
    @ViewBuilder
    private func chapterRowContent(title: String, estimate: String,
                                   isCompleted: Bool) -> some View {
        let titleText = Text(title)
            .font(Theme.font(.headline))
            .foregroundStyle(isCompleted ? Theme.textMuted : Theme.text)
            .truncationMode(.tail)
        let estimateText = Text(estimate)
            .font(Theme.font(.caption))
            .monospacedDigit()
            .foregroundStyle(Theme.textFaint)

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                titleText
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                estimateText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Wrapped rows need their own breathing room; the 52pt minimum
            // only spaces single-line rows.
            .padding(.vertical, Theme.Space.sm)
        } else {
            HStack(spacing: Theme.Space.sm) {
                titleText
                    .lineLimit(1)

                Spacer(minLength: Theme.Space.sm)

                estimateText
            }
        }
    }

    // MARK: - Where you stopped

    /// Something to list: chapters, or places in a book without chapters.
    /// It decides the half-height detent and whether the field takes focus.
    private var hasList: Bool {
        navigation.hasChapterList || !placeRows.isEmpty
    }

    /// The book's places as rows. At most eight, so rebuilding them on a
    /// playhead tick costs nothing worth caching.
    private var placeRows: [PlaceRow] {
        guard let placeHistory else { return [] }
        let entries = placeHistory.places(for: playback.document?.id, contentHash: content.contentHash)
        guard !entries.isEmpty else { return [] }
        return PlaceHistoryRows.rows(entries, content: content, navigation: navigation,
                                     playhead: playback.currentSentence)
    }

    private var placesOnlyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                placesSection(placeRows)
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func placesSection(_ rows: [PlaceRow]) -> some View {
        let visible = PlaceHistory.visibleCount(total: rows.count, hasChapterList: navigation.hasChapterList,
                                                expanded: showsEarlierPlaces)
        eyebrow(PlaceHistoryCopy.header, identifier: "places.header")
        ForEach(Array(rows.prefix(visible))) { row in
            placeRow(row)
        }
        if PlaceHistory.offersEarlier(total: rows.count, hasChapterList: navigation.hasChapterList) {
            Button {
                showsEarlierPlaces.toggle()
            } label: {
                Text(showsEarlierPlaces ? PlaceHistoryCopy.showFewer
                                        : PlaceHistoryCopy.showEarlier(rows.count - visible))
                    .font(Theme.font(.subhead))
                    .foregroundStyle(Theme.accentStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.sheetGutter)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("places.more")
        }
    }

    /// The chapter row's jump: play or pause kept, Undo jump offered.
    private func placeRow(_ row: PlaceRow) -> some View {
        Button {
            playback.jump(to: row.sentence, origin: .chapter)
            dismiss()
        } label: {
            ContentsPlaceLabel(row: row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.vertical, Theme.Space.sm)
                .frame(minHeight: 44)
                // The chapter list's current marker, on the place at the
                // playhead.
                .overlay(alignment: .leading) {
                    if row.isCurrent {
                        Rectangle()
                            .fill(Theme.accentStrong)
                            .frame(width: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier(row.identifier)
    }

    /// An eyebrow over a run of rows that scrolls with them.
    private func eyebrow(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(countLabel)
                .font(Theme.font(.subhead))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .accessibilityIdentifier("search.count")

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { match in
                        resultRow(match)
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countLabel: String {
        ContentsSearch.countLabel(results.count)
    }

    private func resultRow(_ match: SentenceMatch) -> some View {
        Button {
            playback.jump(to: match.sentenceID, origin: .searchResult)
            dismiss()
        } label: {
            ContentsResultLabel(match: match, location: navigation.searchLocation(ofSentence: match.sentenceID,
                                                                                  page: match.page))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.vertical, Theme.Space.sm)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.result.\(match.sentenceID)")
    }

    private func emptyState(for query: String) -> some View {
        VStack {
            Spacer()
            Text(ContentsSearch.noMatchesLabel(query))
                .font(Theme.font(.callout))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .accessibilityIdentifier("search.empty")
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Debounced scan

    /// Debounce, then scan off the main thread. The scan is hundreds of
    /// milliseconds on the largest bundled classics, so it never runs on the
    /// MainActor: the previous scan is cancelled (it polls cancellation per
    /// sentence and abandons the rest of the book), and only the surviving
    /// one publishes — in sentence order, as the scan produces it.
    private func scheduleSearch(for newValue: String) {
        debounceTask?.cancel()
        scanTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            searchedQuery = nil
            return
        }
        let content = content
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let scan = Task.detached(priority: .userInitiated) {
                content.matches(of: trimmed)
            }
            scanTask = scan
            let found = await scan.value
            guard !scan.isCancelled, !Task.isCancelled else { return }
            let previousCount: Int? = searchedQuery == nil ? nil : results.count
            results = found
            searchedQuery = trimmed
            // Focus stays in the field: VoiceOver hears what landed.
            ContentsSearch.announceResults(count: found.count, query: trimmed,
                                           previousCount: previousCount, muted: playback.isOutputMuted)
        }
    }
}

// MARK: - Place label

/// A "Where you stopped" row's text: when and where, over the sentence. The
/// sentence keeps the reader's color and weight on the current row too; the
/// bar marks it.
private struct ContentsPlaceLabel: View {

    let row: PlaceRow

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(row.detail)
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(isAccessibilitySize ? nil : 1)
                .multilineTextAlignment(.leading)

            Text(row.text)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text)
                .lineLimit(isAccessibilitySize ? 4 : 2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Result label

/// A search result's text: the sentence, cut to start a few words before its
/// hit so the hit always sits on the first line, over the hit's chapter or
/// page. Its own view so a layout test can host it without a controller.
struct ContentsResultLabel: View {

    let match: SentenceMatch
    /// nil in text without a chapter list: the sentence says where.
    let location: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let snippet = ContentsSearch.snippet(for: match,
                                             leadLimit: ContentsSearch.leadLimit(for: dynamicTypeSize))
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            emphasized(snippet)
                .font(Theme.font(.body))
                // Three lines held ~35 characters at AX5: two more keep some
                // of the sentence after the hit.
                .lineLimit(isAccessibilitySize ? 5 : 3)
                .multilineTextAlignment(.leading)
                // The cut is only visual: VoiceOver reads the whole sentence,
                // typeset as before ("--" an em dash, not two hyphens).
                .accessibilityLabel(ReaderTypography.typeset(match.text))

            // "BOOK ONE: 1805 · CHAPTER XVIII" tells same-phrase hits apart,
            // so at the accessibility sizes it wraps instead of truncating.
            if let location {
                Text(location)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    /// The hit tinted accent — color only, never a weight change (banned in
    /// reading contexts).
    private func emphasized(_ snippet: ContentsSearch.Snippet) -> Text {
        Text(snippet.lead).foregroundColor(Theme.text)
            + Text(snippet.hit).foregroundColor(Theme.accentStrong)
            + Text(snippet.tail).foregroundColor(Theme.text)
    }
}
