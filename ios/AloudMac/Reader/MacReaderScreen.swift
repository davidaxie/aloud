import SwiftUI

/// One document in the window (M6, M9, contracts §6). Identity sits in the
/// toolbar: Contents, the system back button (⌘[), the book's title with its
/// author as the subtitle, and Aa. Every frequent control sits in the bottom
/// bar. The page is the TextKit 2 book page (`ReaderColumnView`, M14, M15):
/// the voice's sentence highlighted, calm follow, click to play, and the
/// colophon at the end (R24). The Contents panel (M16) sits on its leading
/// edge, docked beside it in a window 780 pt wide or more and floating over
/// it below; the page re-lays out around the voice as it comes and goes,
/// and closing it hands the keyboard back to the text.
///
/// Opening cues the saved sentence and hands the book to `startAutoplay()`,
/// as the iPhone's reader does (R4): one click from the Library is a voice.
/// Progress is saved by `PlaybackController.onProgress` alone.
///
/// One message at a time (R11): the chapter line in the bar shows the one
/// message, and the one chip slot above the bar shows the one chip. Leaving
/// the reader keeps the book playing; the window's close does too. The bar
/// and the chip follow the reader's text size in three chrome bands (M18).
struct MacReaderScreen: View {
    let documentID: UUID

    init(documentID: UUID) {
        self.documentID = documentID
    }

    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @Environment(MacUIState.self) private var ui

    @AppStorage(ReaderTextSize.prefKey) private var textSizeStep = ReaderTextSize.defaultStep

    @State private var content: DocContent?
    /// Derived once when the document loads, and shared with the menus'
    /// chapter steps through `MacNavigationCache`: a build is a pass over
    /// the book.
    @State private var navigation: ReaderNavigation?
    @State private var loadFailed = false
    /// Where the voice is while the page isn't following it (R16): the
    /// Follow chip's arrow, and ⌘J's enabling.
    @State private var voiceOffscreen: ReaderFollowDirection?
    /// Bumped by Follow the voice (the chip, ⌘J); part of the page's
    /// follow request.
    @State private var followVoiceCount = 0
    /// How far the chip slot reaches up over the page's foot; calm follow
    /// measures its band above it (`chipReach(previous:slotHeight:)`).
    @State private var chipReach: CGFloat = 0
    /// Text has scrolled up under the toolbar: its hairline shows.
    @State private var textUnderTopBar = false
    /// Bumped as Contents closes: the keyboard goes back to the text.
    @State private var pageFocusRequests = 0

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
        .environment(\.chromeScale, chromeScale)
        // A new band resizes the slot's chip: its reach starts over from
        // that band's chip, so a smaller band gives the page its foot back.
        .onChange(of: chromeScale) { _, scale in
            chipReach = Self.chipReach(previous: chipReach, bandChangedTo: scale)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { sentenceProbe }
        #endif
        .navigationTitle(document?.title ?? "")
        .navigationSubtitle(document?.author ?? "")
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar { toolbarContent }
        // ⌘J, while the voice is off the page.
        .focusedSceneValue(\.macFollowVoice, Self.followVoiceCommand(voiceOffscreen: voiceOffscreen,
                                                                      action: followVoice))
        // Esc closing Contents, or a jump closing its card: the keyboard
        // goes back to the text, never nowhere (M11).
        .onChange(of: ui.isContentsShown) { wasShown, isShown in
            if Self.returnsFocusToPage(contentsWasShown: wasShown, isShown: isShown) {
                pageFocusRequests &+= 1
            }
        }
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
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                chipReach = Self.chipReach(previous: chipReach, slotHeight: height)
                            }
                            .padding(.bottom, Theme.Space.sm)
                    }
                }
                .padding(.leading, inset)
            if isContentsVisible, let content, let navigation {
                MacContentsPanel(content: content, navigation: navigation, layout: layout)
            }
        }
        // Along the toolbar's edge, the window's width.
        .overlay(alignment: .top) { topEdgeRule }
    }

    /// The chrome's band for the reader's text size: ⌘+ and ⌘− (and the Aa
    /// stepper) move the bar with the page.
    private var chromeScale: ChromeScale {
        ChromeScale(readerStep: textSizeStep)
    }

    /// Shown and loaded: the panel lists the loaded book's chapters.
    private var isContentsVisible: Bool {
        ui.isContentsShown && content != nil && navigation != nil
    }

    @ViewBuilder
    private var page: some View {
        if let document, let content, let navigation {
            ReaderColumnView(
                content: content,
                isChapterBook: document.kind == .text,
                navigation: navigation,
                fontSize: ReaderTextSize.points(forStep: textSizeStep),
                activeSentence: playback.currentSentence,
                // The word-highlight pref is gated once, here at the source.
                activeWord: model.wordHighlight ? playback.currentWord : -1,
                // Following tracks the spoken word whatever the pref, so a
                // sentence taller than the band never ends below the page.
                followWord: playback.currentWord,
                // Following resumes on a user Play, every jump and Undo, and
                // Follow the voice: never by itself.
                followRequest: ReaderColumnView.followRequest(for: playback, followVoiceCount: followVoiceCount),
                obscuredBottom: chipReach,
                colophon: Self.colophon(for: document, content: content, navigation: navigation,
                                        isAtEnd: playback.isAtEnd, playingID: playback.document?.id,
                                        rate: playback.rate),
                focusRequest: pageFocusRequests,
                voiceOffscreen: $voiceOffscreen,
                onPlaySentence: { ReaderColumnView.playFromSentence($0, on: playback) },
                onTextUnderTopBar: { textUnderTopBar = $0 },
                transportStamp: { ReaderColumnView.transportStamp(of: playback) })
            #if DEBUG
            .overlay(alignment: .topLeading) { MacReaderFollowProbeOverlay() }
            #endif
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

    /// Hairline under the toolbar once text has scrolled beneath it, so the
    /// clipped first line reads as framed by the bar (the toolbar and the
    /// page are the same paper). Hidden at the top of the book; a rule, not
    /// a fade: the theme allows no gradients.
    private var topEdgeRule: some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .frame(height: Theme.Stroke.hairlineWidth)
            .opacity(textUnderTopBar ? 1 : 0)
            .animation(.easeOut(duration: Theme.Motion.crossfade), value: textUnderTopBar)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            // Replaced while the text loaded: never load this book over the
            // one now showing.
            guard !Task.isCancelled else { return }
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

            // R4: opening a book plays it; the controller declines for a
            // Finished book, a book already speaking, or a UI-test launch
            // without -uitest-allow-autoplay. A reader reopened at launch, or
            // rebuilt when the window comes back, waits at its place.
            if router.takeAutoplayRequest(for: documentID) { playback.startAutoplay() }
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
        followVoiceCount &+= 1
    }
}

