import SwiftUI

/// One shelf card: cover (PDF thumbnail or typographic cover for text books),
/// serif title, author, and a progress + time-left subtitle.
struct DocumentCardView: View {
    let document: LibraryDocument
    let rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DocumentCoverView(document: document)
                .aspectRatio(3 / 4.4, contentMode: .fit)
            details
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title). \(subtitle)")
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(document.title)
                .font(Theme.serif(16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let author = document.author {
                Text(author)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
    }

    /// The estimate itself is formatted by `LibraryDocument.listeningSubtitle`
    /// — shared with the Continue Listening hero; only the lead differs (a
    /// page count for PDFs, progress for books).
    private var subtitle: String {
        switch document.kind {
        case .pdf:
            let pages = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
            return document.listeningSubtitle(rate: rate, lead: pages)
        case .text:
            return document.listeningSubtitle(rate: rate)
        }
    }
}

// MARK: - Cover

/// Shared cover rendering: PDF thumbnail, typographic cover for text books,
/// or a plain document glyph. Fills whatever frame it's given — the grid card
/// gives it a 3:4.4 aspect, the Continue Listening card a compact 64×88.
struct DocumentCoverView: View {
    let document: LibraryDocument
    var compact = false
    var showsProgress = true

    @State private var thumbnail: UIImage?

    private var cornerRadius: CGFloat { compact ? Theme.Radius.sm : Theme.Radius.md }

    var body: some View {
        ZStack {
            if let thumbnail {
                Color.clear
                    .overlay(
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    )
            } else if document.kind == .text {
                typographicCover
            } else {
                Theme.surface2
                    .overlay(
                        Image(systemName: "doc.text")
                            .font(Theme.ui(compact ? 16 : 28, weight: .light))
                            .foregroundStyle(Theme.textFaint)
                    )
            }
        }
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .task(id: document.id) {
            thumbnail = await ThumbnailProvider.shared.thumbnail(for: document)
        }
    }

    /// Composed typographic cover for plain-text books — type only, no imagery.
    /// Serif title centered in the upper third over a thin accent rule; the
    /// author sits in small caps at the foot (dropped in compact, where it
    /// would fall below legibility). Tonal ground: accentSoft laid over
    /// surface so light and dark both read as one warm material.
    private var typographicCover: some View {
        ZStack {
            Theme.surface
            Theme.accentSoft
            VStack(spacing: 0) {
                Text(document.title)
                    .font(Theme.serif(compact ? 9 : 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.top, compact ? 10 : 26)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: compact ? 14 : 26, height: compact ? 1 : 1.5)
                    .padding(.top, compact ? 5 : 12)
                Spacer(minLength: compact ? 4 : 10)
                if let author = document.author, !compact {
                    Text(author.uppercased())
                        .font(Theme.serif(9.5, weight: .medium))
                        .kerning(1.4)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, compact ? 6 : 16)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if showsProgress, document.progressFraction > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Theme.line
                    Theme.accent
                        .frame(width: geo.size.width * min(max(document.progressFraction, 0), 1))
                }
            }
            .frame(height: 3)
        }
    }
}
