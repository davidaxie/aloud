import SwiftUI
import UniformTypeIdentifiers

/// The shelf. Root screen: the Continue Listening hero over an adaptive grid
/// of document cards sorted last-listened-first, or the featured classic
/// when there are no books. The nav bar's + menu adds a book (R10). Every
/// card opens through the router, and the reader starts it speaking (R4);
/// the hero's circle plays and pauses in place (R18).
///
/// The screen never observes the PlaybackController, which publishes every
/// sentence: only the hero (`ContinueHero`) does. Actions read
/// `model.playback` when they run.
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    /// Hero + grid split, memoized against the store's and the loaded book's
    /// publishes. The split scans the whole library, so it runs once per
    /// change and never per body re-run.
    @State private var shelf = ShelfLayout.empty
    /// The book the controller holds: always the hero, at any progress (R18).
    @State private var loadedID: UUID?
    /// The hero circle's load-and-play, when the book isn't loaded yet. The
    /// app's one instance, shared with the Continue listening shortcut, so
    /// the card shows the shortcut's load. Not observed here: only the hero
    /// redraws for it.
    private var continuePlayback: ContinuePlayback { model.continuePlayback }

    // Whether the picker, Rename alert or Delete dialog is up lives on the
    // router (`rootPresentation`), so Open-in can close it; only what they
    // act on stays here.
    @State private var renameTarget: LibraryDocument?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryDocument?

    /// Two columns; one at the accessibility text sizes (AX1+), where a
    /// half-width card can't hold a legible title.
    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: count)
    }

    var body: some View {
        Group {
            if store.documents.isEmpty {
                EmptyLibraryView(onAddFile: { router.rootPresentation = .filePicker })
            } else {
                grid
            }
        }
        // R12b: magic tap plays or pauses the hero from anywhere on the shelf.
        .accessibilityAction(.magicTap) { magicTap() }
        // R10: VoiceOver cannot reach the shelf under the import overlay.
        // RootView's hiding of the whole stack doesn't carry into the
        // stack's hosted root or its bar, so the shelf (and each bar item
        // below) hides itself; the overlay above stays reachable.
        .accessibilityHidden(importer.isImporting)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // The bar's system content follows the app's scheme, not the
        // phone's: under an in-app Dark override on a Light phone it
        // otherwise drew dark-on-dark.
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            // The bar's items live outside the Group above, so each carries
            // the magic tap itself. Under the import overlay the title hides
            // itself; the buttons leave the bar, because iOS hosts bar buttons
            // as system items that SwiftUI's accessibility hiding doesn't reach.
            ToolbarItem(placement: .navigationBarLeading) {
                Text("Aloud")
                    .font(Theme.font(.title))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(.magicTap) { magicTap() }
                    .accessibilityHidden(importer.isImporting)
            }
            // + sits rightmost, and only once there is a book: the empty
            // Library's own links are the way in until then.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !importer.isImporting {
                    settingsButton
                    if !store.documents.isEmpty {
                        addMenu
                    }
                }
            }
        }
        .fileImporter(isPresented: presented(.filePicker),
                      allowedContentTypes: [.pdf, .plainText]) { result in
            // The picker is gone once it reports. Clear its flag now rather
            // than whenever SwiftUI does: a failure alert waits on it.
            router.dismissRootPresentation(.filePicker)
            importer.handlePick(result)
        }
        // The controller's unattended stop holds a book Finished by the
        // slack rule at its sentence (`DocumentStore.isAtItsEnd`), as the
        // shortcut and remote Play do.
        .onReceive(store.$documents) { documents in
            shelf = ShelfLayout(for: documents, loadedID: loadedID, stop: model.playback.stopped)
        }
        // The plain publisher, like the store's, deduplicated here: only a
        // change of book reshapes the shelf.
        .onReceive(model.playback.$document) { document in
            guard document?.id != loadedID else { return }
            loadedID = document?.id
            shelf = ShelfLayout(for: store.documents, loadedID: loadedID, stop: model.playback.stopped)
        }
        .alert("Rename", isPresented: presented(.rename)) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let target = renameTarget { store.rename(target, to: renameText) }
                renameTarget = nil
            }
            // An empty title is no rename: Save would close the alert on a
            // change the store never makes.
            .disabled(DocumentStore.renamedTitle(renameText) == nil)
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

    // MARK: Chrome

    private var settingsButton: some View {
        Button {
            router.showSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(Theme.font(.body).weight(.medium))
                .foregroundStyle(Theme.textMuted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("library.settings")
        .accessibilityShowsLargeContentViewer()
        .accessibilityAction(.magicTap) { magicTap() }
    }

    /// R10: adding a book is one native menu. Drawn in Theme.text, not
    /// filled: the shelf's one accent fill belongs to the Continue card.
    private var addMenu: some View {
        Menu {
            ForEach(LibraryAddMenuItem.allCases, id: \.self) { item in
                Button {
                    choose(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(Theme.font(.body).weight(.semibold))
                .foregroundStyle(Theme.text)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add")
        .accessibilityInputLabels([Text("Add"), Text("Plus")])
        .accessibilityShowsLargeContentViewer { Label("Add", systemImage: "plus") }
        .accessibilityIdentifier("library.add")
        .accessibilityAction(.magicTap) { magicTap() }
    }

    private func choose(_ item: LibraryAddMenuItem) {
        switch item {
        case .classics: router.showBookshelf()
        case .files: router.rootPresentation = .filePicker
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                if let hero = shelf.hero {
                    // Every estimate runs at the one app-wide speed (R7).
                    ContinueHero(document: hero,
                                 rate: model.globalRate,
                                 playback: model.playback,
                                 continuePlayback: continuePlayback,
                                 onOpen: { open(hero) },
                                 onTogglePlayback: { toggleFromTap(hero) }) {
                        documentActions(for: hero)
                    }
                }
                documentGrid
            }
            .padding(.horizontal, Theme.Space.screenGutter)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, Theme.Space.xl)
        }
        .modifier(ShelfScrollEdge())
    }

    private var documentGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.lg) {
            ForEach(shelf.grid) { document in
                Button {
                    open(document)
                } label: {
                    DocumentCardView(document: document, rate: model.globalRate)
                }
                .buttonStyle(.plain)
                // A Finished book opens paused at its end, so it promises nothing.
                .accessibilityHint(document.isFinished ? "" : "Opens and starts reading aloud")
                .accessibilityIdentifier("library.card")
                .accessibilityActions { documentActions(for: document) }
                .contextMenu { documentActions(for: document) }
            }
        }
    }

    // MARK: Playback

    /// A grid card or the hero's body: the reader takes over, and the soft
    /// haptic answers a tap that will start the voice (R20).
    private func open(_ document: LibraryDocument) {
        if model.playback.opensPlaying(document) { TransportHaptics.emit(.play) }
        continuePlayback.readerOpens(document.id)
        router.open(document)
    }

    /// The hero's circle and magic tap. The haptic follows the glyph the
    /// card shows: a book loading for the circle already shows Pause.
    private func toggleFromTap(_ document: LibraryDocument) {
        let playback = model.playback
        let status = ContinuePlayback.effectiveStatus(documentID: document.id,
                                                      loadedID: playback.document?.id,
                                                      status: playback.status,
                                                      pendingID: continuePlayback.pendingDocumentID)
        TransportHaptics.emitToggle(isActive: status == .playing || status == .buffering)
        toggleContinue(document)
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

    /// R12b. Nothing to do on an empty shelf.
    private func magicTap() {
        guard let hero = shelf.hero else { return }
        toggleFromTap(hero)
    }

    // MARK: Management

    /// Rename, Mark as finished and Delete: ONE implementation, attached as
    /// the context menu and the VoiceOver actions of every surface that
    /// stands in for a document (R12g), grid card and hero alike, so no book
    /// can be shown without a way to manage it.
    @ViewBuilder
    private func documentActions(for document: LibraryDocument) -> some View {
        ForEach(DocumentAction.available(for: document), id: \.self) { action in
            Button(role: action.role) {
                perform(action, on: document)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

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

// MARK: - Continue hero

/// The Continue card wired to playback. The one view on the shelf that
/// observes the controller, so a sentence change redraws the hero alone.
private struct ContinueHero<Actions: View>: View {
    let document: LibraryDocument
    let rate: Double
    @ObservedObject var playback: PlaybackController
    @ObservedObject var continuePlayback: ContinuePlayback
    let onOpen: () -> Void
    let onTogglePlayback: () -> Void
    private let actions: Actions

    @EnvironmentObject private var naturalVoiceOffer: NaturalVoiceOffer
    // Observed for the offer's line: the offer stays visible through a
    // failed space check, so its isVisible alone never redraws the card.
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
    }
}

// MARK: - Scroll edge

/// iOS 26 softens the scroll edge under the nav bar into a fade that reads as
/// a gradient on the flat paper ground. An opaque bar in the screen's own
/// ground gives the same clean cut. Not `scrollEdgeEffectStyle(.hard)`: a
/// hard scroll pocket claims the shared bar's glass, and once this screen is
/// pushed under another its offscreen pocket reads the backdrop as white and
/// turns every glass button light, even in dark mode. Earlier systems keep
/// their plain bar.
struct ShelfScrollEdge: ViewModifier {
    var ground: Color = Theme.bg

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .toolbarBackground(ground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}
