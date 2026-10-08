import SwiftUI
import XCTest
@testable import Aloud

/// The shelf card at real widths: at the accessibility sizes, where the grid
/// is one column, the title and author wrap in full ("The Strange Case of
/// Dr. Jekyll and Mr. Hyde" was cut at two lines, "Emperor of Rome Marcus
/// Aurelius" at one); below them, in two columns, both limits stay.
@MainActor
final class DocumentCardLayoutTests: XCTestCase {

    /// A 393pt phone's grid as the shelf draws it (`PhoneShelfMetrics`):
    /// one column at the accessibility sizes, two below them, the gap
    /// between them the one above the narrowest phones.
    private static let oneColumn = PhoneShelfMetrics(width: 393, isAccessibilitySize: true).columnWidth(forWidth: 393)
    private static let twoColumns = PhoneShelfMetrics(width: 393, isAccessibilitySize: false).columnWidth(forWidth: 393)

    /// The widths above are the real shelf's: 353 pt, and 166.5 pt with
    /// the 20 pt gap (not the 16 pt gap of the narrowest phones).
    func testTheModelledColumnsAreTheShelfs() {
        XCTAssertEqual(Self.oneColumn, 393 - 2 * Theme.Space.screenGutter)
        XCTAssertEqual(Self.twoColumns, (Self.oneColumn - Theme.Space.lg) / 2)
        XCTAssertEqual(Self.twoColumns, 166.5)
    }

    private static let title = "The Strange Case of Dr. Jekyll and Mr. Hyde"
    private static let author = "Emperor of Rome Marcus Aurelius"

