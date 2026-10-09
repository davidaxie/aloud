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

    /// R1-03: the cover's author draws at full size and wraps onto up to
    /// three centred lines; it never shrinks a long name onto one line
    /// (no scale factor below 0.9) and stays small caps, not uppercased.
    /// On a short cover the title keeps its lines and the author gives way.
    func testTheCoverAuthorWrapsInsteadOfShrinking() throws {
        let path = "Library/BookCover.swift"
        let textSources = try SourceTree.sources(only: [path])
        let text = try XCTUnwrap(textSources[path])
        let face = body(ofStruct: "TypographicFace", in: text)
        let start = try XCTUnwrap(face.range(of: "Text(author)"))
        let end = try XCTUnwrap(face[start.upperBound...].range(of: ".padding(.bottom, Theme.Space.md)"))
        let author = String(face[start.upperBound..<end.upperBound])
        let scale = try NSRegularExpression(pattern: #"\.minimumScaleFactor\(([0-9.]+)\)"#)
        for match in scale.matches(in: author, range: NSRange(author.startIndex..., in: author)) {
            let factor = Double((author as NSString).substring(with: match.range(at: 1))) ?? 0
            XCTAssertGreaterThanOrEqual(factor, 0.9, "the author shrinks: \(author)")
        }
        XCTAssertTrue(author.contains(".lineLimit(3)"), author)
        XCTAssertTrue(author.contains(".multilineTextAlignment(.center)"), author)
        XCTAssertTrue(author.contains(".font(Theme.font(.eyebrow))"), author)
        XCTAssertFalse(author.contains(".textCase(.uppercase)"), author)
        XCTAssertFalse(author.contains(".fixedSize"), author)
        let title = try XCTUnwrap(face.range(of: "Text(title)"))
        XCTAssertTrue(face[title.upperBound..<start.lowerBound].contains(".layoutPriority(1)"),
                      "the title keeps its lines before the author")
        // The author wraps at its own, slightly wider line (R1-03 on the
        // Mac's 136pt cover); the title keeps its Theme.Space.md sides.
        XCTAssertTrue(author.contains(".padding(.horizontal, CoverGeometry.authorInset)"), author)
        XCTAssertTrue(face[title.upperBound..<start.lowerBound].contains(".padding(.horizontal, Theme.Space.md)"),
                      String(face[title.upperBound..<start.lowerBound]))
        XCTAssertEqual(face.components(separatedBy: ".padding(.horizontal,").count - 1, 2,
                       "no shared side padding narrows the author's line again")
    }

    /// R2-30: below xxLarge the cover is a text book's only title, so the
    /// title takes up to four lines; the author's first line is kept (the
    /// title's priority leaves the author its least height, one line), and
    /// the face no longer leans on a caption below repeating the author.
    func testTheCoverIsTheShelfsTitleBelowXXLarge() throws {
        let path = "Library/BookCover.swift", cardPath = "Library/DocumentCardView.swift"
        let s = try SourceTree.sources(only: [path, cardPath])
        let text = try XCTUnwrap(s[path])
        let card = try XCTUnwrap(s[cardPath])
        let face = body(ofStruct: "TypographicFace", in: text)
        let title = try XCTUnwrap(face.range(of: "Text(title)"))
        let author = try XCTUnwrap(face.range(of: "Text(author)"))
        let titleModifiers = String(face[title.upperBound..<author.lowerBound])
        XCTAssertTrue(titleModifiers.contains(".lineLimit(4)"), titleModifiers)
        XCTAssertTrue(titleModifiers.contains(".layoutPriority(1)"), titleModifiers)
        XCTAssertFalse(text.contains("caption below repeats"), "the face no longer relies on the card's caption")
        XCTAssertTrue(card.contains("if Self.showsCaption(kind: document.kind, at: dynamicTypeSize) {"),
                      "the card keys its caption on the record's kind, never the art drawn")
        XCTAssertTrue(card.contains("kind == .pdf || wrapsInFull(at: size)"), "a PDF always, text from xxLarge")
    }

    /// R2-31: the small face is a clothbound book in shapes only, drawn
    /// only below 80pt: a spine, an inset panel and a stamped ornament, all
    /// from CoverGeometry's numbers. No greeked text bars or placeholder
    /// capsules: nothing on it may read as text or depend on the title
    /// (testNoTextBelowEightyPoints renders that).
    func testTheSmallFaceIsDrawnInShapesOnly() throws {
        let path = "Library/BookCover.swift"
        let s = try SourceTree.sources(only: [path])
        let text = try XCTUnwrap(s[path])
        let plain = body(ofStruct: "PlainFace", in: text)
        let small = try XCTUnwrap(plain.range(of: "} else {"), "the small face is its own branch")
        let branch = try XCTUnwrap(plain.range(of: "if CoverGeometry.showsText(width: size.width) {"))
        XCTAssertLessThan(branch.lowerBound, small.lowerBound, "the grid-size face comes first")
        for needle in ["CoverGeometry.spineWidth(forWidth: size.width)", "CoverGeometry.ornamentTop",
                       "CoverGeometry.panelInset", "CoverGeometry.spineOpacity", ".rotationEffect(.degrees(45))"] {
            XCTAssertTrue(plain.contains(needle), "the small face draws \(needle)")
        }
        for banned in [".redacted", "Capsule(", "Text(", "title"] {
            XCTAssertFalse(plain.contains(banned), "the small face draws no '\(banned)'")
        }
        let grid = String(plain[branch.upperBound..<small.lowerBound])
        XCTAssertTrue(grid.contains("CoverGeometry.plainRuleTop"), "a grid-size loading face keeps its rule: \(grid)")
        XCTAssertFalse(grid.contains("spine"), "a grid-size loading face keeps the plain ground: \(grid)")
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
