import XCTest
@testable import Aloud

/// R12f/R12g/R25: the shelf subtitle as VoiceOver reads it, from the same
/// implementation as the visible one, and Mark as finished.
final class ShelfModelTests: XCTestCase {

    private func doc(progress: Double,
                     wordCount: Int,
                     kind: DocKind = .text,
                     sentenceCount: Int = 100,
                     lastOpened: Date? = Date(timeIntervalSince1970: 1_000_000)) -> LibraryDocument {
        LibraryDocument(id: UUID(),
                        title: "Book",
                        fileName: "book.txt",
                        addedAt: Date(timeIntervalSince1970: 0),
                        lastOpenedAt: lastOpened,
                        pageCount: 12,
                        sentenceCount: sentenceCount,
                        progressSentence: 10,
                        progressFraction: progress,
                        contentHash: "hash",
                        kind: kind,
                        wordCount: wordCount)
    }

    // MARK: - Spoken subtitle

    func testSpokenSubtitleSpellsOutTheTime() {
        // 20,842 words at 165 wpm is 126.3 min; 57% of it is 72 min.
        let book = doc(progress: 0.43, wordCount: 20_842)
        XCTAssertEqual(book.spokenListeningSubtitle(rate: 1), "1 hour 12 minutes left")
        XCTAssertEqual(book.listeningSubtitle(rate: 1), "1 hr 12 min left")
    }

    /// A PDF reads like a book (R25): no page-count lead, and before the
    /// first listen its whole length.
    func testAnUnstartedPDFReadsItsLength() {
        let pdf = doc(progress: 0, wordCount: 1_320, kind: .pdf)
        XCTAssertEqual(pdf.spokenListeningSubtitle(rate: 1), "8 minutes")
        XCTAssertEqual(pdf.listeningSubtitle(rate: 1), "8 min")
    }

    func testFinishedReadsFinished() {
        let done = doc(progress: 1, wordCount: 9_900)
        XCTAssertEqual(done.spokenListeningSubtitle(rate: 1), "finished")
        XCTAssertEqual(done.listeningSubtitle(rate: 1), "Finished")
        XCTAssertEqual(done.shelfStatus(rate: 1), .finished)
    }

    func testAFinishedPDFReadsFinished() {
        let done = doc(progress: 1, wordCount: 1_320, kind: .pdf)
        XCTAssertEqual(done.listeningSubtitle(rate: 1), "Finished")
        XCTAssertEqual(done.spokenListeningSubtitle(rate: 1), "finished")
    }

    /// Finished outranks an unknown length: a book marked finished says so
    /// even though it was never measured.
    func testAFinishedBookOfUnknownLengthReadsFinished() {
        let done = doc(progress: 1, wordCount: 0)
        XCTAssertEqual(done.listeningSubtitle(rate: 1), "Finished")
        XCTAssertEqual(done.spokenListeningSubtitle(rate: 1), "finished")
    }

    func testUnknownLengthReadsNothing() {
        let unknown = doc(progress: 0.5, wordCount: 0)
        XCTAssertEqual(unknown.spokenListeningSubtitle(rate: 1), "")
        XCTAssertEqual(unknown.listeningSubtitle(rate: 1), "")
        XCTAssertEqual(unknown.shelfStatus(rate: 1), .unknown)
    }

    /// Both forms round to the same minute, at every rate and progress: an
    /// unstarted book quotes its whole length, every other its time left.
    func testVisibleAndSpokenAgreeOnTheMinute() {
        for words in [100, 9_900, 20_842, 333_333] {
            for progress in [0.0, 0.1, 0.43, 0.9] {
                for rate in [0.5, 1, 1.25, 2.5] {
                    let book = doc(progress: progress, wordCount: words)
                    let visible = book.listeningSubtitle(rate: rate)
                    let spoken = book.spokenListeningSubtitle(rate: rate)
                    let context = "\(words) words, \(progress), \(rate)×"
                    if progress == 0 {
                        let total = book.estimatedTotalSeconds(rate: rate) ?? 0
                        let minutes = ListeningEstimate.wholeMinutes(seconds: total)
                        XCTAssertEqual(visible, ListeningEstimate.phrase(minutes: minutes), context)
                        XCTAssertEqual(spoken, ListeningEstimate.spokenPhrase(minutes: minutes), context)
                        XCTAssertFalse(visible.hasSuffix(" left"), visible)
                    } else {
                        let remaining = book.estimatedSecondsRemaining(rate: rate) ?? 0
                        let minutes = ListeningEstimate.wholeMinutes(seconds: remaining)
                        XCTAssertEqual(visible, "\(ListeningEstimate.phrase(minutes: minutes)) left", context)
                        XCTAssertEqual(spoken, "\(ListeningEstimate.spokenPhrase(minutes: minutes)) left", context)
                    }
                    XCTAssertFalse(spoken.contains("·"), spoken)
                    XCTAssertFalse(visible.contains("%"), visible)
                }
            }
        }
    }

    // MARK: - Mark as finished

