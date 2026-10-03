import SwiftUI

/// The reader's page in phase 1 (M6): the book's title page, calm and
/// centered on paper. A large typographic cover (the shared `BookCover`, or
/// a PDF's first page), the title in the display serif, the author, and
/// where the voice is: the current chapter, or a PDF's pages. The cover
/// gives up height first, so a short window keeps every line of type.
/// Phase 2 replaces it with the TextKit 2 page.
struct MacReaderTitlePage: View {

    let document: LibraryDocument
    let navigation: ReaderNavigation
    /// The sentence being read (0 before anything loads).
    let playhead: Int

    /// The cover's largest width; 2:3, so 300 high.
    static let coverWidth: CGFloat = 200
    /// The type's measure: a title wraps before it reaches the window's edges.
    static let textWidth: CGFloat = 480

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            DocumentCoverView(document: document, showsProgress: false)
                .frame(maxWidth: Self.coverWidth, maxHeight: Self.coverWidth * 1.5)

            VStack(spacing: Theme.Space.xs) {
                Text(document.title)
                    .font(Theme.font(.display))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader.titlePage.title")
                if let author = document.author, !author.isEmpty {
                    Text(author)
                        .font(Theme.font(.headline))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let place = Self.place(in: navigation, at: playhead) {
                    // Serif like the rest of the page: the aside's italic.
                    Text(place)
                        .font(Theme.font(.aside))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, Theme.Space.sm)
                        .accessibilityIdentifier("reader.titlePage.chapter")
                }
            }
            .frame(maxWidth: Self.textWidth)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Where the voice is, as the chapter line names it: "Chapter IV" in a
    /// chaptered book, "Pages 12–14" in a PDF. nil in a book without
    /// chapters, whose title the page already shows.
    static func place(in navigation: ReaderNavigation, at sentence: Int) -> String? {
        let line = navigation.positionLine(at: sentence, rate: 1, documentTitle: "")
        if case .book = line.kind { return nil }
        return line.title.isEmpty ? nil : line.title
    }
}
