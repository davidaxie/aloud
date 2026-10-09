import AppKit
import SwiftUI

/// Contents beside the page (M16, mac-ux §3.6): the iPhone's Contents
/// (`ContentsSheet`) as an app-drawn leading panel, 300 wide on
/// Theme.surface, never a sidebar or a material. "Search this book" is
/// pinned at the top; below it the chapter list with each chapter's
/// listening time, the current chapter marked by a 3pt accent bar, a
/// semibold title and `.isSelected`, under the shared Part, Book and Act
/// section headers (R17). A book without a chapter list (The Cask of
/// Amontillado) shows search only. Typing replaces the list with results
/// after the iPhone's 200 ms debounce, each sentence in the reading serif
/// with its hit tinted `accentStrong`, as on the iPhone (R3-13).
///
/// The window picks the chrome (`MacContentsLayout`): docked beside the
/// page from 780 pt wide, a floating card over it below that, which closes
/// after a jump. A row click is the shared jump (R15) and plays from
/// there: the chip slot offers Undo jump, and ⌘Z takes it.
///
/// Keyboard (M11): ⌘F focuses the field (`MacUIState.searchFocus`), ↓
/// there moves into the list (`MacSearchHandoff`), ↑/↓ walk its rows,
/// Return jumps, and Esc clears the search, then closes the panel. The
/// list takes those four keys and passes every other one on, so Space and
/// ←/→ still reach the commands, and nothing beeps.
///
/// "Where you stopped" leads the list when the book has places, as on the
/// iPhone (`PlaceHistoryStore`, from the environment): the newest three,
/// then "Show N earlier stops", each its time and chapter over two lines of
/// the sentence in the reading serif, the one at the playhead with a
/// semibold time and chapter and the bar. A click is
/// the chapter row's jump. The keyboard walks places, the toggle and the
/// chapters as one list (`MacContents.ListLayout`), entering on the newest
/// place. The list opens on the current chapter unless the newest stop is
/// in another chapter, when it opens at the top so the stop shows
/// (`PlaceHistory.opensOnCurrentChapter`).
///
/// Chapters and labels are the reader's, derived once per document, as on
/// the iPhone: deriving them here would rescan the book on every playhead
/// tick.
struct MacContentsPanel: View {
    let content: DocContent
    let navigation: ReaderNavigation
    let layout: MacContentsLayout

    @EnvironmentObject private var playback: PlaybackController
    @Environment(MacUIState.self) private var ui
    @Environment(\.chromeScale) private var scale
    @Environment(\.placeHistory) private var placeHistory

    @State private var query = ""
    @State private var results: [SentenceMatch] = []
    /// The trimmed query `results` answer; nil until one has been scanned,
    /// so "No matches" never shows before the user has typed. A new scan
    /// leaves the previous answer on screen until it lands.
    @State private var searchedQuery: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var scanTask: Task<[SentenceMatch], Never>?
    /// Return in the field before its scan landed: the top result, once it does.
    @State private var submitPending = false
    /// Bumped to put the caret in the field: ⌘F, ↑ off the first row, Esc
    /// from the results.
    @State private var fieldFocusRequest = 0
    /// The row the keyboard is on: a chapter index, or a result's.
    @State private var cursor: Int?
    @FocusState private var isListFocused: Bool
    /// A remap moved the cursor onto a row VoiceOver hasn't heard while the
    /// list was away; focus coming back says it.
    @State private var cursorUnheard = false
    /// Whose ↓ handoff is offered: this panel's, until it goes.
    @State private var handoffOwner = UUID()
    /// "Show N earlier stops" pressed; reset when the panel goes.
    @State private var showsEarlierPlaces = false

