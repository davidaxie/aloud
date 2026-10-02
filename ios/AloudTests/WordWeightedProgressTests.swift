import XCTest
@testable import Aloud

/// R25's two time-left lines agree: the controller saves progress as the
/// share of the book's words before the sentence (`positionFraction`), the
/// sums the reader's position line counts, so the card's `wordCount` times
/// (1 - fraction) is the reader's words left however uneven the sentences
/// (a PDF's index or reference list of short lines). By position only when
/// there are no words to weigh; a Finished book's cue still never
/// un-finishes it (R24).
///
/// Silent: the muted rig, never played.
@MainActor
final class WordWeightedProgressTests: XCTestCase {

    // MARK: - The rule

    /// Two 2-word sentences, then two 8-word ones: 20 words.
    private static let sums = [0, 2, 4, 12, 20]

    func testTheFractionWeighsWordsNotSentences() {
        XCTAssertEqual(PlaybackController.positionFraction(of: 0, wordsBefore: Self.sums, sentenceCount: 4), 0)
        XCTAssertEqual(PlaybackController.positionFraction(of: 1, wordsBefore: Self.sums, sentenceCount: 4),
                       0.1, accuracy: 1e-12)
        XCTAssertEqual(PlaybackController.positionFraction(of: 2, wordsBefore: Self.sums, sentenceCount: 4),
                       0.2, accuracy: 1e-12, "half the sentences, a fifth of the words")
    }

    func testTheLastSentenceStillHasItsOwnWordsAhead() {
        XCTAssertEqual(PlaybackController.positionFraction(of: 3, wordsBefore: Self.sums, sentenceCount: 4),
                       0.6, accuracy: 1e-12, "not 3/4: the long last sentence is 40% of the book")
    }

    func testAnIndexOutsideTheSumsFallsBackToItsPosition() {
        // Sums for fewer sentences than the book has: by position.
        XCTAssertEqual(PlaybackController.positionFraction(of: 3, wordsBefore: [0, 5, 10], sentenceCount: 6),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(PlaybackController.positionFraction(of: 2, wordsBefore: [], sentenceCount: 8),
                       0.25, accuracy: 1e-12, "no sums at all")
    }

    func testABookWithNoWordsFallsBackToItsPosition() {
        XCTAssertEqual(PlaybackController.positionFraction(of: 1, wordsBefore: [0, 0, 0, 0], sentenceCount: 3),
                       1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(PlaybackController.positionFraction(of: 0, wordsBefore: [], sentenceCount: 0), 0,
                       "never a division by zero")
    }

    // MARK: - In the controller

    /// Five 2-word lines, then five 8-word ones: 50 words, half of them
    /// sentences 0-4 by count but a fifth by words.
    private static func unevenBook() -> DocContent {
        var sentences: [Sentence] = []
        for index in 0..<10 {
            let words = ["Line\(index)"] + Array(repeating: "word", count: index < 5 ? 1 : 7)
            sentences.append(Sentence(id: index, text: words.joined(separator: " ") + ".", para: 0, page: 0))
        }
        return DocContent(title: "Uneven", pageCount: 1, sentences: sentences,
                          paragraphs: [Paragraph(id: 0, sentenceIDs: 0..<10, page: 0)],
                          contentHash: "uneven")
    }

    func testSavedProgressIsWordWeightedSoTheCardMatchesTheReader() throws {
        let rig = PlaybackTestRig(sentences: 10)
        let content = Self.unevenBook()
        XCTAssertEqual(content.wordCount, 50)
        var document = PlaybackTestRig.makeDocument(hash: "uneven", sentences: 10, progressSentence: 5)
        document.wordCount = content.wordCount

        rig.controller.load(document: document, content: content)
        let cued = try XCTUnwrap(rig.progress.last)
        XCTAssertEqual(cued.sentence, 5)
        XCTAssertEqual(cued.fraction, 10.0 / 50, accuracy: 1e-12, "the load's cue writes words, not 5/10")

        rig.controller.seek(to: 8, andPlay: false)
        let saved = try XCTUnwrap(rig.progress.last)
        XCTAssertEqual(saved.sentence, 8)
        XCTAssertEqual(saved.fraction, 34.0 / 50, accuracy: 1e-12)

        // The card's time left from that record counts the reader's words
        // left: sentences 8 and 9, 16 words.
        document.progressSentence = saved.sentence
        document.progressFraction = saved.fraction
        let readerSeconds = 16 / LibraryDocument.spokenWordsPerMinute * 60
        XCTAssertEqual(try XCTUnwrap(document.estimatedSecondsRemaining(rate: 1)), readerSeconds, accuracy: 1e-9)
    }

    /// The last sentence holds 8 of the 50 words (0.84 before it), so only
    /// the Finished cue keeps a stored 1.0 from being written back lower.
    func testAFinishedBooksCueKeepsItsStoredFraction() throws {
        let rig = PlaybackTestRig(sentences: 10)
        let content = Self.unevenBook()
        var document = PlaybackTestRig.makeDocument(hash: "uneven", sentences: 10,
                                                    progressSentence: 9, progressFraction: 1.0)
        document.wordCount = content.wordCount

        rig.controller.load(document: document, content: content)
        XCTAssertEqual(rig.controller.status, .ended)
        let cued = try XCTUnwrap(rig.progress.last)
        XCTAssertEqual(cued.sentence, 9)
        XCTAssertEqual(cued.fraction, 1.0, "never 0.84")
    }
}
