import XCTest
@testable import Aloud

final class TextNormalizerTests: XCTestCase {

    // MARK: - NFKC / ligatures

    func testLigaturesExpand() {
        XCTAssertEqual(TextNormalizer.normalize("ﬁnancial ﬂows are eﬃcient"),
                       "financial flows are efficient")
    }

    // MARK: - Invisible characters

    func testSoftHyphenDeleted() {
        XCTAssertEqual(TextNormalizer.normalize("co\u{00AD}operate"), "cooperate")
    }

    func testZeroWidthFamilyDeleted() {
        XCTAssertEqual(TextNormalizer.normalize("zero\u{200B}width\u{200C}chars\u{200D}here\u{FEFF}"),
                       "zerowidthcharshere")
    }

    /// F079: ZWJ and ZWNJ are spelling beside an emoji or a non-Latin
    /// letter, and stay; between Latin letters they still go.
    func testJoinersKeptInEmojiAndNonLatinText() {
        XCTAssertEqual(TextNormalizer.normalize("She typed \u{1F469}\u{200D}\u{1F4BB} all night."),
                       "She typed \u{1F469}\u{200D}\u{1F4BB} all night.")
        XCTAssertEqual(TextNormalizer.normalize("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"), "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}")
        XCTAssertEqual(TextNormalizer.normalize("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"),
                       "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}")
        XCTAssertEqual(TextNormalizer.normalize("\u{0915}\u{094D}\u{200D}\u{0937}"), "\u{0915}\u{094D}\u{200D}\u{0937}")
        XCTAssertEqual(TextNormalizer.normalize("af\u{200C}fair and \u{200D} spaced"), "affair and spaced")
    }

    func testControlCharactersStripped() {
        XCTAssertEqual(TextNormalizer.normalize("a\u{07}b\u{1F}c"), "abc")
    }

    // MARK: - Spaces

    func testExoticSpacesBecomePlainSpace() {
        XCTAssertEqual(TextNormalizer.normalize("a\u{00A0}b\u{2003}c\u{202F}d"), "a b c d")
    }

    func testLineAndParagraphSeparators() {
        XCTAssertEqual(TextNormalizer.normalize("one\u{2028}two\u{2029}three"), "one two three")
    }

    func testWhitespaceCollapsedAndTrimmed() {
        XCTAssertEqual(TextNormalizer.normalize("  a\t b\n\nc  "), "a b c")
    }

    // MARK: - Quotes, dashes, ellipsis, bullets

    func testSmartQuotesStraightened() {
        XCTAssertEqual(TextNormalizer.normalize("\u{201C}Hello,\u{201D} it\u{2019}s me"),
                       "\"Hello,\" it's me")
    }

    func testEnDashRangeBecomesSpacedHyphen() {
        XCTAssertEqual(TextNormalizer.normalize("1990\u{2013}1995"), "1990 - 1995")
    }

    func testEmDashBecomesSpacedHyphen() {
        XCTAssertEqual(TextNormalizer.normalize("wait\u{2014}no"), "wait - no")
    }

    /// H039: after a number an em dash (a clause break) keeps apart from an
    /// en dash (a range): it becomes the ASCII em dash, "--".
    func testEmDashAfterANumberBecomesDoubleHyphen() {
        XCTAssertEqual(TextNormalizer.normalize("In 1915\u{2014}20 years later"), "In 1915 -- 20 years later")
        XCTAssertEqual(TextNormalizer.normalize("in 1850 \u{2015} 3 years"), "in 1850 -- 3 years")
        XCTAssertEqual(TextNormalizer.normalize("1914\u{2013}18"), "1914 - 18")
        XCTAssertEqual(TextNormalizer.normalize("wait\u{2014}20 of them"), "wait - 20 of them")
    }

    /// I005/I010: an em dash before a range end is still a range: a year,
    /// or a short number with no count after it. I006: a spaced en dash
    /// (British parenthetical dash) is a clause break before a count, like
    /// the em dash; an unspaced en dash is always a range.
    func testDashAfterANumberIsARangeBeforeARangeEnd() {
        XCTAssertEqual(TextNormalizer.normalize("The war of 1914\u{2014}1918 changed everything"),
                       "The war of 1914 - 1918 changed everything")
        XCTAssertEqual(TextNormalizer.normalize("Charles Darwin (1809\u{2014}1882)"), "Charles Darwin (1809 - 1882)")
        XCTAssertEqual(TextNormalizer.normalize("Dickens (1812 \u{2014} 1870)"), "Dickens (1812 - 1870)")
        XCTAssertEqual(TextNormalizer.normalize("The 1914\u{2014}18 war"), "The 1914 - 18 war")
        XCTAssertEqual(TextNormalizer.normalize("In 1915 \u{2013} 20 years later"), "In 1915 -- 20 years later")
        XCTAssertEqual(TextNormalizer.normalize("In 1915 \u{2013} 30 men came."), "In 1915 -- 30 men came.")
        XCTAssertEqual(TextNormalizer.normalize("In 1915\u{2014}1,000 men came."), "In 1915 -- 1,000 men came.")
        XCTAssertEqual(TextNormalizer.normalize("(1809 \u{2013} 1882)"), "(1809 - 1882)")
        XCTAssertEqual(TextNormalizer.normalize("the war of 1914 \u{2013} 18"), "the war of 1914 - 18")
        XCTAssertEqual(TextNormalizer.normalize("In 1914\u{2013}18 men died."), "In 1914 - 18 men died.")
        XCTAssertEqual(TextNormalizer.normalize("in 1915 \u{2014} the year"), "in 1915 -- the year")
    }

    func testEllipsisExpanded() {
        XCTAssertEqual(TextNormalizer.normalize("Wait\u{2026} what"), "Wait... what")
    }

    func testBulletsDropped() {
        XCTAssertEqual(TextNormalizer.normalize("\u{2022} Item one"), "Item one")
        XCTAssertEqual(TextNormalizer.normalize("\u{00B7} dotted"), "dotted")
    }

    // MARK: - De-hyphenation

    func testLineWrapHyphenationRepaired() {
        XCTAssertEqual(TextNormalizer.normalize("inter- national"), "international")
        XCTAssertEqual(TextNormalizer.normalize("inter-\nnational"), "international")
    }

    func testGenuineCompoundsUntouched() {
        XCTAssertEqual(TextNormalizer.normalize("well-being matters"), "well-being matters")
    }

    // MARK: - Punctuation spacing

    func testSpaceBeforePunctuationRemoved() {
        XCTAssertEqual(TextNormalizer.normalize("Hello , world . Yes !"), "Hello, world. Yes!")
    }

    // MARK: - Guards

    func testEmptyInputReturnedAsIs() {
        XCTAssertEqual(TextNormalizer.normalize(""), "")
    }

    func testAllRemovedContentFallsBackToOriginal() {
        // A lone bullet normalizes to empty, so the original (trimmed) survives.
        XCTAssertEqual(TextNormalizer.normalize("\u{2022}"), "\u{2022}")
    }

    func testIdempotent() {
        let messy = "  ﬁrst\u{00AD} draft\u{2014}with \u{201C}quotes\u{201D}, 1990\u{2013}95\u{2026} \u{2022} done "
        let once = TextNormalizer.normalize(messy)
        XCTAssertEqual(TextNormalizer.normalize(once), once)
    }
}
