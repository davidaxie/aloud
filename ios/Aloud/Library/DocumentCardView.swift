import SwiftUI

/// One shelf card: cover (PDF thumbnail or typographic cover for text books),
/// serif title, author, and a progress + time-left subtitle.
struct DocumentCardView: View {
    let document: LibraryDocument
    let rate: Double

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            details
        }
        .task(id: document.id) {
            thumbnail = await ThumbnailProvider.shared.thumbnail(for: document)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title). \(subtitle)")
    }

    // MARK: Cover

    private var cover: some View {
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
                            .font(Theme.ui(28, weight: .light))
                            .foregroundStyle(Theme.textFaint)
                    )
            }
        }
        .aspectRatio(3 / 4.4, contentMode: .fit)
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    /// Composed typographic cover for plain-text books — type only, no imagery.
    /// Serif title centered in the upper third over a thin accent rule; the
    /// author sits in small caps at the foot. Tonal ground: accentSoft laid
    /// over surface so light and dark both read as one warm material.
    private var typographicCover: some View {
        ZStack {
            Theme.surface
            Theme.accentSoft
            VStack(spacing: 0) {
                Text(document.title)
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 26)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 26, height: 1.5)
                    .padding(.top, 12)
                Spacer(minLength: 10)
                if let author = document.author {
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
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if document.progressFraction > 0 {
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

    private var subtitle: String {
        let lead: String
        switch document.kind {
        case .pdf:
            lead = "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")"
        case .text:
            lead = "\(document.progressPercent)%"
        }
        guard let remaining = document.estimatedSecondsRemaining(rate: rate) else { return lead }
        if document.progressFraction >= 0.99 { return "\(lead) · Finished" }
        return "\(lead) · \(ListeningEstimate.phrase(seconds: remaining)) left"
    }
}

/// Shared "4 hr 52 min" formatting for listening-time estimates.
enum ListeningEstimate {
    static func phrase(seconds: TimeInterval) -> String {
        phrase(minutes: max(1, Int((seconds / 60).rounded())))
    }

    static func phrase(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours) hr \(rest) min" : "\(hours) hr"
    }
}