    var body: some View {
        let mode = MacContents.mode(hasChapterList: navigation.hasChapterList, hasPlaces: !placeRows.isEmpty,
                                    query: query, searchedQuery: searchedQuery, resultCount: results.count)
        let bookLeft = MacContents.bookMinutesLeft(navigation, playhead: playback.currentSentence,
                                                   rate: playback.rate, isFinished: playback.isAtEnd,
                                                   query: query)
        VStack(alignment: .leading, spacing: 0) {
            Text(MacContents.title)
                .font(Theme.font(.headline, scale: scale))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("contents.title")
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, bookLeft == nil ? Theme.Space.sm : Theme.Space.xxs)

            // The whole book's time left, as the iPhone's Contents says it
            // (R4-29): the chapter line counts only to the chapter's end.
            if let bookLeft {
                Text(ContentsSearch.bookLeftCaption(minutes: bookLeft))
                    .font(Theme.font(.caption, scale: scale))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(ContentsSearch.bookLeftSpoken(minutes: bookLeft))
                    .accessibilityIdentifier("contents.bookLeft")
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
            }

            // Pinned: the field never scrolls away with the list.
            MacContentsSearchField(text: $query, focusRequest: fieldFocusRequest,
                                   fontSize: PlatformTypeRamp.points(.body, scale: scale),
                                   onSubmit: submit, onEscape: escape)
                .padding(.horizontal, Theme.Space.md)
                .padding(.bottom, Theme.Space.xs)

            list(mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // One stop for the keyboard, as a table is: the rows are
                // its cursor, never focus stops of their own.
                .focusable(rowCount(mode) > 0, interactions: .edit)
                .focused($isListFocused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { moveCursor(by: -1, mode: mode) }
                .onKeyPress(.downArrow) { moveCursor(by: 1, mode: mode) }
                .onKeyPress(.return) { activateCursor(mode) }
                .onKeyPress(.escape) {
                    escape()
                    return .handled
                }
        }
        .frame(width: MacContentsLayout.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: layout == .overlaid ? Theme.Radius.lg : 0,
                                    style: .continuous))
        .background { chrome }
        .padding(layout == .overlaid ? Theme.Space.sm : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MacContents.title)
        .accessibilityIdentifier("contents.panel")
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        // ⌘F (Edit ▸ Find) names this field; the request is spent once read.
        .onChange(of: ui.searchFocus, initial: true) { _, target in
            guard target == .contents else { return }
            focusField()
            ui.searchFocus = nil
        }
        // Focus that lands on the list some other way (Tab, a click on its
        // background) starts on the row ↓ would have, or says the row a
        // remap moved the cursor to while the list was away.
        .onChange(of: isListFocused) { _, focused in
            guard focused else { return }
            if cursor == nil {
                cursor = initialCursor(mode)
                announceCursor(mode)
            } else if cursorUnheard {
                announceCursor(mode)
            }
        }
        // A stop recorded, or the toggle shown or hidden, while the list is
        // open: the cursor stays on its row, never the one that slid under it.
        // A results cursor stays on its result. Left on a row VoiceOver
        // hasn't heard (a place pushed behind the toggle, the toggle's new
        // words), it says that row, so Return never acts on one unheard.
        .onChange(of: listLayout) { old, new in
            let remapped = MacContents.remap(cursor, from: old, to: new, in: currentMode)
            let unheard = MacContents.remapIsUnheard(cursor, to: remapped, from: old, to: new, in: currentMode)
            cursor = remapped
            guard unheard else { return }
            cursorUnheard = true
            if isListFocused { announceCursor(currentMode) }
        }
        .onAppear {
            MacSearchHandoff.shared.offer(by: handoffOwner) { focusList() }
        }
        .onDisappear {
            MacSearchHandoff.shared.withdraw(by: handoffOwner)
            debounceTask?.cancel()
            scanTask?.cancel()
        }
    }

    // MARK: - Chrome

    /// Docked: paper with a trailing border, the page beside it. Overlaid:
    /// a floating card, the only place the reader raises anything.
    @ViewBuilder
    private var chrome: some View {
        switch layout {
        case .docked:
            Theme.surface
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Theme.Stroke.borderColor)
                        .frame(width: Theme.Stroke.borderWidth)
                }
                .accessibilityHidden(true)
        case .overlaid:
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
                .shadow(color: Theme.Elevation.raisedInk, radius: Theme.Elevation.raisedRadius,
                        y: Theme.Elevation.raisedY)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private func list(_ mode: MacContents.Mode) -> some View {
        switch mode {
        case .chapters: chapterList
        case .results: resultsList
        case .noMatches(let searched): emptyState(for: searched)
        // Search only, or the first scan still running.
        case .searchOnly, .searching: Color.clear
        }
    }

