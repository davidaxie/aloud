import SwiftUI

/// The bundled Classics Bookshelf. One tap copies a public-domain book into
/// the library — instant and offline — after which the row offers Open.
struct BookshelfView: View {
    var onOpen: (LibraryDocument) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: DocumentStore

    @State private var addingIDs: Set<Int> = []
    @State private var justAddedIDs: Set<Int> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(model.bookshelf) { book in
                    row(for: book)
                        .listRowBackground(Theme.bg)
                        .listRowSeparatorTint(Theme.line)
                }
            } header: {
                Text("Classic literature, bundled with Aloud. All offline.")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(nil)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .listStyle(.plain)
        .background(Theme.bg.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Classics Bookshelf")
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .alert("Couldn't add book", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Row

    private func row(for book: BookshelfBook) -> some View {
        HStack(spacing: 14) {
            miniCover(for: book)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(byline(for: book))
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Text("~\(ListeningEstimate.phrase(minutes: book.estimatedListeningMinutes))")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 10)
            trailingControl(for: book)
        }
        .padding(.vertical, 8)
    }

    private func miniCover(for book: BookshelfBook) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(Theme.accentSoft)
            .frame(width: 44, height: 58)
            .overlay(
                Text(String(book.title.prefix(1)))
                    .font(Theme.serif(22, weight: .semibold))
                    .foregroundStyle(Theme.accentStrong)
            )
    }

    private func byline(for book: BookshelfBook) -> String {
        book.year.map { "\(book.author) · \(String($0))" } ?? book.author
    }

    @ViewBuilder
    private func trailingControl(for book: BookshelfBook) -> some View {
        if addingIDs.contains(book.id) {
            ProgressView()
                .tint(Theme.accent)
                .frame(width: 56)
        } else if justAddedIDs.contains(book.id) {
            Image(systemName: "checkmark")
                .font(Theme.ui(14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 56)
                .transition(.opacity)
        } else if let document = libraryDocument(for: book) {
            capsuleButton("Open", filled: false) { onOpen(document) }
        } else {
            capsuleButton("Add", filled: true) { add(book) }
        }
    }

    private func capsuleButton(_ label: String, filled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.ui(13, weight: .semibold))
                .foregroundStyle(filled ? Theme.bg : Theme.accentStrong)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(filled ? Theme.accent : Theme.accentSoft))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 56)
    }

    // MARK: State

    private func libraryDocument(for book: BookshelfBook) -> LibraryDocument? {
        store.documents.first {
            $0.kind == .text && $0.title == book.title && $0.author == book.author
        }
    }

    private func add(_ book: BookshelfBook) {
        addingIDs.insert(book.id)
        Task {
            do {
                _ = try await store.addClassic(book)
                addingIDs.remove(book.id)
                withAnimation(.easeOut(duration: 0.2)) {
                    _ = justAddedIDs.insert(book.id)
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut(duration: 0.2)) {
                    _ = justAddedIDs.remove(book.id)
                }
            } catch {
                addingIDs.remove(book.id)
                errorMessage = error.localizedDescription
            }
        }
    }
}