    func testMarkingFinishedMovesToTheLastSentence() {
        let opened = Date(timeIntervalSince1970: 5_000)
        let book = doc(progress: 0.3, wordCount: 9_900, sentenceCount: 40, lastOpened: opened)
        let finished = DocumentStore.markingFinished(book)
        XCTAssertEqual(finished.progressFraction, 1.0)
        XCTAssertEqual(finished.progressSentence, 39)
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.lastOpenedAt, opened, "finishing a book isn't listening to it")
        XCTAssertEqual(finished.id, book.id)
        XCTAssertEqual(finished.title, book.title)
    }

    func testMarkingAnEmptyBookFinishedStaysAtSentenceZero() {
        let empty = doc(progress: 0, wordCount: 0, sentenceCount: 0)
        let finished = DocumentStore.markingFinished(empty)
        XCTAssertEqual(finished.progressSentence, 0)
        XCTAssertEqual(finished.progressFraction, 1.0)
    }

    func testNeverOpenedBookStaysNeverOpened() {
        let fresh = doc(progress: 0, wordCount: 9_900, lastOpened: nil)
        XCTAssertNil(DocumentStore.markingFinished(fresh).lastOpenedAt)
    }

    // MARK: - Mark as Unfinished (R2-06)

    /// Partway, finished, unfinished: the place it had, and nothing kept.
    func testUnfinishingRestoresThePlaceTheMarkKept() {
        let opened = Date(timeIntervalSince1970: 5_000)
        let book = doc(progress: 0.3, wordCount: 9_900, sentenceCount: 40, lastOpened: opened)
        let finished = DocumentStore.markingFinished(book)
        XCTAssertEqual(finished.placeBeforeFinish, 10)
        XCTAssertEqual(finished.fractionBeforeFinish, 0.3)
        let unfinished = DocumentStore.markingUnfinished(finished, newestPlace: 25)
        XCTAssertEqual(unfinished.progressSentence, 10)
        XCTAssertEqual(unfinished.progressFraction, 0.3)
        XCTAssertFalse(unfinished.isFinished)
        XCTAssertNil(unfinished.placeBeforeFinish)
        XCTAssertNil(unfinished.fractionBeforeFinish)
        XCTAssertEqual(unfinished.lastOpenedAt, opened, "unfinishing a book isn't listening to it")
    }

    /// A book that finished by playing kept no place: back to the start,
    /// or to its newest place-history stop short of the end.
    func testABookThatPlayedToItsEndGoesBackToTheStartOrItsNewestStop() {
        let played = doc(progress: 1, wordCount: 9_900, sentenceCount: 40)
        let finished = DocumentStore.markingFinished(played)
        XCTAssertNil(finished.placeBeforeFinish, "nothing to keep at the end")
        let start = DocumentStore.markingUnfinished(finished)
        XCTAssertEqual(start.progressSentence, 0)
        XCTAssertEqual(start.progressFraction, 0)
        XCTAssertFalse(start.isFinished)

        let stop = DocumentStore.markingUnfinished(finished, newestPlace: 20)
        XCTAssertEqual(stop.progressSentence, 20)
        XCTAssertEqual(stop.progressFraction, 0.5, accuracy: 0.0001)
        XCTAssertFalse(stop.isFinished)

        // The newest stop of a short book that played to its end is that
        // end (place history records the last sentence): no way back, so
        // the start, as is a stop past the text or within
        // `PlaceHistory.samePlaceSentences` of the end. 39 of 40 reads
        // 0.975, under `LibraryDocument.finishedThreshold`, so only this
        // rule brings it back.
        for end in [39, 400, 39 - PlaceHistory.samePlaceSentences] {
            let back = DocumentStore.markingUnfinished(finished, newestPlace: end)
            XCTAssertEqual(back.progressSentence, 0, "stop \(end)")
            XCTAssertEqual(back.progressFraction, 0, "stop \(end)")
            XCTAssertFalse(back.isFinished, "stop \(end)")
        }
        // A stop just short of that is a place to go back to.
        let short = 38 - PlaceHistory.samePlaceSentences
        XCTAssertEqual(DocumentStore.markingUnfinished(finished, newestPlace: short).progressSentence, short)

        // The newest stop near the end of a long text, though clear of
        // its last sentences, would still read Finished (seconds left):
        // the start instead.
        let long = DocumentStore.markingFinished(doc(progress: 1, wordCount: 9_900, sentenceCount: 1_000))
        let nearTheEnd = 995
        XCTAssertLessThan(nearTheEnd, 999 - PlaceHistory.samePlaceSentences, "clear of the end")
        var wouldRead = long
        wouldRead.progressFraction = Double(nearTheEnd) / 1_000
        XCTAssertTrue(wouldRead.isFinished, "995 of 1,000 still reads Finished")
        let atTheEnd = DocumentStore.markingUnfinished(long, newestPlace: nearTheEnd)
        XCTAssertFalse(atTheEnd.isFinished)
        XCTAssertEqual(atTheEnd.progressSentence, 0)
        XCTAssertEqual(atTheEnd.progressFraction, 0)
    }

    /// Finishing twice keeps the first place, not the end.
    func testMarkingAFinishedRecordAgainKeepsItsPlace() {
        let finished = DocumentStore.markingFinished(doc(progress: 0.3, wordCount: 9_900, sentenceCount: 40))
        let again = DocumentStore.markingFinished(finished)
        XCTAssertEqual(again.placeBeforeFinish, 10)
        XCTAssertEqual(again.fractionBeforeFinish, 0.3)
    }
}
