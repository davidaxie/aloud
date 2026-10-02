import MediaPlayer
import SwiftUI

/// Lock-screen and Dynamic Island art (R22): the one cover, centred on a
/// square of bgTint, rendered from the same SwiftUI view the shelf draws.
///
/// Two renders serve every request size. The 300pt square carries the
/// 160×240pt cover with its type; below 150pt the cover would be narrower
/// than 80pt, so the system gets a 96pt square whose 51pt cover is the
/// textless ground and rule (the Dynamic Island's compact art).
///
/// Not main-actor as a whole: the artwork's request handler runs on
/// whatever thread MediaPlayer calls it from.
enum NowPlayingArtwork {
    /// Its cover is 51pt wide, so it is textless.
    static let smallSide: CGFloat = 96
    /// `CoverGeometry.artworkCoverRect(side: 150).width` is exactly 80.
    static let textlessSide: CGFloat = 150

    /// An opaque `side`-point square at `scale`: 900×900 px by default.
    @MainActor
    static func image(title: String, author: String?, page: UIImage?,
                      side: CGFloat = CoverGeometry.artworkSide,
                      scale: CGFloat = CoverGeometry.artworkScale) -> UIImage? {
        let renderer = ImageRenderer(content: NowPlayingArtworkView(title: title, author: author,
                                                                    page: page, side: side))
        renderer.scale = scale
        renderer.isOpaque = true
        // No trait wrapper needed: the view's light colorScheme reaches
        // Theme's trait-resolved colors, and the renderer ignores the
        // current trait collection (a dark phone renders the same square).
        return renderer.uiImage
    }

    /// Serves the textless render to requests under `textlessSide`, the
    /// full one otherwise.
    static func artwork(large: UIImage, small: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: large.size) { size in
            min(size.width, size.height) < textlessSide ? small : large
        }
    }

    /// The art for `document`: its first page when it is a PDF that has
    /// one, else its typographic cover. nil when a render fails.
    @MainActor
    static func artwork(for document: LibraryDocument) async -> MPMediaItemArtwork? {
        var page: UIImage?
        if document.kind == .pdf {
            page = await ThumbnailProvider.shared.thumbnail(for: document)
        }
        guard let large = image(title: document.title, author: document.author, page: page,
                                side: CoverGeometry.artworkSide),
              let small = image(title: document.title, author: document.author, page: page,
                                side: smallSide) else { return nil }
        return artwork(large: large, small: small)
    }
}

/// The lock-screen square: BookCover at 80% of the side, raised so its 2:3
/// silhouette reads against a ground of nearly the same tone. Always the
/// light palette, like the page it stands for.
struct NowPlayingArtworkView: View {
    let title: String
    let author: String?
    let page: UIImage?
    var side: CGFloat = CoverGeometry.artworkSide

    var body: some View {
        let rect = CoverGeometry.artworkCoverRect(side: side)
        let art: BookCover.Art = page.map { BookCover.Art.page($0) } ?? .typographic
        ZStack {
            Theme.bgTint
            BookCover(title: title, author: author, art: art)
                .frame(width: rect.width, height: rect.height)
                // One shadow from the cover's silhouette: without the group
                // each glyph and the rule cast their own onto the cover.
                .compositingGroup()
                .raisedElevation()
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .light)
    }
}
