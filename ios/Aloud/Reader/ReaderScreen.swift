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
    /// The failure state's Delete Book… confirmation, and a delete the
    /// library couldn't record (R2-11).
    @State private var confirmingDelete = false
    @State private var deleteFailure: DeleteFailure?
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
    /// The Voice & speed sheet's height while it rests open, and the text
    /// view's bottom edge in the window's space. The sheet stands on the
    /// window's bottom edge, where the text ends too, so it covers the page
    /// from its height above that edge; that strip counts as covered, so
    /// following keeps the spoken sentence above it (P034). Nil once the
    /// sheet closes, and the band is the bar's again.
    @State private var listeningSheetHeight: CGFloat?
    @State private var textBottomInWindow: CGFloat?
    /// The resting sheet's top edge in the window's space.
    private var listeningSheetTop: CGFloat? {
        guard let listeningSheetHeight, let textBottomInWindow else { return nil }
        return textBottomInWindow - listeningSheetHeight
    }
    /// How far the chip slot reaches above the bar: the tallest chip seen
    /// and its padding, a running maximum (`FollowBand.chipReach`, P049).
    @State private var chipReach: CGFloat = 0
    /// The open's signpost (R1-16), from the load starting to the column's
    /// first string; ended as given up if the reader goes first.
    @State private var openSignpost: BudgetSignposts.Interval?
    /// The page's width, measured before the text loads, so the column's
    /// first build is set for its real measure (P043).
    @State private var pageWidth: CGFloat?
    private static let space = "reader.screen"

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let content, let navigation {
                page(content: content, navigation: navigation)
                    // R12b: a two-finger double-tap anywhere on the page plays
                    // or pauses. On the page only: the failure state has
                    // nothing to play, and an ancestor action there put its
                    // hidden icon back in VoiceOver's order (R2-10).
                    .accessibilityAction(.magicTap) { togglePlayback() }
            } else if loadFailed {
                failureState
            }
            // While the cached text decodes the paper stays bare: a system
            // spinner would keep turning under Reduce Motion (R20).
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .local).width
        } action: { width in
            pageWidth = width
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let content, let navigation {
                PlayerBarView(document: liveDocument, content: content, navigation: navigation,
                              listeningSheetHeight: $listeningSheetHeight)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.space)).minY
                    } action: { minY in
                        barTop = minY
                    }
                    // R12b: the bar plays and pauses on a magic tap too.
                    .accessibilityAction(.magicTap) { togglePlayback() }
                    // The Aa sheet covers the bar but leaves the page live
                    // (P037), so VoiceOver could walk into the bar behind it,
                    // where the Voice chip or the chapter line would ask for
                    // a second sheet iOS refuses. Hidden until the sheet goes.
                    .accessibilityHidden(showAppearanceSheet)
            }
        }
        // One space for the text's bottom and the bar's top: their gap is
        // the bar's height plus the home-indicator strip it paints over.
        .coordinateSpace(.named(Self.space))
        #if DEBUG
        .overlay(alignment: .topLeading) { sentenceProbe }
        #endif
        .navigationBarTitleDisplayMode(.inline)
        // The back button is the plain system button, as on Classics and
        // Settings (with the edge swipe to the Library), and the title sits
        // centred between it and Aa like every other screen's.
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
        // A voice added or removed in Settings drops the System pick; rank
        // it again off the main thread before the Voice & speed sheet asks.
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechEngine.installedVoicesDidChange)
            .receive(on: RunLoop.main)) { _ in
            AVSpeechEngine.warmSystemVoice(reading: playback.systemVoiceLanguage)
        }
        .task {
            await load()
        }
        .onDisappear { BudgetSignposts.live.end(&openSignpost, gaveUp: true) }
    }

    /// The page: the reading column and the chip slot over it.
    private func page(content: DocContent, navigation: ReaderNavigation) -> some View {
        ZStack {
            ReaderTextView(
                content: content,
                isChapterBook: document.kind == .text,
                navigation: navigation,
                fontSize: ReaderTextSize.points(forStep: textSizeStep),
                activeSentence: playback.currentSentence,
                // The word-highlight pref is gated once, here at the source.
                activeWord: model.wordHighlight ? playback.currentWord : -1,
                // Following tracks the spoken word whatever the pref, so
                // a sentence taller than the band never ends under the bar.
                followWord: playback.currentWord,
                // Following resumes on a user Play, every jump and Undo,
                // and the Follow chip: never by itself.
                followRequest: playback.userPlayAction &+ playback.jumpSerial &+ followChipTaps,
                // The bar's reach, the chip's while one floats over the
                // text, and a resting sheet's, so the spoken line is
                // never under any of them.
                // A chip counts from the pass it resolves in, at its
                // minimum until it is measured (R2-09).
                obscuredBottom: FollowBand.obscuredBottom(textMaxY: textBottom, chromeMinY: barTop,
                                                          chipReach: FollowBand.chipReach(previous: chipReach,
                                                                                          showsChip: chip != nil),
                                                          showsChip: chip != nil,
                                                          windowTextMaxY: textBottomInWindow,
                                                          sheetMinY: listeningSheetTop),
                // R3-01: the colophon lands only on a band whose edges are
                // measured, the bar with a real height.
                bandMeasured: FollowBand.isMeasured(textMaxY: textBottom, chromeMinY: barTop),
                colophon: colophon(for: content, navigation: navigation),
                voiceOffscreen: $voiceOffscreen,
                textUnderTopBar: $textUnderTopBar,
                onTapSentence: tapSentence,
                onMagicTap: togglePlayback,
                bookTitle: liveDocument.title,
                bookAuthor: liveDocument.author,
                pageWidth: pageWidth,
                onPinchTextSize: pinchTextSize,
                // R1-14: with Aa up, a tap on the page closes the sheet.
                onDismissTap: showAppearanceSheet ? { showAppearanceSheet = false } : nil,
                onColumnShown: { BudgetSignposts.live.end(&openSignpost) })
            .ignoresSafeArea(edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.space)).maxY
            } action: { maxY in
                textBottom = maxY
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY
            } action: { maxY in
                textBottomInWindow = maxY
            }
            .overlay(alignment: .top) { topEdgeRule }
            #if DEBUG
            .overlay(alignment: .topLeading) { ReaderFollowProbeOverlay() }
            #endif

            bottomLayer
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Identity, not a control: chapters and search live in the chapter
        // line at the bottom. The bar is hosted apart from the screen, so
        // its items take magic tap themselves.
        ToolbarItem(placement: .principal) {
            titleLines
                // One header naming the book and its author (P046).
                .accessibilityElement(children: .combine)
                .accessibilityLabel(ReaderTitleCopy.label(title: liveDocument.title, author: shownAuthor))
                .accessibilityAddTraits(.isHeader)
                // The bar caps its text size and truncates a long title;
                // long-press shows both lines whole and large.
                .accessibilityShowsLargeContentViewer {
                    Text([liveDocument.title, shownAuthor].compactMap { $0 }.joined(separator: "\n"))
                }
                .accessibilityIdentifier("reader.title")
                .accessibilityAction(.magicTap) { togglePlayback() }
        }
        .withoutGlassCapsule()
        // A page with no text has nothing to size (R2-11).
        if !loadFailed {
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
                // The bar caps its text size, and iOS hosts this custom label
                // apart from the screen: long-press shows the glyph large.
                .accessibilityShowsLargeContentViewer { Text("Aa") }
                .accessibilityIdentifier("reader.appearance")
                .accessibilityAction(.magicTap) { togglePlayback() }
            }
        }
    }

    /// The author, when the record has one.
    private var shownAuthor: String? {
        guard let author = liveDocument.author, !author.isEmpty else { return nil }
        return author
    }

    /// The title over the author, as the Mac's window names both, at every
    /// size: capped at xxLarge, where the bar caps its text anyway and both
    /// lines fit.
    private var titleLines: some View {
        VStack(spacing: 0) {
            titleText
            if let author = shownAuthor {
                Text(author)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var titleText: some View {
        Text(liveDocument.title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
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
                // The tallest chip seen counts toward the band (P049).
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .local).height
                } action: { height in
                    chipReach = FollowBand.chipReach(previous: chipReach, slotHeight: height)
                }
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

    private var failureGlyph: some View {
        let glyph = Image(systemName: "doc.questionmark")
            .font(Theme.font(.title))
            .imageScale(.large)
        return glyph
            .hidden()
            .overlay { Theme.textFaint.mask { glyph } }
    }

    private var failureState: some View {
        VStack(spacing: Theme.Space.sm) {
            // No symbol name reaches VoiceOver (R2-10); never combined with
            // the title. A hidden Image still reached the accessibility
            // tree, so the glyph is its colour masked by the symbol, over
            // an invisible copy that sizes it: no image element exists.
            failureGlyph
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(true)
            Text(ReaderFailureCopy.title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text(ReaderFailureCopy.detail)
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
            // A way back that isn't only the bar's chevron (P050).
            Button { router.popToRoot() } label: {
                Text(ReaderFailureCopy.backToLibrary)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.accentStrong)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.backToLibrary")
            // A book that fails to open fails on every open: the way to let
            // it go, confirmed as on the shelf (R2-11).
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text(ReaderFailureCopy.deleteBook)
                    .font(Theme.font(.callout))
                    .foregroundStyle(Theme.accentStrong)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader.deleteBook")
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xxl)
        .confirmationDialog(ReaderFailureCopy.deleteTitle(liveDocument.title),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(DocumentAction.delete.title, role: .destructive) { deleteFailedBook() }
            Button(ReaderFailureCopy.cancel, role: .cancel) {}
        } message: {
            Text(DocumentAction.deleteMessage(for: liveDocument))
        }
        .alert(deleteFailure?.title ?? "", isPresented: Binding(get: { deleteFailure != nil },
                                                                 set: { if !$0 { deleteFailure = nil } }),
               presenting: deleteFailure) { _ in
            Button(ReaderFailureCopy.ok, role: .cancel) {}
        } message: { failure in
            Text(failure.nextStep)
        }
    }

    /// The failure state's Delete: the shelf's own entry point. The audio
    /// never loaded this book (the load failed first), so nothing stops.
    /// A delete the library can't record keeps the book and says why.
    private func deleteFailedBook() {
        if let failure = model.deleteDocument(liveDocument) {
            deleteFailure = failure
            return
        }
        router.popToRoot()
    }

    // MARK: - Loading

    private func load() async {
        guard content == nil else { return }
        BudgetSignposts.live.end(&openSignpost, gaveUp: true)
        openSignpost = BudgetSignposts.live.begin(.readerOpen)

        do {
            // UI-test hook (no-op in Release): `-uitest-fail-reader-load`
            // fails the load, for the failure state's way back.
            if UITestHooks.failReaderLoad { throw CocoaError(.fileReadCorruptFile) }
            let loaded = try await store.content(for: document)
            // Popped or replaced while the text loaded: never load this book
            // over the one now showing, and never start its audio.
            guard !Task.isCancelled else {
                BudgetSignposts.live.end(&openSignpost, gaveUp: true)
                return
            }
            content = loaded

            // Audio first (R1-16): the voice starts while the page is set.
            // Reconciliation may have reset progress; load the live record so
            // the controller cues at the saved sentence.
            playback.load(document: liveDocument, content: loaded)

            // UI-test hook (no-op in Release): `-uitest-seek-text <substring>`
            // cues the playhead at the first sentence containing the
            // substring, so the screenshot rig can land on a known passage
            // deterministically.
            if let needle = UITestHooks.seekText,
               let match = loaded.sentences.first(where: { $0.text.contains(needle) }) {
                playback.seek(to: match.id, andPlay: false)
            }

            // R4: opening a book plays it; the controller declines for a
            // Finished book, a book already speaking, or a UI-test launch
            // without -uitest-allow-autoplay. A reader reopened at launch
            // waits at its place for Play.
            if router.takeAutoplayRequest(for: document.id) { playback.startAutoplay() }

            // The System row names its voice on the Voice & speed sheet's
            // first frame (P035): rank the pick for this book's language
            // now, off the main thread, so that frame finds it cached.
            AVSpeechEngine.warmSystemVoice(reading: playback.systemVoiceLanguage)

            // Chapters and labels are pure: derived off the main thread, and
            // shown (with the column) only for the book still loaded here.
            let input = OffMain((loaded, document.kind))
            let derived = await Task.detached(priority: .userInitiated) { () -> OffMain<ReaderNavigation> in
                OffMain(ReaderNavigation(content: input.value.0, kind: input.value.1))
            }.value
            guard !Task.isCancelled, content?.contentHash == loaded.contentHash else {
                BudgetSignposts.live.end(&openSignpost, gaveUp: true)
                return
            }
            navigation = derived.value
            store.noteOpened(id: document.id)
        } catch {
            BudgetSignposts.live.end(&openSignpost, gaveUp: true)
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

    /// A pinch on the page ended (P044, R1-15): its net step, stored like
    /// the Aa sheet's stepper and the new size spoken, once per pinch. The
    /// column has ticked each step and reflowed once itself.
    private func pinchTextSize(_ delta: Int) {
        let next = ReaderPinch.clamped(textSizeStep, by: delta)
        guard next != textSizeStep else { return }
        textSizeStep = next
        A11yAnnounce.post(ReaderMenuCopy.textSize(points: ReaderTextSize.points(forStep: next)))
    }

    /// Magic tap (R12b), from anywhere on the screen.
    private func togglePlayback() {
        TransportHaptics.emitToggle(isActive: playback.isActive)
        playback.togglePlayPause()
    }
}

private extension ToolbarContent {
    /// Centred, iOS 26 would set the title in a glass capsule, like a
    /// button (as `PaperTitleItem` opts out); earlier systems draw none.
    @ToolbarContentBuilder
    func withoutGlassCapsule() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
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
                // R3-01: the colophon's landing inputs, for the UI test's
                // failure messages.
                if let aim = probe.colophonAim {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityLabel("Colophon aim")
                        .accessibilityValue(aim)
                        .accessibilityIdentifier("reader.colophonAim")
                }
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
