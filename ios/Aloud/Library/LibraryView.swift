import SwiftUI

/// The shelf. Root screen: adaptive grid of document cards sorted
/// last-listened-first, import entry points, and navigation into the reader.
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var importer = DocumentImporter()

    /// Import-sheet presentation: nil = closed, otherwise which screen the
    /// sheet opens on. One optional value instead of a Bool paired with a
    /// destination, so a stale destination is unrepresentable.
    enum ImportPresentation: String, Identifiable {
        case root, bookshelf

        var id: String { rawValue }

        var destination: ImportSheet.Destination? {
            self == .bookshelf ? .bookshelf : nil
        }
    }

    @State private var importPresentation: ImportPresentation?
    @State private var pushedDocument: LibraryDocument?
    /// Rides the push alongside `pushedDocument`: the Continue Listening
    /// hero's request to start speaking on arrival. Every other entry point
    /// goes through `open(_:)` with the default `false`, so the request can
    /// never leak into the next document.
    @State private var pushedAutoplay = false
    @State private var isReaderPresented = false

    /// Hero + grid split, memoized against the store's publishes — the split
    /// scans the whole library, so it runs once per documents change and
    /// never per body re-run.
    @State private var shelf = ShelfLayout.empty

    @State private var renameTarget: LibraryDocument?
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var deleteTarget: LibraryDocument?
    @State private var isConfirmingDelete = false

    @State private var didAutoOpen = false

    private let columns = [GridItem(.flexible(), spacing: 15),
                           GridItem(.flexible(), spacing: 15)]

    var body: some View {
        Group {
            if store.documents.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .bottomTrailing) { addButton }
        .overlay { importOverlay }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Text("Aloud")
                    .font(Theme.serif(22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                        .font(Theme.ui(16, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(isPresented: $isReaderPresented) {
            if let pushedDocument {
                ReaderScreen(document: pushedDocument, autoplay: pushedAutoplay)
            }
        }
        .sheet(item: $importPresentation) { presentation in
            ImportSheet(importer: importer,
                        initialDestination: presentation.destination,
                        onOpenDocument: openFromBookshelf)
                .presentationDetents([.medium, .large])
        }
        .onReceive(store.$documents) { documents in
            shelf = ShelfLayout(for: documents)

            // Screenshot/debug hook (no-op in Release): jump straight into
            // the first document.
            guard UITestHooks.openFirstDoc,
                  !didAutoOpen, let first = documents.first else { return }
            didAutoOpen = true
            Task {   // let the NavigationStack attach before pushing
                try? await Task.sleep(nanoseconds: 300_000_000)
                open(first)
            }
        }
        .onChange(of: importer.completed?.id) { _ in
            guard let document = importer.completed else { return }
            importer.acknowledgeCompletion()
            open(document)
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let target = renameTarget { store.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleteTarget?.title ?? "")\u{201D}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { store.delete(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the document and its listening progress.")
        }
        .alert("Couldn't import", isPresented: .init(
            get: { if case .failed = importer.phase { return true } else { return false } },
            set: { if !$0 { importer.dismissFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let message) = importer.phase { Text(message) }
        }
    }

    // MARK: Grid

    /// Every card's time-left estimate runs at THAT book's effective speed —
    /// its own per-book pin, else the global default. The controller's live
    /// rate belongs to whichever book was last loaded and would put the shelf
    /// at odds with the reader.
    private func estimateRate(for document: LibraryDocument) -> Double {
        document.effectiveRate(globalDefault: model.globalRate)
    }

    private var grid: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let hero = shelf.hero {
                    continueCard(for: hero)
                }
                documentGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 96)
        }
    }

    private func continueCard(for document: LibraryDocument) -> some View {
        Button {
            open(document, autoplay: true)
        } label: {
            ContinueListeningCard(document: document, rate: estimateRate(for: document))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.continue")
        // The hero is lifted OUT of the grid, so it carries the same
        // management affordances its grid card would have given it.
        .contextMenu { documentActions(for: document) }
    }

    private var documentGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(shelf.grid) { document in
                Button {
                    open(document)
                } label: {
                    DocumentCardView(document: document, rate: estimateRate(for: document))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.card")
                .contextMenu { documentActions(for: document) }
            }
        }
    }

    /// Rename / Delete: ONE implementation, attached to every surface that
    /// stands in for a document — grid card and Continue Listening hero
    /// alike — so no book can be shown without a way to manage it.
    @ViewBuilder
    private func documentActions(for document: LibraryDocument) -> some View {
        Button {
            renameTarget = document
            renameText = document.title
            isRenaming = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteTarget = document
            isConfirmingDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Theme.accentSoft)
                .frame(width: 92, height: 92)
                .overlay(
                    Text("A")
                        .font(Theme.serif(44, weight: .semibold))
                        .foregroundStyle(Theme.accentStrong)
                )
                .padding(.bottom, 28)
            Text("Add something to read")
                .font(Theme.serif(24, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 8)
            Text("Everything stays on your device.")
                .font(Theme.ui(15))
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 32)
            Button {
                importPresentation = .root
            } label: {
                Text("Import")
                    .font(Theme.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(AccentCapsuleButtonStyle())
            Button {
                importPresentation = .bookshelf
            } label: {
                Text("Browse the Classics Bookshelf")
                    .font(Theme.ui(15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("library.browseClassics")
            .padding(.top, 12)
            Text(classicsCaption)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textFaint)
                .padding(.top, 4)
        }
        .padding(.bottom, 40)
    }

    /// Counted from the shipped catalog, never a literal — the bookshelf is
    /// grown by a scheduled Gutenberg top-up, and the app's first screen must
    /// not promise a stale number.
    private var classicsCaption: String {
        let count = model.bookshelf.count
        guard count > 0 else { return "Classics bookshelf · everything offline" }
        return "\(count) classic\(count == 1 ? "" : "s") included · everything offline"
    }

    // MARK: Chrome

    private var addButton: some View {
        Button {
            importPresentation = .root
        } label: {
            Image(systemName: "plus")
                .font(Theme.ui(22, weight: .semibold))
                .foregroundStyle(Theme.bg)
        }
        .buttonStyle(AccentCircleButtonStyle(diameter: 54))
        .shadow(color: Theme.text.opacity(0.18), radius: 12, y: 4)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel("Add a document")
    }

    @ViewBuilder
    private var importOverlay: some View {
        if case .importing(let fileName, let progress) = importer.phase {
            ImportProgressOverlay(fileName: fileName, progress: progress)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
        }
    }

    // MARK: Navigation

    /// `autoplay` is the Continue Listening hero's request to start speaking
    /// on arrival. It travels as a ReaderScreen parameter rather than shared
    /// app state, so every other entry point (grid card, bookshelf, importer,
    /// UI-test hook) clears it by construction.
    private func open(_ document: LibraryDocument, autoplay: Bool = false) {
        store.noteOpened(id: document.id)
        pushedDocument = document
        pushedAutoplay = autoplay
        isReaderPresented = true
    }

    /// Bookshelf "Open" lives inside the import sheet; let the sheet settle
    /// before pushing the reader.
    private func openFromBookshelf(_ document: LibraryDocument) {
        importPresentation = nil
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            open(document)
        }
    }
}