// MARK: - Wiring (pure, for the tests)

extension MacReaderScreen {

    /// ⌘J's action while the voice is off the page; nil (the menu item
    /// disabled) while it is in view or followed.
    static func followVoiceCommand(voiceOffscreen: ReaderFollowDirection?,
                                   action: @escaping () -> Void) -> (() -> Void)? {
        voiceOffscreen == nil ? nil : action
    }

    /// Contents went from shown to hidden: Esc, a card's jump, the toolbar
    /// button or ⌃⌘S. The keyboard goes back to the page's text.
    static func returnsFocusToPage(contentsWasShown wasShown: Bool, isShown: Bool) -> Bool {
        wasShown && !isShown
    }

    /// How far the chip slot reaches over the page's foot: the tallest chip
    /// it has shown (`slotHeight`, 0 while empty) and the slot's padding,
    /// kept while the slot is empty, so a chip coming and going never moves
    /// the band, and the page with it. The player bar sits below the page
    /// and covers none of it.
    static func chipReach(previous: CGFloat, slotHeight: CGFloat) -> CGFloat {
        guard slotHeight > 0 else { return previous }
        return max(previous, (slotHeight + Theme.Space.sm).rounded(.up))
    }

    /// The reach once the chrome band changes (M18): a chip already seen is
    /// measured afresh from the new band's chip, so a smaller band gives
    /// the page back its foot (a showing chip is measured again as it
    /// re-lays out). With none seen yet, nothing is covered still.
    static func chipReach(previous: CGFloat, bandChangedTo scale: ChromeScale) -> CGFloat {
        guard previous > 0 else { return previous }
        return chipReach(previous: 0, slotHeight: MacPlayerBarLayout.chipHeight(for: scale))
    }

    /// R24: the colophon, only while the listener is at the end of THIS
    /// book (`playingID`). Its length uses the record's word count (the
    /// card's figure) and the app-wide speed, as on the iPhone; the word
    /// total is a prefix-sum lookup, cheap on every body pass.
    static func colophon(for document: LibraryDocument, content: DocContent, navigation: ReaderNavigation,
                         isAtEnd: Bool, playingID: UUID?, rate: Double) -> ReaderColophon? {
        guard isAtEnd, playingID == document.id else { return nil }
        let words = navigation.wordsRemaining(from: 0, through: max(content.sentences.count - 1, 0))
        return ReaderColophon.forBook(document, textWords: words, rate: rate)
    }
}

#if DEBUG
/// UI-test probes for calm follow (R16), as on the iPhone: the
/// programmatic scroll count in an identifier, the active sentence's page
/// line, and an element framed on the active sentence. Overlaid on the
/// page, whose bounds the probe's rect is measured in.
private struct MacReaderFollowProbeOverlay: View {
    @ObservedObject private var probe = ReaderFollowProbe.shared

    var body: some View {
        if UITestHooks.isUITestLaunch {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Follow scrolls")
                    .accessibilityIdentifier("reader.followScrolls.\(probe.scrolls)")
                if let line = probe.activeLine {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Active line")
                        .accessibilityIdentifier("reader.activeLine.\(line)")
                }
                if let rect = probe.activeRect {
                    Color.clear
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .accessibilityElement()
                        .accessibilityLabel("Active sentence")
                        .accessibilityIdentifier("reader.activeSentence")
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}
#endif
