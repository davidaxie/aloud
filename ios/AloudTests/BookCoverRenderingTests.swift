import SwiftUI
import XCTest
@testable import Aloud

/// R22 measured on the real component: every cover lays out at 2:3 inside
/// whatever it is offered, nothing narrower than 80pt draws type or a page,
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
            ("a PDF record", AnyView(DocumentCoverView(document: Self.record(kind: .pdf), showsProgress: false))),
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

    /// Below 80pt every cover is the same ground and rule: the title, the
    /// author, a page and a loading page all draw nothing of their own.
    func testNoTextOrPageBelowEightyPoints() throws {
        for size in [CGSize(width: 44, height: 66), CGSize(width: 64, height: 96),
                     CGSize(width: 79, height: 118.5), CoverGeometry.heroSize] {
            let label = "\(size.width)×\(size.height)"
            let full = try XCTUnwrap(RenderedPixels(BookCover(title: "The Cask of Amontillado",
                                                              author: "Edgar Allan Poe"), size: size), label)
            let short = try XCTUnwrap(RenderedPixels(BookCover(title: "I"), size: size), label)
            let page = try XCTUnwrap(RenderedPixels(BookCover(title: "The Cask of Amontillado",
                                                              art: .page(Self.red)), size: size), label)
            let pending = try XCTUnwrap(RenderedPixels(BookCover(title: "The Cask of Amontillado",
                                                                 art: .pending), size: size), label)
            XCTAssertLessThanOrEqual(full.maxChannelDifference(to: short), 1, "\(label): a title was drawn")
            XCTAssertLessThanOrEqual(full.maxChannelDifference(to: page), 1, "\(label): a page was drawn")
            XCTAssertLessThanOrEqual(full.maxChannelDifference(to: pending), 1, "\(label): pending differs")
        }
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
