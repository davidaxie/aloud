import XCTest
@testable import Aloud

final class SentenceSegmenterTests: XCTestCase {

    // MARK: - Sentence splitting

    func testBasicSplit() {
        XCTAssertEqual(SentenceSegmenter.splitIntoSentences("Hello world. This is a test."),
                       ["Hello world.", "This is a test."])
    }

    func testEmptyAndBlankInput() {
        XCTAssertEqual(SentenceSegmenter.splitIntoSentences(""), [])
        XCTAssertEqual(SentenceSegmenter.splitIntoSentences("   \n  "), [])
    }

    func testTitleAbbreviationNotSplit() {
        let sentences = SentenceSegmenter.splitIntoSentences("Dr. Smith arrived at 3 p.m. and left quickly.")
        XCTAssertEqual(sentences.count, 1)
        XCTAssertTrue(sentences[0].contains("Dr. Smith"))
    }

    func testLatinAbbreviationNotSplit() {
        let sentences = SentenceSegmenter.splitIntoSentences("See e.g. the appendix. Then stop.")
        XCTAssertEqual(sentences, ["See e.g. the appendix.", "Then stop."])
    }

    func testInitialismNotSplit() {
        let sentences = SentenceSegmenter.splitIntoSentences("The U.S. economy grew fast. It slowed later.")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("U.S. economy"))
    }

    func testSingleInitialNotSplit() {
        let sentences = SentenceSegmenter.splitIntoSentences("J. Smith wrote the book. It sold well.")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0], "J. Smith wrote the book.")
    }

    func testListMarkerNotSplit() {
        let sentences = SentenceSegmenter.splitIntoSentences("1. Begin the sequence now.")
        XCTAssertEqual(sentences, ["1. Begin the sequence now."])
    }

    // MARK: - Soft split

    func testShortSentenceUntouched() {
        XCTAssertEqual(SentenceSegmenter.softSplitLongSentence("Short."), ["Short."])
    }

    func testLongSentenceSplitsOnClauses() {
        let long = String(repeating: "alpha beta gamma delta epsilon, ", count: 30) + "end."
        let chunks = SentenceSegmenter.softSplitLongSentence(long)
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
            XCTAssertFalse(chunk.isEmpty)
        }
        // No words lost or broken across cuts.
        let originalWords = long.split(separator: " ").map(String.init)
        let chunkWords = chunks.joined(separator: " ").split(separator: " ").map(String.init)
        XCTAssertEqual(chunkWords, originalWords)
    }

    func testLongSentenceWithoutPunctuationSplitsOnSpaces() {
        let long = String(repeating: "word ", count: 100).trimmingCharacters(in: .whitespaces)
        let chunks = SentenceSegmenter.softSplitLongSentence(long)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
            // Every chunk is whole words — nothing was hard-cut mid-word.
            XCTAssertTrue(chunk.split(separator: " ").allSatisfy { $0 == "word" })
        }
    }

    func testChunkParagraphCombinesBothPasses() {
        let text = "First sentence here. " + String(repeating: "clause after clause, ", count: 25) + "done."
        let chunks = SentenceSegmenter.chunkParagraph(text)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertTrue(chunks[0].hasPrefix("First sentence here."))
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
        }
        // Nothing lost across both passes.
        let originalWords = text.split(separator: " ").map(String.init)
        let chunkWords = chunks.joined(separator: " ").split(separator: " ").map(String.init)
        XCTAssertEqual(chunkWords, originalWords)
    }

    // MARK: - Tokenization

    func testTokenizationIsNonDestructive() {
        let text = "  Keep (this)  spaced—out, ok?  "
        let tokens = SentenceSegmenter.tokenizeSentence(text)
        XCTAssertEqual(tokens.map(\.text).joined(), text)
    }

    func testTokenFlags() {
        let tokens = SentenceSegmenter.tokenizeSentence("wait — ok")
        let dash = tokens.first { $0.text == "—" }
        XCTAssertNotNil(dash)
        XCTAssertFalse(dash!.isWord)          // no letters/digits
        XCTAssertGreaterThan(dash!.weight, 0) // but it carries pause time
        let word = tokens.first { $0.text == "wait" }
        XCTAssertEqual(word?.isWord, true)
    }

    func testWhitespaceTokensHaveZeroWeight() {
        let tokens = SentenceSegmenter.tokenizeSentence("a b")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[1].weight, 0)
        XCTAssertFalse(tokens[1].isWord)
    }

    // MARK: - Syllables

    func testEstimatedSyllables() {
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("make"), 1)   // silent e
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("table"), 2)  // -le kept
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("the"), 1)    // only vowel kept
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("understanding"), 4)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("123"), 0)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables(""), 0)
    }

    // MARK: - Bracket skipping

    func testSpokenTextVerbatimWhenNotSkipping() {
        let text = "Keep this (drop this) end."
        XCTAssertEqual(SentenceSegmenter.spokenText(text, skipBrackets: false), text)
    }

    func testSpokenTextDropsBracketedSpans() {
        XCTAssertEqual(SentenceSegmenter.spokenText("Keep this (drop this) end.", skipBrackets: true),
                       "Keep this end.")
    }

    func testNestedBracketsSkippedAsOneSpan() {
        XCTAssertEqual(SentenceSegmenter.spokenText("a (b [c] d) e", skipBrackets: true), "a e")
    }

    func testUnmatchedOpenerWithoutCloserIsIgnored() {
        XCTAssertEqual(SentenceSegmenter.spokenText("A (b c", skipBrackets: true), "A (b c")
    }

    func testStrayCloserIsIgnored() {
        XCTAssertEqual(SentenceSegmenter.spokenText("a) b c", skipBrackets: true), "a) b c")
    }

    func testGluedParentheticalStaysSpoken() {
        // A parenthetical glued mid-word is not fully inside the span's tokens.
        XCTAssertEqual(SentenceSegmenter.spokenText("word(aside)more stays", skipBrackets: true),
                       "word(aside)more stays")
    }

    func testSkippedSpanCollapsesWhitespace() {
        XCTAssertEqual(SentenceSegmenter.spokenText("Result (see fig. 2) holds, done.", skipBrackets: true),
                       "Result holds, done.")
    }
}
