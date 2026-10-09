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

    /// A 375 pt phone (SE 2/3, 12/13 mini): the default column is 327 pt
    /// (17.2 em at 19 pt), and it keeps the book's setting too; so does a
    /// column of exactly the wide measure.
    func testTheSmallestPhonesDefaultColumnKeepsTheBooksSetting() {
        let page = ReaderPageStyle(fontSize: 19)
        XCTAssertEqual(page.body(columnWidth: 375 - 2 * 24),
                       ReaderPageStyle.BodySetting(firstLineIndent: 21, hyphenationFactor: 0.25),
                       "19 pt in a 327 pt column is unchanged")
        let twenty = ReaderPageStyle(fontSize: 20)
        XCTAssertEqual(twenty.firstLineIndent(columnWidth: 360), 22, "18 em keeps round(1.1 x 20)")
        XCTAssertEqual(twenty.firstLineIndent(columnWidth: 20 * ReaderPageStyle.wideColumnEms), 22)
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
        let middle = (ReaderPageStyle.wideColumnEms + ReaderPageStyle.narrowColumnEms) / 2
        XCTAssertEqual(ReaderPageStyle.hyphenationFactor(emsPerLine: middle), 0.425, accuracy: 0.001)
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
        // R3-01: no chip term while either edge is unmeasured: a band of the
        // chip alone looked measured, and the colophon landed under the bar.
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: nil, chromeMinY: 700, chipReach: 56, showsChip: true), 0)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 800, chromeMinY: nil, chipReach: 56, showsChip: true), 0)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: nil, chromeMinY: nil, chipReach: 56, showsChip: true,
                                                 windowTextMaxY: nil, sheetMinY: nil), 0,
                       "the screen's whole band, nothing measured")
    }

    /// R3-01: the band is measured once both edges are, the bar taller
    /// than a touch target.
    func testTheBandIsMeasuredOnceBothEdgesAreAndTheBarHasAHeight() {
        XCTAssertFalse(FollowBand.isMeasured(textMaxY: nil, chromeMinY: 700))
        XCTAssertFalse(FollowBand.isMeasured(textMaxY: 874, chromeMinY: nil))
        XCTAssertFalse(FollowBand.isMeasured(textMaxY: 874, chromeMinY: 874), "a bar of no height")
        XCTAssertFalse(FollowBand.isMeasured(textMaxY: 874, chromeMinY: 830), "a bar of 44 pt is not yet the bar")
        XCTAssertTrue(FollowBand.isMeasured(textMaxY: 874, chromeMinY: 622))
    }

    /// R3-01 on both apps: while the colophon shows, the Mac page's resting
    /// end is measured from the colophon itself too, so a range clamped
    /// short by TextKit's trailing usage bounds never leaves it below the
    /// page. In an offscreen window those bounds already cover the colophon,
    /// so the Mac's hosted test passes either way; this pins the bound.
    func testTheMacsRestingEndIsMeasuredFromTheColophon() throws {
        let macPath = "Reader/ReaderColumnView.swift"
        let s = try SourceTree.sources(in: SourceTree.macRoot, only: [macPath])
        let mac = try XCTUnwrap(s[macPath])
        let open = try XCTUnwrap(mac.range(of: "private func restingOffsets() -> ClosedRange<CGFloat> {"),
                                 "the Mac page's resting range")
        let close = mac.range(of: "\n        }\n", range: open.upperBound..<mac.endIndex)?.lowerBound ?? mac.endIndex
        let body = String(mac[open.upperBound..<close])
        XCTAssertTrue(body.contains("shownColophon != nil"), body)
        XCTAssertTrue(body.contains("colophon.maxY + textView.textContainerInset.height"), body)
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
