import SwiftUI
import UniformTypeIdentifiers

/// Bridges file-picker results into the DocumentStore, publishing extraction
/// progress for the import overlay and the finished document for auto-open.
@MainActor
final class DocumentImporter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case importing(fileName: String, progress: Double)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed: LibraryDocument?

    var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    func handlePickResult(_ result: Result<[URL], Error>, store: DocumentStore) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importFile(at: url, store: store)
        case .failure(let error):
            phase = .failed(message: error.localizedDescription)
        }
    }

    func importFile(at url: URL, store: DocumentStore) {
        guard !isImporting else { return }
        let fileName = url.lastPathComponent
        phase = .importing(fileName: fileName, progress: 0)

        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, case .importing(let name, _) = self.phase else { return }
                self.phase = .importing(fileName: name, progress: value)
            }
        }

        Task {
            do {
                let document: LibraryDocument
                if url.pathExtension.lowercased() == "pdf" {
                    document = try await store.importPDF(from: url, progress: onProgress)
                } else {
                    document = try await store.importText(title: Self.title(from: url),
                                                          from: url,
                                                          progress: onProgress)
                }
                phase = .idle
                completed = document
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func acknowledgeCompletion() { completed = nil }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// "moby-dick_ch1.txt" → "Moby Dick Ch1"
    private static func title(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return url.lastPathComponent }
        return base == base.lowercased() ? base.localizedCapitalized : base
    }
}

/// Progress card shown over the Library while extraction runs.
struct ImportProgressOverlay: View {
    let fileName: String
    let progress: Double

    var body: some View {
        ZStack {
            Theme.text.opacity(0.18)
                .ignoresSafeArea()
            card
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(fileName), \(percent) percent")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preparing")
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .textCase(.uppercase)
                .kerning(0.8)
            Text(fileName)
                .font(Theme.ui(15, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 4)
                Text("\(percent)%")
                    .font(Theme.ui(12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.text.opacity(0.12), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .padding(32)
    }

    private var percent: Int { Int((min(max(progress, 0), 1) * 100).rounded()) }
}
