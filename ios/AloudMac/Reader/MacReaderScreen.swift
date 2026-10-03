import SwiftUI

/// One document in the window (M6, M9, contracts §6). Identity sits in the
/// toolbar: Contents, the system back button (⌘[), the book's title with its
/// author as the subtitle, and Aa. Every frequent control sits in the bottom
/// bar. The page slot holds the title page until wave 2.2 puts the TextKit 2
/// page there; the Contents panel (M16) sits on its leading edge, docked
/// beside it in a window 780 pt wide or more and floating over it below.
///
/// Opening cues the saved sentence and hands the book to `startAutoplay()`,
/// as the iPhone's reader does (R4): one click from the Library is a voice.
/// Progress is saved by `PlaybackController.onProgress` alone.
///
/// One message at a time (R11): the chapter line in the bar shows the one
/// message, and the one chip slot above the bar shows the one chip. Leaving
/// the reader keeps the book playing; the window's close does too.
struct MacReaderScreen: View {
    let documentID: UUID

    init(documentID: UUID) {
        self.documentID = documentID
    }

    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @Environment(MacUIState.self) private var ui

    @AppStorage(ReaderTextSize.prefKey) private var textSizeStep = ReaderTextSize.defaultStep

    @State private var content: DocContent?
    /// Derived once when the document loads, and shared with the menus'
    /// chapter steps through `MacNavigationCache`: a build is a pass over
    /// the book.
    @State private var navigation: ReaderNavigation?
    @State private var loadFailed = false
    /// Where the voice is while the page isn't following it (R16). The
    /// phase-1 title page never sets it; phase 2's page does.
    @State private var voiceOffscreen: ReaderFollowDirection?
    /// Bumped by Follow the voice; phase 2's page follows on a change.
    @State private var followRequests = 0

    var body: some View {
        VStack(spacing: 0) {
            // The window's width, not the page's: the reader spans the
            // window, and the panel docks by what the window can hold.
            GeometryReader { proxy in
                pageArea(MacContentsLayout(windowWidth: proxy.size.width))
            }
            if let content, let navigation, let document {
                MacPlayerBar(document: document, content: content, navigation: navigation,
                             onToggleContents: toggleContents)
            }
        }
        .background(Theme.bg)
        // The bar's type and Play circle grow with the reader's text size,
        // in three bands (M18).
        .environment(\.chromeScale, ChromeScale(readerStep: textSizeStep))
        #if DEBUG
        .overlay(alignment: .topLeading) { sentenceProbe }
        #endif
        .navigationTitle(document?.title ?? "")
        .navigationSubtitle(document?.author ?? "")
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar { toolbarContent }
        // ⌘J, while the chip offers it.
        .focusedSceneValue(\.macFollowVoice, voiceOffscreen == nil ? nil : followVoice)
        .task {
            await load()
        }
        .onDisappear {
            // A popover belongs to this reader; the next one opens bare.
            ui.isListeningShown = false
            ui.isAppearanceShown = false
        }
    }

    // MARK: - Page

    /// The page with the chip slot over its foot, and Contents on its
    /// leading edge while shown. One place in the tree for the panel,
    /// docked or floating, so a resize across 780 pt keeps its search.
    private func pageArea(_ layout: MacContentsLayout) -> some View {
        let inset = isContentsVisible ? layout.pageInset : 0
        return ZStack(alignment: .topLeading) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The chip rides the page: centered beside a docked panel,
                // and under a floating card, the one raised surface, which
                // would otherwise lose its last rows to the chip below 780
                // pt. A jump closes the card, uncovering Undo jump.
                .overlay(alignment: .bottom) {
                    if content != nil {
                        MacChipSlot(voiceOffscreen: voiceOffscreen, onFollowVoice: followVoice)
                            .padding(.bottom, Theme.Space.sm)
                    }
                }
                .padding(.leading, inset)
            if isContentsVisible, let content, let navigation {
                MacContentsPanel(content: content, navigation: navigation, layout: layout)
            }
        }
    }

    /// Shown and loaded: the panel lists the loaded book's chapters.
    private var isContentsVisible: Bool {
        ui.isContentsShown && content != nil && navigation != nil
    }

    @ViewBuilder
    private var page: some View {
        if let document, let navigation, content != nil {
            MacReaderTitlePage(document: document, navigation: navigation,
                               playhead: max(playback.currentSentence, 0))
        } else if loadFailed {
            failureState
        }
        // While the cached text decodes the paper stays bare: a spinner
        // would keep turning under Reduce Motion (R20).
    }

    private var failureState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "doc.questionmark")
                .imageScale(.large)
                .font(Theme.font(.title))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
            Text("Couldn't open this document")
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
            Text("It may be damaged or a scanned document.")
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(Theme.Space.xxl)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: toggleContents) {
                Label(MacMenuCopy.Help.label(for: .toggleContents), systemImage: "sidebar.leading")
            }
            .help(MacCommand.toggleContents.help)
            .accessibilityIdentifier("reader.contents")
        }
        ToolbarItem(placement: .primaryAction) {
            appearanceButton
        }
    }

    private var appearanceButton: some View {
        @Bindable var ui = ui
        return Button {
            ui.isAppearanceShown.toggle()
        } label: {
            Label(AppearanceCopy.title, systemImage: "textformat.size")
        }
        .help(MacCommand.appearance.help)
        .accessibilityInputLabels([Text("Aa"), Text(AppearanceCopy.title), Text("Appearance")])
        .accessibilityIdentifier("reader.appearance")
        .popover(isPresented: $ui.isAppearanceShown, arrowEdge: .bottom) {
            MacAppearancePopover()
        }
    }

    #if DEBUG
    /// UI-test playhead probe, as on the iPhone: a 1×1 element whose
    /// IDENTIFIER carries the sentence index under a constant label. Only in
    /// DEBUG and only in UI-test launches; no value carries the index (R12e).
    @ViewBuilder
    private var sentenceProbe: some View {
        if UITestHooks.isUITestLaunch {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Playhead")
                .accessibilityIdentifier("reader.sentence.\(max(playback.currentSentence, 0))")
        }
    }
    #endif

    // MARK: - Loading

    private func load() async {
        guard content == nil, let document else { return }

        do {
            let loaded = try await store.content(for: document)
            content = loaded
            navigation = MacNavigationCache.navigation(for: loaded, kind: document.kind)

            // Reconciliation may have reset progress; load the live record so
            // the controller cues at the saved sentence.
            playback.load(document: self.document ?? document, content: loaded)
            store.noteOpened(id: document.id)

            // UI-test hook (no-op in Release): `-uitest-seek-text <substring>`
            // cues the playhead at the first sentence containing it.
            if let needle = UITestHooks.seekText,
               let match = loaded.sentences.first(where: { $0.text.contains(needle) }) {
                playback.seek(to: match.id, andPlay: false)
            }

            // R4: opening any book plays it; the controller declines for a
            // Finished book, a book already speaking, or a UI-test launch
            // without -uitest-allow-autoplay.
            playback.startAutoplay()
        } catch {
            loadFailed = true
        }
    }

    /// The store's current record (progress moves while reading); nil once
    /// the book is deleted.
    private var document: LibraryDocument? {
        store.documents.first(where: { $0.id == documentID })
    }

    // MARK: - Actions

    /// The toolbar button and the chapter line; ⌃⌘S is the menu's. Shown
    /// or hidden stays with the window, from book to book.
    private func toggleContents() {
        ui.isContentsShown.toggle()
    }

    private func followVoice() {
        followRequests &+= 1
    }
}
