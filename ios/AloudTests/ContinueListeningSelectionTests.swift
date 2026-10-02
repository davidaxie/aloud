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
        // The shelf's one Finished rule: 0.99 of an hour-long book (9,900
        // words) leaves 36 s, so it and 1.0 are both out.
        let nearlyDone = doc(progress: 0.99, lastOpened: date(0))
        let done = doc(progress: 1.0, lastOpened: date(100))
        XCTAssertTrue(nearlyDone.isFinished)
        XCTAssertNil(DocumentStore.continueListeningCandidate(in: [nearlyDone, done]))
    }

    func testJustUnderFinishedThresholdStillQualifies() {
        let almost = doc(progress: 0.989, lastOpened: date(0))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [almost])?.id, almost.id)
    }

    /// Past 0.99 with 20 minutes still to go (333,333 words), a long book is
    /// in progress: it is the Continue card, which reads its time left.
    func testALongBookPastTheThresholdWithMinutesLeftQualifies() {
        let longBook = doc(progress: 0.99, lastOpened: date(0), wordCount: 333_333)
        XCTAssertFalse(longBook.isFinished)
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [longBook])?.id, longBook.id)
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

    // MARK: - The loaded book (R18)

    func testLoadedBookIsTheHeroEvenAtZeroPercent() {
        let loaded = doc(title: "Loaded", progress: 0, lastOpened: date(0))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [loaded], loadedID: loaded.id)?.id,
                       loaded.id)
    }

    func testLoadedBookBeatsAMoreRecentInProgressBook() {
        let recent = doc(title: "Recent", progress: 0.6, lastOpened: date(500))
        let loaded = doc(title: "Loaded", progress: 0.1, lastOpened: date(10))
        let picked = DocumentStore.continueListeningCandidate(in: [recent, loaded], loadedID: loaded.id)
        XCTAssertEqual(picked?.id, loaded.id, "the card is where the loaded book plays")
    }

    func testLoadedFinishedBookIsTheHero() {
        let finished = doc(title: "Finished", progress: 1.0, lastOpened: date(0))
        let other = doc(title: "Other", progress: 0.3, lastOpened: date(100))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [other, finished],
                                                                loadedID: finished.id)?.id,
                       finished.id)
    }

    func testUnknownLoadedIDFallsBackToTheUsualRule() {
        let inProgress = doc(title: "In progress", progress: 0.3, lastOpened: date(10))
        let fresh = doc(title: "Fresh", progress: 0, lastOpened: date(100))
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [fresh, inProgress],
                                                                loadedID: UUID())?.id,
                       inProgress.id)
        XCTAssertEqual(DocumentStore.continueListeningCandidate(in: [fresh, inProgress],
                                                                loadedID: nil)?.id,
                       inProgress.id)
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

    func testShelfLayoutLiftsTheLoadedHeroOutOfTheGrid() {
        let first = doc(title: "First", progress: 0.5, lastOpened: date(300))
        let loaded = doc(title: "Loaded", progress: 0, lastOpened: date(200))
        let third = doc(title: "Third", progress: 0, lastOpened: date(100))

        let shelf = ShelfLayout(for: [first, loaded, third], loadedID: loaded.id)
        XCTAssertEqual(shelf.hero?.id, loaded.id)
        XCTAssertEqual(shelf.grid.map(\.id), [first.id, third.id],
                       "the loaded hero is shown once, and the in-progress book returns to the grid")
    }

    func testEmptyShelfLayoutHasNoHeroAndNoGrid() {
        XCTAssertNil(ShelfLayout.empty.hero)
        XCTAssertTrue(ShelfLayout.empty.grid.isEmpty)
        XCTAssertNil(ShelfLayout(for: []).hero)
        XCTAssertTrue(ShelfLayout(for: []).grid.isEmpty)
    }

    // MARK: - Shelf subtitle (one implementation for hero and grid card)

    func testSubtitleReadsTheTimeLeft() {
        // 9,900 words at 165 wpm = 60 min whole; half read leaves 30.
        let book = doc(progress: 0.5, lastOpened: date(0))
        XCTAssertEqual(book.listeningSubtitle(rate: 1.0), "30 min left")
    }

    func testSubtitleScalesWithTheRateItIsGiven() {
        // The rate is the app-wide speed: the same book at 2× must read as
        // half the time left.
        let book = doc(progress: 0.5, lastOpened: date(0))
        XCTAssertEqual(book.listeningSubtitle(rate: 2.0), "15 min left")
    }

    func testAPDFSubtitleReadsLikeABook() {
        // No page-count lead (R25): the hero and the grid card read one line.
        let pdf = doc(progress: 0.5, lastOpened: date(0), kind: .pdf, pageCount: 12)
        XCTAssertEqual(pdf.listeningSubtitle(rate: 1.0), "30 min left")
    }

    func testSubtitleWithoutAWordCountIsEmpty() {
        let unknown = doc(progress: 0.5, lastOpened: date(0), wordCount: 0)
        XCTAssertEqual(unknown.listeningSubtitle(rate: 1.0), "")
    }

    func testFinishedBookReadsFinishedInsteadOfTimeLeft() {
        let done = doc(progress: 1.0, lastOpened: date(0))
        XCTAssertEqual(done.listeningSubtitle(rate: 1.0), "Finished")
    }
}
