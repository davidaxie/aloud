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
