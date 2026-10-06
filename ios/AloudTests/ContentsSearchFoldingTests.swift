import XCTest
@testable import Aloud

/// Contents search folds the query's typeset punctuation to the ASCII that
/// TextNormalizer stores, so a pasted, dictated or Smart Punctuation query
/// ("Daisy’s", “quoted”, an em dash) finds what the reader shows.
final class ContentsSearchFoldingTests: XCTestCase {

    /// Stored text, as the extractor writes it: ASCII quotes, a real dash
    /// folded to " - ", Gutenberg's "--" kept, an ASCII ellipsis.
    private let book = DocContent(
        title: "Fixture",
        pageCount: 1,
        sentences: [
            Sentence(id: 0, text: "Daisy's voice was full of money.", para: 0, page: 1),
            Sentence(id: 1, text: "\"Whenever you feel like criticizing anyone,\" he told me.", para: 1, page: 1),
            Sentence(id: 2, text: "This was a point definitely settled - but the very definitiveness.", para: 2, page: 1),
            Sentence(id: 3, text: "I said--and meant it--that I would go.", para: 3, page: 1),
            Sentence(id: 4, text: "Well... no, 'tis nothing.", para: 4, page: 1),
            Sentence(id: 5, text: "x - y and later x--y.", para: 5, page: 1),
        ],
        paragraphs: [],
        contentHash: "folding")

    func testCurlyApostropheMatchesStoredASCII() {
        let matches = book.matches(of: "Daisy\u{2019}s")
        XCTAssertEqual(matches.map(\.sentenceID), [0])
        XCTAssertEqual(matches.first?.matchedText, "Daisy's")
    }

    func testOpeningSingleQuoteMatches() {
        XCTAssertEqual(book.matches(of: "\u{2018}tis").map(\.sentenceID), [4])
    }

    func testCurlyDoubleQuotesMatch() {
        XCTAssertEqual(book.matches(of: "\u{201C}Whenever you feel").map(\.sentenceID), [1])
        XCTAssertEqual(book.matches(of: "anyone,\u{201D}").map(\.sentenceID), [1])
    }

    /// The reader shows " - " as an em dash; typed with or without spaces
    /// around it, the dash finds the stored spaced hyphen.
    func testEmDashMatchesTheStoredSpacedHyphen() {
        XCTAssertEqual(book.matches(of: "settled\u{2014}but").map(\.sentenceID), [2])
        XCTAssertEqual(book.matches(of: "settled \u{2014} but").map(\.sentenceID), [2])
        XCTAssertEqual(book.matches(of: "settled \u{2013} but").map(\.sentenceID), [2])
    }

    /// ...and Gutenberg's "--", shown as an em dash too.
    func testEmDashMatchesTheStoredDoubleHyphen() {
        XCTAssertEqual(book.matches(of: "said\u{2014}and").map(\.sentenceID), [3])
    }

    /// Text copied from the reader carries the word joiner set after a
    /// typeset "--".
    func testCopiedWordJoinerIsIgnored() {
        XCTAssertEqual(book.matches(of: "said\u{2014}\u{2060}and").map(\.sentenceID), [3])
    }

    func testEllipsisCharacterMatchesThreeDots() {
        XCTAssertEqual(book.matches(of: "Well\u{2026}").map(\.sentenceID), [4])
    }

    /// One match per sentence, at the earliest of the dash spellings.
    func testDashQueryReportsTheFirstOccurrence() {
        let matches = book.matches(of: "x\u{2014}y")
        XCTAssertEqual(matches.map(\.sentenceID), [5])
        XCTAssertEqual(matches.first?.matchedText, "x - y")
    }

    /// Two spellings still poll cancellation once per sentence.
    func testDashQueryPollsCancellationOncePerSentence() {
        var polls = 0
        _ = book.matches(of: "a\u{2014}b", isCancelled: {
            polls += 1
            return false
        })
        XCTAssertEqual(polls, book.sentences.count)
    }

    /// F093: the spaces the normalizer stores plain (no-break, narrow,
    /// thin), runs of spaces, and a space before punctuation are folded
    /// the same way in a query.
    func testQuerySpacesFoldLikeStoredText() {
        let darcy = DocContent(
            title: "Fixture", pageCount: 1,
            sentences: [Sentence(id: 0, text: "\"I am glad, Mr. Darcy, to see you.\" Il dit: oui.", para: 0, page: 1)],
            paragraphs: [], contentHash: "spaces")
        for query in ["Mr.\u{00A0}Darcy", "Mr.\u{202F}Darcy", "Mr.\u{2009}Darcy", "Mr.  Darcy", "Mr.\tDarcy",
                      "dit\u{202F}:", "glad ,"] {
            XCTAssertEqual(darcy.matches(of: query).map(\.sentenceID), [0], query.debugDescription)
        }
        XCTAssertEqual(DocContent.searchNeedles(for: "Mr.\u{00A0}Darcy"), ["Mr. Darcy"])
        XCTAssertEqual(DocContent.searchNeedles(for: "a \u{2014}\u{00A0}b"), ["a -- b", "a - b"])
    }

    /// F079's search side: a ZWJ the normalizer now keeps is kept in the
    /// query, with a needle without it for a book imported before.
    func testJoinerNeedles() {
        XCTAssertEqual(DocContent.searchNeedles(for: "\u{1F469}\u{200D}\u{1F4BB}"),
                       ["\u{1F469}\u{200D}\u{1F4BB}", "\u{1F469}\u{1F4BB}"])
        XCTAssertEqual(DocContent.searchNeedles(for: "af\u{200C}fair"), ["affair"])
    }

    func testNeedlesForPlainAndDashedQueries() {
        XCTAssertEqual(DocContent.searchNeedles(for: "  whale  "), ["whale"])
        XCTAssertEqual(DocContent.searchNeedles(for: " \u{2019} "), ["'"])
        XCTAssertEqual(DocContent.searchNeedles(for: "\u{200B} "), [])
        XCTAssertEqual(DocContent.searchNeedles(for: "a \u{2014} b"), ["a -- b", "a - b"])
    }
}
