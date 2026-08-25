import SwiftUI
import UniformTypeIdentifiers

/// Medium-detent "Add to Library" sheet: Files import, the bundled Classics
/// Bookshelf, and ghost rows for what's coming next.
struct ImportSheet: View {
    @ObservedObject var importer: DocumentImporter
    var onOpenDocument: (LibraryDocument) -> Void

    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ImportRow(icon: "doc.fill",
                              title: "From Files",
                              subtitle: "PDF or plain text") {
                        showFilePicker = true
                    }
                    NavigationLink {
                        BookshelfView(onOpen: onOpenDocument)
                    } label: {
                        ImportRowLabel(icon: "books.vertical.fill",
                                       title: "Classics Bookshelf",
                                       subtitle: "Bundled with Aloud, ready instantly")
                    }
                    .buttonStyle(.plain)
                    ImportRowLabel(icon: "doc.viewfinder",
                                   title: "Scan pages",
                                   subtitle: "Soon",
                                   ghost: true)
                    ImportRowLabel(icon: "text.quote",
                                   title: "Paste text",
                                   subtitle: "Soon",
                                   ghost: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Theme.bgTint.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add to Library")
                        .font(Theme.serif(17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Theme.ui(15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.pdf, .plainText],
                      allowsMultipleSelection: false) { result in
            importer.handlePickResult(result, store: store)
            dismiss()
        }
    }
}

// MARK: - Rows

private struct ImportRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ImportRowLabel(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportRowLabel: View {
    let icon: String
    let title: String
    let subtitle: String
    var ghost = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(ghost ? Theme.surface2 : Theme.accentSoft)
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: icon)
                        .font(Theme.ui(17, weight: .medium))
                        .foregroundStyle(ghost ? Theme.textFaint : Theme.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.ui(16, weight: .medium))
                    .foregroundStyle(ghost ? Theme.textFaint : Theme.text)
                Text(subtitle)
                    .font(Theme.ui(13))
                    .foregroundStyle(ghost ? Theme.textFaint : Theme.textMuted)
            }
            Spacer()
            if !ghost {
                Image(systemName: "chevron.right")
                    .font(Theme.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}
