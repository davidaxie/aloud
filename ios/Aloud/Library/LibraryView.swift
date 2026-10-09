import SwiftUI
import UIKit
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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The import overlay is up (RootView reveals it only for a slow add):
    /// the shelf and its bar items leave VoiceOver and the bar only then.
    @Environment(\.importOverlayRevealed) private var overlayRevealed

    /// Hero + grid split, memoized against the store's and the loaded book's
    /// publishes, and only while the Library shows (`ShelfFeed`): under the
    /// reader every sentence's progress save publishes the store, and a
    /// covered shelf only marks itself stale. The split scans the whole
    /// library, so it runs once per change and never per body re-run.
    @State private var feed = ShelfFeed()
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
    /// Why the last Delete, Rename or Mark as finished didn't happen, for
    /// the failure alert.
    @State private var shelfFailure: (any ShelfFailure)?
    /// Where VoiceOver goes after a Delete (a neighbour) or a Mark as
    /// finished on the Continue card (the book's grid card): lost, it
    /// jumped to the top of the screen.
    @AccessibilityFocusState private var voFocus: UUID?
    /// The card a hand-off is bound for, once the dialog or menu has gone.
    /// The shelf scrolls it into view before VoiceOver takes it: the grid
    /// is lazy, and a card it hasn't built (a finished Continue book back
    /// in its slot far below) can't take focus.
    @State private var pendingFocus: UUID?
    /// The shelf's width, for the column gap (`PhoneShelfMetrics`).
    @State private var shelfWidth: CGFloat = 0
    /// Whether the clipboard holds text, for the paste item and link. Read
    /// without the paste prompt; the text itself is read only on a tap.
    /// Read on appear, not here: RootView builds a LibraryView on every
    /// import progress tick, and an initial value runs each time.
    @State private var clipboardHasText = false
    /// A Paste Text that read nothing from a clipboard holding text: the
    /// paste was declined, and the alert says how to allow it.
    @State private var pasteDeclined = false

    /// The shelf as the feed has it.
    private var shelf: ShelfLayout { feed.layout }

    /// The link row's prompt-free paste, under the featured classic and at
    /// the shelf's foot: offered only while the clipboard holds text, so it
    /// shows and hides with `refreshClipboard()`.
    private var pasteHandler: (([String]) -> Void)? {
        clipboardHasText ? { importer.importText($0.joined(separator: "\n\n")) } : nil
    }

    private var metrics: PhoneShelfMetrics {
        PhoneShelfMetrics(width: shelfWidth, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    /// Two columns; one at the accessibility text sizes (AX1+), where a
    /// half-width card can't hold a legible title.
    private var columns: [GridItem] {
        // Top-aligned: a card with a one-line title is shorter than its
        // two-line neighbour, and centring it pushed its cover and caption
        // off the row's line. Top alignment keeps them level, as on the Mac.
        Array(repeating: GridItem(.flexible(), spacing: metrics.columnSpacing, alignment: .top), count: metrics.columns)
    }

    var body: some View {
        Group {
            if store.documents.isEmpty {
                EmptyLibraryView(onAddFile: { router.rootPresentation = .filePicker },
                                 onPaste: pasteHandler, onPasteEmpty: refreshClipboard)
            } else {
                grid
            }
        }
        // L011: a library.json that can't be read leaves the shelf empty or
        // short; the notice says the books are kept, over either.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !store.isIndexReadable {
                UnreadableLibraryNotice(gutter: Theme.Space.screenGutter)
            }
        }
        // R12b: magic tap plays or pauses the hero from anywhere on the shelf.
        .accessibilityAction(.magicTap) { magicTap() }
        // R10: VoiceOver cannot reach the shelf under the import overlay.
        // RootView's hiding of the whole stack doesn't carry into the
        // stack's hosted root or its bar, so the shelf (and each bar item
        // below) hides itself; the overlay above stays reachable.
        .accessibilityHidden(overlayRevealed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        #if DEBUG
        // R3-03: the paste control's count, for the paste UI tests' failure
        // messages. Here, on the one screen that draws the control, and
        // after the shelf's own hiding, which would take it away while the
        // import overlay is up.
        .overlay(alignment: .bottomTrailing) { PasteCallsProbe() }
        #endif
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
            PaperTitleItem(isHidden: overlayRevealed, onMagicTap: magicTap)
            // + sits rightmost, and only once there is a book: the empty
            // Library's own links are the way in until then.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !overlayRevealed {
                    settingsButton
                    if !store.documents.isEmpty {
                        addMenu
                    }
                }
            }
        }
        // Several files at once are a batch: all added, none opened, one
        // count said (M8). One file opens playing, as ever (R4).
        .fileImporter(isPresented: presented(.filePicker),
                      allowedContentTypes: LibraryAddMenuItem.fileContentTypes,
                      allowsMultipleSelection: true) { result in
            // The picker is gone once it reports. Clear its flag now rather
            // than whenever SwiftUI does: a failure alert waits on it.
            router.dismissRootPresentation(.filePicker)
            importer.handlePicks(result)
        }
        // The controller's unattended stop holds a book Finished by the
        // slack rule at its sentence (`DocumentStore.isAtItsEnd`), as the
        // shortcut and remote Play do.
        .onReceive(store.$documents) { documents in
            let shows = router.path.isEmpty
            feedShelf { $0.publish(documents, loadedID: loadedID, stop: model.playback.stopped, libraryShows: shows) }
        }
        // The plain publisher, like the store's, deduplicated here: only a
        // change of book reshapes the shelf.
        .onReceive(model.playback.$document) { document in
            guard document?.id != loadedID else { return }
            let id = document?.id
            loadedID = id
            let shows = router.path.isEmpty
            feedShelf { $0.publish(store.documents, loadedID: id, stop: model.playback.stopped, libraryShows: shows) }
        }
        // Back from the reader, Classics or Settings: the saves made
        // meanwhile, once, so the Continue card shows the new place at once.
        // On appear too: an interactive back swipe shows the Library for the
        // whole gesture, before the pop completes and the path empties, and
        // the book loaded under the reader belongs on the shelf by then. A
        // current shelf is left alone; saves made during the swipe are
        // rebuilt once the pop completes.
        .onAppear {
            feedShelf { $0.libraryShown(store.documents, loadedID: loadedID, stop: model.playback.stopped) }
            refreshClipboard()
        }
        .onChange(of: router.path.isEmpty) { _, shows in
            guard shows else { return }
            feedShelf { $0.libraryShown(store.documents, loadedID: loadedID, stop: model.playback.stopped) }
        }
        // Copied elsewhere, or here: the paste item and link follow.
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard()
        }
        .alert("Rename", isPresented: presented(.rename)) {
            TextField("Title", text: $renameText)
            Button("Save") {
                // A title the library can't record stays as it was, and the
                // failure alert says why: the alert's own close leaves it up.
                if let target = renameTarget {
                    do {
                        try store.rename(target, to: renameText)
                    } catch {
                        showFailure(EditFailure(.rename, error))
                    }
                }
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
                // A delete the library can't record keeps the book, and says
                // why: the dialog's own close leaves this alert up. One that
                // succeeds hands VoiceOver to a neighbour, read off the shelf
                // before the book leaves it.
                if let target = deleteTarget {
                    let next = ShelfLayout.focusAfterRemoving(target.id, in: shelf)
                    if let failure = model.deleteDocument(target) {
                        showFailure(failure)
                    } else {
                        moveVoiceOverFocus(to: next)
                    }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map(DocumentAction.deleteMessage(for:)) ?? "")
        }
        // Fixed copy only, as an add's failure (R10). A failed Rename or
        // Mark as finished shows here too, on the Delete failure's slot.
        .alert(shelfFailure?.title ?? "", isPresented: presented(.deleteFailed),
               presenting: shelfFailure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.nextStep)
        }
        // A declined paste says so, with the way to allow it next time.
        .alert(PasteTextAction.declinedTitle, isPresented: $pasteDeclined) {
            Button(PasteTextAction.openSettings) { openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text(PasteTextAction.declinedMessage)
        }
    }

    /// `change` on a copy of the feed, written back only when it changed:
    /// a publish under the reader writes no state at all after the first.
    private func feedShelf(_ change: (inout ShelfFeed) -> Bool) {
        var next = feed
        if change(&next) { feed = next }
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
            // The same ink and weight as +, so the pair reads as one control.
            Image(systemName: "gearshape")
                .font(Theme.font(.body).weight(.semibold))
                .foregroundStyle(Theme.text)
                // The bar sizes the platter: 44 pt, as the back circle (R4-07).
                .modifier(BarItemTarget())
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
                    // R3-06: From Files… says which files it takes, as the
                    // menu's second line, so a greyed-out EPUB isn't a puzzle.
                    if item == .files {
                        Label {
                            Text(item.title)
                            Text(LibraryAddMenuItem.fileFormats)
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                    } else {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
            // The clipboard's text as a book, last. Off while there is no
            // text to paste; the system asks before the text is read.
            Button {
                pasteText()
            } label: {
                Label(PasteTextAction.menuTitle, systemImage: PasteTextAction.systemImage)
            }
            .disabled(!clipboardHasText)
        } label: {
            Image(systemName: "plus")
                .font(Theme.font(.body).weight(.semibold))
                .foregroundStyle(Theme.text)
                .modifier(BarItemTarget())
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

    /// The clipboard's text, added as a book that opens playing (R4); text
    /// that is only whitespace fails as an empty text file does. A declined
    /// paste (text was there, the read came back empty) says so; text that
    /// has gone says nothing. `hasStrings` is read first: it never asks.
    private func pasteText() {
        let hadStrings = UIPasteboard.general.hasStrings
        switch PasteTextAction.outcome(hadStrings: hadStrings, string: UIPasteboard.general.string) {
        case .text(let text):
            importer.importText(text)
        case .declined:
            refreshClipboard()
            pasteDeclined = true
        case .gone:
            refreshClipboard()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshClipboard() {
        let hasText = UIPasteboard.general.hasStrings
        if hasText != clipboardHasText { clipboardHasText = hasText }
    }

    // MARK: Grid

    /// The shelf, scrolled to a VoiceOver hand-off's card (`pendingFocus`)
    /// before focus moves there. Only under VoiceOver: a sighted reader's
    /// shelf stays where they left it.
    private var grid: some View {
        ScrollViewReader { proxy in
            shelfScroll
                .onChange(of: pendingFocus) { _, id in
                    guard let id else { return }
                    landVoiceOverFocus(on: id, proxy: proxy)
                }
        }
    }

    private var shelfScroll: some View {
        ScrollView {
            VStack(spacing: PhoneShelfMetrics.heroToGrid) {
                if let hero = shelf.hero {
                    // Every estimate runs at the one app-wide speed (R7).
                    ContinueHero(document: hero,
                                 rate: model.globalRate,
                                 playback: model.playback,
                                 continuePlayback: continuePlayback,
                                 focus: $voFocus,
                                 onOpen: { open(hero) },
                                 onTogglePlayback: { toggleFromTap(hero) }) {
                        silentOpenAction(for: hero)
                        documentActions(for: hero)
                    } menu: {
                        contextMenuActions(for: hero)
                    }
                    .id(hero.id)
                }
                // Only with cards to hold: an empty grid would still take the
                // stack's spacing on both sides, two steps under the card.
                if !shelf.grid.isEmpty { documentGrid }
                // The empty Library's links stay at the shelf's foot, so the
                // next book is in reach without the + menu; Paste joins them
                // while the clipboard holds text.
                ShelfLinks(onAddFile: { router.rootPresentation = .filePicker }, onPaste: pasteHandler,
                           onPasteEmpty: refreshClipboard, idPrefix: "library.shelf")
            }
            .padding(.horizontal, PhoneShelfMetrics.gutter)
            .padding(.top, PhoneShelfMetrics.topPadding)
            .padding(.bottom, Theme.Space.xl)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            shelfWidth = width
        }
        .modifier(ShelfScrollEdge(showsScrollRule: true))
    }

    private var documentGrid: some View {
        LazyVGrid(columns: columns, spacing: PhoneShelfMetrics.rowSpacing) {
            ForEach(shelf.grid) { document in
                Button {
                    open(document)
                } label: {
                    DocumentCardView(document: document, rate: model.globalRate)
                }
                // A paper plate under the finger, never a dimmed cover.
                .buttonStyle(ShelfPlateButtonStyle())
                // A Finished book opens paused at its end, so it promises nothing.
                .accessibilityHint(document.isFinished ? "" : "Opens and starts reading aloud")
                .accessibilityInputLabels(DocumentCardView.inputLabels(for: document))
                .accessibilityIdentifier("library.card")
                .accessibilityActions {
                    silentOpenAction(for: document)
                    documentActions(for: document)
                }
                .accessibilityFocused($voFocus, equals: document.id)
                // What a VoiceOver hand-off scrolls to (`pendingFocus`).
                .id(document.id)
                // The long press lifts the cover alone, by its own corners,
                // not the cover and a slab of caption; it starts anywhere on
                // the cell.
                .contentShape(.contextMenuPreview,
                              CoverLiftShape(fixedSize: DocumentCardView.usesHeroCover(at: dynamicTypeSize)
                                             ? CoverGeometry.heroSize : nil))
                .contextMenu { contextMenuActions(for: document) }
            }
        }
    }

    // MARK: Playback

    /// A grid card or the hero's body: the reader takes over, and the soft
    /// haptic answers a tap that will start the voice (R20). A silent open
    /// (`autoplay` false, R4-10) starts no voice, so it plays no haptic.
    private func open(_ document: LibraryDocument, autoplay: Bool = true) {
        if autoplay, model.playback.opensPlaying(document) { TransportHaptics.emit(.play) }
        continuePlayback.readerOpens(document.id)
        // A book opened from a shelf with no Continue card would otherwise
        // load the natural voice cold behind the preparing-voice notice
        // (PlaybackController.isPreparingVoice).
        model.neuralPrewarm.bookIsOpening(document.id)
        router.open(document, autoplay: autoplay)
    }

    /// The hero's circle and magic tap. The haptic follows the glyph the
    /// card shows: a book loading for the circle already shows Pause.
    private func toggleFromTap(_ document: LibraryDocument) {
        let playback = model.playback
        let status = ContinuePlayback.effectiveStatus(documentID: document.id,
                                                      loadedID: playback.document?.id,
                                                      status: playback.status,
                                                      pendingID: continuePlayback.pendingDocumentID,
                                                      stop: playback.stopReason(for: document.id))
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
    /// the VoiceOver actions of every surface that stands in for a document
    /// (R12g), grid card and hero alike, so no book can be shown without a
    /// way to manage it. The context menu is the same list, sectioned.
    @ViewBuilder
    private func documentActions(for document: LibraryDocument) -> some View {
        ForEach(DocumentAction.available(for: document), id: \.self) { action in
            actionButton(action, on: document)
        }
    }

    /// The long-press menu: the card's own tap first (`openMenuItem`), then
    /// the actions that keep the book, then Delete in a section of its own,
    /// in red.
    @ViewBuilder
    private func contextMenuActions(for document: LibraryDocument) -> some View {
        Section {
            openMenuItem(for: document)
            silentOpenMenuItem(for: document)
        }
        ForEach(DocumentAction.menuSections(for: document), id: \.self) { section in
            Section {
                ForEach(section, id: \.self) { action in
                    actionButton(action, on: document)
                }
            }
        }
    }

    /// What a tap on the card does, as the menu's lead, labelled by the
    /// soft haptic's rule in `open(_:)`: it promises playback only when the
    /// open will start the voice, and not for a finished book, the one
    /// already playing, or a launch that doesn't autoplay. Not a
    /// `DocumentAction`: those are the VoiceOver actions and the Mac's
    /// commands, and opening is the card's own tap.
    private func openMenuItem(for document: LibraryDocument) -> some View {
        let plays = model.playback.opensPlaying(document)
        return Button {
            open(document)
        } label: {
            Label(OpenMenuItem.title(plays: plays), systemImage: OpenMenuItem.systemImage(plays: plays))
        }
    }

    /// R4-10: while the lead plays, the open that doesn't, right under it.
    /// When the lead already only opens, it is the same item, so it isn't
    /// offered twice.
    @ViewBuilder
    private func silentOpenMenuItem(for document: LibraryDocument) -> some View {
        if model.playback.opensPlaying(document) {
            Button {
                open(document, autoplay: false)
            } label: {
                Label(OpenMenuItem.silentTitle, systemImage: OpenMenuItem.silentSystemImage)
            }
        }
    }

    /// The same open as a VoiceOver action, on a grid card and the Continue
    /// card alike, under the same rule: only when the card's own activation
    /// would start the voice.
    @ViewBuilder
    private func silentOpenAction(for document: LibraryDocument) -> some View {
        if model.playback.opensPlaying(document) {
            Button(OpenMenuItem.silentTitle) { open(document, autoplay: false) }
        }
    }

    private func actionButton(_ action: DocumentAction, on document: LibraryDocument) -> some View {
        Button(role: action.role) {
            perform(action, on: document)
        } label: {
            actionLabel(action)
        }
    }

    /// A menu's icons take the tint of the view the menu hangs from (the
    /// app's accent), not the item's role: Delete's trash glyph is drawn red
    /// in its own colours, to match its red title. VoiceOver's actions read
    /// only the title.
    @ViewBuilder
    private func actionLabel(_ action: DocumentAction) -> some View {
        if action.role == .destructive, let base = UIImage(systemName: action.systemImage) {
            Label {
                Text(action.title)
            } icon: {
                Image(uiImage: base.withTintColor(.systemRed, renderingMode: .alwaysOriginal))
            }
        } else {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    private func perform(_ action: DocumentAction, on document: LibraryDocument) {
        switch action {
        case .rename:
            renameTarget = document
            renameText = document.title
            router.rootPresentation = .rename
        case .markFinished:
            // Written first: a mark the store can't record leaves the book
            // as it was, playing if it was. Then the player and any Continue
            // load let go, at once, so no later progress write or Play
            // undoes it.
            let wasHero = document.id == shelf.hero?.id
            do {
                try store.markFinished(id: document.id)
            } catch {
                showFailure(EditFailure(.markFinished, error))
                return
            }
            continuePlayback.letGo(of: document.id, playback: model.playback)
            // A finished Continue book is redrawn as a grid card: VoiceOver
            // follows it there.
            if wasHero { moveVoiceOverFocus(to: document.id) }
            PlaybackController.postAnnouncement("Marked as finished", muted: model.playback.isOutputMuted)
        case .delete:
            deleteTarget = document
            router.rootPresentation = .deleteConfirmation
        case .markUnfinished:
            // The place it had goes back, written at once; nothing opens or
            // plays (`AppModel.markUnfinished`). A mark the store can't
            // record leaves the book Finished and says why.
            if let failure = model.markUnfinished(document) {
                showFailure(failure)
                return
            }
            // Back in progress, the book may now be the Continue card:
            // VoiceOver follows it there, as a mark the other way does. The
            // feed is published now, while the Library shows, so the shelf
            // read here is the one about to be drawn.
            let loadedID = model.playback.document?.id
            feedShelf { $0.publish(store.documents, loadedID: loadedID, stop: model.playback.stopped, libraryShows: true) }
            if shelf.hero?.id == document.id { moveVoiceOverFocus(to: document.id) }
            PlaybackController.postAnnouncement(DocumentAction.markedUnfinished,
                                                muted: model.playback.isOutputMuted)
        }
    }

    /// The failure alert, for a Delete, Rename, Mark as finished or Mark as
    /// unfinished the library couldn't record.
    private func showFailure(_ failure: any ShelfFailure) {
        shelfFailure = failure
        router.rootPresentation = .deleteFailed
    }

    /// Once the shelf has redrawn and the dialog or menu has gone (its
    /// dismissal would otherwise put VoiceOver back where it was), the
    /// grid scrolls the card in and VoiceOver lands on it (`grid`). Neither
    /// the dialog nor the menu says when it has gone, hence the wait, which
    /// the Library lint sanctions (`LibraryEntryLintTests.sanctionedSleeps`):
    /// the Delete or mark has already landed, and nothing is added or opened.
    /// Scrolls the hand-off's card in (under VoiceOver only) and moves
    /// focus there once the lazy grid has built it. The grid says nothing
    /// when a cell is ready, hence the short wait, which the Library lint
    /// sanctions beside `moveVoiceOverFocus`.
    private func landVoiceOverFocus(on id: UUID, proxy: ScrollViewProxy) {
        if voiceOverEnabled { proxy.scrollTo(id, anchor: .center) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.scrollSettleDelay)
            voFocus = id
            pendingFocus = nil
        }
    }

    private func moveVoiceOverFocus(to card: UUID?) {
        guard let card else { return }
        Task { @MainActor in
            try? await Task.sleep(for: Self.focusHandoffDelay)
            pendingFocus = card
        }
    }

    /// Long enough for a confirmation dialog to finish leaving.
    private static let focusHandoffDelay: Duration = .milliseconds(300)
    /// Long enough for the lazy grid to build the card it scrolled to.
    private static let scrollSettleDelay: Duration = .milliseconds(100)
}

// MARK: - Title

/// The wordmark on the bar's paper. iOS 26 sets every bar item on a shared
/// glass capsule, which drew the app's name as a button; the leading item
/// opts out of it there. Earlier systems draw no capsule.
private struct PaperTitleItem: ToolbarContent {
    let isHidden: Bool
    let onMagicTap: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarLeading) { wordmark }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarLeading) { wordmark }
        }
    }

    private var wordmark: some View {
        Text("Aloud")
            .font(Theme.font(.title))
            .foregroundStyle(Theme.text)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
            // The bar caps text scaling; at accessibility sizes a
            // long press shows the title large instead (J020).
            .accessibilityShowsLargeContentViewer()
            .accessibilityAction(.magicTap) { onMagicTap() }
            .accessibilityHidden(isHidden)
    }
}

// MARK: - Continue hero

/// The Continue card wired to playback. The one view on the shelf that
/// observes the controller, so a sentence change redraws the hero alone.
private struct ContinueHero<Actions: View, MenuItems: View>: View {
    let document: LibraryDocument
    let rate: Double
    @ObservedObject var playback: PlaybackController
    @ObservedObject var continuePlayback: ContinuePlayback
    let focus: AccessibilityFocusState<UUID?>.Binding
    let onOpen: () -> Void
    let onTogglePlayback: () -> Void
    private let actions: Actions
    private let menu: MenuItems

    @EnvironmentObject private var naturalVoiceOffer: NaturalVoiceOffer
    // Observed for the offer's line: the offer stays visible through a
    // failed space check, so its isVisible alone never redraws the card.
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(document: LibraryDocument, rate: Double, playback: PlaybackController,
         continuePlayback: ContinuePlayback, focus: AccessibilityFocusState<UUID?>.Binding,
         onOpen: @escaping () -> Void, onTogglePlayback: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions, @ViewBuilder menu: () -> MenuItems) {
        self.document = document
        self.rate = rate
        self.playback = playback
        self.continuePlayback = continuePlayback
        self.focus = focus
        self.onOpen = onOpen
        self.onTogglePlayback = onTogglePlayback
        self.actions = actions()
        self.menu = menu()
    }

    var body: some View {
        let loaded = playback.document?.id == document.id
        let stop = playback.stopReason(for: document.id)
        let status = ContinuePlayback.effectiveStatus(documentID: document.id,
                                                      loadedID: playback.document?.id,
                                                      status: playback.status,
                                                      pendingID: continuePlayback.pendingDocumentID,
                                                      stop: stop)
        ContinueListeningCard(document: document,
                              rate: rate,
                              playState: PlayButtonState(status: status,
                                                         isPreparingVoice: loaded && playback.isPreparingVoice,
                                                         reduceMotion: reduceMotion),
                              stop: stop,
                              offersNaturalVoice: naturalVoiceOffer.isVisible,
                              modelState: modelManager.state,
                              spaceNeeded: modelManager.spaceNeeded,
                              opensPlaying: playback.opensPlaying(document),
                              onOpen: onOpen,
                              onTogglePlayback: onTogglePlayback) {
            actions
        } menu: {
            menu
        }
        .voiceOverFocus(focus)
    }
}

// MARK: - Scroll edge

/// iOS 26 softens the scroll edge under the nav bar into a fade that reads as
/// a gradient on the flat paper ground. An opaque bar in the screen's own
/// ground gives the same clean cut. Not `scrollEdgeEffectStyle(.hard)`: a
/// hard scroll pocket claims the shared bar's glass, and once this screen is
/// pushed under another its offscreen pocket reads the backdrop as white and
/// turns every glass button light, even in dark mode. Earlier systems keep
/// their plain bar, which draws its own separator once content scrolls
/// under it.
///
/// The opaque bar draws no edge of its own, so covers slid under a bar of
/// their own colour: on the shelves (the Library, its empty state and
/// Classics), which opt in with `showsScrollRule`, a hairline fades in once
/// anything has scrolled under it (`ShelfEdgeRule`), and none shows at
/// rest, as on the Mac. The other screens sharing the opaque bar keep it
/// plain until someone looks at them with the rule.
struct ShelfScrollEdge: ViewModifier {
    var ground: Color = Theme.bg
    /// The hairline under the bar once content scrolls under it.
    var showsScrollRule = false

    @State private var scrolledUnder = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let bar = content
                .toolbarBackground(ground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            if showsScrollRule {
                bar
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        ShelfEdgeRule.shows(contentOffsetY: geometry.contentOffset.y,
                                            topInset: geometry.contentInsets.top)
                    } action: { _, scrolled in
                        scrolledUnder = scrolled
                    }
                    .overlay(alignment: .top) { rule }
            } else {
                bar
            }
        } else {
            content
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .frame(height: Theme.Stroke.hairlineWidth)
            .opacity(scrolledUnder ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.press), value: scrolledUnder)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
