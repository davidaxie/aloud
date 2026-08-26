import SwiftUI

/// The shelf. Root screen: adaptive grid of document cards sorted
/// last-listened-first, import entry points, and navigation into the reader.
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var importer = DocumentImporter()

    @State private var showImportSheet = false
    @State private var pushedDocument: LibraryDocument?
    @State private var isReaderPresented = false

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
                ReaderScreen(document: pushedDocument)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(importer: importer, onOpenDocument: openFromBookshelf)
                .presentationDetents([.medium, .large])
        }
        .onReceive(store.$documents) { documents in
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(store.documents) { document in
                    Button {
                        open(document)
                    } label: {
                        DocumentCardView(document: document, rate: playback.rate)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.card")
                    .contextMenu {
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
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 96)
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
                showImportSheet = true
            } label: {
                Text("Import")
                    .font(Theme.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(AccentCapsuleButtonStyle())
        }
        .padding(.bottom, 40)
    }

    // MARK: Chrome

    private var addButton: some View {
        Button {
            showImportSheet = true
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

    private func open(_ document: LibraryDocument) {
        store.noteOpened(id: document.id)
        pushedDocument = document
        isReaderPresented = true
    }

    /// Bookshelf "Open" lives inside the import sheet; let the sheet settle
    /// before pushing the reader.
    private func openFromBookshelf(_ document: LibraryDocument) {
        showImportSheet = false
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            open(document)
        }
    }
}
