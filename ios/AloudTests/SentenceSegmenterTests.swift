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

    /// H046: Chinese and Japanese write no space after a clause mark, and
    /// "，" is "," once normalized: a long sentence still breaks after a
    /// clause mark, not mid-word at exactly the length limit.
    func testLongCJKSentenceSplitsAfterClauseMarks() {
        let chinese = String(repeating: "他走到池边,看那水中游鱼来来去去", count: 25) + "。"
        let japanese = String(repeating: "私は古い喫茶店に入り、珈琲を一杯頼んだ", count: 22) + "。"
        for (sentence, mark) in [(chinese, ","), (japanese, "、")] {
            let chunks = SentenceSegmenter.softSplitLongSentence(sentence)
            XCTAssertGreaterThanOrEqual(chunks.count, 2)
            XCTAssertEqual(chunks.joined(), sentence, "nothing lost")
            for chunk in chunks.dropLast() {
                XCTAssertLessThanOrEqual(chunk.count, SentenceSegmenter.maxSentenceLength)
                XCTAssertTrue(chunk.hasSuffix(mark), String(chunk.suffix(8)))
            }
        }
        // A thousands comma between digits is still no clause break.
        let digits = String(repeating: "1,500,000 ", count: 50).trimmingCharacters(in: .whitespaces)
        for chunk in SentenceSegmenter.softSplitLongSentence(digits) {
            XCTAssertTrue(chunk.hasPrefix("1,500,000"), String(chunk.prefix(12)))
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

    /// L013: accented Latin vowels count with the accent off, a diaeresis
    /// vowel is its own syllable, and only a plain lone final "e" is silent.
    func testAccentedLatinVowelsCount() {
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("été"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("café"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("résumé"), 3)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("naïve"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("Zoë"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("fiancée"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("señor"), 2)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("degree"), 2)   // "-ee" is said
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("tongue"), 1)   // "-gue" is not
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("vague."), 1)

        let tokens = SentenceSegmenter.tokenizeSentence("The résumé lay on the table.")
        let resume = tokens.first { $0.text == "résumé" }
        let the = tokens.first { $0.text == "The" }
        XCTAssertGreaterThan(resume?.weight ?? 0, 2 * (the?.weight ?? 1))
    }

    /// L013: other scripts weigh what they say, not 1 a word: vowel letters
    /// in Cyrillic and Greek, one a character in Han, a virama's silenced
    /// vowel uncounted in Devanagari.
    func testOtherScriptsCountTheirSyllables() {
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("Здравствуйте"), 3)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("и"), 1)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("Χαίρετε"), 3)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("संयुक्तराष्ट्र"), 5)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("नमस्ते"), 3)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("床前明月光"), 5)
        XCTAssertEqual(SentenceSegmenter.estimatedSyllables("שלום"), 2)
    }

    /// H040: a number weighs what the voice says for it, so the word
    /// highlight doesn't run ahead of a sentence full of years.
    func testNumberTokensWeighTheirSpokenLength() throws {
        XCTAssertEqual(SentenceSegmenter.spokenNumberSyllables("1915"), 4)
        XCTAssertEqual(SentenceSegmenter.spokenNumberSyllables("1914-1918"), 9)
        XCTAssertEqual(SentenceSegmenter.spokenNumberSyllables("1,500"), 6)
        XCTAssertEqual(SentenceSegmenter.spokenNumberSyllables("7"), 1)
        XCTAssertEqual(SentenceSegmenter.spokenNumberSyllables("words"), 0)

        let tokens = SentenceSegmenter.tokenizeSentence(
            "Between 1914-1918 and 1939-1945 over 1,500 towns were destroyed.")
        let towns = try XCTUnwrap(tokens.firstIndex { $0.text == "towns" })
        let total = tokens.reduce(0) { $0 + $1.weight }
        let before = tokens[..<towns].reduce(0) { $0 + $1.weight }
        // Spoken, "towns" comes at about 85% of the clip; weighing the
        // numbers as one syllable each put it at 59%.
        XCTAssertGreaterThan(before / total, 0.75)
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

    func testPunctuationGluedToCloserSurvivesSkip() {
        // The span is removed at character-range granularity, so punctuation
        // hugging the closer is kept — no "Result 2), holds." fragments.
        XCTAssertEqual(SentenceSegmenter.spokenText("Result (see fig. 2), holds.", skipBrackets: true),
                       "Result, holds.")
        XCTAssertEqual(SentenceSegmenter.spokenText("as predicted [12].", skipBrackets: true),
                       "as predicted.")
        XCTAssertEqual(SentenceSegmenter.spokenText("He paused (quietly), then left.", skipBrackets: true),
                       "He paused, then left.")
    }

    func testOrphanedLeadingCommaDroppedWithLeadingSpan() {
        XCTAssertEqual(SentenceSegmenter.spokenText("(However), we left.", skipBrackets: true),
                       "we left.")
    }

    func testGluedSpanStaysWhileFreeSpanDrops() {
        // "(s)" is glued to a word character and must survive; "(draft)"
        // stands free and is dropped.
        XCTAssertEqual(SentenceSegmenter.spokenText("Save item(s) and (draft) notes.", skipBrackets: true),
                       "Save item(s) and notes.")
    }

    func testTokenizationNonDestructiveWithGluedPunctuation() {
        let text = "Result (see fig. 2), holds [12]. done"
        XCTAssertEqual(SentenceSegmenter.tokenizeSentence(text).map(\.text).joined(), text)
    }

    // MARK: - Special-case skipping

    func testCitationMarkersSkipped() {
        XCTAssertEqual(SentenceSegmenter.spokenText("Gravity bends light [12] as predicted.", skipBrackets: true),
                       "Gravity bends light as predicted.")
        XCTAssertEqual(SentenceSegmenter.spokenText("Results agree [3,4] with theory.", skipBrackets: true),
                       "Results agree with theory.")
        XCTAssertEqual(SentenceSegmenter.spokenText("See the appendix [note 7] for details.", skipBrackets: true),
                       "See the appendix for details.")
    }

    func testCurlyBracesSkipped() {
        XCTAssertEqual(SentenceSegmenter.spokenText("Values {a, b, c} are shown.", skipBrackets: true),
                       "Values are shown.")
    }

    func testStandaloneFootnoteMarkersSkipped() {
        XCTAssertEqual(SentenceSegmenter.spokenText("The result † holds everywhere.", skipBrackets: true),
                       "The result holds everywhere.")
        XCTAssertEqual(SentenceSegmenter.spokenText("Doubly noted †† here.", skipBrackets: true),
                       "Doubly noted here.")
    }

    func testStandaloneAsteriskStaysSpoken() {
        // A free-standing "*" is ambiguous (multiplication, emphasis, scene
        // breaks) so it is never treated as a footnote marker — only daggers.
        XCTAssertEqual(SentenceSegmenter.spokenText("2 * 3 = 6", skipBrackets: true),
                       "2 * 3 = 6")
        XCTAssertEqual(SentenceSegmenter.spokenText("A rule * with an exception.", skipBrackets: true),
                       "A rule * with an exception.")
        XCTAssertEqual(SentenceSegmenter.spokenText("† *", skipBrackets: true), "*")
    }

    func testGluedFootnoteMarkerStaysSpoken() {
        // A dagger attached to a word is not "standing alone" — keep it.
        XCTAssertEqual(SentenceSegmenter.spokenText("word† stays", skipBrackets: true),
                       "word† stays")
    }

    func testFullyBracketedSentenceSilenced() {
        // A sentence skipping empties returns "" — the playback layer plays a
        // short silence for it and advances, so the aside is never read aloud.
        XCTAssertEqual(SentenceSegmenter.spokenText("(An entire aside of a sentence.)", skipBrackets: true),
                       "")
    }

    func testCitationOnlySentencesSilenced() {
        XCTAssertEqual(SentenceSegmenter.spokenText("[12]", skipBrackets: true), "")
        XCTAssertEqual(SentenceSegmenter.spokenText("[Illustration: The White Rabbit]", skipBrackets: true),
                       "")
        XCTAssertEqual(SentenceSegmenter.spokenText("[1] (2) {3}", skipBrackets: true), "")
        XCTAssertEqual(SentenceSegmenter.spokenText("† ‡", skipBrackets: true), "")
    }

    func testTokenizationNonDestructiveWithMarkers() {
        let text = "A claim † with [12] notes * end."
        XCTAssertEqual(SentenceSegmenter.tokenizeSentence(text).map(\.text).joined(), text)
    }

    func testStandaloneMarkerTokenIsSkippable() {
        let tokens = SentenceSegmenter.tokenizeSentence("Noted † indeed")
        XCTAssertEqual(tokens.first { $0.text == "†" }?.isSkippable, true)
        XCTAssertEqual(tokens.first { $0.text == "Noted" }?.isSkippable, false)
    }
}
