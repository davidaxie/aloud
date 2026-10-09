import XCTest
import UIKit
@testable import Aloud

/// Display typesetting (`ReaderTypography`): curly quotes and em dashes on
/// screen, and the UTF-16 length contract that keeps sentence/word ranges
/// exact. The column's attributed string is `ReaderColumnTextTests`.
final class ReaderTypographyTests: XCTestCase {

    // MARK: - Quotes

    func testDoubleQuotesCurlOpenAndClose() {
        XCTAssertEqual(ReaderTypography.typeset(#""Whenever you feel like criticizing anyone," he told me."#),
                       "\u{201C}Whenever you feel like criticizing anyone,\u{201D} he told me.")
    }

    func testQuoteAfterDashOrBracketOpens() {
        XCTAssertEqual(ReaderTypography.typeset(#"He said ("yes") and left."#),
                       "He said (\u{201C}yes\u{201D}) and left.")
    }

    func testApostrophesBecomeRightSingleQuotes() {
        XCTAssertEqual(ReaderTypography.typeset("I've been turning it over; didn't you?"),
                       "I\u{2019}ve been turning it over; didn\u{2019}t you?")
    }

    func testSingleQuotedDialogue() {
        XCTAssertEqual(ReaderTypography.typeset("'Hello,' she said."),
                       "\u{2018}Hello,\u{2019} she said.")
    }

    func testLeadingElisionsStayApostrophes() {
        XCTAssertEqual(ReaderTypography.typeset("'Tis the season."), "\u{2019}Tis the season.")
        XCTAssertEqual(ReaderTypography.typeset("Back in the '90s."), "Back in the \u{2019}90s.")
    }

    // MARK: - Review regressions (quotes after dashes, nesting, elisions)

    func testClosingQuoteAfterDoubleHyphenCloses() {
        XCTAssertEqual(ReaderTypography.typeset(#""Why, I--" he began."#),
                       "\u{201C}Why, I\u{2014}\u{2060}\u{201D} he began.")
    }

    func testClosingQuoteAfterSpacedDashCloses() {
        // TextNormalizer folds an em dash to " - " before sentences are stored.
        XCTAssertEqual(ReaderTypography.typeset(#""But I - " She stopped."#),
                       "\u{201C}But I \u{2014} \u{201D} She stopped.")
        XCTAssertEqual(ReaderTypography.typeset("'But I - ' she said."),
                       "\u{2018}But I \u{2014} \u{2019} she said.")
    }

    func testNestedOpeningQuotes() {
        XCTAssertEqual(ReaderTypography.typeset(#""'You must come,' he told me," she explained."#),
                       "\u{201C}\u{2018}You must come,\u{2019} he told me,\u{201D} she explained.")
        XCTAssertEqual(ReaderTypography.typeset(#"'"Such a fool," he called me.'"#),
                       "\u{2018}\u{201C}Such a fool,\u{201D} he called me.\u{2019}")
    }

    func testElisionsMatchWholeWordsAtAnyBoundary() {
        XCTAssertEqual(ReaderTypography.typeset("I'll show 'em!"), "I\u{2019}ll show \u{2019}em!")
        XCTAssertEqual(ReaderTypography.typeset("Get 'em"), "Get \u{2019}em")
        XCTAssertEqual(ReaderTypography.typeset("'Emma,' she said."), "\u{2018}Emma,\u{2019} she said.")
    }

    // MARK: - Dashes

    func testSpacedHyphenBecomesEmDash() {
        XCTAssertEqual(ReaderTypography.typeset("Simon Called Peter - either it was terrible"),
                       "Simon Called Peter \u{2014} either it was terrible")
    }

    func testDoubleHyphenBecomesEmDashPlusWordJoiner() {
        XCTAssertEqual(ReaderTypography.typeset("It was--I think--late."),
                       "It was\u{2014}\u{2060}I think\u{2014}\u{2060}late.")
    }

    func testHyphenatedWordsAndRulesAreUntouched() {
        XCTAssertEqual(ReaderTypography.typeset("the living-room"), "the living-room")
        XCTAssertEqual(ReaderTypography.typeset("---"), "---")
        XCTAssertEqual(ReaderTypography.typeset("a --- b"), "a --- b")
    }

    /// The segmenter trims each sentence, so the dash TextNormalizer spaced
    /// out (" - ") ends a sentence as " -". The end of the text counts as a
    /// space (R2-13: Gatsby's last page ends on a dash).
    func testASpacedHyphenEndingASentenceBecomesAnEmDash() {
        XCTAssertEqual(ReaderTypography.typeset("And one fine morning -"),
                       "And one fine morning \u{2014}")
    }

    /// A sentence the paragraph already started may open on the dash that
    /// joined it to the one before. Only the column knows that, so the
    /// leading rule needs `opensParagraph: false`; by default a "- item"
    /// list line keeps its hyphen.
    func testALeadingSpacedHyphenIsADashOnlyInsideAParagraph() {
        XCTAssertEqual(ReaderTypography.typeset("- and so it ended.", opensParagraph: false),
                       "\u{2014} and so it ended.")
        XCTAssertEqual(ReaderTypography.typeset("- milk"), "- milk")
        XCTAssertEqual(ReaderTypography.typeset("- milk", opensParagraph: true), "- milk")
    }

    func testLoneAndTrailingWordHyphensAreUntouched() {
        XCTAssertEqual(ReaderTypography.typeset("-"), "-")
        XCTAssertEqual(ReaderTypography.typeset("-", opensParagraph: false), "-")
        XCTAssertEqual(ReaderTypography.typeset("well-"), "well-")
        XCTAssertEqual(ReaderTypography.typeset("x-"), "x-")
        XCTAssertEqual(ReaderTypography.typeset("a well-"), "a well-")
        XCTAssertEqual(ReaderTypography.typeset("a ---"), "a ---")
    }

    /// The column passes `opensParagraph: false` for every sentence after
    /// the first in its paragraph and leaves a paragraph's first sentence on
    /// the default, so a list line keeps its hyphen.
    @MainActor
    func testTheColumnTypesetsADashAcrossASentenceBreak() {
        let sentences = [
            Sentence(id: 0, text: "And one fine morning -", para: 0, page: 1),
            Sentence(id: 1, text: "- and so it ended.", para: 0, page: 1),
            Sentence(id: 2, text: "- milk", para: 1, page: 1),
        ]
        let paragraphs = [
            Paragraph(id: 0, sentenceIDs: 0..<2, page: 1),
            Paragraph(id: 1, sentenceIDs: 2..<3, page: 1),
        ]
        let content = DocContent(title: "Test", pageCount: 1, sentences: sentences,
                                 paragraphs: paragraphs, contentHash: "h")
        let built = ReaderColumnText.makeAttributedString(content: content, fontSize: 19)
        let rendered = built.string.string as NSString
        XCTAssertEqual(rendered.substring(with: built.sentenceRanges[0]), "And one fine morning \u{2014}")
        XCTAssertEqual(rendered.substring(with: built.sentenceRanges[1]), "\u{2014} and so it ended.")
        XCTAssertEqual(rendered.substring(with: built.sentenceRanges[2]), "- milk")
    }

    func testPlainTextIsReturnedAsIs() {
        let text = "No quotes or dashes here."
        XCTAssertEqual(ReaderTypography.typeset(text), text)
    }

    // MARK: - Length contract

    /// Every range the reader computes walks the SOURCE text's UTF-16 lengths,
    /// so typesetting must never change a string's UTF-16 count.
    func testUTF16LengthIsAlwaysPreserved() {
        let alphabet = Array("ab '\"-(—\n.,1é😀")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...24, using: &generator)
            let sample = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            XCTAssertEqual(ReaderTypography.typeset(sample).utf16.count, sample.utf16.count,
                           "length changed for \(sample.debugDescription)")
            XCTAssertEqual(ReaderTypography.typeset(sample, opensParagraph: false).utf16.count,
                           sample.utf16.count,
                           "length changed mid-paragraph for \(sample.debugDescription)")
        }
    }
}
