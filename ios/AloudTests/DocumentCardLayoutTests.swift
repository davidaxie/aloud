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

    func testTheTwoColumnCardKeepsItsLimits() {
        let width = Self.twoColumns
        let title = Theme.font(.headline)
        for size in [DynamicTypeSize.large, .xxxLarge] {
            XCTAssertEqual(cardExtra(width: width, size: size),
                           textExtra(titleLimit: 2, authorLimit: 1, width: width, size: size),
                           accuracy: 1, "\(size): two lines of title and one of author")
            XCTAssertGreaterThan(textHeight(Self.title, font: title, lineLimit: nil, width: width, size: size),
                                 textHeight(Self.title, font: title, lineLimit: 2, width: width, size: size) + 10,
                                 "\(size) fixture: the title should need more than two lines")
        }
    }
}
