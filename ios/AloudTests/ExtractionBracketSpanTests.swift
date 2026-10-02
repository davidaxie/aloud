import XCTest
@testable import Aloud

/// Bracketed spans with a sentence end inside stay one sentence, so
/// skip-brackets (which decides per sentence) can drop them whole.
final class ExtractionBracketSpanTests: XCTestCase {

    private func chunks(_ paragraph: String) -> [String] {
        SentenceSegmenter.chunkParagraph(TextNormalizer.normalize(paragraph))
    }

    private func spoken(_ paragraph: String) -> [String] {
        chunks(paragraph).map { SentenceSegmenter.spokenText($0, skipBrackets: true) }
    }

    func testMultiSentenceCaptionIsOneSilentSentence() {
        XCTAssertEqual(chunks("[Illustration: The ship. It sank.]"),
                       ["[Illustration: The ship. It sank.]"])
        XCTAssertEqual(spoken("[Illustration: The ship. It sank.]"), [""])
    }

    func testGulliverStyleCaptionMidParagraph() {
        let paragraph = "Before. [Illustration: \"HE COMMANDED HIS GENERALS TO DRAW UP THE TROOPS.\" P. 42.] After it."
        XCTAssertEqual(chunks(paragraph), [
            "Before.",
            "[Illustration: \"HE COMMANDED HIS GENERALS TO DRAW UP THE TROOPS.\" P. 42.]",
            "After it.",
        ])
        XCTAssertEqual(spoken(paragraph), ["Before.", "", "After it."])
    }

    func testMultiSentenceAsideIsSkippedWhole() {
        XCTAssertEqual(chunks("(He said so. She agreed.) Then they left."),
                       ["(He said so. She agreed.)", "Then they left."])
        XCTAssertEqual(spoken("(He said so. She agreed.) Then they left."), ["", "Then they left."])
    }

    func testStageDirectionWithItalicsIsOneSentence() {
        XCTAssertEqual(chunks("[_Exit Countess._]"), ["[_Exit Countess._]"])
        let paragraph = "[_Lane is arranging afternoon tea on a table, and after the music has ceased, Algernon enters._] I don't know that I am much interested in your family life, Lane."
        XCTAssertEqual(chunks(paragraph), [
            "[_Lane is arranging afternoon tea on a table, and after the music has ceased, Algernon enters._]",
            "I don't know that I am much interested in your family life, Lane.",
        ])
    }

    func testGluedFootnoteReferenceStaysWithItsSentence() {
        let paragraph = "Breakfasted with the Rev. Dr. Somerville.[344] This venerable gentleman is old."
        XCTAssertEqual(chunks(paragraph), [
            "Breakfasted with the Rev. Dr. Somerville.[344]",
            "This venerable gentleman is old.",
        ])
        XCTAssertEqual(spoken(paragraph)[0], "Breakfasted with the Rev. Dr. Somerville.")
    }

    func testUnclosedOpenerIsIgnored() {
        XCTAssertEqual(chunks("He paid (with a smile. A big one."),
                       ["He paid (with a smile.", "A big one."])
    }

    func testSpanLongerThanSoftSplitLengthIsLeftSplit() {
        let inside = String(repeating: "This is one more sentence inside the aside. ", count: 12)
        let result = chunks("(" + inside + ") After.")
        XCTAssertGreaterThan(result.count, 2)
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
        }
    }

    func testMergeThatSoftSplittingWouldCutIsNotMade() {
        // The aside opens late in a long sentence. Merging it whole would
        // make a piece over the soft-split length, cut again at a comma
        // inside the aside; the natural sentence boundary is kept instead.
        let first = "The old porter told us, in his slow way, that the house had stood (so his father had always said, and his grandfather before him, whose memory went back a long way, longer than anyone else in the village could claim, to the days of the great frost and the flood that followed it."
        let second = "The river rose in the night, and by morning the lower rooms stood deep in water.)"
        let result = chunks(first + " " + second + " Then he went home.")
        XCTAssertEqual(result, [first, second, "Then he went home."])
    }

    func testShortSpanInALongSentenceStaysWhole() {
        // A long sentence is soft-split anyway; a short bracketed span that
        // the tokenizer cut ("(p." | "810).") is still merged when the
        // soft split leaves it whole.
        let paragraph = "The press he used was the same machine, which was like the one the author described in his lecture at the society last year, and which he showed to all present with great care and many fine words, together with the tools of the trade, his notes, his drawings, and a set of coins struck by him in a hurry to show the stages of the process he described in his lecture (p. 810). In a letter he said more."
        let result = chunks(paragraph)
        XCTAssertTrue(result.contains { $0.hasSuffix("in his lecture (p. 810).") }, "\(result)")
        XCTAssertFalse(result.contains("810)."))
        XCTAssertEqual(result.last, "In a letter he said more.")
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
        }
    }

    func testChainedSpansInALongPieceStayWhole() {
        let paragraph = (0..<12).map { "we saw it (He left. She stayed \($0)) and" }
            .joined(separator: " ") + " the end."
        let result = chunks(paragraph)
        XCTAssertEqual(result.joined(separator: " "), paragraph)
        for n in 0..<12 {
            XCTAssertTrue(result.contains { $0.contains("(He left. She stayed \(n))") }, "span \(n)")
        }
        for chunk in result {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
        }
    }

    func testClosingMarksStayWithTheSentenceTheyEnd() {
        XCTAssertEqual(chunks("_Hush, child._ She slept."), ["_Hush, child._", "She slept."])
        XCTAssertEqual(chunks("It was _very_ odd. _Quite_ odd._ Then."),
                       ["It was _very_ odd.", "_Quite_ odd._", "Then."])
        // A leading apostrophe belongs to the next word.
        XCTAssertEqual(chunks("'Tis true. 'Twas so."), ["'Tis true.", "'Twas so."])
    }

    func testSuperscriptFootnoteMarkerStaysWithItsSentence() {
        let paragraph = "It came back to me from childhood.¹ It was a sharp reminder. The end.²"
        XCTAssertEqual(chunks(paragraph),
                       ["It came back to me from childhood.¹", "It was a sharp reminder.", "The end.²"])
        // The next sentence no longer opens with the marker (read "one it was").
        XCTAssertEqual(spoken(paragraph)[1], "It was a sharp reminder.")
        // A superscript glued to a following word is not a trailing mark.
        XCTAssertEqual(chunks("He left. ²He came back."), ["He left.", "²He came back."])
    }

    func testMergedTextIsExactlyAsWritten() {
        // Pieces are slices of the paragraph: no space is inserted where a
        // boundary is undone, and UTF-16 lengths line up for the reader.
        let paragraph = "Smile 😀. [Illustration: A 😀 face. It grins.] Done 👍. _Fin._"
        let result = chunks(paragraph)
        XCTAssertEqual(result, ["Smile 😀.", "[Illustration: A 😀 face. It grins.]", "Done 👍.", "_Fin._"])
        XCTAssertEqual(result.joined(separator: " "), paragraph)
        for sentence in result {
            let tokens = SentenceSegmenter.tokenizeSentence(sentence)
            XCTAssertEqual(tokens.map(\.text).joined(), sentence)
            XCTAssertEqual(tokens.reduce(0) { $0 + $1.text.utf16.count }, sentence.utf16.count)
        }
    }
}
