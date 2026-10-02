import XCTest
@testable import Aloud

/// R17 acceptance on the shipped books: War and Peace groups its chapters
/// under its BOOK and EPILOGUE headings, and Pepys' Diary scrubs one month
/// at a time. Slow (each test extracts a whole book); skipped when the
/// bundled file is missing.
final class BundledNavigationTests: XCTestCase {

    private func extracted(_ gutenbergID: Int) async throws -> (content: DocContent, navigation: ReaderNavigation) {
        guard let book = BookshelfCatalog.load(from: .main).first(where: { $0.gutenbergID == gutenbergID }),
              let url = BookshelfCatalog.bundledURL(for: book) else {
            throw XCTSkip("Bookshelf book \(gutenbergID) isn't bundled in this build")
        }
        let content = try await ExtractionPipeline().extractText(fileURL: url, title: book.title, progress: nil)
        return (content, ReaderNavigation(content: content, kind: .text))
    }

    func testWarAndPeaceGroupsChaptersUnderItsBooks() async throws {
        let (content, navigation) = try await extracted(2600)
        let titles = navigation.sections.map { $0.title ?? "" }

        XCTAssertTrue(content.sentences.first?.text.hasPrefix("BOOK ONE") ?? false,
                      "front matter still ends at BOOK ONE: \(content.sentences.first?.text ?? "nil")")
        XCTAssertTrue(titles.first?.hasPrefix("BOOK ONE: 1805") ?? false, "first section: \(titles.first ?? "nil")")
        XCTAssertGreaterThanOrEqual(titles.filter { $0.hasPrefix("BOOK ") }.count, 15, "\(titles)")
        XCTAssertTrue(titles.contains { $0.contains("FIRST EPILOGUE") }, "\(titles)")
        XCTAssertTrue(titles.contains { $0.contains("SECOND EPILOGUE") }, "\(titles)")
        XCTAssertTrue(navigation.sections.allSatisfy { !$0.chapterRange.isEmpty })
        XCTAssertGreaterThanOrEqual(navigation.chapters.count, 360)
        XCTAssertTrue(navigation.isGrouped)
    }

    func testPepysScrubsOneMonthAtATime() async throws {
        let (content, navigation) = try await extracted(4200)
        XCTAssertGreaterThanOrEqual(navigation.chapters.count, 100, "one chapter per month")
        let span = navigation.scrubSpan(at: content.sentences.count / 2)
        XCTAssertLessThan(Double(span.count), Double(content.sentences.count) * 0.02,
                          "a mid-book drag spans \(span.count) of \(content.sentences.count) sentences")
    }
}
