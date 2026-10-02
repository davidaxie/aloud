import XCTest
@testable import Aloud

/// Scene-break rows ("* * * * *") are shown but never spoken: the neural
/// voice's espeak fallback reads "*" as "asterisk".
final class ExtractionSceneBreakTests: XCTestCase {

    func testAsteriskRowIsSilentWithSkipBracketsOnAndOff() {
        for row in ["* * * * *", "*****", "*       *       *", "* * * * * * *"] {
            XCTAssertEqual(SentenceSegmenter.spokenText(row, skipBrackets: true), "", row)
            XCTAssertEqual(SentenceSegmenter.spokenText(row, skipBrackets: false), "", row)
        }
    }

    func testOtherRuleRowsAreSilent() {
        for row in ["-----", "=", "+ + +", "~~~", "• • •", "......", "│"] {
            XCTAssertTrue(SentenceSegmenter.isSeparatorRow(row), row)
            XCTAssertEqual(SentenceSegmenter.spokenText(row, skipBrackets: false), "", row)
        }
    }

    func testRowsWithWordsOrMixedMarksAreNotSeparators() {
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow("2 * 3 = 6"))
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow("A rule * with an exception."))
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow("† *"))
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow("*]"))
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow(""))
        XCTAssertFalse(SentenceSegmenter.isSeparatorRow("   "))
    }

    func testExistingAsteriskInvariantsHold() {
        // The standalone asterisk inside text stays spoken, and a dagger
        // next to an asterisk is still the only mark dropped.
        XCTAssertEqual(SentenceSegmenter.spokenText("2 * 3 = 6", skipBrackets: true), "2 * 3 = 6")
        XCTAssertEqual(SentenceSegmenter.spokenText("A rule * with an exception.", skipBrackets: true),
                       "A rule * with an exception.")
        XCTAssertEqual(SentenceSegmenter.spokenText("† *", skipBrackets: true), "*")
        XCTAssertEqual(SentenceSegmenter.spokenText("Keep this (drop this) end.", skipBrackets: false),
                       "Keep this (drop this) end.")
    }

    func testSeparatorRowHasNoWordWindows() {
        // Playback schedules silence for it, so no word may light up.
        let tokens = SentenceSegmenter.tokenizeSentence("* * * * *")
        XCTAssertEqual(tokens.map(\.text).joined(), "* * * * *")
        XCTAssertTrue(tokens.allSatisfy { $0.weight == 0 && !$0.isWord })
        XCTAssertTrue(WordTimingEstimator.windows(sentenceText: "* * * * *",
                                                  duration: 0.3,
                                                  skipBrackets: false).isEmpty)
        XCTAssertEqual(SentenceSegmenter.spokenText(tokens: tokens, skipBrackets: false), "")
    }

    func testSceneBreakStaysItsOwnSentenceForDisplay() {
        // Still a sentence (the reader shows the break and indices don't
        // move); only the audio is silent.
        XCTAssertEqual(SentenceSegmenter.chunkParagraph(TextNormalizer.normalize("*       *       *")),
                       ["* * *"])
    }

    func testRowAlreadyStoredByOlderExtractorIsSilencedAtPlayback() {
        // Cached documents keep their sentences; the silence is decided when
        // the sentence is spoken, so no re-extraction is needed.
        let stored = Sentence(id: 7, text: "* * * * * * *", para: 3, page: 1)
        XCTAssertEqual(SentenceSegmenter.spokenText(stored.text, skipBrackets: true), "")
    }

    func testSceneBreakInExtractedBookIsSilent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-scene-\(UUID().uuidString).txt")
        try Data("""
        Alice was beginning to get very tired.

        *       *       *       *       *

        Down, down, down.
        """.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        XCTAssertEqual(content.sentences.map(\.text),
                       ["Alice was beginning to get very tired.", "* * * * *", "Down, down, down."])
        XCTAssertEqual(SentenceSegmenter.spokenText(content.sentences[1].text, skipBrackets: true), "")
    }
}