    private var chapterList: some View {
        let current = navigation.chapterIndex(containing: playback.currentSentence)
        let rate = playback.rate
        let rows = placeRows
        // Chapters follow the places in the flat list (ids, cursor).
        let offset = flatLayout(rows).chapterOffset
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !rows.isEmpty {
                        placesSection(rows)
                        // A titled first section (Part, Book) names itself.
                        if navigation.hasChapterList, navigation.sections.first?.title == nil {
                            eyebrow(PlaceHistoryRows.listsPages(navigation)
                                        ? PlaceHistoryCopy.pagesHeader : PlaceHistoryCopy.chaptersHeader,
                                    identifier: "contents.section.list")
                        }
                    }
                    if navigation.hasChapterList {
                        ForEach(navigation.sections) { section in
                            if let title = section.title {
                                Section {
                                    chapterRows(section, current: current, rate: rate, offset: offset)
                                } header: {
                                    sectionHeader(title, id: section.id)
                                }
                            } else {
                                Section {
                                    chapterRows(section, current: current, rate: rate, offset: offset)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            // On the current chapter when the newest stop is in it (or there
            // are none); at the top, on the newest stop, when that stop is in
            // another chapter. Chapters follow the places in the flat ids.
            .onAppear {
                if PlaceHistory.opensOnCurrentChapter(newestStop: rows.first?.sentence,
                                                      playhead: playback.currentSentence,
                                                      navigation: navigation) {
                    scrollToCurrent(proxy, current: current.map { $0 + offset })
                }
            }
            .onChange(of: cursor) { _, row in
                guard let row else { return }
                // A place is keyed by its sentence (`PlaceKey`); the rest
                // by their flat index.
                if case .place(let index)? = flatLayout(rows).row(at: row), rows.indices.contains(index) {
                    proxy.scrollTo(MacContents.PlaceKey(sentence: rows[index].sentence))
                } else {
                    proxy.scrollTo(row)
                }
            }
        }
    }

    private func chapterRows(_ section: ContentsSection, current: Int?, rate: Double,
                             offset: Int) -> some View {
        ForEach(section.chapterRange, id: \.self) { index in
            chapterRow(MacContents.chapterRow(navigation, index: index, current: current, rate: rate),
                       flatIndex: offset + index)
        }
    }

    /// Opaque, so the rows scrolling beneath a pinned header never show
    /// through it.
    private func sectionHeader(_ title: String, id: Int) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow, scale: scale))
            .eyebrowTracking()
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .background(Theme.surface)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("contents.section.\(id)")
    }

