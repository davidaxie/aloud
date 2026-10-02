import SwiftUI

/// The Library's navigation stack, bound to the router, with the import
/// overlay and the import failure alert above all of it.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // R10: VoiceOver cannot reach anything under the overlay.
        .accessibilityHidden(importer.isImporting)
        // Above the WHOLE stack, so the scrim covers the nav bar too.
        .overlay { importLayer }
        // The tint colors text — back buttons, bar buttons, alert and dialog
        // actions — so it is accentStrong. Controls that want the plain
        // accent (toggles, sliders, spinners) set their own tint.
        .tint(Theme.accentStrong)
        // "Open in Aloud" from Files, Mail or Safari (Info.plist declares
        // PDF and plain-text handlers).
        .onOpenURL { model.handleOpenURL($0) }
        // Fixed copy only: one sentence and its next step, never the error's
        // own text (R10).
        .alert(importer.failure?.title ?? "", isPresented: failureShown,
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
        // UI-test launches only: what VoiceOver heard and which haptics played.
        .overlay(alignment: .bottomTrailing) { UITestProbeOverlay() }
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

    /// The overlay fades; under Reduce Motion it simply appears.
    private var importLayer: some View {
        ZStack {
            if case .importing(let name, let progress) = importer.phase {
                ImportProgressOverlay(fileName: name, progress: progress, onCancel: importer.cancel)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.crossfade),
                   value: importer.isImporting)
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
