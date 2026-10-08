import XCTest
@testable import Aloud

/// The reader page's pure rules that both apps share (iPhone parity B6):
/// the measure-dependent body setting (P043), the quote Copy, Share and
/// VoiceOver's lines take (P042, P045), Look Up's word (P042), the chip's
/// reach in the follow band (P049) and the title bar's header (P046).
/// No views, no UIKit or AppKit: this suite runs on the iPhone and the Mac.
final class ReaderPageStyleSharedTests: XCTestCase {

    // MARK: Large type on a phone (P043)

    func testTheDefaultPhoneColumnKeepsTheBooksSetting() {
        let page = ReaderPageStyle(fontSize: 19)
        let setting = page.body(columnWidth: 354)
        XCTAssertEqual(setting.hyphenationFactor, 0.25, "19 pt in a 354 pt column is unchanged")
        XCTAssertEqual(setting.firstLineIndent, 21, "round(1.1 x 19), under 6% of the column")
        XCTAssertEqual(page.body(columnWidth: nil), page.body(columnWidth: .infinity))
        XCTAssertEqual(page.body(columnWidth: nil).hyphenationFactor, ReaderPageStyle.hyphenationFactor)
        XCTAssertEqual(page.body(columnWidth: nil).firstLineIndent, page.firstLineIndent)
    }

    func testTheMacsNormalColumnIsUnchanged() {
        for size: CGFloat in [16, 19, 23, 26] {
            let page = ReaderPageStyle(fontSize: size)
            XCTAssertEqual(page.body(columnWidth: 640),
                           ReaderPageStyle.BodySetting(firstLineIndent: page.firstLineIndent,
                                                       hyphenationFactor: ReaderPageStyle.hyphenationFactor),
                           "\(size) pt in the 640 pt measure")
        }
    }

    func testANarrowColumnAtLargeSizesHyphenatesMoreAndIndentsLess() {
        let page = ReaderPageStyle(fontSize: 40)
        let column: CGFloat = 402 - 2 * 16
        let setting = page.body(columnWidth: column)
        XCTAssertGreaterThanOrEqual(setting.hyphenationFactor, 0.5)
        XCTAssertLessThanOrEqual(setting.firstLineIndent, 0.06 * column, "at most 6% of the column")
        XCTAssertLessThan(setting.firstLineIndent, page.firstLineIndent)
    }

    func testHyphenationRisesLinearlyAndClamps() {
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: 40), 0.25)
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: ReaderPageStyle.wideColumnEms), 0.25)
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: ReaderPageStyle.narrowColumnEms), 0.6)
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: 5), 0.6)
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: 15), 0.425, accuracy: 0.001)
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: .infinity), 0.25)
    }

    // MARK: Quotes (P042, P045)

    /// Ported from the Mac's copy across a rule: the rule paragraph's
    /// attachment and the line it stood on never reach a quote.
    func testAQuoteAcrossARuleParagraphKeepsOnlyTheWords() {
        let text = NSAttributedString(string: "Last sentence.\nChapter Two\n\u{FFFC}\nFirst line of chapter two.")
        XCTAssertEqual(ReaderColumnText.quote(of: NSRange(location: 0, length: text.length), in: text),
                       "Last sentence.\nChapter Two\nFirst line of chapter two.")
        XCTAssertEqual(ReaderColumnText.quotable("words\n\u{FFFC}"), "words\n", "a selection ending on the rule")
        XCTAssertEqual(ReaderColumnText.quotable("plain words"), "plain words")
    }

    /// A quote across a PDF page's mark leaves out the numeral (the page's
    /// furniture) and the rule: no U+FFFC, no numeral.
    func testAQuoteAcrossAPageMarkLeavesOutTheNumeral() {
        let text = NSMutableAttributedString(string: "End of page one. ")
        text.append(NSAttributedString(string: "\n\u{FFFC}\n"))
        text.append(NSAttributedString(string: "12\n", attributes: [.readerFurniture: true]))
        text.append(NSAttributedString(string: "Top of page two."))
        let quote = ReaderColumnText.quote(of: NSRange(location: 0, length: text.length), in: text)
        XCTAssertFalse(quote.contains("\u{FFFC}"))
        XCTAssertFalse(quote.contains("12"))
        XCTAssertTrue(quote.hasPrefix("End of page one."))
        XCTAssertTrue(quote.hasSuffix("Top of page two."))
        XCTAssertEqual(ReaderColumnText.quote(of: NSRange(location: text.length, length: 4), in: text), "",
                       "nothing past the end")
    }

    func testLookUpTakesTheWordUnderTheFinger() {
        let text = NSMutableAttributedString(string: "The gilded age, 1925.\n")
        text.append(NSAttributedString(string: "12", attributes: [.readerFurniture: true]))
        let string = text.string as NSString
        let gilded = string.range(of: "gilded")
        XCTAssertEqual(ReaderColumnText.lookUpRange(at: gilded.location + 2, in: text), gilded)
        XCTAssertNil(ReaderColumnText.lookUpRange(at: string.range(of: ",").location, in: text), "punctuation")
        XCTAssertNil(ReaderColumnText.lookUpRange(at: string.range(of: "12").location, in: text), "furniture")
        XCTAssertNil(ReaderColumnText.lookUpRange(at: text.length, in: text))
        XCTAssertEqual(ReaderColumnText.longestWord(in: "The gilded age."), "gilded")
        XCTAssertNil(ReaderColumnText.longestWord(in: "\u{2014} !"))
    }

    func testASharedQuoteNamesTheBook() {
        XCTAssertEqual(ReaderMenuCopy.sharedQuote("So we beat on.", title: "The Great Gatsby",
                                                  author: "F. Scott Fitzgerald"),
                       "So we beat on.\n\u{2014} The Great Gatsby, F. Scott Fitzgerald")
        XCTAssertEqual(ReaderMenuCopy.sharedQuote("Words.", title: "Notes", author: nil), "Words.\n\u{2014} Notes")
    }

    // MARK: The chip's reach (P049)

    func testTheBandCountsTheChipOnlyWhileOneShows() {
        let bar = FollowBand.obscuredBottom(textMaxY: 800, chromeMinY: 700)
        XCTAssertEqual(bar, 100)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 800, chromeMinY: 700, chipReach: 52, showsChip: true),
                       100 + 52 + Theme.Space.sm)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 800, chromeMinY: 700, chipReach: 52, showsChip: false), bar)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: nil, chromeMinY: 700, chipReach: 52, showsChip: false), 0)
    }

    func testTheChipsReachIsARunningMaximum() {
        let first = FollowBand.chipReach(previous: 0, slotHeight: 44)
        XCTAssertEqual(first, (44 + Theme.Space.sm).rounded(.up))
        XCTAssertEqual(FollowBand.chipReach(previous: first, slotHeight: 0), first, "an empty slot keeps it")
        XCTAssertEqual(FollowBand.chipReach(previous: first, slotHeight: 30), first, "a smaller chip keeps it")
        XCTAssertGreaterThan(FollowBand.chipReach(previous: first, slotHeight: 60), first)
    }

    // MARK: The title bar (P046)

    func testTheTitleBarNamesTheAuthor() {
        XCTAssertEqual(ReaderTitleCopy.label(title: "The Great Gatsby", author: "F. Scott Fitzgerald"),
                       "The Great Gatsby, by F. Scott Fitzgerald")
        XCTAssertEqual(ReaderTitleCopy.label(title: "Notes", author: nil), "Notes")
        XCTAssertEqual(ReaderTitleCopy.label(title: "Notes", author: ""), "Notes")
    }
}
