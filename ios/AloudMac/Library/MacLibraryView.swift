import AppKit
import SwiftUI

/// The Library, the window's root (M6, mac-ux §3.1-3.3). With no books: the
/// featured classic in the Continue card's shape, the links "More classics"
/// and "Add a file", and the privacy line once. With books: the shared
/// Continue card over an adaptive grid of 2:3 covers (`MacGridMetrics`).
/// Every card opens through the router, and the reader starts it speaking
/// (R4); the Continue card's circle plays and pauses in place (R18). The
/// toolbar's "+" appears once a book exists. ⌘V adds what was copied.
///
/// Like the iPhone's shelf, the screen never observes the PlaybackController,
/// which publishes every sentence: only the Continue card does.
struct MacLibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter

    /// Hero and grid, split once per store or loaded-book publish while
    /// the Library shows (`MacShelfFeed`).
    @State private var shelfFeed = MacShelfFeed()
    /// The book the controller holds: always the hero (R18).
    @State private var loadedID: UUID?
    // Whether Rename or Delete is up lives on the router, so Open With can
    // close it; only what they act on stays here.
    @State private var renameTarget: LibraryDocument?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryDocument?
    /// The grid card with keyboard focus, which the arrows move.
    @FocusState private var focusedCard: UUID?
    /// The shelf's scroll view width, scroller excluded; nil until measured.
    @State private var shelfWidth: CGFloat?
    /// Whose Paste the window's key tail serves: this screen's, until it goes.
    @State private var pasteOwner = UUID()

    private var continuePlayback: ContinuePlayback { model.continuePlayback }

    /// The Continue card's widest (mac-ux §3.3).
    private static let continueMaxWidth: CGFloat = 560

    var body: some View {
        Group {
            if store.documents.isEmpty {
                MacEmptyLibrary()
            } else {
                shelfView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .navigationTitle("Library")
        .toolbarBackground(Theme.bg, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // Only once there is a book: the empty Library's links are the
            // way in until then (R4). Not under the import overlay.
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.documents.isEmpty, !importer.isImporting {
                    MacAddMenu()
                }
            }
        }
        // Edit ▸ Paste (⌘V), empty or not (M8): copied files are added as
        // a drop's are, and copied text becomes a book titled from its
        // first line. Only here: Classics and the reader paste nothing.
        // SwiftUI asks its paste command only while a Library view has
        // keyboard focus; with none (Full Keyboard Access off, a mouse),
        // the window's key tail takes Paste and hands it here. AppKit sends
        // one Paste to one responder, the first in the chain that takes it,
        // so a paste is one book either way.
        .onPasteCommand(of: MacFileIntake.pasteTypes) { providers in
            Task { await MacFileIntake.shared.admitPaste(providers) }
        }
        .onAppear { offerPaste(router.path.isEmpty) }
        .onChange(of: router.path.isEmpty) { _, atRoot in
            offerPaste(atRoot)
            // Back from the reader or Classics: the saves made meanwhile, once.
            if atRoot {
                feedShelf { $0.libraryShown(store.documents, loadedID: loadedID, stop: model.playback.stopped) }
            }
        }
        .onDisappear { offerPaste(false) }
        .onReceive(store.$documents) { documents in
            let shows = router.path.isEmpty
            feedShelf { $0.publish(documents, loadedID: loadedID, stop: model.playback.stopped, libraryShows: shows) }
        }
        .onReceive(model.playback.$document) { document in
            guard document?.id != loadedID else { return }
            let id = document?.id
            loadedID = id
            let shows = router.path.isEmpty
            feedShelf { $0.publish(store.documents, loadedID: id, stop: model.playback.stopped, libraryShows: shows) }
        }
        .alert("Rename", isPresented: presented(.rename)) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let target = renameTarget { store.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleteTarget?.title ?? "")\u{201D}?",
            isPresented: presented(.deleteConfirmation),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { model.deleteDocument(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the document and its listening progress.")
        }
    }

    /// Offers Paste to the window's key tail (`MacPasteTarget`) while the
    /// Library shows, or withdraws it. The root stays in the stack under
    /// Classics and the reader, which paste nothing, so it goes with them.
    private func offerPaste(_ shows: Bool) {
        if shows {
            MacPasteTarget.shared.offer(by: pasteOwner) { MacFileIntake.shared.admitPasteboard($0) }
        } else {
            MacPasteTarget.shared.withdraw(by: pasteOwner)
        }
    }

    /// The shelf as the feed has it.
    private var shelf: ShelfLayout { shelfFeed.layout }

    /// `change` on a copy of the feed, written back only when it changed:
    /// a publish under the reader writes no state at all.
    private func feedShelf(_ change: (inout MacShelfFeed) -> Bool) {
        var feed = shelfFeed
        if change(&feed) { shelfFeed = feed }
    }

    /// One root modal's flag, read from and written to the router.
    private func presented(_ presentation: LibraryRouter.RootPresentation) -> Binding<Bool> {
        Binding(get: { router.rootPresentation == presentation },
                set: { shown in
                    if shown {
                        router.rootPresentation = presentation
                    } else {
                        router.dismissRootPresentation(presentation)
                    }
                })
    }

    // MARK: Shelf

    private var shelfView: some View {
        GeometryReader { proxy in
            // The window's width until the scroll view reports its own,
            // which a legacy scroller (a mouse attached) makes narrower.
            let width = shelfWidth ?? proxy.size.width
            let metrics = MacGridMetrics(windowWidth: width)
            MacEdgeScrollView {
                VStack(spacing: 0) {
                    // Fully flexible, so it takes the width the scroll view
                    // offers, however wide the grid below it comes out.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
                            if measured > 0, measured != shelfWidth { shelfWidth = measured }
                        }
                        .accessibilityHidden(true)
                    shelfContent(metrics, gutter: MacGridMetrics.gutter(forWindowWidth: width))
                }
            }
        }
    }

    private func shelfContent(_ metrics: MacGridMetrics, gutter: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            if let hero = shelf.hero {
                MacContinueHero(document: hero,
                                rate: model.globalRate,
                                playback: model.playback,
                                continuePlayback: continuePlayback,
                                onOpen: { open(hero) },
                                onTogglePlayback: { toggleContinue(hero) }) {
                    MacDocumentMenu(document: hero, onOpen: { open(hero) },
                                    perform: { perform($0, on: hero) })
                }
                .frame(maxWidth: Self.continueMaxWidth, alignment: .leading)
                // The keyboard's as a grid card is (mac-ux §3.2): ↑ from the
                // grid's first row reaches it, ↓ goes back, Return opens it
                // and Delete Book… (⌘⌫) acts on its book.
                .focused($focusedCard, equals: hero.id)
                .onKeyPress(.return) {
                    open(hero)
                    return .handled
                }
                .onMoveCommand { direction in
                    moveFocus(direction, in: metrics)
                }
                .focusedValue(\.macDeleteBook) { perform(.delete, on: hero) }
            }
            grid(metrics)
                // The cells carry the plates: pull them out by a
                // plate so the covers line up with the card above.
                .padding(.horizontal, -MacGridMetrics.plateOutset)
        }
        .padding(.horizontal, gutter)
        .padding(.top, Theme.Space.lg)
        .padding(.bottom, Theme.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ metrics: MacGridMetrics) -> some View {
        let cell = GridItem(.fixed(metrics.cellWidth), spacing: MacGridMetrics.columnSpacing, alignment: .top)
        return LazyVGrid(columns: Array(repeating: cell, count: metrics.columns),
                         alignment: .leading, spacing: MacGridMetrics.rowSpacing) {
            ForEach(shelf.grid) { document in
                MacLibraryCard(document: document,
                               rate: model.globalRate,
                               coverWidth: metrics.coverWidth,
                               onOpen: { open(document) },
                               perform: { perform($0, on: document) })
                    .focused($focusedCard, equals: document.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The arrows walk the grid by its own columns (mac-ux §3.2).
        .onMoveCommand { direction in
            moveFocus(direction, in: metrics)
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, in metrics: MacGridMetrics) {
        let move: MacGridMetrics.Move
        switch direction {
        case .left: move = .left
        case .right: move = .right
        case .up: move = .up
        case .down: move = .down
        @unknown default: return
        }
        guard let next = Self.focusTarget(from: focusedCard, moving: move, hero: shelf.hero?.id,
                                          grid: shelf.grid.map(\.id), metrics: metrics) else { return }
        focusedCard = next
    }

    /// Where an arrow takes keyboard focus on the shelf: through the grid
    /// by its own columns, ↑ from its first row to the Continue card, and
    /// ↓ from the card to the grid's first card. nil: focus stays.
    static func focusTarget(from focused: UUID?, moving move: MacGridMetrics.Move, hero: UUID?,
                            grid: [UUID], metrics: MacGridMetrics) -> UUID? {
        guard let focused else { return nil }
        if focused == hero { return move == .down ? grid.first : nil }
        guard let index = grid.firstIndex(of: focused) else { return nil }
        if let next = metrics.neighbor(of: index, moving: move, count: grid.count) { return grid[next] }
        return move == .up ? hero : nil
    }

    // MARK: Playback

    /// Opens `document` in the reader. A Continue circle load of another
    /// book stops first, so it can't take the controller from the page on
    /// screen (`ContinuePlayback.readerOpens`).
    private func open(_ document: LibraryDocument) {
        continuePlayback.readerOpens(document.id)
        router.open(document)
    }

    /// Plays or pauses `document` without opening it. A book the controller
    /// doesn't hold yet is loaded first; if it can't be, the reader opens
    /// and says why.
    private func toggleContinue(_ document: LibraryDocument) {
        let store = store
        let router = router
        continuePlayback.toggle(
            document, playback: model.playback,
            loader: { try await store.liveContent(for: document) },
            onLoaded: { store.noteOpened(id: $0) },
            onFailure: { router.open(document) })
    }

    // MARK: Management

    /// Rename, Mark as Finished and Delete, the one implementation behind
    /// every card's menu, VoiceOver actions and Delete Book… (⌘⌫) (R12g).
    private func perform(_ action: DocumentAction, on document: LibraryDocument) {
        switch action {
        case .rename:
            renameTarget = document
            renameText = document.title
            router.rootPresentation = .rename
        case .markFinished:
            // The player and any Continue load let go first, so no later
            // progress write or Play undoes it.
            continuePlayback.letGo(of: document.id, playback: model.playback)
            store.markFinished(id: document.id)
            PlaybackController.postAnnouncement("Marked as finished", muted: model.playback.isOutputMuted)
        case .delete:
            deleteTarget = document
            router.rootPresentation = .deleteConfirmation
        }
    }
}

// MARK: - Shelf feed

/// The Library's shelf (`ShelfLayout`), rebuilt only while the Library
/// shows. Under the reader (or Classics) the Library stays in the window's
/// stack, and the controller saves progress every sentence: a hidden shelf
/// rebuilt for each save is work nobody sees. A publish while covered marks
/// the shelf stale; the Library showing again rebuilds it once, from the
/// store as it is then.
struct MacShelfFeed {
    private(set) var layout = ShelfLayout.empty
    /// A publish arrived while the Library was covered.
    private(set) var isStale = false
    /// Layouts built (tests).
    private(set) var builds = 0

    /// A publish of the store or of the loaded book. False when the feed is
    /// unchanged (covered and already stale), so the view writes no state.
    /// `stop` is the controller's unattended stop, which keeps a book
    /// stopped in its last minute on offer (`DocumentStore.isAtItsEnd`).
    mutating func publish(_ documents: [LibraryDocument], loadedID: UUID?, stop: PlaybackStop? = nil,
                          libraryShows: Bool) -> Bool {
        guard libraryShows else {
            guard !isStale else { return false }
            isStale = true
            return true
        }
        layout = ShelfLayout(for: documents, loadedID: loadedID, stop: stop)
        isStale = false
        builds += 1
        return true
    }

    /// The Library shows again: a stale shelf is rebuilt, once; a current
    /// one is left alone.
    mutating func libraryShown(_ documents: [LibraryDocument], loadedID: UUID?, stop: PlaybackStop? = nil) -> Bool {
        guard isStale else { return false }
        return publish(documents, loadedID: loadedID, stop: stop, libraryShows: true)
    }
}

// MARK: - Empty

/// The Library with no books: the featured classic, two text links and the
/// privacy line, in a centered 480 pt column. The card's play circle is the
/// screen's one accent fill. Deleting every book comes back here.
private struct MacEmptyLibrary: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter

    var body: some View {
        GeometryReader { proxy in
            MacEdgeScrollView {
                VStack(spacing: Theme.Space.xl) {
                    if let book = FeaturedClassic.resolve(in: model.bookshelf) {
                        featuredButton(for: book)
                    }
                    links
                    Text(PrivacyCopy.line)
                        .font(Theme.font(.aside))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, MacGridMetrics.gutter(forWindowWidth: proxy.size.width))
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One click adds the classic; the importer then opens it, playing (R4).
    /// Disabled while the add runs, so a double click adds one copy.
    private func featuredButton(for book: BookshelfBook) -> some View {
        Button {
            importer.addClassic(book)
        } label: {
            FeaturedClassicCard(book: book, rate: model.globalRate)
        }
        .buttonStyle(MacHoverPlateStyle(radius: Theme.Radius.lg, outset: MacGridMetrics.plateOutset))
        .disabled(importer.addingClassicID != nil)
        .onKeyPress(.return) {
            importer.addClassic(book)
            return .handled
        }
        .accessibilityLabel(FeaturedClassic.accessibilityLabel(for: book, rate: model.globalRate))
        .accessibilityHint("Opens and starts reading aloud")
        .accessibilityIdentifier("library.featured")
    }

    private var links: some View {
        HStack(spacing: Theme.Space.xl) {
            if !model.bookshelf.isEmpty {
                Button("More classics") { router.showBookshelf() }
                    .buttonStyle(MacTextLinkStyle())
                    .accessibilityIdentifier("library.moreClassics")
            }
            Button("Add a file") { router.rootPresentation = .filePicker }
                .buttonStyle(MacTextLinkStyle())
                .accessibilityIdentifier("library.addFile")
        }
    }
}

// MARK: - Continue card

/// The shared Continue card wired to playback: the one Library view that
/// observes the controller, so a sentence change redraws it alone. Hover
/// draws the plate behind the whole card.
private struct MacContinueHero<Actions: View>: View {
    let document: LibraryDocument
    let rate: Double
    @ObservedObject var playback: PlaybackController
    @ObservedObject var continuePlayback: ContinuePlayback
    let onOpen: () -> Void
    let onTogglePlayback: () -> Void
    private let actions: Actions

    @EnvironmentObject private var naturalVoiceOffer: NaturalVoiceOffer
    // Observed for the offer's line, as on the iPhone.
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(document: LibraryDocument, rate: Double, playback: PlaybackController,
         continuePlayback: ContinuePlayback, onOpen: @escaping () -> Void,
         onTogglePlayback: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.document = document
        self.rate = rate
        self.playback = playback
        self.continuePlayback = continuePlayback
        self.onOpen = onOpen
        self.onTogglePlayback = onTogglePlayback
        self.actions = actions()
    }

    var body: some View {
        let loaded = playback.document?.id == document.id
        let status = ContinuePlayback.effectiveStatus(documentID: document.id,
                                                      loadedID: playback.document?.id,
                                                      status: playback.status,
                                                      pendingID: continuePlayback.pendingDocumentID)
        ContinueListeningCard(document: document,
                              rate: rate,
                              playState: PlayButtonState(status: status,
                                                         isPreparingVoice: loaded && playback.isPreparingVoice,
                                                         reduceMotion: reduceMotion),
                              stop: playback.stopReason(for: document.id),
                              offersNaturalVoice: naturalVoiceOffer.isVisible,
                              modelState: modelManager.state,
                              opensPlaying: playback.opensPlaying(document),
                              onOpen: onOpen,
                              onTogglePlayback: onTogglePlayback) {
            actions
        }
        .modifier(MacHoverPlate(radius: Theme.Radius.lg, outset: MacGridMetrics.plateOutset))
    }
}

// MARK: - Shared Mac pieces

/// A text link ("More classics", "Add a file", Cancel): accentStrong text,
/// an underline and the pointing hand on hover, at least 28 pt tall.
struct MacTextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Linked(configuration: configuration)
    }

    private struct Linked: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(Theme.font(.callout).weight(.medium))
                .foregroundStyle(Theme.accentStrong)
                .underline(isHovered)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .padding(.horizontal, Theme.Space.xs)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .modifier(MacLinkPointer())
        }
    }
}

/// The pointing hand over a link (mac-ux §11): the system's link pointer on
/// macOS 15, and a pushed cursor on 14, popped when the pointer leaves or
/// the link goes away under it ("More classics" pushes Classics), so the
/// hand never outlives its link.
private struct MacLinkPointer: ViewModifier {
    @State private var isPushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onHover { inside in
                    if inside { push() } else { pop() }
                }
                .onDisappear { pop() }
        }
    }

    private func push() {
        guard !isPushed else { return }
        NSCursor.pointingHand.push()
        isPushed = true
    }

    private func pop() {
        guard isPushed else { return }
        NSCursor.pop()
        isPushed = false
    }
}

/// A scroll view whose top edge draws Stroke.hairline once content has
/// scrolled under the toolbar (mac-ux §9.2), and nothing at rest: the
/// window's toolbar is paper with the system separator off.
struct MacEdgeScrollView<Content: View>: View {
    private let content: Content
    @State private var isScrolled = false

    private static var space: String { "macEdgeScroll" }

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .background(alignment: .top) {
                    GeometryReader { geo in
                        Color.clear.preference(key: MacScrollTopKey.self,
                                               value: geo.frame(in: .named(Self.space)).minY)
                    }
                }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MacScrollTopKey.self) { top in
            let scrolled = top < 0
            if scrolled != isScrolled { isScrolled = scrolled }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .frame(height: Theme.Stroke.hairlineWidth)
                .opacity(isScrolled ? 1 : 0)
                .animation(.easeOut(duration: Theme.Motion.press), value: isScrolled)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct MacScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
