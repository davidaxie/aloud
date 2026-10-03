import XCTest

/// R22 source lints: one cover component, drawn from exactly its call
/// sites, owning the only aspect ratio and fill; the old frames are gone and
/// Bookshelf rows carry no cover. Skips when the host can't read the tree.
final class CoverLintTests: XCTestCase {

    func testTheOldTypographicCoverIsGone() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.files(containing: "TypographicCover", in: sources), [])
    }

    /// Call sites, counted by a following "(": the cover itself (through
    /// DocumentCoverView), the featured classic and the lock-screen art.
    func testEveryCoverIsTheOneCover() throws {
        let sources = try SourceTree.sources()
        XCTAssertEqual(SourceTree.files(containing: "BookCover(", in: sources),
                       ["Library/BookCover.swift", "Library/EmptyLibraryView.swift", "NowPlaying/NowPlayingArtwork.swift"])
        XCTAssertEqual(SourceTree.files(containing: "DocumentCoverView(", in: sources),
                       ["Library/ContinueListeningCard.swift", "Library/DocumentCardView.swift"])
    }

    /// No caller reshapes a cover: the 2:3 and the page fill live in it.
    func testOnlyTheCoverSetsAnAspectOrAFill() throws {
        let sources = try SourceTree.sources()
        for needle in [".aspectRatio(", "scaledToFill"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: sources), ["Library/BookCover.swift"],
                           "'\(needle)' belongs only to the cover")
        }
    }

    func testTheOldCoverFramesAreGone() throws {
        let library = try SourceTree.sources(only: ["Library"])
        XCTAssertEqual(SourceTree.files(containing: "4.4", in: library), [], "the 3:4.4 grid aspect")
        XCTAssertEqual(SourceTree.files(containing: "height: 88", in: library), [], "the 64×88 hero frame")
        let card = try XCTUnwrap(library["Library/ContinueListeningCard.swift"])
        XCTAssertTrue(body(ofStruct: "ShelfHeroCard", in: card).contains("CoverGeometry.heroSize"),
                      "the hero frames its cover with CoverGeometry.heroSize")
    }

    /// Covers draw through `Image(platformImage:)` since the seam (S1);
    /// `Image(uiImage` stays banned too, so neither spelling slips in.
    func testBookshelfRowsCarryNoCover() throws {
        let bookshelf = try SourceTree.sources(only: ["Bookshelf"])
        for needle in ["BookCover", "DocumentCoverView", "Image(platformImage", "Image(uiImage", "ThumbnailProvider"] {
            XCTAssertEqual(SourceTree.files(containing: needle, in: bookshelf), [], "'\(needle)' in a Bookshelf row")
        }
        // The cover itself draws with the first spelling, so the needle
        // can't go stale unseen again.
        let library = try SourceTree.sources(only: ["Library"])
        XCTAssertTrue(SourceTree.files(containing: "Image(platformImage", in: library).contains("Library/BookCover.swift"),
                      "the cover draws with Image(platformImage:), so the Bookshelf needle above is the live one")
    }

    /// The text of `struct <name>` (generic or not) up to the next top-level
    /// closing brace.
    private func body(ofStruct name: String, in text: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let start = text.range(of: "struct \(name)") else {
            XCTFail("struct \(name) not found", file: file, line: line)
            return ""
        }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }
}
