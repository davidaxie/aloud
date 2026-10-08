import SwiftUI

// MARK: - Geometry

/// The one cover's numbers (R22), pure so tests and the lock-screen art
/// read the same rules the views draw with.
enum CoverGeometry {
    /// Width over height: every cover is a 2:3 book.
    static let aspectRatio: CGFloat = 2.0 / 3.0
    /// Narrower than this, type would fall below legibility, so a
    /// typographic cover draws only its ground and rule. A PDF's page is a
    /// picture, not type, and draws at every width.
    static let minimumTextWidth: CGFloat = 80
    /// The Continue card's cover, beside its own title. Fixed, never scaled
    /// with Dynamic Type: the title next to it is the text that grows.
    static let heroSize = CGSize(width: 64, height: 96)
    static let progressBarHeight: CGFloat = 3
    /// Where the plain face's rule sits, as a fraction of the height: where
    /// a grid cover's rule sits under a two-line title.
    static let plainRuleTop: CGFloat = 1.0 / 3.0
    /// The plain face's rule, as a fraction of the cover's width: the grid
    /// cover's rule scaled down with it, so a 64pt cover reads as a small
    /// book rather than an empty tile.
    static let plainRuleWidthFraction: CGFloat = 0.4
    /// The lock-screen square, in points, and the scale it renders at.
    static let artworkSide: CGFloat = 300
    static let artworkScale: CGFloat = 3
    /// The cover's height as a fraction of the lock-screen square.
    static let artworkCoverFraction: CGFloat = 0.8
    /// The author line's side inset on a cover with type: a little under
    /// the title's (Theme.Space.md), so a long name's longest word still
    /// fits whole, at full size, on the narrowest grid cover (the Mac's
    /// 136pt). Both apps.
    static let authorInset: CGFloat = Theme.Space.sm

    static func showsText(width: CGFloat) -> Bool { width >= minimumTextWidth }

    static func height(forWidth width: CGFloat) -> CGFloat { width / aspectRatio }

    /// The width the author's lines wrap at on a cover this wide.
    static func authorLineWidth(forWidth width: CGFloat) -> CGFloat { width - 2 * authorInset }

    static func ruleSize(forWidth width: CGFloat) -> CGSize {
        showsText(width: width) ? CGSize(width: 26, height: 1.5)
            : CGSize(width: width * plainRuleWidthFraction, height: 1.5)
    }

    static func cornerRadius(forWidth width: CGFloat) -> CGFloat {
        showsText(width: width) ? Theme.Radius.md : Theme.Radius.sm
    }

    /// The 2:3 cover centred in a `side`-point square: 300 → (70, 30, 160, 240).
    static func artworkCoverRect(side: CGFloat) -> CGRect {
        let height = side * artworkCoverFraction
        let width = height * aspectRatio
        return CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
    }
}

/// What a long press lifts from a shelf cell: the cover alone, by its own
/// corners, never the cover plus a slab of caption. The cover sits at the
/// cell's top leading corner, as wide as the cell, or at `fixedSize` where
/// the card keeps the hero's cover (`DocumentCardView.usesHeroCover`).
struct CoverLiftShape: Shape {
    var fixedSize: CGSize?

    func path(in rect: CGRect) -> Path {
        let size = fixedSize ?? CGSize(width: rect.width, height: CoverGeometry.height(forWidth: rect.width))
        return RoundedRectangle(cornerRadius: CoverGeometry.cornerRadius(forWidth: size.width), style: .continuous)
            .path(in: CGRect(origin: rect.origin, size: size))
    }
}

// MARK: - The cover

/// The app's one cover design (R22): a 2:3 book with a serif title, an
/// accent rule and a small-caps author, or a PDF's first page in the same
/// frame. It fits the largest 2:3 rect inside whatever it is offered, so a
/// caller sizes it with a width or a frame and never sets an aspect itself.
/// Below 80pt wide a typographic or loading cover draws only the ground and
/// the rule, never shrunken type; a PDF's page draws at every width, so the
/// Continue card's 64pt cover shows it too.
///
/// A cover is a picture: its type is pinned to the default size so it
/// composes the same at every Dynamic Type setting, Smart Invert leaves it
/// as drawn (R12h), and VoiceOver skips it because the card beside or
/// below it says the title.
struct BookCover: View {
    enum Art {
        case typographic
        case page(PlatformImage)
        /// A PDF whose page is still loading: a plain face, so no title flashes.
        case pending
    }

    private let title: String
    private let author: String?
    private let art: Art
    private let progress: Double

    init(title: String, author: String? = nil, art: Art = .typographic, progress: Double = 0) {
        self.title = title
        self.author = author
        self.art = art
        self.progress = progress
    }

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: CoverGeometry.cornerRadius(forWidth: proxy.size.width),
                                         style: .continuous)
            face(in: proxy.size)
                .overlay(alignment: .bottom) { progressBar }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
        }
        .aspectRatio(CoverGeometry.aspectRatio, contentMode: .fit)
        .dynamicTypeSize(.large)
        .accessibilityIgnoresInvertColors()
        .accessibilityHidden(true)
    }

    /// The art first: a page is a picture and draws at any width; type
    /// draws only from 80pt (R22); a loading page is always plain.
    @ViewBuilder
    private func face(in size: CGSize) -> some View {
        switch art {
        case .page(let image):
            Color.clear.overlay(Image(platformImage: image).resizable().scaledToFill())
        case .typographic:
            if CoverGeometry.showsText(width: size.width) {
                TypographicFace(title: title, author: author, width: size.width)
            } else {
                PlainFace(size: size)
            }
        case .pending:
            PlainFace(size: size)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if progress > 0 {
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Theme.track
                    Theme.accent
                        .frame(width: bar.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: CoverGeometry.progressBarHeight)
        }
    }
}