    /// `flatIndex`: the row's place in the flat list, after any places.
    private func chapterRow(_ row: MacContentsChapterRow, flatIndex: Int) -> some View {
        Button {
            pickChapter(row.index)
        } label: {
            MacContentsChapterLabel(row: row, scale: scale)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.sm))
        .focusable(false)
        .overlay { cursorRing(flatIndex) }
        .padding(.horizontal, Theme.Space.xs)
        // The current chapter's marker: a bar on the panel's leading edge,
        // outside the rows, so every title stays aligned.
        .overlay(alignment: .leading) {
            if row.isCurrent {
                Rectangle()
                    .fill(Theme.accentStrong)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
        .id(flatIndex)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier(row.identifier)
    }

    // MARK: - Where you stopped

    /// The book's places as rows; at most eight.
    private var placeRows: [PlaceRow] {
        guard let placeHistory else { return [] }
        let entries = placeHistory.places(for: playback.document?.id, contentHash: content.contentHash)
        guard !entries.isEmpty else { return [] }
        return PlaceHistoryRows.rows(entries, content: content, navigation: navigation,
                                     playhead: playback.currentSentence)
    }

    private var listLayout: MacContents.ListLayout { flatLayout(placeRows) }

    private func flatLayout(_ places: [PlaceRow]) -> MacContents.ListLayout {
        MacContents.listLayout(placeCount: places.count, expanded: showsEarlierPlaces,
                               chapterCount: navigation.chapters.count,
                               hasChapterList: navigation.hasChapterList,
                               placeSentences: places.map(\.sentence))
    }

    @ViewBuilder
    private func placesSection(_ rows: [PlaceRow]) -> some View {
        let list = flatLayout(rows)
        eyebrow(PlaceHistoryCopy.header, identifier: "places.header")
        // Keyed by place, never position: a stop recorded while the panel
        // is open slides the rows down with their own elements, so the
        // VoiceOver cursor stays on the place it read (L026).
        ForEach(Array(rows.prefix(list.placeCount)), id: \.sentence) { row in
            placeRow(row)
        }
        if list.hasShowEarlier {
            let flatIndex = list.index(of: .showEarlier)
            Button {
                toggleEarlierPlaces()
            } label: {
                Text(showsEarlierPlaces ? PlaceHistoryCopy.showFewer
                                        : PlaceHistoryCopy.showEarlier(rows.count - list.placeCount))
                    .font(Theme.font(.subhead, scale: scale))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.sm)
                    .frame(minHeight: 32)
            }
            .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.sm))
            .focusable(false)
            .overlay { cursorRing(flatIndex) }
            .padding(.horizontal, Theme.Space.xs)
            .id(flatIndex)
            .accessibilityIdentifier("places.more")
        }
    }

    private func placeRow(_ row: PlaceRow) -> some View {
        Button {
            pickPlace(row.index)
        } label: {
            MacContentsPlaceLabel(row: row, scale: scale)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.sm))
        .focusable(false)
        .overlay { cursorRing(row.index) }
        .padding(.horizontal, Theme.Space.xs)
        // The current chapter's bar, on the place at the playhead.
        .overlay(alignment: .leading) {
            if row.isCurrent {
                Rectangle()
                    .fill(Theme.accentStrong)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
        .id(MacContents.PlaceKey(sentence: row.sentence))
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier(row.identifier)
    }

    /// An eyebrow over a run of rows that scrolls with them.
    private func eyebrow(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow, scale: scale))
            .eyebrowTracking()
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(MacContents.countLabel(results.count))
                .font(Theme.font(.subhead, scale: scale))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.Space.md)
                .accessibilityIdentifier("search.count")

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results.indices, id: \.self) { index in
                            resultRow(results[index], index: index)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
                .onChange(of: cursor) { _, row in
                    if let row { proxy.scrollTo(row) }
                }
            }
        }
    }

    private func resultRow(_ match: SentenceMatch, index: Int) -> some View {
        Button {
            pickResult(index)
        } label: {
            MacContentsResultLabel(match: match, location: navigation.searchLocation(ofSentence: match.sentenceID,
                                                                                     page: match.page),
                                   scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.xs)
                .frame(minHeight: 44)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.sm))
        .focusable(false)
        .overlay { cursorRing(index) }
        .padding(.horizontal, Theme.Space.xs)
        .id(index)
        .accessibilityIdentifier("search.result.\(match.sentenceID)")
    }

    private func emptyState(for searched: String) -> some View {
        Text(MacContents.noMatchesLabel(searched))
            .font(Theme.font(.callout, scale: scale))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.xxl)
            .accessibilityIdentifier("search.empty")
    }

    /// The keyboard's row while the list has focus: the system focus
    /// ring's shape, in the accent, over the hover plate.
    @ViewBuilder
    private func cursorRing(_ index: Int) -> some View {
        if isListFocused, cursor == index {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.accentStrong, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Land on the current chapter without animation. A LazyVStack has not
    /// laid out its rows when `onAppear` fires, so the scroll repeats once
    /// after the first layout pass, as the iPhone's sheet does.
    private func scrollToCurrent(_ proxy: ScrollViewProxy, current: Int?) {
        guard let current else { return }
        Task { @MainActor in
            proxy.scrollTo(current, anchor: .center)
            try? await Task.sleep(nanoseconds: 150_000_000)
            proxy.scrollTo(current, anchor: .center)
        }
    }

    // MARK: - Keyboard

    private func rowCount(_ mode: MacContents.Mode) -> Int {
        switch mode {
        case .chapters: return listLayout.count
        case .results: return results.count
        case .searchOnly, .searching, .noMatches: return 0
        }
    }

    /// Where the keyboard enters the list: the newest place, else the
    /// current chapter; or the top result.
    private func initialCursor(_ mode: MacContents.Mode) -> Int? {
        switch mode {
        case .chapters:
            return listLayout.entry(currentChapter: navigation.chapterIndex(containing: playback.currentSentence))
        case .results: return results.isEmpty ? nil : 0
        case .searchOnly, .searching, .noMatches: return nil
        }
    }

    private var currentMode: MacContents.Mode {
        MacContents.mode(hasChapterList: navigation.hasChapterList, hasPlaces: !placeRows.isEmpty,
                         query: query, searchedQuery: searchedQuery, resultCount: results.count)
    }

    /// ↓ in the field (`MacSearchHandoff`): the list takes focus on its
    /// entry row. False with no rows, and the field keeps the key.
    private func focusList() -> Bool {
        guard let entry = initialCursor(currentMode) else { return false }
        cursor = entry
        isListFocused = true
        announceCursor(currentMode)
        return true
    }

    private func focusField() {
        isListFocused = false
        fieldFocusRequest &+= 1
    }

    private func moveCursor(by delta: Int, mode: MacContents.Mode) -> KeyPress.Result {
        switch MacContents.step(cursor ?? initialCursor(mode), by: delta, count: rowCount(mode)) {
        case .row(let row):
            cursor = row
            announceCursor(mode)
        case .field: focusField()
        }
        return .handled
    }

    /// VoiceOver hears the row the keyboard's cursor lands on: the ring is
    /// drawn only, and the list is one element, so ↓ from the field and
    /// each ↑/↓ would be silent, and Return would open a row never heard.
    private func announceCursor(_ mode: MacContents.Mode) {
        guard let cursor, let label = cursorLabel(cursor, mode: mode) else { return }
        cursorUnheard = false
        MacContents.announceCursor(label, muted: playback.isOutputMuted)
    }

    private func cursorLabel(_ index: Int, mode: MacContents.Mode) -> String? {
        switch mode {
        case .chapters:
            let rows = placeRows
            let layout = flatLayout(rows)
            return MacContents.cursorLabel(layout.row(at: index), places: rows,
                                           earlier: rows.count - layout.placeCount,
                                           expanded: showsEarlierPlaces, navigation: navigation,
                                           current: navigation.chapterIndex(containing: playback.currentSentence),
                                           rate: playback.rate)
        case .results:
            guard results.indices.contains(index) else { return nil }
            let match = results[index]
            return MacContents.resultLabel(match, location: navigation.searchLocation(ofSentence: match.sentenceID,
                                                                                      page: match.page))
        case .searchOnly, .searching, .noMatches: return nil
        }
    }

    private func activateCursor(_ mode: MacContents.Mode) -> KeyPress.Result {
        guard let cursor, cursor < rowCount(mode) else { return .handled }
        switch mode {
        case .chapters:
            switch listLayout.row(at: cursor) {
            case .place(let index): pickPlace(index)
            case .showEarlier: toggleEarlierPlaces()
            case .chapter(let index): pickChapter(index)
            case nil: break
            }
        case .results: pickResult(cursor)
        case .searchOnly, .searching, .noMatches: break
        }
        return .handled
    }

    /// Esc: the first clears the search, the next closes the panel.
    private func escape() {
        switch MacContents.escape(query: query) {
        case .clearSearch:
            query = ""
            focusField()
        case .close:
            ui.isContentsShown = false
        }
    }

    /// Return in the field: the top result, as Spotlight does. Pressed
    /// before the debounced scan lands, it waits for it.
    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard searchedQuery == trimmed else {
            submitPending = true
            return
        }
        if !results.isEmpty { pickResult(0) }
    }

    // MARK: - Jumps

    private func pickChapter(_ index: Int) {
        guard navigation.chapters.indices.contains(index) else { return }
        cursor = listLayout.index(of: .chapter(index))
        jump(to: navigation.chapters[index].startSentence, origin: .chapter)
    }

    /// A place is a chapter row's jump: it plays, and ⌘Z restores. The
    /// stop the jump records lands above the place, and the remap follows
    /// the place down by its sentence.
    private func pickPlace(_ index: Int) {
        let rows = placeRows
        guard rows.indices.contains(index) else { return }
        cursor = index
        jump(to: rows[index].sentence, origin: .chapter)
    }

    /// The cursor stays on the toggle, which moves as rows come and go:
    /// put on it in the list before the press, and carried once by the
    /// remap of `onChange(of: listLayout)`, which says its new words.
    private func toggleEarlierPlaces() {
        cursor = MacContents.cursorOnToggle(cursor, before: listLayout)
        showsEarlierPlaces.toggle()
    }

    private func pickResult(_ index: Int) {
        guard results.indices.contains(index) else { return }
        cursor = index
        jump(to: results[index].sentenceID, origin: .searchResult)
    }

    /// A docked panel keeps focus in its list, so ↓ Return can step again;
    /// a card closes, uncovering the page the jump moved.
    private func jump(to sentence: Int, origin: JumpOrigin) {
        MacContents.jump(playback, to: sentence, origin: origin)
        if layout.closesAfterJump {
            ui.isContentsShown = false
        } else {
            isListFocused = true
        }
    }

    // MARK: - Debounced scan

    /// Debounce, then scan off the main thread, as the iPhone's sheet does:
    /// the previous scan is cancelled, and only the surviving one publishes.
    private func scheduleSearch(for newValue: String) {
        debounceTask?.cancel()
        scanTask?.cancel()
        submitPending = false
        cursor = nil
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            searchedQuery = nil
            return
        }
        let content = content
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: MacContents.debounceNanoseconds)
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
            // VoiceOver hears what landed.
            ContentsSearch.announceResults(count: found.count, query: trimmed,
                                           previousCount: previousCount, muted: playback.isOutputMuted)
            // ↓ may have entered the list on the previous query's results
            // while this scan ran: its cursor moves onto what landed.
            switch MacContents.cursorAfterScan(listFocused: isListFocused, found: found.count) {
            case .row(let row)?:
                cursor = row
                announceCursor(.results)
            case .field?:
                cursor = nil
                focusField()
            case nil:
                break
            }
            if submitPending {
                submitPending = false
                if !found.isEmpty { pickResult(0) }
            }
        }
    }
}

