import SwiftUI

/// Contents (R6), opened from the chapter line: the search field pinned
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
/// A row or result tap jumps there and plays from there, as a sentence tap
/// and the Mac's Contents do (`ContentsSearch.jumpAndPlay`, P025), offers
/// Undo jump (R15), which restores the pause too, and closes the sheet.
/// A result names its place with its section. Rows press to surface2 (P026).
///
/// The places list leads when the book has places (`PlaceHistoryStore`,
/// from the environment): at half height above a chapter list only the
/// newest, so the chapters start above the fold (P024), else the newest
/// three, then the earlier-stops toggle; each its time and chapter over the
/// sentence (`PlaceHistoryRows`). A row is the chapter row's jump; the one
/// at the playhead carries the current bar, a semibold detail line and
/// `.isSelected`. The sheet opens on the current chapter unless the newest
/// stop is in another chapter, when it opens at the top so the stop shows
/// (`PlaceHistory.opensOnCurrentChapter`); a book without a chapter list
/// lists its places instead of focusing the field.
///
/// A picked result's search is remembered for the book
/// (`ContentsSearchMemory`, P029): reopened, the sheet opens at full height
/// on the same results with the pick marked, so the next hit is one tap
/// away. The keyboard's Search key scans at once and drops the keyboard
/// (P030); Cancel beside the focused field backs out of a search, and the
/// blank and no-match states scroll, so a drag drops the keyboard (P031).
///
/// Chapters and labels are derived once per loaded document by the reader and
/// handed in — deriving them here would rerun a whole-book scan on every
/// parent body evaluation (word-highlight cadence during playback).
struct ContentsSheet: View {

    let content: DocContent
    let navigation: ReaderNavigation
    /// Read here, on the main actor, rather than as a default argument.
    private var searchMemory: ContentsSearchMemory { .shared }

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
    /// The earlier-stops toggle pressed; reset each time the sheet opens,
    /// and kept as the sheet changes height.
    @State private var showsEarlierPlaces = false
    /// The result picked from the restored search, marked like the current
    /// chapter; cleared by the next edit.
    @State private var pickedSentence: Int?
    /// The restored query, scanned at once as the sheet opens: its arrival
    /// in the field is not a keystroke to debounce.
    @State private var openedQuery: String?

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

