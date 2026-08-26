import SwiftUI

/// Full-width Continue Listening hero above the shelf grid: compact cover,
/// serif title, a "43% · 1 hr 12 min left" line, and an accent play circle.
/// Purely visual — the whole card is one button in LibraryView, which opens
/// the reader and starts playback immediately.
struct ContinueListeningCard: View {
    let document: LibraryDocument
    let rate: Double

    var body: some View {
        HStack(spacing: 16) {
            DocumentCoverView(document: document, compact: true, showsProgress: false)
                .frame(width: 64, height: 88)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Decorative echo of AccentCircleButtonStyle — the card itself
            // is the button, so this stays a plain 44pt accent circle.
            Circle()
                .fill(Theme.accent)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Continue listening. \(document.title). \(subtitle)")
    }

    /// Shared with the grid card (`LibraryDocument.listeningSubtitle`) so the
    /// hero and the card right below it always phrase the estimate identically.
    private var subtitle: String {
        document.listeningSubtitle(rate: rate)
    }
}