// MARK: - Layout

/// Where the Contents panel sits (mac-ux §3.6): beside the page while the
/// window holds the panel and a reading column, over the page below that.
enum MacContentsLayout: Equatable {
    case docked
    case overlaid

    /// The panel's width, docked or not.
    static let panelWidth: CGFloat = 300
    /// The narrowest reading column the page keeps beside a docked panel.
    static let readingMinimum: CGFloat = 480
    /// 300 + 480: from here the panel docks.
    static let dockingWidth: CGFloat = panelWidth + readingMinimum

    init(windowWidth: CGFloat) {
        self = windowWidth >= Self.dockingWidth ? .docked : .overlaid
    }

    /// A card covers the page a jump just moved, so it goes.
    var closesAfterJump: Bool { self == .overlaid }

    /// The page's leading inset while the panel shows: a docked panel takes
    /// its width, a card floats over the page.
    var pageInset: CGFloat { self == .docked ? Self.panelWidth : 0 }
}

// MARK: - Rules

/// The panel's rules and copy, apart from the view, so the tests read what
/// the panel draws and does.
@MainActor
enum MacContents {

    static let title = ContentsSearch.title
    static let searchPrompt = ContentsSearch.searchPrompt

    /// The line under the title (R4-29): the shared whole-book estimate,
    /// over the list only, as on the iPhone. nil draws no line.
    static func bookMinutesLeft(_ navigation: ReaderNavigation, playhead: Int, rate: Double,
                                isFinished: Bool, query: String) -> Int? {
        guard ContentsSearch.showsBookLeft(query: query) else { return nil }
        return navigation.bookMinutesLeft(at: playhead, rate: rate, isFinished: isFinished)
    }

