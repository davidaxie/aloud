import XCTest
@testable import Aloud

/// Selection logic behind the Library's Continue Listening hero card:
/// the most recently listened in-progress document wins; never-opened,
/// not-started, and finished documents never qualify.
final class ContinueListeningSelectionTests: XCTestCase {

    private func doc(title: String = "Book",
                     progress: Double,
                     lastOpened: Date?,
                     kind: DocKind = .text,
                     pageCount: Int = 1,
                     wordCount: Int = 9_900) -> LibraryDocument {
        LibraryDocument(id: UUID(),
                        title: title,
                        fileName: "\(UUID().uuidString).txt",
                        addedAt: Date(timeIntervalSince1970: 0),
                        lastOpenedAt: lastOpened,
                        pageCount: pageCount,
                        sentenceCount: 100,
                        progressSentence: 10,
                        progressFraction: progress,
                        contentHash: "hash",
                        kind: kind,
                        wordCount: wordCount)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + offset)
    }

    // MARK: - Selection

    func testPicksMostRecentlyListenedInProgressDocument() {
        let older = doc(title: "Older", progress: 0.5, lastOpened: date(0))
        let newest = doc(title: "Newest", progress: 0.2, lastOpened: date(200))
        let middle = doc(title: "Middle", progress: 0.8, lastOpened: date(100))

        let picked = DocumentStore.continueListeningCandidate(in: [older, newest, middle])
        XCTAssertEqual(picked?.id, newest.id,
                       "Recency of listening decides, not amount of progress")
    }

    func testSingleQualifyingDocumentIsPicked() {
        let only = doc(progress: 0.43, lastOpened: date(0))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [only])?.id, only.id)
    }

    // MARK: - Exclusions

    func testNeverOpenedDocumentsAreExcluded() {
        // progress > 0 with a nil lastOpenedAt shouldn't occur in practice,
        // but the guard must hold regardless.
        let neverOpened = doc(progress: 0.5, lastOpened: nil)
        XCTAssertNil(DocumentStore.continueListeningCandidate(in: [neverOpened]))
    }

    func testNotStartedDocumentsAreExcluded() {
        let opened = doc(progress: 0, lastOpened: date(0))
        XCTAssertNil(DocumentStore.continueListeningCandidate(in: [opened]))
    }

    func testFinishedDocumentsAreExcluded() {
        // 0.99 is the shelf's "Finished" threshold; both it and 1.0 are out.
        let nearlyDone = doc(progress: 0.99, lastOpened: date(0))
        let done = doc(progress: 1.0, lastOpened: date(100))
        XCTAssertNil(DocumentStore.continueListeningCandidate(in: [nearlyDone, done]))
    }

    func testJustUnderFinishedThresholdStillQualifies() {
        let almost = doc(progress: 0.989, lastOpened: date(0))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [almost])?.id, almost.id)
    }

    func testExcludedDocumentsNeverOutrankAQualifyingOne() {
        let finishedRecent = doc(title: "Finished", progress: 1.0, lastOpened: date(500))
        let freshRecent = doc(title: "Fresh", progress: 0, lastOpened: date(400))
        let inProgress = doc(title: "In progress", progress: 0.3, lastOpened: date(10))

        let picked = DocumentStore.continueListeningCandidate(
            in: [finishedRecent, freshRecent, inProgress])
        XCTAssertEqual(picked?.id, inProgress.id)
    }

    func testEmptyLibraryYieldsNil() {
        XCTAssertNil(DocumentStore.continueListeningCandidate(in: []))
    }

    // MARK: - Shelf layout (hero + grid, derived once)

    func testShelfLayoutLiftsTheHeroOutOfTheGrid() {
        let hero = doc(title: "Hero", progress: 0.4, lastOpened: date(100))
        let other = doc(title: "Other", progress: 0, lastOpened: date(50))

        let shelf = ShelfLayout(for: [hero, other])
        XCTAssertEqual(shelf.hero?.id, hero.id)
        XCTAssertEqual(shelf.grid.map(\.id), [other.id],
                       "The hero is shown once — as the hero, not also in the grid")
    }

    func testShelfLayoutKeepsEveryDocumentWhenThereIsNoHero() {
        let fresh = doc(title: "Fresh", progress: 0, lastOpened: date(0))
        let finished = doc(title: "Finished", progress: 1.0, lastOpened: date(10))

        let shelf = ShelfLayout(for: [fresh, finished])
        XCTAssertNil(shelf.hero)
        XCTAssertEqual(shelf.grid.map(\.id), [fresh.id, finished.id])
    }

    func testShelfLayoutPreservesStoreOrder() {
        let first = doc(title: "First", progress: 0, lastOpened: date(300))
        let hero = doc(title: "Hero", progress: 0.5, lastOpened: date(200))
        let third = doc(title: "Third", progress: 0, lastOpened: date(100))

        let shelf = ShelfLayout(for: [first, hero, third])
        XCTAssertEqual(shelf.hero?.id, hero.id)
        XCTAssertEqual(shelf.grid.map(\.id), [first.id, third.id],
                       "The store's last-listened-first order survives the split")
    }

    func testEmptyShelfLayoutHasNoHeroAndNoGrid() {
        XCTAssertNil(ShelfLayout.empty.hero)
        XCTAssertTrue(ShelfLayout.empty.grid.isEmpty)
        XCTAssertNil(ShelfLayout(for: []).hero)
        XCTAssertTrue(ShelfLayout(for: []).grid.isEmpty)
    }

    // MARK: - Shelf subtitle (one implementation for hero and grid card)

    func testSubtitlePairsProgressWithTimeLeft() {
        // 9,900 words at 165 wpm = 60 min whole; half read leaves 30.
        let book = doc(progress: 0.5, lastOpened: date(0))
        XCTAssertEqual(book.listeningSubtitle(rate: 1.0), "50% · 30 min left")
    }

    func testSubtitleScalesWithTheRateItIsGiven() {
        // The rate is the book's effective (per-book) rate, not a global one:
        // the same book at 2× must read as half the time left.
        let book = doc(progress: 0.5, lastOpened: date(0))
        XCTAssertEqual(book.listeningSubtitle(rate: 2.0), "50% · 15 min left")
    }

    func testSubtitleLeadOverrideKeepsTheSameEstimateFormatting() {
        // The grid card's PDF lead is the only difference between the two
        // cards; separator, suffix and rounding come from the shared helper.
        let pdf = doc(progress: 0.5, lastOpened: date(0), kind: .pdf, pageCount: 12)
        XCTAssertEqual(pdf.listeningSubtitle(rate: 1.0, lead: "12 pages"),
                       "12 pages · 30 min left")
    }

    func testSubtitleWithoutAWordCountShowsTheLeadAlone() {
        let unknown = doc(progress: 0.5, lastOpened: date(0), wordCount: 0)
        XCTAssertEqual(unknown.listeningSubtitle(rate: 1.0), "50%")
    }

    func testFinishedBookReadsFinishedInsteadOfTimeLeft() {
        let done = doc(progress: 1.0, lastOpened: date(0))
        XCTAssertEqual(done.listeningSubtitle(rate: 1.0), "100% · Finished")
    }
}
