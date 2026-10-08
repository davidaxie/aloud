import SwiftUI
import XCTest
@testable import Aloud

/// The shelf card at real widths: at the accessibility sizes, where the grid
/// is one column, the title and author wrap in full ("The Strange Case of
/// Dr. Jekyll and Mr. Hyde" was cut at two lines, "Emperor of Rome Marcus
/// Aurelius" at one); below them, in two columns, both limits stay.
@MainActor
final class DocumentCardLayoutTests: XCTestCase {

    /// A 393pt phone's grid: the screen minus the 20pt gutters, one column
    /// at the accessibility sizes and two below them (LibraryView.columns).
    private static let oneColumn: CGFloat = 393 - 2 * Theme.Space.screenGutter
    private static let twoColumns: CGFloat = (oneColumn - Theme.Space.md) / 2

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
}