    /// The iPhone's debounce: a scan per pause in typing, not per key.
    static let debounceNanoseconds: UInt64 = 200_000_000
    /// Characters kept before a result's hit: the iPhone's below the
    /// accessibility sizes, which a 300 pt panel's line holds twice over.
    static let leadLimit = ContentsSearch.leadLimit(for: .large)

    static func countLabel(_ count: Int) -> String {
        ContentsSearch.countLabel(count)
    }

    static func noMatchesLabel(_ query: String) -> String {
        ContentsSearch.noMatchesLabel(query)
    }

    // MARK: Chapters

    /// Chapter `index` as its row shows and speaks it. Rate-aware, like the
    /// chapter line's time left: at 2× a chapter takes half as long.
    static func chapterRow(_ navigation: ReaderNavigation, index: Int, current: Int?,
                           rate: Double) -> MacContentsChapterRow {
        let chapter = navigation.chapters[index]
        return MacContentsChapterRow(
            index: index,
            title: navigation.title(ofChapter: index),
            minutes: chapter.estimatedMinutes(wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate),
            startSentence: chapter.startSentence,
            isCurrent: index == current,
            isCompleted: current.map { index < $0 } ?? false,
            identifier: navigation.rowIdentifier(at: index))
    }

    /// Every chapter's row, with the playhead's marked.
    static func chapterRows(_ navigation: ReaderNavigation, playhead: Int,
                            rate: Double) -> [MacContentsChapterRow] {
        let current = navigation.chapterIndex(containing: playhead)
        return navigation.chapters.indices.map { chapterRow(navigation, index: $0, current: current, rate: rate) }
    }

    // MARK: What shows

    enum Mode: Equatable {
        /// No query: the chapter list.
        case chapters
        /// No query in a book without a chapter list: the field alone.
        case searchOnly
        /// A query whose first scan hasn't landed.
        case searching
        case results
        case noMatches(String)
    }