    private func doc(title: String, author: String) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "doc", addedAt: Date(timeIntervalSince1970: 0),
                        pageCount: 1, sentenceCount: 100, progressSentence: 43,
                        progressFraction: 0.43, contentHash: "hash", kind: .text,
                        author: author, wordCount: 20_842)
    }

    private func height(of view: some View, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    private func textHeight(_ string: String, font: Font, lineLimit: Int?,
                            width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        height(of: Text(string).font(font).lineLimit(lineLimit), width: width, size: size)
    }

    /// How much taller the long title and author set than "Emma" and "Jane
    /// Austen" in the card's fonts, at the given limits.
    private func textExtra(titleLimit: Int?, authorLimit: Int?, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let title = Theme.font(.headline), author = Theme.font(.footnote)
        return textHeight(Self.title, font: title, lineLimit: titleLimit, width: width, size: size)
            - textHeight("Emma", font: title, lineLimit: titleLimit, width: width, size: size)
            + textHeight(Self.author, font: author, lineLimit: authorLimit, width: width, size: size)
            - textHeight("Jane Austen", font: author, lineLimit: authorLimit, width: width, size: size)
    }

    /// How much taller the long title and author make the card: the cover
    /// and the listening line are the same for both.
    private func cardExtra(width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        height(of: DocumentCardView(document: doc(title: Self.title, author: Self.author), rate: 1),
               width: width, size: size)
            - height(of: DocumentCardView(document: doc(title: "Emma", author: "Jane Austen"), rate: 1),
                     width: width, size: size)
    }

    func testTheTitleAndAuthorWrapInFullAtAccessibilitySizes() {
        let width = Self.oneColumn
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            XCTAssertEqual(cardExtra(width: width, size: size),
                           textExtra(titleLimit: nil, authorLimit: nil, width: width, size: size),
                           accuracy: 1, "\(size): the title and author should show in full")
        }
        // The fixture needs it: at AX3 two lines and one cut both short.
        let title = Theme.font(.headline), author = Theme.font(.footnote)
        XCTAssertGreaterThan(textHeight(Self.title, font: title, lineLimit: nil, width: width, size: .accessibility3),
                             textHeight(Self.title, font: title, lineLimit: 2, width: width, size: .accessibility3) + 10,
                             "fixture: the title should need more than two lines at AX3")
        XCTAssertGreaterThan(textHeight(Self.author, font: author, lineLimit: nil, width: width, size: .accessibility3),
                             textHeight(Self.author, font: author, lineLimit: 1, width: width, size: .accessibility3) + 10,
                             "fixture: the author should need more than one line at AX3")
    }

    /// At the accessibility sizes the cover keeps the Continue card's fixed
    /// 64x96 above the text. Filling the one column it was 2:3 of the
    /// screen's width (353x530pt here), and one card was about a screen.
    func testTheCoverKeepsItsFixedSizeAtAccessibilitySizes() {
        let width = Self.oneColumn
        let document = doc(title: "Emma", author: "Jane Austen")
        let subtitle = document.listeningSubtitle(rate: 1)
        XCTAssertFalse(subtitle.isEmpty, "fixture: the card should show its listening line")
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let text = textHeight("Emma", font: Theme.font(.headline), lineLimit: nil, width: width, size: size)
                + Theme.Space.xxs
                + textHeight("Jane Austen", font: Theme.font(.footnote), lineLimit: nil, width: width, size: size)
                + Theme.Space.xxs
                + textHeight(subtitle, font: Theme.font(.caption), lineLimit: 2, width: width, size: size)
            XCTAssertEqual(height(of: DocumentCardView(document: document, rate: 1), width: width, size: size),
                           CoverGeometry.heroSize.height + Theme.Space.sm + text,
                           accuracy: 2, "\(size): the cover should stay 64x96, not fill the column")
        }
    }

    /// J014: at the accessibility sizes the card spans its one column, so
    /// the band beside the 64pt cover is part of the tap target (with the
    /// card's content shape) and a short title's card starts at the
    /// column's leading edge instead of sitting centred in it.
    func testTheCardFillsItsColumnAtAccessibilitySizes() {
        let width = Self.oneColumn
        for title in ["Emma", Self.title] {
            for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
                let card = DocumentCardView(document: doc(title: title, author: "Jane Austen"), rate: 1)
                    .environment(\.dynamicTypeSize, size)
                let fitted = UIHostingController(rootView: card)
                    .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                XCTAssertEqual(fitted.width, width, accuracy: 0.5, "\(size) '\(title)': the card should fill the column")
            }
        }
    }

    /// The width `line` sets in `font`, on one line.
    private func lineWidth(_ line: String, _ font: Font) -> CGFloat {
        UIHostingController(rootView: Text(line).font(font).fixedSize())
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            .width
    }

    /// J027: under Bold Text the serif styles (the card's title among them)
    /// take the family's bold face, as SwiftUI bolds the sans styles itself
    /// and the column swaps its own face; nothing else changes. The styles
    /// views set follow the system setting.
    func testTheSerifStylesTakeTheirBoldFaceUnderBoldText() {
        let line = "Hamburgefonstiv Library"
        XCTAssertEqual(Theme.TypeStyle.allCases.filter(\.isSerif), [.display, .title, .headline, .aside])
        for style in Theme.TypeStyle.allCases {
            let regular = Theme.font(style, boldText: false), bold = Theme.font(style, boldText: true)
            guard style.isSerif else {
                XCTAssertEqual(bold, regular, "\(style): SwiftUI bolds a system style itself")
                continue
            }
            if style == .headline {
                // Its semibold is already Iowan's bold face.
                XCTAssertGreaterThanOrEqual(lineWidth(line, bold), lineWidth(line, regular) - 0.5)
            } else {
                XCTAssertGreaterThan(lineWidth(line, bold), lineWidth(line, regular) + 1,
                                     "\(style) should set in the bold face under Bold Text")
            }
        }
        let saved = Theme.BoldText.shared.isOn
        defer { Theme.BoldText.shared.isOn = saved }
        for isOn in [false, true] {
            Theme.BoldText.shared.isOn = isOn
            for style in Theme.TypeStyle.allCases {
                XCTAssertEqual(Theme.font(style), Theme.font(style, boldText: style.isSerif && isOn),
                               "\(style) with Bold Text \(isOn ? "on" : "off")")
            }
        }
    }

    func testTheTwoColumnCardKeepsItsLimits() {
        let width = Self.twoColumns
        let title = Theme.font(.headline)
        for size in [DynamicTypeSize.large, .xxxLarge] {
            // From xxLarge the two columns wrap in full (L016); below, two
            // lines of title and one of author.
            let wraps = DocumentCardView.wrapsInFull(at: size)
            XCTAssertEqual(cardExtra(width: width, size: size),
                           textExtra(titleLimit: wraps ? nil : 2, authorLimit: wraps ? nil : 1,
                                     width: width, size: size),
                           accuracy: 1, "\(size): \(wraps ? "the whole title and author" : "two lines of title and one of author")")
            XCTAssertGreaterThan(textHeight(Self.title, font: title, lineLimit: nil, width: width, size: size),
                                 textHeight(Self.title, font: title, lineLimit: 2, width: width, size: size) + 10,
                                 "\(size) fixture: the title should need more than two lines")
        }
    }

    // MARK: - Pressed plate (P019)

    /// Pressed, a surface2 plate reaches `outset` (Theme.Space.xs, 8 pt)
    /// past the card on every side; at rest nothing is drawn round it. A
    /// 40 pt label padded 16 pt, rendered at 2x: pixel x 24 is 12 pt in,
    /// 4 pt outside the label and inside the plate; pixel x 4 is 2 pt in,
    /// past the plate's edge at 8 pt; pixel x 72 is the label's centre.
    /// The label is opaque: ImageRenderer hands back the previous render's
    /// bitmap for content that draws nothing at all, so a clear label at
    /// rest read the pressed plate. Here, not in ShelfFeedTests, because
    /// RenderedPixels is UIKit and the Mac host leaves it out.
    func testThePressedPlateDrawsOnlyWhilePressed() throws {
        XCTAssertEqual(ShelfPlateButtonStyle().outset, Theme.Space.xs)
        XCTAssertEqual(Theme.Space.xs, 8, "the pixels below assume an 8 pt plate")
        func render(pressed: Bool) throws -> RenderedPixels {
            let view = ShelfPlateButtonStyle.Plated(isPressed: pressed) {
                Color.black.frame(width: 40, height: 40)
            }
            .padding(16)
            return try XCTUnwrap(RenderedPixels(view, size: CGSize(width: 72, height: 72)))
        }
        let pressed = try render(pressed: true)
        let resting = try render(pressed: false)
        XCTAssertEqual(resting.rgba(x: 72, y: 72).a, 255, "the card itself draws at rest")
        XCTAssertGreaterThan(pressed.rgba(x: 24, y: 72).a, 200, "on the plate, 4 pt outside the card")
        XCTAssertEqual(resting.rgba(x: 24, y: 72).a, 0, "no plate at rest")
        XCTAssertEqual(pressed.rgba(x: 4, y: 72).a, 0, "the plate stops 8 pt out")
    }

    /// The Continue card's plate leaves the card full size (`scales: false`):
    /// its play circle is placed from outside the button, so a shrinking
    /// body would slide out from under it. A 100 pt red card padded 16 pt,
    /// rendered at 2x: pixel x 33 is 16.5 pt in, on the card at full size
    /// and on the plate once the card draws at 0.98 (1 pt in on each side).
    func testANonScalingPlateKeepsTheCardFullSize() throws {
        func edge(scales: Bool) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let view = ShelfPlateButtonStyle.Plated(isPressed: true, scales: scales) {
                Color(red: 1, green: 0, blue: 0).frame(width: 100, height: 100)
            }
            .padding(16)
            return try XCTUnwrap(RenderedPixels(view, size: CGSize(width: 132, height: 132))).rgba(x: 33, y: 132)
        }
        let full = try edge(scales: false)
        XCTAssertGreaterThan(full.r, 200, "the card's own edge")
        XCTAssertLessThan(full.g, 60, "the card's own edge")
        // The plate is a near-grey paper in both appearances; the card is red.
        let scaled = try edge(scales: true)
        XCTAssertGreaterThan(scaled.a, 200, "on the plate")
        XCTAssertLessThan(abs(scaled.r - scaled.g), 60, "a grid card still draws in, off its own edge")
    }
}