            Text(ContentsSearch.title)
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
            queryChanged(to: newValue)
        }
        .onAppear { opened() }
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
                keyboardDismissingArea { Color.clear.frame(height: 0) }
            }
        } else if let searchedQuery {
            if results.isEmpty {
                emptyState(for: searchedQuery)
            } else {
                resultsList
            }
        } else {
            // Still scanning.
            keyboardDismissingArea { Color.clear.frame(height: 0) }
        }
    }

    // MARK: - Opening

    /// A remembered search for this book comes back at full height with its
    /// results and the keyboard down; the chapter line's search action, or
    /// a book with nothing to list, focuses the field instead.
    private func opened() {
        let restored = searchMemory.restore(for: playback.document?.id)
        let searchAsked = searchMemory.consumeSearchFocus()
        if let restored {
            pickedSentence = restored.pickedSentence
            openedQuery = restored.query
            query = restored.query
            detent = .large
            startSearch(now: restored.query)
        }
        guard searchAsked || (restored == nil && !hasList) else { return }
        detent = .large
        // Focus after the sheet's presentation settles; an immediate set
        // is dropped by the transition on some runtimes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            fieldFocused = true
        }
    }

    /// A keystroke: debounce a scan. Any edit forgets the remembered search,
    /// so a reopening never brings back a query the field no longer holds
    /// (the next pick remembers again), and clears the restored pick's mark.
    private func queryChanged(to newValue: String) {
        if let opening = openedQuery {
            openedQuery = nil
            if opening == newValue { return }
        }
        pickedSentence = nil
        searchMemory.forget()
        scheduleSearch(for: newValue)
    }

    /// Backs out of a search, as the system search bar's Cancel does.
    private func cancelSearch() {
        query = ""
        searchMemory.forget()
        fieldFocused = false
    }

    /// A pick: jump, play from there unless already playing (with the play
    /// haptic only then), and close.
    private func pick(_ sentence: Int, origin: JumpOrigin) {
        if ContentsSearch.jumpAndPlay(playback, to: sentence, origin: origin) {
            TransportHaptics.emit(.play)
        }
        dismiss()
    }

    // MARK: - Field

    /// The field, and Cancel beside it while it has focus.
    private var searchField: some View {
        HStack(spacing: Theme.Space.xs) {
            fieldBox
            if fieldFocused {
                Button(action: cancelSearch) {
                    Text(ContentsSearch.cancelSearch)
                        .font(Theme.font(.callout))
                        .foregroundStyle(Theme.accentStrong)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityIdentifier("search.cancel")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.press), value: fieldFocused)
        .padding(.horizontal, Theme.Space.sheetGutter)
    }

    private var fieldBox: some View {
        HStack(spacing: Theme.Space.xs) {
            // Decorative: the field names itself.
            Image(systemName: "magnifyingglass")
                .font(Theme.font(.body))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)

            TextField(ContentsSearch.searchPrompt, text: $query,
                      // textFaint, as the magnifier: 4.5:1 on surface2 in
                      // both schemes, where the system placeholder is not.
                      prompt: Text(ContentsSearch.searchPrompt).foregroundStyle(Theme.textFaint))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .submitLabel(.search)
                // The Search key scans now (no debounce left to wait out)
                // and drops the keyboard; the pick stays the listener's.
                .onSubmit {
                    debounceTask?.cancel()
                    startSearch(now: query)
                    fieldFocused = false
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                    searchMemory.forget()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.font(.body))
                        .foregroundStyle(Theme.textFaint)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
            // On the current chapter when the newest stop is in it (or there
            // are none); at the top when that stop is in another chapter, so
            // the stop shows.
            .onAppear {
                if PlaceHistory.opensOnCurrentChapter(newestStop: placeRows.first?.sentence,
                                                      playhead: playback.currentSentence,
                                                      navigation: navigation) {
                    scrollToCurrent(proxy)
                }
            }
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
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
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
            pick(chapter.startSentence, origin: .chapter)
        } label: {
            ContentsChapterLabel(title: title,
                                 estimate: ListeningEstimate.phrase(minutes: minutes),
                                 isCurrent: isCurrent,
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
        .buttonStyle(ContentsRowButtonStyle())
        .id(chapter.id)
        .accessibilityLabel(ContentsSearch.chapterAccessibilityLabel(title: title, minutes: minutes,
                                                                     isCurrent: isCurrent))
        .accessibilityHint(ContentsSearch.playsFromHereHint)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(navigation.rowIdentifier(at: index))
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
        let collapsed = placesCollapsedCount
        let visible = PlaceHistory.visibleCount(total: rows.count, hasChapterList: navigation.hasChapterList,
                                                expanded: showsEarlierPlaces, collapsedCount: collapsed)
        eyebrow(PlaceHistoryCopy.header, identifier: "places.header")
        // Keyed by place, never position: a stop recorded while the sheet
        // is open slides the rows down with their own elements, so
        // VoiceOver stays on the place it read (L026).
        ForEach(Array(rows.prefix(visible)), id: \.sentence) { row in
            placeRow(row)
        }
        // At half height the toggle waits for the sheet to grow, so the
        // first chapter clears the fold on the smallest screen.
        if PlaceHistory.offersEarlier(total: rows.count, hasChapterList: navigation.hasChapterList,
                                      expanded: showsEarlierPlaces, atHalfHeight: detent == .medium,
                                      accessibilitySize: dynamicTypeSize.isAccessibilitySize) {
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
            .buttonStyle(ContentsRowButtonStyle())
            .accessibilityIdentifier("places.more")
        }
    }

    /// Places kept above the toggle: one at half height over a chapter
    /// list, below the accessibility sizes (with the toggle held back until
    /// the sheet grows); three otherwise. Read from the live detent, so
    /// growing the sheet shows three without resetting the toggle.
    private var placesCollapsedCount: Int {
        PlaceHistory.collapsedCount(atHalfHeight: detent == .medium,
                                    hasChapterList: navigation.hasChapterList,
                                    accessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    /// The chapter row's pick: plays from the place, Undo jump offered.
    private func placeRow(_ row: PlaceRow) -> some View {
        Button {
            pick(row.sentence, origin: .chapter)
        } label: {
            ContentsPlaceLabel(row: row, compact: detent == .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.vertical, Theme.Space.xs)
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
        .buttonStyle(ContentsRowButtonStyle())
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(ContentsSearch.playsFromHereHint)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier(row.identifier)
    }

    /// An eyebrow over a run of rows that scrolls with them.
    private func eyebrow(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { match in
                            resultRow(match)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
                .scrollDismissesKeyboard(.immediately)
                // A restored search lands on the result picked last time.
                .onAppear { scrollToPicked(proxy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// As `scrollToCurrent`: after the first layout pass, and once more
    /// when the presentation has settled.
    private func scrollToPicked(_ proxy: ScrollViewProxy) {
        guard let pickedSentence, results.contains(where: { $0.sentenceID == pickedSentence }) else { return }
        Task { @MainActor in
            proxy.scrollTo(pickedSentence, anchor: .center)
            try? await Task.sleep(nanoseconds: 150_000_000)
            proxy.scrollTo(pickedSentence, anchor: .center)
        }
    }

    private var countLabel: String {
        ContentsSearch.countLabel(results.count)
    }

    /// A result's pick remembers the search for this book, so reopening
    /// Contents steps on to the next hit.
    private func resultRow(_ match: SentenceMatch) -> some View {
        let isPicked = match.sentenceID == pickedSentence
        return Button {
            searchMemory.remember(query: query, pickedSentence: match.sentenceID, in: playback.document?.id)
            pick(match.sentenceID, origin: .searchResult)
        } label: {
            ContentsResultLabel(match: match, location: navigation.searchLocation(ofSentence: match.sentenceID,
                                                                                  page: match.page))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.vertical, Theme.Space.sm)
                .frame(minHeight: 44)
                // The last pick of a restored search: the current marker.
                .overlay(alignment: .leading) {
                    if isPicked {
                        Rectangle()
                            .fill(Theme.accentStrong)
                            .frame(width: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(ContentsRowButtonStyle())
        .id(match.id)
        .accessibilityHint(ContentsSearch.playsFromHereHint)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("search.result.\(match.sentenceID)")
    }

    private func emptyState(for query: String) -> some View {
        keyboardDismissingArea {
            Text(ContentsSearch.noMatchesLabel(query))
                .font(Theme.font(.callout))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .accessibilityIdentifier("search.empty")
        }
    }

    /// Where the list would be, with nothing or one line in it: still a
    /// scroll view, so a drag drops the keyboard as it does over a list.
    /// The line sits a third of the way down, where the old spacers set it.
    private func keyboardDismissingArea<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let line = content()
        return GeometryReader { proxy in
            ScrollView {
                line
                    .frame(maxWidth: .infinity)
                    .padding(.top, proxy.size.height / 3)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - Debounced scan

    /// Debounce, then scan off the main thread. The scan is hundreds of
    /// milliseconds on the largest bundled classics, so it never runs on the
    /// MainActor: the previous scan is cancelled (it polls cancellation per
    /// sentence and abandons the rest of the book), and only the surviving
    /// one publishes — in sentence order, as the scan produces it.
    private func scheduleSearch(for newValue: String, immediately: Bool = false) {
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
            if !immediately {
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }
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

    /// The scan with no debounce: the Search key, and a restored search.
    private func startSearch(now query: String) {
        scheduleSearch(for: query, immediately: true)
    }
}

// MARK: - Row press

/// Contents rows press to surface2, edge to edge, over the sheet's surface;
/// no scale, so the column of text holds still (the shelf's rows do the
/// same).
private struct ContentsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface2 : Color.clear)
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
    }
}

// MARK: - Chapter label

/// A chapter row's text: the title, regular, or semibold on the current
/// chapter (`Theme.rowTitle`), with its listening time trailing on the
/// title's first baseline. Below the accessibility sizes a long title takes
/// two lines before it truncates; at them a trailing time left the title
/// almost no width (every row read as a cut-off first word), so the title
/// wraps to three lines and the time stacks beneath it. Its own view so a
/// layout test can host it without a controller.
struct ContentsChapterLabel: View {

    let title: String
    let estimate: String
    let isCurrent: Bool
    let isCompleted: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let titleText = Text(title)
            .font(Theme.rowTitle(emphasized: isCurrent))
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
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                titleText
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: Theme.Space.sm)

                // The time never truncates; a long title does.
                estimateText
                    .fixedSize()
            }
            // A two-line title's room; a one-line row stays at the 52pt
            // minimum.
            .padding(.vertical, Theme.Space.xs)
        }
    }
}

// MARK: - Place label

/// A place row's text: when and where, over the sentence. The sentence
/// keeps the reader's color and weight on the current row too; the bar and
/// a semibold detail line mark it. At half height (`compact`) the sentence
/// takes one line, two at full height, four at the accessibility sizes.
private struct ContentsPlaceLabel: View {

    let row: PlaceRow
    let compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(row.detail)
                .font(Theme.font(row.isCurrent ? .subhead : .footnote))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(isAccessibilitySize ? nil : 1)
                .multilineTextAlignment(.leading)

            Text(row.snippet)
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text)
                .lineLimit(isAccessibilitySize ? 4 : (compact ? 1 : 2))
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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let snippet = ContentsSearch.snippet(for: match,
                                             leadLimit: ContentsSearch.leadLimit(for: dynamicTypeSize))
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Self.emphasized(snippet, underlined: differentiateWithoutColor)
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

    /// The hit tinted accent, never a weight change (banned in reading
    /// contexts). Under Differentiate Without Color (`underlined`) it is
    /// underlined too, a cue that isn't colour and doesn't change the
    /// snippet's width (P032).
    static func emphasized(_ snippet: ContentsSearch.Snippet, underlined: Bool) -> Text {
        Text(snippet.lead).foregroundColor(Theme.text)
            + Text(snippet.hit).foregroundColor(Theme.accentStrong)
                .underline(underlined, color: Theme.accentStrong)
            + Text(snippet.tail).foregroundColor(Theme.text)
    }
}
