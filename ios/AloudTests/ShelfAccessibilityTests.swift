import SwiftUI
import XCTest
@testable import Aloud

/// R12f/R12g: what VoiceOver hears for a shelf card, and the management
/// actions every card and the hero offer.
final class ShelfAccessibilityTests: XCTestCase {

    private func doc(title: String = "Title", author: String? = "Author",
                     progress: Double = 0.43, wordCount: Int = 20_842,
                     kind: DocKind = .text, pageCount: Int = 1) -> LibraryDocument {
        LibraryDocument(id: UUID(), title: title, fileName: "doc", addedAt: Date(timeIntervalSince1970: 0),
                        pageCount: pageCount, sentenceCount: 100, progressSentence: 43,
                        progressFraction: progress, contentHash: "hash", kind: kind,
                        author: author, wordCount: wordCount)
    }

    // MARK: - Card label

    /// R25: "Title, Author, <spoken form>", never a percent.
    func testLabelReadsTitleAuthorAndTheSpokenSubtitle() {
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(), rate: 1),
                       "Title, Author, 1 hour 12 minutes left")
    }

    func testLabelWithoutAnAuthor() {
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(author: nil), rate: 1),
                       "Title, 1 hour 12 minutes left")
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(author: ""), rate: 1),
                       "Title, 1 hour 12 minutes left")
    }

    /// A PDF reads like a book: its length, with no page-count lead.
    func testPDFReadsLikeABook() {
        let pdf = doc(title: "Doc", author: nil, progress: 0, wordCount: 1_320, kind: .pdf, pageCount: 12)
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: pdf, rate: 1), "Doc, 8 minutes")
    }

    func testFinishedBook() {
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(progress: 1), rate: 1),
                       "Title, Author, finished")
    }

    /// A book of unknown length has no line, so its label adds nothing.
    func testUnknownLengthReadsTitleAndAuthorOnly() {
        XCTAssertEqual(DocumentCardView.accessibilityLabel(for: doc(progress: 0.43, wordCount: 0), rate: 1),
                       "Title, Author")
    }

    func testLabelNeverSaysMinHrOrAMiddleDot() {
        for rate in [0.5, 1, 1.5, 3] {
            for progress in [0, 0.43, 0.995] {
                let label = DocumentCardView.accessibilityLabel(for: doc(progress: progress), rate: rate)
                XCTAssertFalse(label.contains("·"), label)
                XCTAssertFalse(label.contains("%"), label)
                XCTAssertNil(label.range(of: #"\b(min|hr)\b"#, options: .regularExpression), label)
                XCTAssertTrue(label.hasPrefix("Title, Author, "), "starts with the visible text: \(label)")
            }
        }
    }

    // MARK: - Document actions

    func testUnfinishedBookOffersAllThree() {
        XCTAssertEqual(DocumentAction.available(for: doc()).map(\.title),
                       ["Rename", "Mark as Finished", "Delete"])
        // Past 0.99 with 20 minutes left (333,333 words), a book is in
        // progress, so it can still be marked.
        XCTAssertEqual(DocumentAction.available(for: doc(progress: LibraryDocument.finishedThreshold,
                                                         wordCount: 333_333)).map(\.title),
                       ["Rename", "Mark as Finished", "Delete"], "the shelf's one Finished rule")
    }

    func testFinishedBookHasNothingToMark() {
        XCTAssertEqual(DocumentAction.available(for: doc(progress: 1)).map(\.title), ["Rename", "Delete"])
        // 9,900 words is an hour: 0.99 leaves 36 seconds.
        XCTAssertEqual(DocumentAction.available(for: doc(progress: LibraryDocument.finishedThreshold,
                                                         wordCount: 9_900)).map(\.title),
                       ["Rename", "Delete"], "the shelf's one Finished rule")
    }

    func testOnlyDeleteIsDestructive() {
        XCTAssertEqual(DocumentAction.delete.role, .destructive)
        XCTAssertNil(DocumentAction.rename.role)
        XCTAssertNil(DocumentAction.markFinished.role)
        XCTAssertEqual(DocumentAction.allCases.map(\.systemImage), ["pencil", "checkmark.circle", "trash"])
    }

    /// Mark as finished lands the record where the Finished rule reads it.
    func testMarkingFinishedDropsTheAction() {
        let marked = DocumentStore.markingFinished(doc())
        XCTAssertTrue(marked.isFinished)
        XCTAssertFalse(DocumentAction.available(for: marked).contains(.markFinished))
    }

    // MARK: - Voice Control

    /// J017: "Tap The Great Gatsby" reaches the book. Voice Control matched
    /// the spoken labels, which end in a time left that changes as you
    /// listen (a grid card) or start with the eyebrow (the Continue card).
    func testVoiceControlAnswersToTheTitle() {
        let gatsby = doc(title: "The Great Gatsby", author: "F. Scott Fitzgerald")
        XCTAssertEqual(DocumentCardView.inputLabels(for: gatsby), ["The Great Gatsby"])
        XCTAssertEqual(DocumentCardView.inputLabels(for: doc(title: "The Great Gatsby", progress: 0.9)),
                       ["The Great Gatsby"], "the time left never enters the name")
        XCTAssertEqual(ContinueListeningCopy.inputLabels(title: gatsby.title),
                       ["The Great Gatsby", "Continue listening"])
    }

    // MARK: - Large text

    /// L016: from xxLarge, the largest sizes below the accessibility range,
    /// a card's title and author wrap in full rather than stop at two lines
    /// and one: at those sizes a phone's two columns cut a long author's
    /// name and a classic's title short. Below it the limits stay.
    func testCardsWrapInFullFromTheLargestStandardSizes() {
        for size: DynamicTypeSize in [.xSmall, .small, .medium, .large, .xLarge] {
            XCTAssertFalse(DocumentCardView.wrapsInFull(at: size), "\(size)")
        }
        for size: DynamicTypeSize in [.xxLarge, .xxxLarge, .accessibility1, .accessibility5] {
            XCTAssertTrue(DocumentCardView.wrapsInFull(at: size), "\(size)")
        }
    }

    /// L016: the grid card and the hero both read that rule; the hero no
    /// longer keeps its title at two lines beside the cover and circle.
    func testTheCardAndTheHeroWrapByTheOneRule() throws {
        let paths = ["Library/DocumentCardView.swift", "Library/ContinueListeningCard.swift"]
        let sources = try SourceTree.sources(only: paths)
        let card = try XCTUnwrap(sources[paths[0]])
        let hero = try XCTUnwrap(sources[paths[1]])
        XCTAssertTrue(card.contains("let wrapsInFull = Self.wrapsInFull(at: dynamicTypeSize)"))
        XCTAssertFalse(card.contains("let wrapsInFull = dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(hero.contains("titleText.lineLimit(DocumentCardView.wrapsInFull(at: dynamicTypeSize) ? nil : 2)"))
        XCTAssertFalse(hero.contains("titleText.lineLimit(2)"), "a fixed two lines cut the hero's title")
    }
}