// MARK: - Faces

/// Tonal ground: accentSoft over surface, so light and dark both read as
/// one warm material.
private struct CoverGround: View {
    var body: some View {
        ZStack {
            Theme.surface
            Theme.accentSoft
        }
    }
}

private struct CoverRule: View {
    let size: CGSize

    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: size.width, height: size.height)
    }
}

/// The ground and a centred rule a third of the way down: a typographic
/// cover below 80pt, and a PDF's while its page loads. Below 80pt one more
/// accentSoft wash over the ground stands the small tile off the card's
/// surface, so it reads as a book in miniature rather than an image that
/// failed to load; a grid-size cover still loading keeps the plain ground
/// its face will have.
private struct PlainFace: View {
    let size: CGSize

    var body: some View {
        ZStack {
            CoverGround()
            if !CoverGeometry.showsText(width: size.width) {
                Theme.accentSoft
            }
        }
        .overlay(alignment: .top) {
            CoverRule(size: CoverGeometry.ruleSize(forWidth: size.width))
                .padding(.top, size.height * CoverGeometry.plainRuleTop)
        }
    }
}

/// Type only, no imagery: the headline serif title in the upper part over a
/// thin accent rule, and the author as a small-caps eyebrow at the foot.
private struct TypographicFace: View {
    let title: String
    let author: String?
    let width: CGFloat

    var body: some View {
        ZStack {
            CoverGround()
            VStack(spacing: 0) {
                Text(title)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.xl)
                    // On a short cover the author's lines give way first:
                    // the caption below repeats the author.
                    .layoutPriority(1)
                CoverRule(size: CoverGeometry.ruleSize(forWidth: width))
                    .padding(.top, Theme.Space.sm)
                Spacer(minLength: Theme.Space.xs)
                if let author, !author.isEmpty {
                    // At full size, wrapping onto up to three centred lines
                    // rather than shrinking or cutting a long name short.
                    Text(author)
                        .font(Theme.font(.eyebrow))
                        .eyebrowTracking()
                        // textMuted, not textFaint: the ground is accentSoft.
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        // A little wider than the title's lines: see
                        // CoverGeometry.authorInset.
                        .padding(.horizontal, CoverGeometry.authorInset)
                        .padding(.bottom, Theme.Space.md)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - A library record's cover

/// The cover of a library record: typographic for text books, the first
/// page for PDFs (typographic when the page can't be drawn), and a plain
/// face while that page loads. The shelf card and the Continue card both
/// draw it, with the record's progress bar (hidden at 0%); the featured
/// classic, with no record yet, draws BookCover.
struct DocumentCoverView: View {
    private let document: LibraryDocument

    @State private var cover = CoverPage()

    init(document: LibraryDocument) {
        self.document = document
    }

    var body: some View {
        BookCover(title: document.title,
                  author: document.author,
                  art: cover.art(for: document),
                  progress: document.progressFraction)
            // Runs again on every reappear (back from the reader, scrolled
            // back on screen): `begin` keeps a page already in hand, so the
            // cover never drops to its plain face for the same record.
            .task(id: document.id) {
                let id = document.id
                guard cover.begin(id), document.kind == .pdf else { return }
                let loaded = await ThumbnailProvider.shared.thumbnail(for: document)
                // Keyed by id: a newer record's state ignores this page.
                cover.land(loaded, for: id)
            }
    }

    static func art(kind: DocKind, page: PlatformImage?, pageLoaded: Bool) -> BookCover.Art {
        switch kind {
        case .text:
            return .typographic
        case .pdf:
            if let page { return .page(page) }
            return pageLoaded ? .typographic : .pending
        }
    }
}

/// A record's loaded first page and the record it belongs to. Pure, so the
/// cover's load rules are tested without a window:
/// - a reappear of the same record keeps its page and loads nothing;
/// - a different record forgets the old page at once, and never shows it;
/// - a failed load (typographic) is retried on the next appear, in place.
struct CoverPage {
    private(set) var documentID: UUID?
    private(set) var page: PlatformImage?
    private(set) var loaded = false

    /// At the start of a load for `id`: forgets another record's page, and
    /// returns false when this record's page is already in hand.
    mutating func begin(_ id: UUID) -> Bool {
        if documentID != id {
            documentID = id
            page = nil
            loaded = false
        }
        return page == nil
    }

    /// A finished load for `id`; dropped when the state now belongs to
    /// another record.
    mutating func land(_ page: PlatformImage?, for id: UUID) {
        guard documentID == id else { return }
        self.page = page
        loaded = true
    }

    /// The art for `document`: its own page, or pending while its own load
    /// has not landed. Another record's page is never drawn.
    func art(for document: LibraryDocument) -> BookCover.Art {
        let own = documentID == document.id
        return DocumentCoverView.art(kind: document.kind,
                                     page: own ? page : nil,
                                     pageLoaded: own && loaded)
    }
}
