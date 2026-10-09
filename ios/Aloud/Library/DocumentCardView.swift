import SwiftUI

/// One shelf card: the one 2:3 cover (R22) over its caption. A typographic
/// cover already sets the title and the author, so below xxLarge a text
/// book's caption is the listening line alone (its length, the time left,
/// or finished; no line when the length is unknown), and each book is
/// named once (R2-30). A PDF's cover is its page, so its card always sets
/// the serif title, the author and the listening line, as every card does
/// from xxLarge, where they wrap in full (`showsCaption`). Both apps.
struct DocumentCardView: View {
    let document: LibraryDocument
    let rate: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            cover
            details
        }
        // The whole cell is the card: at the accessibility sizes the 64pt
        // cover left a blank band beside it that a plain button ignored, and
        // a short title's card sat centred in its column (J014).
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: document, rate: rate))
    }

    /// Whether the card keeps the Continue card's fixed cover
    /// (`CoverGeometry.heroSize`) instead of filling its column: at the
    /// accessibility sizes, where the grid is one column. The shelf's long
    /// press lifts the same cover (`CoverLiftShape`), so the two read this
    /// one rule.
    static func usesHeroCover(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// Whether a card's title and author wrap in full rather than stop at
    /// two lines and one: from xxLarge, the largest sizes below the
    /// accessibility range, where a phone's two columns cut a long author's
    /// name and a classic's title short (L016). The hero's title follows.
    static func wrapsInFull(at size: DynamicTypeSize) -> Bool {
        size >= .xxLarge
    }

    /// Whether the card sets the title and author under its cover (R2-30):
    /// always for a PDF, whose cover is a page that may set neither; and
    /// from xxLarge, where they wrap in full (the accessibility sizes among
    /// them, whose 64pt hero cover is textless). Below that a text book's
    /// cover already names it, and the card adds only the listening line.
    /// Keyed on the record's kind, never on the art drawn, so a PDF's card
    /// never reflows when its page lands or fails to.
    static func showsCaption(kind: DocKind, at size: DynamicTypeSize) -> Bool {
        kind == .pdf || wrapsInFull(at: size)
    }

    /// What Voice Control answers to ("Tap The Great Gatsby"): the title
    /// alone, since the label's time left changes as you listen (J017).
    static func inputLabels(for document: LibraryDocument) -> [String] {
        [document.title]
    }

    /// The title, the author and the listening line, in that order (R12f,
    /// R25), with commas so VoiceOver pauses and durations spelled out:
    /// the book as its cover and caption show it together, so the label
    /// is the same whether the caption repeats the title or not (R2-30).
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
        if Self.usesHeroCover(at: dynamicTypeSize) {
            DocumentCoverView(document: document)
                .frame(width: CoverGeometry.heroSize.width, height: CoverGeometry.heroSize.height)
        } else {
            DocumentCoverView(document: document)
        }
    }

    // MARK: Details

    /// The full caption where `showsCaption` says so, else the listening
    /// line alone: the typographic cover above already sets the title and
    /// the author (R2-30). A book of unknown length then shows no caption.
    @ViewBuilder
    private var details: some View {
        if Self.showsCaption(kind: document.kind, at: dynamicTypeSize) {
            caption
        } else if !subtitle.isEmpty {
            listeningLine
        }
    }

    /// The listening line in the caption face: textFaint on the solid
    /// ground (4.6:1 or better on bg in both modes), wrapping at large text
    /// sizes instead of truncating the time left.
    private var listeningLine: some View {
        Text(subtitle)
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.textFaint)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    /// From xxLarge up the title and author wrap in full: two lines and one
    /// cut a long classic's title and a long author's name short, in the
    /// two columns those sizes keep as in the one the accessibility sizes
    /// get (LibraryView.columns). fixedSize, as on the hero: inside a
    /// button label in a scroll view a Text can be offered less height
    /// than its lines need.
    private var caption: some View {
        let wrapsInFull = Self.wrapsInFull(at: dynamicTypeSize)
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