    /// `hasPlaces`: "Where you stopped" has rows, which a book without a
    /// chapter list shows in place of the list.
    static func mode(hasChapterList: Bool, hasPlaces: Bool = false, query: String, searchedQuery: String?,
                     resultCount: Int) -> Mode {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hasChapterList || hasPlaces ? .chapters : .searchOnly
        }
        guard let searchedQuery else { return .searching }
        return resultCount == 0 ? .noMatches(searchedQuery) : .results
    }

    // MARK: Keys

    enum CursorMove: Equatable {
        case row(Int)
        /// Up off the first row: back to "Search this book".
        case field
    }

    /// ↑/↓ from `cursor` over `count` rows: clamped at the bottom, back to
    /// the field off the top.
    static func step(_ cursor: Int?, by delta: Int, count: Int) -> CursorMove {
        guard count > 0 else { return .field }
        guard let cursor else { return delta < 0 ? .field : .row(0) }
        let next = cursor + delta
        return next < 0 ? .field : .row(min(next, count - 1))
    }

    /// A place row's identity in the list: its sentence, never its
    /// position (L026). A type of its own, apart from the flat indices the
    /// toggle and the chapters are keyed by.
    struct PlaceKey: Hashable {
        let sentence: Int
    }

    /// Where the keyboard's cursor goes as a scan lands (L024). With the
    /// list away, nowhere: the field keeps the keyboard. With the list
    /// holding it (↓ entered the previous query's results while the scan
    /// ran), the top result, said, so Return never opens a row VoiceOver
    /// hasn't read; with nothing found, the field, since a list with no
    /// rows can't hold the keyboard.
    static func cursorAfterScan(listFocused: Bool, found: Int) -> CursorMove? {
        guard listFocused else { return nil }
        return found > 0 ? .row(0) : .field
    }

    /// What VoiceOver hears as the cursor lands on a row of the list: the
    /// row's own label (a place's, a chapter's), or the toggle's words.
    /// `earlier`: the places the collapsed list holds back.
    static func cursorLabel(_ row: ListRow?, places: [PlaceRow], earlier: Int, expanded: Bool,
                            navigation: ReaderNavigation, current: Int?, rate: Double) -> String? {
        switch row {
        case .place(let index):
            return places.indices.contains(index) ? places[index].accessibilityLabel : nil
        case .showEarlier:
            return expanded ? PlaceHistoryCopy.showFewer : PlaceHistoryCopy.showEarlier(earlier)
        case .chapter(let index):
            guard navigation.chapters.indices.contains(index) else { return nil }
            return chapterRow(navigation, index: index, current: current, rate: rate).accessibilityLabel
        case nil:
            return nil
        }
    }

    /// A row of the list as VoiceOver hears it, by what it is rather than
    /// where it sits: a place by its sentence, the toggle by the stops it
    /// holds back (none once pressed: "Show fewer"), a chapter by its index.
    enum HeardRow: Equatable {
        case place(sentence: Int?)
        case toggle(earlier: Int)
        case chapter(Int)
    }

    static func heardRow(_ cursor: Int?, in layout: ListLayout) -> HeardRow? {
        switch cursor.flatMap(layout.row(at:)) {
        case .place(let index):
            return .place(sentence: layout.placeSentences.indices.contains(index)
                          ? layout.placeSentences[index] : nil)
        case .showEarlier:
            return .toggle(earlier: max(layout.placeSentences.count - layout.placeCount, 0))
        case .chapter(let index):
            return .chapter(index)
        case nil:
            return nil
        }
    }

    /// The remap left the cursor on a row VoiceOver hasn't heard: another
    /// place (a picked place pushed behind the toggle leaves it on the
    /// toggle; the newest place replaced in one sitting), another chapter,
    /// or the toggle with new words (pressed, or holding back one more).
    /// A place followed down a row by its sentence is the row it heard,
    /// and stays quiet. Only the list in `.chapters` remaps.
    static func remapIsUnheard(_ cursor: Int?, to remapped: Int?, from old: ListLayout, to new: ListLayout,
                               in mode: Mode) -> Bool {
        guard mode == .chapters, remapped != nil else { return false }
        return heardRow(cursor, in: old) != heardRow(remapped, in: new)
    }

    /// A result as VoiceOver reads its row: the whole sentence, then its
    /// chapter or page.
    static func resultLabel(_ match: SentenceMatch, location: String?) -> String {
        [ReaderTypography.typeset(match.text), location].compactMap { $0 }.joined(separator: ", ")
    }

    /// The cursor's row, said at once: unqueued, so a run of ↑/↓ says the
    /// row it is on now, never every row it passed.
    static func announceCursor(_ label: String, muted: Bool) {
        #if DEBUG
        UITestAnnouncementLog.shared.record(label)
        #endif
        guard !muted else { return }
        A11yAnnounce.post(label, queued: false)
    }

    enum Escape: Equatable {
        case clearSearch
        case close
    }

    /// The first Esc clears the search; with nothing to clear, Esc closes.
    static func escape(query: String) -> Escape {
        query.isEmpty ? .close : .clearSearch
    }

    // MARK: Jumps

    /// A row's click (R15, M16): the shared jump, which offers Undo jump
    /// with the listener's status, then play from there. On the Mac a row
    /// plays, as a click on the page does; ⌘Z restores the sentence and the
    /// pause.
    static func jump(_ playback: PlaybackController, to sentence: Int, origin: JumpOrigin) {
        ContentsSearch.jumpAndPlay(playback, to: sentence, origin: origin)
    }
}

/// One chapter row, as the panel draws and VoiceOver reads it.
struct MacContentsChapterRow: Equatable {
    /// Into `ReaderNavigation.chapters`.
    let index: Int
    let title: String
    let minutes: Int
    let startSentence: Int
    let isCurrent: Bool
    /// Before the current chapter: muted.
    let isCompleted: Bool
    /// The iPhone's: "chapters.row.<page>".
    let identifier: String

    /// "8 min", "1 hr 12 min".
    var estimate: String { ListeningEstimate.phrase(minutes: minutes) }

    /// "CHAPTER I, 1 hour 12 minutes, current".
    var accessibilityLabel: String {
        ContentsSearch.chapterAccessibilityLabel(title: title, minutes: minutes, isCurrent: isCurrent)
    }
}

// MARK: - Row labels

/// Serif title, semibold on the current chapter, with its listening time
/// trailing in tabular digits. Two lines before it truncates: the panel's
/// width is fixed, and the chrome's type grows with the reader's size.
private struct MacContentsChapterLabel: View {
    let row: MacContentsChapterRow
    let scale: ChromeScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(row.title)
                .font(Theme.readerSerif(PlatformTypeRamp.points(.headline, scale: scale),
                                        weight: row.isCurrent ? .semibold : .regular))
                .foregroundStyle(row.isCompleted ? Theme.textMuted : Theme.text)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.estimate)
                .font(Theme.font(.caption, scale: scale))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: 44)
    }
}

