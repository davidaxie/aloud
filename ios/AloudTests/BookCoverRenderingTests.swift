import SwiftUI
import XCTest
@testable import Aloud

/// R22 measured on the real component: every cover lays out at 2:3 inside
/// whatever it is offered, nothing narrower than 80pt draws type (a page
/// draws at any width), a long author wraps at full size,
/// and the progress bar stays in its 3pt. Hosted sizeThatFits and
/// ImageRenderer pixels only: no window, no controller, no sound.
@MainActor
final class BookCoverRenderingTests: XCTestCase {

    private static let unbounded = CGFloat.greatestFiniteMagnitude

    /// A grid card, the hero, the hero's old 64×88 frame, a phone-wide card
    /// and the lock-screen square.
    private static let proposals = [
        CGSize(width: 160, height: unbounded),
        CGSize(width: 64, height: 96),
        CGSize(width: 64, height: 88),
        CGSize(width: 335, height: unbounded),
        CGSize(width: 300, height: 300),
    ]

    private static func record(kind: DocKind) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "The Cask of Amontillado", fileName: "cask",
                        addedAt: Date(timeIntervalSince1970: 0), pageCount: 3, sentenceCount: 120,
                        progressSentence: 40, progressFraction: 0.33, contentHash: "cask",
                        kind: kind, author: "Edgar Allan Poe", wordCount: 2_300)
    }

    private static let red = RenderedPixels.solidImage(rgb: 0xFF0000, size: CGSize(width: 480, height: 720))

    private func render(_ cover: BookCover, width: CGFloat) throws -> RenderedPixels {
        try XCTUnwrap(RenderedPixels(cover, size: CGSize(width: width, height: CoverGeometry.height(forWidth: width))),
                      "render at \(width)pt")
    }

    // MARK: - Layout

    func testEveryCoverFitsATwoByThreeRectInsideItsProposal() {
        let covers: [(name: String, view: AnyView)] = [
            ("BookCover", AnyView(BookCover(title: "T"))),
            ("a text record", AnyView(DocumentCoverView(document: Self.record(kind: .text)))),
            ("a PDF record", AnyView(DocumentCoverView(document: Self.record(kind: .pdf)))),
        ]
        for proposal in Self.proposals {
            for cover in covers {
                let size = UIHostingController(rootView: cover.view).sizeThatFits(in: proposal)
                let label = "\(cover.name) offered \(proposal.width)×\(proposal.height): \(size)"
                XCTAssertGreaterThan(size.height, 0, label)
                guard size.height > 0 else { continue }
                XCTAssertEqual(size.width / size.height, 0.667, accuracy: 0.01, label)
                XCTAssertLessThanOrEqual(size.width, proposal.width + 0.01, label)
                XCTAssertLessThanOrEqual(size.height, proposal.height + 0.01, label)
            }
        }
    }

    // MARK: - No type below 80pt

    /// Below 80pt a typographic cover is the same ground and rule whatever
    /// its title and author, and a loading page matches it: no shrunken
    /// type (R22).
    func testNoTextBelowEightyPoints() throws {
        for size in [CGSize(width: 44, height: 66), CGSize(width: 64, height: 96),
                     CGSize(width: 79, height: 118.5), CoverGeometry.heroSize] {
            let label = "\(size.width)×\(size.height)"
            let full = try XCTUnwrap(RenderedPixels(BookCover(title: "The Cask of Amontillado",
                                                              author: "Edgar Allan Poe"), size: size), label)
            let short = try XCTUnwrap(RenderedPixels(BookCover(title: "I"), size: size), label)
            let pending = try XCTUnwrap(RenderedPixels(BookCover(title: "The Cask of Amontillado",
                                                                 art: .pending), size: size), label)
            XCTAssertLessThanOrEqual(full.maxChannelDifference(to: short), 1, "\(label): a title was drawn")
            XCTAssertLessThanOrEqual(full.maxChannelDifference(to: pending), 1, "\(label): pending differs")
        }
    }

    /// R1-04: a PDF's page is a picture, not type, so the Continue card's
    /// 64pt cover shows it rather than a blank tile.
    func testAPageDrawsAtTheHerosSize() throws {
        let page = try XCTUnwrap(RenderedPixels(BookCover(title: "Doc", art: .page(Self.red)),
                                                size: CoverGeometry.heroSize))
        let centre = page.rgba(x: page.width / 2, y: page.height / 2)
        XCTAssertTrue(centre.r > 200 && centre.g < 60 && centre.b < 60, "centre pixel \(centre)")
    }

    /// R1-04: the small face stands off the card: its ground carries one
    /// more accentSoft wash than a grid cover's, so the hero's 64pt cover
    /// reads as a book in miniature, not an image that failed to load.
    func testTheSmallFaceStandsOffTheCard() throws {
        let small = try XCTUnwrap(RenderedPixels(BookCover(title: "I"), size: CoverGeometry.heroSize))
        let grid = try render(BookCover(title: "I"), width: 160)
        // Low on each cover, clear of the rule, the title and the border.
        let smallGround = small.rgba(x: small.width / 2, y: small.height * 4 / 5)
        let gridGround = grid.rgba(x: grid.width / 2, y: grid.height * 4 / 5)
        let difference = max(abs(smallGround.r - gridGround.r), abs(smallGround.g - gridGround.g),
                             abs(smallGround.b - gridGround.b))
        XCTAssertGreaterThan(difference, 4, "small \(smallGround) vs grid \(gridGround)")
        XCTAssertLessThan(smallGround.b, gridGround.b, "a warmer, deeper ground, not a new hue")
    }

    func testTitlesAreDrawnFromEightyPoints() throws {
        for width in [80, 160] as [CGFloat] {
            let cask = try render(BookCover(title: "The Cask of Amontillado"), width: width)
            let pride = try render(BookCover(title: "Pride and Prejudice"), width: width)
            XCTAssertGreaterThan(cask.maxChannelDifference(to: pride), 64, "\(width)pt shows no title")
        }
    }

    /// A PDF whose page is loading shows no title, so none flashes.
    func testAPendingPageDrawsNoTitle() throws {
        let cask = try render(BookCover(title: "The Cask of Amontillado", art: .pending), width: 160)
        let pride = try render(BookCover(title: "Pride and Prejudice", art: .pending), width: 160)
        XCTAssertLessThanOrEqual(cask.maxChannelDifference(to: pride), 1)
    }

    // MARK: - The author

    /// R1-03: a long author draws at full size, wrapping onto up to three
    /// centred lines, never shrunk or cut short. The phone's covers run
    /// from 155pt; MacGridMetricsTests checks the Mac's 136-168 with the
    /// Mac's own type.
    func testALongAuthorWrapsAtFullSize() throws {
        let title = "Frankenstein; or, The Modern Prometheus"
        let author = "Mary Wollstonecraft Shelley"
        for width: CGFloat in [155, 160, 169] {
            let face = width - 2 * Theme.Space.md
            let lines = Self.eyebrowLines(author, width: face)
            XCTAssertLessThanOrEqual(lines.count, 3, "\(width)pt: \(lines)")
            for word in author.split(separator: " ") {
                XCTAssertLessThanOrEqual(Self.eyebrowWidth(String(word)), face, "\(width)pt: '\(word)' is cut")
            }
            // The cover draws each of those lines: the rows that differ from
            // the same cover with no author fall into one band a line.
            let named = try render(BookCover(title: title, author: author), width: width)
            let bare = try render(BookCover(title: title), width: width)
            XCTAssertEqual(Self.inkBands(named, against: bare), lines.count, "\(width)pt: \(lines)")
        }
    }

    /// A name that fits on one line draws as one line, as before.
    func testAShortAuthorStaysOnOneLine() throws {
        let named = try render(BookCover(title: "Emma", author: "Jane Austen"), width: 160)
        let bare = try render(BookCover(title: "Emma"), width: 160)
        XCTAssertEqual(Self.inkBands(named, against: bare), 1)
    }

    /// One line of the cover's author type, as wide as it draws.
    private static func eyebrowWidth(_ text: String) -> CGFloat {
        let line = Text(text).font(Theme.font(.eyebrow)).eyebrowTracking().fixedSize().dynamicTypeSize(.large)
        return UIHostingController(rootView: line).sizeThatFits(in: CGSize(width: unbounded, height: unbounded)).width
    }

    /// `text` broken greedily into lines no wider than `width`.
    private static func eyebrowLines(_ text: String, width: CGFloat) -> [String] {
        var lines: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if let last = lines.last, eyebrowWidth(last + " " + word) <= width {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        return lines
    }

    /// Runs of rows where `pixels` differs from `reference`.
    private static func inkBands(_ pixels: RenderedPixels, against reference: RenderedPixels) -> Int {
        var bands = 0
        var inBand = false
        for row in 0..<pixels.height {
            let ink = pixels.maxChannelDifference(to: reference, row: row) > 24
            if ink && !inBand { bands += 1 }
            inBand = ink
        }
        return bands
    }

    func testAPageFillsTheCover() throws {
        let page = try render(BookCover(title: "Doc", art: .page(Self.red)), width: 160)
        let centre = page.rgba(x: page.width / 2, y: page.height / 2)
        XCTAssertTrue(centre.r > 200 && centre.g < 60 && centre.b < 60, "centre pixel \(centre)")
    }

    // MARK: - A record's art

    private func name(_ art: BookCover.Art) -> String {
        if case .typographic = art { return "typographic" }
        if case .pending = art { return "pending" }
        if case .page = art { return "page" }
        return "unknown"
    }

    func testARecordsArt() {
        let page = Self.red
        XCTAssertEqual(name(DocumentCoverView.art(kind: .text, page: nil, pageLoaded: false)), "typographic")
        XCTAssertEqual(name(DocumentCoverView.art(kind: .text, page: page, pageLoaded: true)), "typographic",
                       "a text book never shows a page")
        XCTAssertEqual(name(DocumentCoverView.art(kind: .pdf, page: nil, pageLoaded: false)), "pending")
        XCTAssertEqual(name(DocumentCoverView.art(kind: .pdf, page: nil, pageLoaded: true)), "typographic",
                       "a PDF without a page falls back to type")
        if case .page(let image) = DocumentCoverView.art(kind: .pdf, page: page, pageLoaded: true) {
            XCTAssertTrue(image === page)
        } else {
            XCTFail("a PDF with a page shows it")
        }
    }

    // MARK: - A record's page, across appears

    /// The cover's `.task(id:)` runs again on every reappear (back from the
    /// reader, scrolled back on screen) with the same id. That keeps the
    /// page it has and loads nothing, so a PDF never drops to its plain face.
    func testAReappearKeepsTheLoadedPage() {
        let pdf = Self.record(kind: .pdf)
        var cover = CoverPage()
        XCTAssertEqual(name(cover.art(for: pdf)), "pending", "before the first load lands")
        XCTAssertTrue(cover.begin(pdf.id), "the first appear loads")
        cover.land(Self.red, for: pdf.id)

        XCTAssertFalse(cover.begin(pdf.id), "a reappear loads nothing")
        guard case .page(let image) = cover.art(for: pdf) else {
            return XCTFail("a reappear dropped the page: \(name(cover.art(for: pdf)))")
        }
        XCTAssertTrue(image === Self.red)

        var renamed = pdf
        renamed.title = "Renamed"
        renamed.progressFraction = 0.9
        XCTAssertFalse(cover.begin(renamed.id), "a rename or progress change keeps the page")
        XCTAssertEqual(name(cover.art(for: renamed)), "page")
    }

    /// A different record (the hero switching books) never shows the old
    /// page, even for the frame before its own load starts, and a late
    /// landing of the old page is dropped.
    func testAnotherRecordNeverShowsTheOldPage() {
        let first = Self.record(kind: .pdf)
        let second = Self.record(kind: .pdf)
        var cover = CoverPage()
        _ = cover.begin(first.id)
        cover.land(Self.red, for: first.id)

        XCTAssertEqual(name(cover.art(for: second)), "pending", "before the new record's task runs")
        XCTAssertTrue(cover.begin(second.id), "a new record loads")
        XCTAssertEqual(name(cover.art(for: second)), "pending")
        cover.land(Self.red, for: first.id)
        XCTAssertEqual(name(cover.art(for: second)), "pending", "the old record's late page is dropped")
        XCTAssertEqual(name(cover.art(for: first)), "pending", "the state now belongs to the new record")
    }

    /// A page that can't be drawn falls back to type, and the next appear
    /// tries again without flashing the plain face in between.
    func testAFailedLoadRetriesInPlace() {
        let pdf = Self.record(kind: .pdf)
        var cover = CoverPage()
        _ = cover.begin(pdf.id)
        cover.land(nil, for: pdf.id)
        XCTAssertEqual(name(cover.art(for: pdf)), "typographic")

        XCTAssertTrue(cover.begin(pdf.id), "the next appear retries")
        XCTAssertEqual(name(cover.art(for: pdf)), "typographic", "no plain face while it retries")
        cover.land(Self.red, for: pdf.id)
        XCTAssertEqual(name(cover.art(for: pdf)), "page")
    }

    // MARK: - Progress

    func testProgressDrawsOnlyInTheBottomThreePoints() throws {
        let plain = try render(BookCover(title: "T"), width: 160)
        let zero = try render(BookCover(title: "T", progress: 0), width: 160)
        XCTAssertLessThanOrEqual(zero.maxChannelDifference(to: plain), 1, "0 draws no bar")

        let half = try render(BookCover(title: "T", progress: 0.5), width: 160)
        let scale = 2
        let firstBarRow = (Int(CoverGeometry.height(forWidth: 160)) - Int(CoverGeometry.progressBarHeight)) * scale
        let changedAbove = (0..<firstBarRow).first { half.maxChannelDifference(to: plain, row: $0) > 1 }
        XCTAssertNil(changedAbove, "the bar reaches above its 3pt")
        let barDifference = (firstBarRow..<half.height).map { half.maxChannelDifference(to: plain, row: $0) }.max() ?? 0
        XCTAssertGreaterThan(barDifference, 64, "0.5 draws a bar")
    }
}
