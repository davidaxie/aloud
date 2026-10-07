import SwiftUI

/// One shelf card: the one 2:3 cover (R22), the serif title, the author and
/// the listening line ("4 hr 52 min", "1 hr 12 min left" or "Finished"; no
/// line when the length is unknown).
struct DocumentCardView: View {
    let document: LibraryDocument
    let rate: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            cover
            details
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: document, rate: rate))
    }

    /// "Title, Author, 1 hour 12 minutes left" (R12f, R25): the visible lines
    /// in order, with commas so VoiceOver pauses and durations spelled out.
    /// A missing author or an unknown length adds nothing, so the label
    /// never ends in a dangling comma.
    static func accessibilityLabel(for document: LibraryDocument, rate: Double) -> String {
        var parts = [document.title]
        if let author = document.author, !author.isEmpty { parts.append(author) }
        let spoken = document.spokenListeningSubtitle(rate: rate)
        if !spoken.isEmpty { parts.append(spoken) }
        return parts.joined(separator: ", ")
    }

    // MARK: Cover

    /// At the accessibility sizes the grid is one column, the screen's
    /// width, and a cover filling it (335x502pt on a 375pt phone) left about
    /// one book a screen, its title below the fold. There the cover keeps
    /// the Continue card's fixed size (`CoverGeometry.heroSize`), never
    /// scaled with Dynamic Type: the text below it is what grows.
    @ViewBuilder
    private var cover: some View {
        if dynamicTypeSize.isAccessibilitySize {
            DocumentCoverView(document: document)
                .frame(width: CoverGeometry.heroSize.width, height: CoverGeometry.heroSize.height)
        } else {
            DocumentCoverView(document: document)
        }
    }

    // MARK: Details

    /// At the accessibility sizes the grid is one column (LibraryView.columns)
    /// and the title and author wrap in full: two lines and one cut "The
    /// Strange Case of Dr. Jekyll and Mr. Hyde" and "Arthur Conan Doyle"
    /// short. fixedSize, as on the hero: inside a button label in a scroll
    /// view a Text can be offered less height than its lines need.
    private var details: some View {
        let wrapsInFull = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(document.title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.text)
                .lineLimit(wrapsInFull ? nil : 2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let author = document.author {
                Text(author)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(wrapsInFull ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A book of unknown length shows no line rather than an empty one.
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)   // wraps at large text sizes instead of truncating the time left
            }
        }
    }

    /// Formatted by `LibraryDocument.listeningSubtitle`, shared with the
    /// Continue Listening hero, so the two cards can never disagree.
    private var subtitle: String {
        document.listeningSubtitle(rate: rate)
    }
}
