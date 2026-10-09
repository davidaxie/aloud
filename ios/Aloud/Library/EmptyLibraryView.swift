import SwiftUI

/// The one privacy line. R21's Settings footer reads the same constant, so
/// the promise is worded once.
enum PrivacyCopy {
    static let line = "Everything stays on your device."
}

/// The Library's standing notice while library.json can't be read (L011).
/// The detail names the device, so it is spelled in `DeviceCopy`.
enum UnreadableLibraryCopy {
    static let title = "Aloud couldn’t read your library."
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

    /// The card's eyebrow, drawn uppercased as the Continue card's is: it
    /// says what the card is before the title says which book.
    static let eyebrow = "Start with a classic"

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

    /// The eyebrow, then "The Cask of Amontillado, Edgar Allan Poe, 14
    /// minutes": the visible text in order, commas, not middle dots, so
    /// VoiceOver pauses, and the duration spelled out.
    static func accessibilityLabel(for book: BookshelfBook, rate: Double) -> String {
        "\(eyebrow), \(book.title), \(book.author), \(ListeningEstimate.spokenPhrase(minutes: minutes(of: book, rate: rate)))"
    }

    /// What Voice Control answers to: the title, as on every card, or the
    /// eyebrow. The label leads with the eyebrow, so the title alone would
    /// match nothing otherwise.
    static func inputLabels(title: String) -> [String] {
        [title, eyebrow]
    }

    /// Whole-book length at the app-wide speed, like every shelf estimate.
    private static func minutes(of book: BookshelfBook, rate: Double) -> Int {
        ListeningEstimate.minutes(words: book.words,
                                  wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate)
    }
}

/// The featured classic in the Continue card's shape: it is the card the
/// book becomes once it has been listened to, with its own eyebrow.
struct FeaturedClassicCard: View {
    let book: BookshelfBook
    let rate: Double

    var body: some View {
        ShelfHeroCard(eyebrow: FeaturedClassic.eyebrow, title: book.title,
                      subtitle: FeaturedClassic.subtitle(for: book, rate: rate)) {
            BookCover(title: book.title, author: book.author)
        } accessory: {
            PlayCircleGlyph()
        }
    }
}

/// The Library with no books: the featured classic under its eyebrow, the
/// shelf's text links and the privacy line, at the optical centre while it
/// fits (`OpticalCenterColumn`, R4-22) and scrolling once it doesn't (AX5).
/// No heading; the play circle is the screen's only accent-filled element.
struct EmptyLibraryView: View {
    let onAddFile: () -> Void
    /// Adds the clipboard's text as a book; its paste control shows only
    /// when set (the iPhone, while there is text to paste).
    var onPaste: (([String]) -> Void)? = nil
    /// A paste that found no text: the clipboard is looked at again.
    var onPasteEmpty: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var importer: DocumentImporter

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    if let book = FeaturedClassic.resolve(in: model.bookshelf) {
                        featuredButton(for: book)
                    }
                    // R3-06: the formats Add a file takes, a sentence of
                    // its own under the row, since the row holds three links.
                    VStack(spacing: Theme.Space.xs) {
                        ShelfLinks(onAddFile: onAddFile, onPaste: onPaste, onPasteEmpty: onPasteEmpty,
                                   idPrefix: "library")
                        FileFormatsCaption()
                    }
                    Text(PrivacyCopy.line)
                        .font(Theme.font(.aside))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, Theme.Space.screenGutter)
                .padding(.vertical, Theme.Space.xl)
                // R4-22: a little above the true centre, which read low
                // under the bar's tall chrome.
                .opticalCenter(minHeight: proxy.size.height)
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
        .accessibilityInputLabels(FeaturedClassic.inputLabels(title: book.title))
        .accessibilityHint("Opens and starts reading aloud")
        .accessibilityIdentifier("library.featured")
    }
}

/// R4-22: one block in a column at least `minHeight` tall, set at the
/// optical centre rather than the true one: `bias` of the slack above it
/// and the rest below. Centred in the scroll height, the empty Library's
/// block sat low on the iPhone, its centre at 55% of the screen, since the
/// bar's chrome above it is much taller than the home indicator's inset
/// below. Both apps' empty Libraries (`opticalCenter(minHeight:)`).
///
/// Stateless, measured in one pass, so nothing moves after the first frame
/// or on a text size change. A block taller than `minHeight` (AX5) starts
/// at the top and scrolls, as it did centred.
struct OpticalCenterColumn: Layout {
    let minHeight: CGFloat
    var bias: CGFloat = 0.42

