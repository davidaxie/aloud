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

    /// I011: a clause break after a number is stored " -- ", which a query
    /// typed with any dash spacing finds.
    func testDashQueryMatchesTheStoredClauseBreakAfterANumber() {
        let stored = DocContent(
            title: "Fixture",
            pageCount: 1,
            sentences: [
                Sentence(id: 0, text: "Charles Dickens (1812 -- 1870) wrote it.", para: 0, page: 1),
                Sentence(id: 1, text: TextNormalizer.normalize("In 1915\u{2014}20 years later he came home."),
                         para: 1, page: 1),
            ],
            paragraphs: [],
            contentHash: "clause")
        XCTAssertEqual(stored.matches(of: "1812\u{2014}1870").map(\.sentenceID), [0])
        XCTAssertEqual(stored.matches(of: "Dickens (1812\u{2014}").map(\.sentenceID), [0])
        XCTAssertEqual(stored.matches(of: "1812 \u{2014} 1870").map(\.sentenceID), [0])
        XCTAssertEqual(stored.matches(of: "1915\u{2014}20").map(\.sentenceID), [1])
        XCTAssertEqual(stored.matches(of: "1915 \u{2013} 20 years").map(\.sentenceID), [1])
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

    /// H008: the normalizer stores NFKC text, so a fullwidth comma, colon,
    /// bracket, digit, letter or halfwidth kana typed by a Chinese or
    /// Japanese keyboard finds the folded form the reader shows.
    func testFullwidthQueryMatchesFoldedStoredText() {
        let cjk = DocContent(
            title: "Fixture", pageCount: 1,
            sentences: [
                Sentence(id: 0, text: "\u{4F60}\u{597D},\u{4E16}\u{754C}", para: 0, page: 1),
                Sentence(id: 1, text: "\u{4ED6}\u{8BF4}:\"\u{597D}\u{7684}\u{3002}\"", para: 1, page: 1),
                Sentence(id: 2, text: "(\u{6CE8})\u{8FD9}\u{662F}\u{4E00}\u{672C}\u{4E66}", para: 2, page: 1),
                Sentence(id: 3, text: "1945\u{5E74}\u{306B}ABC\u{793E}\u{30C6}\u{30B9}\u{30C8}", para: 3, page: 1),
                Sentence(id: 4, text: "It took 4\u{00BD} days.", para: 4, page: 1),
            ],
            paragraphs: [], contentHash: "width")
        let cases: [(String, Int)] = [
            ("\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}", 0),   // 你好，世界
            ("\u{4ED6}\u{8BF4}\u{FF1A}", 1),                     // 他说：
            ("\u{FF08}\u{6CE8}\u{FF09}", 2),                     // （注）
            ("\u{FF11}\u{FF19}\u{FF14}\u{FF15}\u{5E74}", 3),   // １９４５年
            ("\u{FF21}\u{FF22}\u{FF23}", 3),                     // ＡＢＣ
            ("\u{FF83}\u{FF7D}\u{FF84}", 3),                     // ﾃｽﾄ
        ]
        for (query, id) in cases {
            XCTAssertEqual(cjk.matches(of: query).map(\.sentenceID), [id], query.debugDescription)
        }
        XCTAssertEqual(cjk.matches(of: "\u{FF0C}").first?.matchedText, ",")
        // The fraction the normalizer keeps is still found as written.
        XCTAssertEqual(cjk.matches(of: "4\u{00BD}").map(\.sentenceID), [4])
    }

    func testNeedlesForPlainAndDashedQueries() {
        XCTAssertEqual(DocContent.searchNeedles(for: "  whale  "), ["whale"])
        XCTAssertEqual(DocContent.searchNeedles(for: " \u{2019} "), ["'"])
        XCTAssertEqual(DocContent.searchNeedles(for: "\u{200B} "), [])
        XCTAssertEqual(DocContent.searchNeedles(for: "a \u{2014} b"), ["a -- b", "a - b"])
    }
}
