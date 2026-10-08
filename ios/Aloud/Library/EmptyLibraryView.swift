import SwiftUI

/// The one privacy line. R21's Settings footer reads the same constant, so
/// the promise is worded once.
enum PrivacyCopy {
    static let line = "Everything stays on your device."
}

/// The Library's standing notice while library.json can't be read (L011).
/// The detail names the device, so it is spelled in `DeviceCopy`.
enum UnreadableLibraryCopy {
    static let title = "Aloud couldn't read your library."
    static var detail: String { DeviceCopy.unreadableLibraryDetail }
}

/// Above the Library in both apps while library.json can't be read
/// (`DocumentStore.isIndexReadable`, L011). The shelf below shows only the
/// books whose records still decode, or the first-run screen, which would
/// read as every book gone; this says they are kept and what to try. It
/// stays until a launch reads the file: nothing on screen can mend it.
struct UnreadableLibraryNotice: View {
    /// The screen's side margin: the iPhone's gutter, the Mac's.
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.font(.callout))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs / 2) {
                Text(UnreadableLibraryCopy.title)
                    .font(Theme.font(.callout).weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(UnreadableLibraryCopy.detail)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(Theme.textMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .padding(.horizontal, gutter)
        .padding(.vertical, Theme.Space.xs)
        // On the paper, so a shelf scrolled beneath never shows round it.
        .background(Theme.bg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.unreadableNotice")
    }
}

/// R4: the empty Library's one featured short classic, so a new listener is
/// one tap from a voice.
enum FeaturedClassic {
    /// The Cask of Amontillado: about 14 minutes, and no chapter headings to
    /// read out before the story starts.
    static let gutenbergID = 1063

    /// The featured book, else the shortest one with a known length, so a
    /// catalog without 1063 still shows a card.
    static func resolve(in catalog: [BookshelfBook]) -> BookshelfBook? {
        catalog.first { $0.gutenbergID == gutenbergID }
            ?? catalog.lazy.filter { $0.words > 0 }.min { $0.words < $1.words }
    }

    /// "Edgar Allan Poe · 14 min" at 1×.
    static func subtitle(for book: BookshelfBook, rate: Double) -> String {
        "\(book.author) · \(ListeningEstimate.phrase(minutes: minutes(of: book, rate: rate)))"
    }

    /// "The Cask of Amontillado, Edgar Allan Poe, 14 minutes": commas, not
    /// middle dots, so VoiceOver pauses, and the duration spelled out.
    static func accessibilityLabel(for book: BookshelfBook, rate: Double) -> String {
        "\(book.title), \(book.author), \(ListeningEstimate.spokenPhrase(minutes: minutes(of: book, rate: rate)))"
    }

    /// Whole-book length at the app-wide speed, like every shelf estimate.
    private static func minutes(of book: BookshelfBook, rate: Double) -> Int {
        ListeningEstimate.minutes(words: book.words,
                                  wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate)
    }
}

/// The featured classic in the Continue card's shape: it is the card the
/// book becomes once it has been listened to.
struct FeaturedClassicCard: View {
    let book: BookshelfBook
    let rate: Double

    var body: some View {
        ShelfHeroCard(title: book.title, subtitle: FeaturedClassic.subtitle(for: book, rate: rate)) {
            BookCover(title: book.title, author: book.author)
        } accessory: {
            PlayCircleGlyph()
        }
    }
}

/// The Library with no books: the featured classic, its text links and the
/// privacy line, centered while it fits and scrolling once it doesn't
/// (AX5). No heading and no other copy; the play circle is the screen's
/// only accent-filled element.
struct EmptyLibraryView: View {
    let onAddFile: () -> Void
    /// Adds the clipboard's text as a book; its link shows only when set
    /// (the iPhone, while there is text to paste).
    var onPasteText: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter
    @EnvironmentObject private var importer: DocumentImporter

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    if let book = FeaturedClassic.resolve(in: model.bookshelf) {
                        featuredButton(for: book)
                    }
                    links
                    Text(PrivacyCopy.line)
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, Theme.Space.screenGutter)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .shelfScrollEdge(rule: true)
        }
    }

    /// One tap adds the classic; the importer then opens it, playing (R4).
    /// Disabled while the add runs, so a double tap adds one copy. The soft
    /// haptic answers a tap that will start a voice (R20): not one the
    /// importer will ignore, nor one in a launch where nothing autoplays.
    private func featuredButton(for book: BookshelfBook) -> some View {
        Button {
            if importer.addingClassicID == nil, importer.phase == .idle,
               !model.playback.isAutoplaySuppressed {
                TransportHaptics.emit(.play)
            }
            importer.addClassic(book)
        } label: {
            FeaturedClassicCard(book: book, rate: model.globalRate)
        }
        // A paper plate under the finger, round the card's corners.
        .buttonStyle(ShelfPlateButtonStyle(radius: Theme.Radius.lg))
        .disabled(importer.addingClassicID != nil)
        .accessibilityLabel(FeaturedClassic.accessibilityLabel(for: book, rate: model.globalRate))
        .accessibilityHint("Opens and starts reading aloud")
        .accessibilityIdentifier("library.featured")
    }

    /// Side by side while they fit, stacked at the large text sizes.
    private var links: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xl) { linkButtons }
            VStack(spacing: Theme.Space.xs) { linkButtons }
        }
    }

    @ViewBuilder
    private var linkButtons: some View {
        if !model.bookshelf.isEmpty {
            link("More classics", identifier: "library.moreClassics") { router.showBookshelf() }
        }
        link("Add a file", identifier: "library.addFile", action: onAddFile)
        if let onPasteText {
            link(PasteTextAction.linkTitle, identifier: "library.pasteText", action: onPasteText)
        }
    }

    /// Accent text is accentStrong; the label is padded out to a 44pt target.
    private func link(_ title: String, identifier: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(.callout).weight(.medium))
                .foregroundStyle(Theme.accentStrong)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.sm)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