    /// The block's offset from the column's top: `bias` of the room left
    /// over in `available`, never above the top.
    static func offset(blockHeight: CGFloat, in available: CGFloat, bias: CGFloat = 0.42) -> CGFloat {
        max(0, (available - blockHeight) * bias)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let block = subviews.first else { return CGSize(width: proposal.width ?? 0, height: minHeight) }
        let size = block.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let block = subviews.first else { return }
        let size = block.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let top = bounds.minY + Self.offset(blockHeight: size.height, in: bounds.height, bias: bias)
        block.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top,
                    proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

extension View {
    /// This view at the optical centre of a column at least `minHeight`
    /// tall, across the full width (`OpticalCenterColumn`): the empty
    /// Library's block on both apps, in place of a centring min-height frame.
    func opticalCenter(minHeight: CGFloat) -> some View {
        OpticalCenterColumn(minHeight: minHeight) { self }
            .frame(maxWidth: .infinity)
    }
}

/// The shelf's quiet text links: to Classics (while there is a catalog), to
/// the Files picker and, when `onPaste` is set (the iPhone, while the
/// clipboard holds text), the system's paste control.
/// Under the empty Library's featured classic (`library.*`), and at the foot
/// of a shelf that holds books (`library.shelf.*`), so the way to the next
/// book stays in reach without the + menu.
struct ShelfLinks: View {
    let onAddFile: () -> Void
    /// Takes the pasted strings; the paste control shows only when set.
    let onPaste: (([String]) -> Void)?
    /// A paste that found no text (`PlatformPasteControl.onEmpty`).
    var onPasteEmpty: (() -> Void)? = nil
    /// Each link's identifier is the prefix and its name.
    let idPrefix: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: LibraryRouter

    /// Side by side while they fit, stacked at the large text sizes.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xl) { linkButtons }
            VStack(spacing: Theme.Space.xs) { linkButtons }
        }
    }

    @ViewBuilder
    private var linkButtons: some View {
        if !model.bookshelf.isEmpty {
            link("More classics", identifier: "\(idPrefix).moreClassics") { router.showBookshelf() }
        }
        link("Add a file", identifier: "\(idPrefix).addFile", hint: LibraryAddMenuItem.fileFormatsHint,
             action: onAddFile)
        if let onPaste {
            pasteControl(onPaste)
        }
    }

    /// Accent text is accentStrong; the label is padded out to a 44pt target.
    /// A hint, when given, is VoiceOver's (Add a file names its formats).
    /// Each link is a press (TransportHaptics); the paste control beside
    /// them is the system's own, its tap left as the system makes it.
    private func link(_ title: String, identifier: String, hint: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button {
            TransportHaptics.emit(.press)
            action()
        } label: {
            Text(title)
                .font(Theme.font(.callout).weight(.medium))
                .foregroundStyle(Theme.accentStrong)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.sm)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint.map { Text($0) } ?? Text(""))
        .accessibilityIdentifier(identifier)
    }

    /// The system's prompt-free paste: it reads the clipboard on the tap,
    /// with no Allow Paste prompt. Drawn as a third accent link on the
    /// page's own ground (`PlatformPasteControl`), level with the two
    /// beside it, so the featured card's Play stays the screen's one accent
    /// fill. The control takes the 44pt frame its representable asks for.
    /// Only the iPhone hands this an onPaste.
    private func pasteControl(_ onPaste: @escaping ([String]) -> Void) -> some View {
        PlatformPasteControl(onPaste: onPaste, identifier: "\(idPrefix).pasteText", onEmpty: onPasteEmpty)
    }
}

/// R3-06: the empty Library's line naming what Add a file accepts, under
/// the link row and over the privacy line, on both apps. Its own sentence,
/// quiet, centred; never at a shelf's foot.
struct FileFormatsCaption: View {
    var body: some View {
        Text(LibraryAddMenuItem.fileFormatsCaption)
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("library.fileFormats")
    }
}
