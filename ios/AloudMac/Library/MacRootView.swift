import SwiftUI

/// The window's content (M5, contracts §6): one NavigationStack bound to the
/// shared `LibraryRouter`, with the Library at the root and Classics and the
/// reader pushed. Back is the toolbar's button or ⌘[; Esc never navigates.
/// Over the whole stack: the window-wide drop target and its "Drop to add"
/// border, the import overlay, and the one import failure alert. Every file,
/// from Add from Files…, a drop or Open With, goes through `MacFileIntake`
/// into the shared importer.
struct MacRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings

    /// The app's one intake, wrapping the app's one importer.
    @ObservedObject private var intake = MacFileIntake.shared
    /// A valid drag is over the window.
    @State private var isDropTargeted = false
    /// The import overlay is up (an add has run past 0.8 s).
    @State private var isImportOverlayShown = false
    /// A file of a type Aloud can't add, forced in by Open With.
    @State private var openFailure: ImportFailure?

    var body: some View {
        NavigationStack(path: $router.path) {
            MacLibraryView()
                .navigationDestination(for: LibraryRouter.Route.self) { route in
                    switch route {
                    case .bookshelf: MacClassicsView()
                    // Settings is its own window on the Mac (below); the
                    // route never draws, but the stack needs a view for it.
                    case .settings: Theme.bg
                    case .reader(let id): MacReaderRoute(documentID: id)
                    }
                }
        }
        .background(Theme.bg)
        // R10: VoiceOver cannot reach anything under the overlay, and
        // neither can the keyboard: macOS key-view focus ignores
        // accessibilityHidden, so a focused card would still open on Space
        // or Return, and offer Delete Book… (⌘⌫), behind the scrim.
        .accessibilityHidden(isImportOverlayShown)
        .disabled(isImportOverlayShown)
        .overlay {
            if isDropTargeted {
                MacDropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.press), value: isDropTargeted)
        // Above the whole stack, so the scrim covers the toolbar's content too.
        .overlay { MacImportOverlay(isRevealed: $isImportOverlayShown) }
        // Every screen, the whole window (mac-ux §2).
        .onDrop(of: [.fileURL], delegate: MacFileDropDelegate(isTargeted: $isDropTargeted) { urls in
            intake.admit(urls)
        })
        // Add from Files… (⌘O, the "+" and "Add a file"): PDF and plain
        // text, several at once. Here, not on the Library, so File ▸ Add
        // from Files… works over Classics and the reader too.
        .fileImporter(isPresented: filePickerShown,
                      allowedContentTypes: MacFileIntake.contentTypes,
                      allowsMultipleSelection: true) { result in
            // The panel is gone once it reports. Clear its flag now: a
            // failure alert waits on it.
            router.dismissRootPresentation(.filePicker)
            switch result {
            case .success(let urls): intake.admit(urls)
            case .failure(let error): importer.handlePick(.failure(error))
            }
        }
        // Finder's Open With and a drop on the Dock icon, when they arrive
        // as a URL: the bare Library first, as on the iPhone, so the
        // overlay, any failure and the opened reader have the window (a
        // second file of the same open finds it bare already). SwiftUI
        // hands several files over one at a time; the intake gathers them
        // into one batch, so they are all added and none opens.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            if let failure = Self.receiveOpened(url, router: router, intake: intake) {
                openFailure = failure
            }
        }
        // Fixed copy only: one sentence and its next step (R10). The
        // intake's failure (a file that never reached the importer) first.
        // A batch's failure names its file (L007).
        .alert(shownFailureTitle, isPresented: failureShown, presenting: shownFailure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.nextStep)
        }
        // The router's settings route is the Settings window here.
        .onChange(of: router.path) { _, path in
            guard path.last == .settings else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { _ = router.path.removeLast() }
            openSettings()
        }
        .task { await model.performLaunchTasks() }
        // From the first appearance: the pre-warm starts cold unless the app
        // was already active when AppModel was built (NeuralPrewarm).
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhaseChange(toBackground: phase == .background)
        }
        .onChange(of: scenePhase) { _, phase in
            // A stop recorded while the window was away is announced on return.
            if phase == .active { model.sceneBecameActive() }
        }
    }

    private var filePickerShown: Binding<Bool> {
        Binding(get: { router.rootPresentation == .filePicker },
                set: { shown in
                    if shown {
                        router.rootPresentation = .filePicker
                    } else {
                        router.dismissRootPresentation(.filePicker)
                    }
                })
    }

    /// One alert at a time; the iPhone's rule for waiting on a modal holds
    /// (`RootView.showsFailureAlert`'s twin: a failure waits while the
    /// panel, Rename or Delete is up).
    private var shownFailure: ImportFailure? {
        guard router.rootPresentation == nil else { return nil }
        return intake.failure ?? openFailure ?? importer.failure
    }

    /// `shownFailure`'s title, from the same source in the same order.
    private var shownFailureTitle: String {
        guard router.rootPresentation == nil else { return "" }
        return intake.failureTitle ?? openFailure?.title ?? importer.failureTitle ?? ""
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { shownFailure != nil },
                set: { shown in
                    guard !shown else { return }
                    if intake.failure != nil {
                        intake.dismissFailure()
                    } else if openFailure != nil {
                        openFailure = nil
                    } else {
                        importer.dismissFailure()
                    }
                })
    }

    /// One file from Open With. A type Aloud can add clears the window to
    /// the bare Library and goes to the intake. Any other (Open With ▸
    /// Other… forces one here, past Info.plist's types) leaves the window as
    /// it is, the reader and any Rename or Delete still up, and returns the
    /// failure to show: the intake would drop it without a word. Static, so
    /// the tests take the same steps.
    static func receiveOpened(_ url: URL, router: LibraryRouter, intake: MacFileIntake) -> ImportFailure? {
        guard MacFileIntake.isAddable(url) else { return .unsupportedType }
        router.clearForOpenIn()
        intake.admitOpened(url)
        return nil
    }
}

/// Resolves a reader route against the live library: a book deleted
/// meanwhile has no reader to show.
private struct MacReaderRoute: View {
    let documentID: UUID

    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        if store.documents.contains(where: { $0.id == documentID }) {
            // A different document is always a fresh reader.
            MacReaderScreen(documentID: documentID)
                .id(documentID)
        }
    }
}
