import SwiftUI

/// The document is the screen: full-bleed reading column, player bar below.
/// Identity sits on top (the system back button, the title and Aa) and every
/// frequent control at the bottom (R6). The title no longer opens chapters;
/// the chapter line does. Opening cues the saved sentence and hands the book
/// to `startAutoplay()` (R4). Progress is saved by
/// `PlaybackController.onProgress` alone.
///
/// One message at a time (R11): the chapter line in the player bar shows the
/// single message, and the one chip slot above the bar shows the single
/// chip, where "Undo jump" (R15) outranks the end of the book's More
/// classics (R24), which outranks "Follow the voice" (R16). Nothing floats
/// over the text.
struct ReaderScreen: View {

    let document: LibraryDocument

    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    /// R24's More classics hands the reader's place to the Bookshelf.
    @EnvironmentObject private var router: LibraryRouter
    /// Carries the in-app Appearance override (and `-uitest-force-dark`);
    /// the nav bar is resolved and pinned from it (see `Theme.bgResolved`).
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(ReaderTextSize.prefKey) private var textSizeStep = ReaderTextSize.defaultStep

    @State private var content: DocContent?
    /// Chapter list + page/chapter labels, derived once when the document
    /// loads. Deriving inside a sheet's initializer would rerun a whole-book
    /// scan on every body evaluation — word-highlight cadence during playback.
    @State private var navigation: ReaderNavigation?
    @State private var loadFailed = false
    @State private var textUnderTopBar = false
    @State private var showAppearanceSheet = false
    /// Where the voice is while the column isn't following it (R16).
    @State private var voiceOffscreen: ReaderFollowDirection?
    /// Bumped by the Follow chip; part of the column's follow request.
    @State private var followChipTaps = 0
    /// The text view's bottom edge and the player bar's top edge, in the
    /// screen's own coordinate space. The text runs under the bar, and the
    /// bar paints its paper under the home indicator too, so calm follow
    /// measures its band above the bar's top edge, not above its height.
    @State private var textBottom: CGFloat?
    @State private var barTop: CGFloat?
    private static let space = "reader.screen"

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let content, let navigation {
                ReaderTextView(
                    content: content,
                    isChapterBook: document.kind == .text,
                    navigation: navigation,
                    fontSize: ReaderTextSize.points(forStep: textSizeStep),
                    activeSentence: playback.currentSentence,
                    // The word-highlight pref is gated once, here at the source.
                    activeWord: model.wordHighlight ? playback.currentWord : -1,
                    // Following resumes on a user Play, every jump and Undo,
                    // and the Follow chip: never by itself.
                    followRequest: playback.userPlayAction &+ playback.jumpSerial &+ followChipTaps,
                    obscuredBottom: FollowBand.obscuredBottom(textMaxY: textBottom, chromeMinY: barTop),
                    colophon: colophon(for: content, navigation: navigation),
                    voiceOffscreen: $voiceOffscreen,
                    textUnderTopBar: $textUnderTopBar,
                    onTapSentence: tapSentence,
                    onMagicTap: togglePlayback)
                .ignoresSafeArea(edges: .bottom)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.space)).maxY
                } action: { maxY in
                    textBottom = maxY
                }
                .overlay(alignment: .top) { topEdgeRule }
                #if DEBUG
                .overlay(alignment: .topLeading) { ReaderFollowProbeOverlay() }
                #endif

                bottomLayer
            } else if loadFailed {
                failureState
            }
            // While the cached text decodes the paper stays bare: a system
            // spinner would keep turning under Reduce Motion (R20).
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let content, let navigation {
                PlayerBarView(document: liveDocument, content: content, navigation: navigation)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.space)).minY
                    } action: { minY in
                        barTop = minY
                    }
            }
        }
        // One space for the text's bottom and the bar's top: their gap is
        // the bar's height plus the home-indicator strip it paints over.
        .coordinateSpace(.named(Self.space))
        // R12b: a two-finger double-tap anywhere on the screen plays or pauses.
        .accessibilityAction(.magicTap) { togglePlayback() }
        #if DEBUG
        .overlay(alignment: .topLeading) { sentenceProbe }
        #endif
        .navigationBarTitleDisplayMode(.inline)
        // The system back button, chevron only (VoiceOver: "Back"), which
        // also brings back the edge swipe to the Library.
        .toolbarRole(.editor)
        // Paper, explicitly: the bar is the page's own color in both modes.
        // A static color resolved for THIS scheme (a dynamic one resolved in
        // the bar's light traits under an in-app Dark override: cream bar),
        // and the bar's content pinned to the same scheme so the title and
        // buttons never render light-mode on the dark paper. The opaque bar
        // also gives iOS 26 one clean top edge. Never a hard scroll edge
        // here: on a pushed screen it turns the bar's glass buttons light in
        // dark mode (see `ShelfScrollEdge`).
        .toolbarBackground(Theme.bgResolved(for: colorScheme), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAppearanceSheet) { AppearanceSheet() }
        .task {
            await load()
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Identity, not a control: chapters and search live in the chapter
        // line at the bottom. The bar is hosted apart from the screen, so
        // its items take magic tap themselves.
        ToolbarItem(placement: .principal) {
            Text(liveDocument.title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
                // The bar caps its text size and truncates a long title;
                // long-press shows it whole and large.
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("reader.title")
                .accessibilityAction(.magicTap) { togglePlayback() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showAppearanceSheet = true } label: {
                Text("Aa")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // The sheet's own title, so Aa and Settings share one name.
            .accessibilityLabel(AppearanceCopy.title)
            .accessibilityInputLabels([Text("Aa"), Text("Text and appearance"), Text("Appearance")])
            .accessibilityIdentifier("reader.appearance")
            .accessibilityAction(.magicTap) { togglePlayback() }
        }
    }

    #if DEBUG
    /// UI-test playhead probe: a 1×1 element whose IDENTIFIER carries the
    /// sentence index under a constant label (which keeps SwiftUI from
    /// dropping it). Only in DEBUG and only in UI-test launches; no value
    /// anywhere carries the index (R12e).
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

    /// Hairline under the top chrome once text has scrolled beneath it, so
    /// the clipped first line reads as framed by the bar instead of sliced
    /// mid-page (the bar and the page are the same paper color). Hidden at
    /// the very top of the book. A rule, not a fade: the theme allows no
    /// gradients.
    private var topEdgeRule: some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .frame(height: Theme.Stroke.hairlineWidth)
            .opacity(textUnderTopBar ? 1 : 0)
            .animation(.easeOut(duration: Theme.Motion.crossfade), value: textUnderTopBar)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The one chip slot, in a stack above the player bar. Empty space in
    /// the stack passes touches through to the text; only the chip takes
    /// taps.
    private var bottomLayer: some View {
        VStack(spacing: 0) {
            Spacer()
            chipSlot
        }
        .padding(.bottom, Theme.Space.sm)
        .animation(.easeOut(duration: Theme.Motion.message), value: chip?.slotKey)
    }

    /// Keyed by slot, so the Follow arrow flipping direction doesn't
    /// re-animate; the shared transition is a plain fade under Reduce Motion.
    @ViewBuilder
    private var chipSlot: some View {
        if let chip {
            ReaderChipView(chip: chip) { handle(chip) }
                .id(chip.slotKey)
                .messageTransition()
        }
    }

    private var chip: ReaderChip? {
        ReaderChip.resolve(canUndoJump: playback.undoableJump != nil, voiceOffscreen: voiceOffscreen,
                           isAtEnd: playback.isAtEnd)
    }

    /// R24: the colophon, only while the listener is at the end of THIS
    /// book. Its length uses the record's word count (the card's figure)
    /// and the app-wide speed. Cheap enough for every body pass: the word
    /// total is a prefix-sum lookup.
    private func colophon(for content: DocContent, navigation: ReaderNavigation) -> ReaderColophon? {
        guard playback.isAtEnd, playback.document?.id == document.id else { return nil }
        let words = navigation.wordsRemaining(from: 0, through: max(content.sentences.count - 1, 0))
        return ReaderColophon.forBook(liveDocument, textWords: words, rate: playback.rate)
    }

    private func handle(_ chip: ReaderChip) {
        switch chip {
        case .undoJump: playback.undoJump()
        case .moreClassics: router.showBookshelfFromReader()   // navigation, no haptic
        case .followVoice: followChipTaps &+= 1
        }
    }

    private var failureState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "doc.questionmark")
                .font(.title)
                .foregroundStyle(Theme.textFaint)
            Text("Couldn't open this document")
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
            Text("It may be damaged or a scanned document.")
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(Theme.Space.xxl)
    }

    // MARK: - Loading

    private func load() async {
        guard content == nil else { return }

        do {
            let loaded = try await store.content(for: document)
            content = loaded
            navigation = ReaderNavigation(content: loaded, kind: document.kind)

            // Reconciliation may have reset progress; load the live record so
            // the controller cues at the saved sentence.
            playback.load(document: liveDocument, content: loaded)
            store.noteOpened(id: document.id)

            // UI-test hook (no-op in Release): `-uitest-seek-text <substring>`
            // cues the playhead at the first sentence containing the
            // substring, so the screenshot rig can land on a known passage
            // deterministically.
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

    /// The store's current record for this document (progress moves while reading).
    private var liveDocument: LibraryDocument {
        store.documents.first(where: { $0.id == document.id }) ?? document
    }

    // MARK: - Actions

    private func tapSentence(_ id: Int) {
        Self.playFromSentence(id, on: playback)
    }

    /// R15: a tap plays from the tapped sentence in any state. The haptic
    /// answers only a tap that starts playback, as the controller counts
    /// it: a voice audition reads as active, but it is a sample over the
    /// listener's pause (R8), so a tap over it starts the book.
    static func playFromSentence(_ id: Int, on playback: PlaybackController) {
        let plays = playback.userPlayAction
        playback.jump(to: id, origin: .sentence)
        if playback.userPlayAction != plays { TransportHaptics.emit(.play) }
    }

    /// Magic tap (R12b), from anywhere on the screen.
    private func togglePlayback() {
        TransportHaptics.emitToggle(isActive: playback.isActive)
        playback.togglePlayPause()
    }
}

#if DEBUG
/// UI-test probes for calm follow (R16): the programmatic scroll count in an
/// identifier, and an element framed on the active sentence. Overlaid on the
/// text view, whose bounds the probe's rect is measured in.
private struct ReaderFollowProbeOverlay: View {
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
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}
#endif
