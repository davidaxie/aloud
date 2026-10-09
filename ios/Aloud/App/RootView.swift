import SwiftUI

/// The Library's navigation stack, bound to the router, with the import
/// overlay and the import failure alert above all of it.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The import overlay has waited out its delay (`ImportOverlayReveal`):
    /// a quicker add shows nothing and leaves the shelf as it was.
    @State private var isOverlayRevealed = false

    var body: some View {
        NavigationStack(path: $router.path) {
            LibraryView()
                .navigationDestination(for: LibraryRouter.Route.self) { route in
                    switch route {
                    case .bookshelf: BookshelfView()
                    case .settings: SettingsView()
                    case .reader(let id): ReaderRoute(documentID: id)
                    }
                }
        }
        // The screens beneath hide themselves and their bar items while the
        // overlay is up, and only then.
        .environment(\.importOverlayRevealed, overlayShows)
        // R10: VoiceOver cannot reach anything under the overlay.
        .accessibilityHidden(overlayShows)
        // Above the WHOLE stack, so the scrim covers the nav bar too.
        .overlay { importLayer }
        // Keyed on the add as a whole: a queued file starts in the same turn
        // the last one ends, so a run of adds keeps the overlay up.
        .task(id: importer.isImporting) { await revealOnceSlow() }
        // The tint colors text — back buttons, bar buttons, alert and dialog
        // actions — so it is accentStrong. Controls that want the plain
        // accent (toggles, sliders, spinners) set their own tint.
        .tint(Theme.accentStrong)
        // "Open in Aloud" from Files, Mail or Safari (Info.plist declares
        // PDF and plain-text handlers).
        .onOpenURL { model.handleOpenURL($0) }
        // Fixed copy only: one sentence and its next step, never the error's
        // own text (R10).
        // A file that failed among several picked at once is named.
        .alert(importer.failureTitle ?? "", isPresented: failureShown,
               presenting: importer.failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.nextStep)
        }
        .task { await model.performLaunchTasks() }
        // From the first appearance too: the pre-warm starts out cold unless
        // the app was already active when AppModel was built (NeuralPrewarm).
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhaseChange(toBackground: phase == .background)
        }
        .onChange(of: scenePhase) { _, phase in
            // A stop recorded in the background is announced on return.
            if phase == .active { model.sceneBecameActive() }
        }
        #if DEBUG
        // UI-test launches only: what VoiceOver heard, which haptics played
        // and how many pastes the system control handed over (R3-03).
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                UITestProbeOverlay()
                PasteCallsProbe()
            }
        }
        #endif
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { Self.showsFailureAlert(failure: importer.failure,
                                              rootPresentation: router.rootPresentation) },
                set: { if !$0 { importer.dismissFailure() } })
    }

    /// A failure waits while the Library's picker, Rename alert or Delete
    /// dialog is up (a classic that fails while the user picks a file): an
    /// alert can't present over it, and one that silently failed to present
    /// would leave the importer holding its queue forever, since only the
    /// alert's OK clears a failure.
    static func showsFailureAlert(failure: ImportFailure?,
                                  rootPresentation: LibraryRouter.RootPresentation?) -> Bool {
        failure != nil && rootPresentation == nil
    }

    /// The overlay is up: revealed, and the add still under way.
    private var overlayShows: Bool { isOverlayRevealed && importer.isImporting }

    /// The overlay fades; under Reduce Motion it simply appears.
    private var importLayer: some View {
        ZStack {
            if isOverlayRevealed, case .importing(let name, let progress) = importer.phase {
                ImportProgressOverlay(fileName: name, progress: progress, onCancel: importer.cancel)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.crossfade),
                   value: overlayShows)
    }

    /// A display delay only: the add itself never waits on it. Hidden at
    /// once when the add ends. The wait is the root's, as the Mac overlay's
    /// is its own: the add path itself holds no timer (LibraryEntryLintTests).
    private func revealOnceSlow() async {
        let importer = importer
        let reveals = await ImportOverlayReveal.revealsAfterDelay(isBusy: { importer.isImporting }) {
            try await Task.sleep(for: $0)
        }
        guard !Task.isCancelled else { return }
        isOverlayRevealed = reveals
    }
}

/// Resolves a reader route against the live library: a book deleted
/// meanwhile has no reader to show.
private struct ReaderRoute: View {
    let documentID: UUID

    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        if let document = store.documents.first(where: { $0.id == documentID }) {
            // A different document is always a fresh reader: no loaded
            // content, playback wiring or progress target carries over.
            ReaderScreen(document: document)
                .id(documentID)
        }
    }
}