/// A result: the sentence in the reading serif (`Theme.excerpt`), cut to
/// start a few words before its hit (`ContentsSearch.snippet`), the hit
/// tinted `accentStrong` as on the iPhone (never a weight change), and
/// underlined too under Differentiate Without Color, over its chapter or
/// page in the sans: none in a book without chapters, where every hit
/// would name the same one (`ReaderNavigation.searchLocation`).
struct MacContentsResultLabel: View {
    let match: SentenceMatch
    let location: String?
    let scale: ChromeScale

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        let snippet = ContentsSearch.snippet(for: match, leadLimit: MacContents.leadLimit)
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Self.emphasized(snippet, underlined: differentiateWithoutColor)
                .font(Theme.excerpt(scale: scale))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                // The cut is only visual: VoiceOver reads the whole sentence.
                .accessibilityLabel(ReaderTypography.typeset(match.text))

            if let location {
                Text(location)
                    .font(Theme.font(.footnote, scale: scale))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
    }

    /// The hit in `accentStrong`, the rest in the reader's colour; one
    /// weight throughout. Under Differentiate Without Color (`underlined`)
    /// the hit is underlined too, a cue that isn't colour and doesn't
    /// change the snippet's width, as on the iPhone (P032).
    static func emphasized(_ snippet: ContentsSearch.Snippet, underlined: Bool) -> Text {
        Text(snippet.lead).foregroundColor(Theme.text)
            + Text(snippet.hit).foregroundColor(Theme.accentStrong)
                .underline(underlined, color: Theme.accentStrong)
            + Text(snippet.tail).foregroundColor(Theme.text)
    }
}

// MARK: - Search field

/// "Search this book": an `NSSearchField`, so the key router knows it for
/// a search field and offers its ↓ to the list (`MacSearchHandoff`), and
/// so it edits through the window's field editor, whose menu carries no
/// Speech (`MacFieldEditor`). Return submits, Esc goes to the panel, and
/// every other key is the field's own.
struct MacContentsSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Each change puts the caret in the field.
    let focusRequest: Int
    let fontSize: CGFloat
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// "Search this book" in textFaint at the field's size.
    static func placeholder(fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(string: MacContents.searchPrompt,
                           attributes: [.foregroundColor: NSColor(Theme.textFaint),
                                        .font: NSFont.systemFont(ofSize: fontSize)])
    }

    func makeNSView(context: Context) -> MacContentsSearchFieldView {
        let field = MacContentsSearchFieldView()
        field.placeholderString = MacContents.searchPrompt
        // textFaint, as the iPhone's field: 4.5:1 on its ground in both
        // appearances, where the system placeholder grey is not.
        field.placeholderAttributedString = Self.placeholder(fontSize: fontSize)
        field.setAccessibilityIdentifier("search.field")
        field.controlSize = .large
        field.font = .systemFont(ofSize: fontSize)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The cancel button clears through the action; typing reports
        // through `controlTextDidChange`.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: MacContentsSearchFieldView, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.font?.pointSize != fontSize {
            field.font = .systemFont(ofSize: fontSize)
            field.placeholderAttributedString = Self.placeholder(fontSize: fontSize)
        }
        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        // Not inside SwiftUI's update: the focus change reaches its state.
        DispatchQueue.main.async { field.requestFocus() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacContentsSearchFieldView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? MacContentsLayout.panelWidth, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacContentsSearchField
        /// The request the field last answered: none yet, so a request
        /// made as the panel appears (⌘F) lands with the first update.
        var focusRequest = 0

        init(parent: MacContentsSearchField) {
            self.parent = parent
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }

        /// Return and Esc are the panel's, and handled: neither ends the
        /// edit, and neither beeps. Every other command is the field's,
        /// save one it has no use for, which ends here in silence.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch MacContentsFieldKey(selector: selector) {
            case .submit?: parent.onSubmit()
            case .escape?: parent.onEscape()
            case nil: return MacContentsFieldKey.isUnused(selector, by: textView)
            }
            return true
        }
    }
}

/// The field's two keys of its own, as the field editor reads them.
enum MacContentsFieldKey: Equatable {
    case submit
    case escape

    init?(selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            self = .submit
        case #selector(NSResponder.cancelOperation(_:)):
            self = .escape
        default:
            return nil
        }
    }

    /// An unbound key's `noop:`, or a command the field editor doesn't
    /// implement: past the field it would climb the chain to the alert
    /// sound (M11).
    static func isUnused(_ selector: Selector, by textView: NSTextView) -> Bool {
        selector == Selector(("noop:")) || !textView.responds(to: selector)
    }
}

/// Takes the caret when asked, or, asked before it is in a window (⌘F
/// opening the panel), as soon as it is.
final class MacContentsSearchFieldView: NSSearchField {
    private var wantsFocus = false

    func requestFocus() {
        guard let window else {
            wantsFocus = true
            return
        }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, window != nil else { return }
        requestFocus()
    }
}
