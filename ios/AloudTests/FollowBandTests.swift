import XCTest
@testable import Aloud

/// R16 calm follow as numbers: the 18–70% band (80% on the phone), the 28% landing, the arrow
/// direction and the glide-or-jump rule, plus a scroll-count simulation.
final class FollowBandTests: XCTestCase {

    /// A 500pt viewport scrolled to 1,000: the band runs 1,090–1,350 and the
    /// landing line sits at 1,140.
    private let viewport = CGRect(x: 0, y: 1_000, width: 390, height: 500)

    private func line(_ minY: CGFloat, height: CGFloat = 30) -> CGRect {
        CGRect(x: 0, y: minY, width: 300, height: height)
    }

    // MARK: - Band

    /// The band's bottom edge in this viewport: 1,350 on the Mac, 1,400 on
    /// the phone (`PlatformTuning.followBandBottom`).
    private var bottomEdge: CGFloat { viewport.minY + FollowBand.bottom * viewport.height }

    func testBandMembership() {
        XCTAssertTrue(FollowBand.contains(line(1_100), in: viewport))
        XCTAssertTrue(FollowBand.contains(line(1_090), in: viewport), "the top edge is in")
        XCTAssertTrue(FollowBand.contains(line(1_089.6), in: viewport), "within the 0.5pt tolerance")
        XCTAssertFalse(FollowBand.contains(line(1_080), in: viewport), "above the band")
        XCTAssertTrue(FollowBand.contains(line(bottomEdge - 30), in: viewport), "bottom edge at \(bottomEdge)")
        XCTAssertTrue(FollowBand.contains(line(bottomEdge - 29.6), in: viewport), "within the 0.5pt tolerance")
        XCTAssertFalse(FollowBand.contains(line(bottomEdge - 29), in: viewport), "below the band")
        XCTAssertFalse(FollowBand.contains(line(600), in: viewport))
        XCTAssertFalse(FollowBand.contains(line(1_700), in: viewport))
    }

    /// A sentence taller than the band (260pt here on the Mac, 310pt on the
    /// phone) is in once its top is at or above the landing line, so it
    /// doesn't scroll on every boundary.
    func testTallSentencesAreInOnceTheirTopIsAtTheLandingLine() {
        XCTAssertTrue(FollowBand.contains(line(1_100, height: 400), in: viewport))
        XCTAssertTrue(FollowBand.contains(line(1_141, height: 400), in: viewport), "within 1pt")
        XCTAssertFalse(FollowBand.contains(line(1_142, height: 400), in: viewport))
        XCTAssertFalse(FollowBand.contains(line(1_080, height: 400), in: viewport), "still not above the band")
    }

    /// Past the word that would be read below the band with the sentence
    /// parked on the landing line (210pt down it here), following tracks the
    /// spoken word instead, wherever the text has scrolled to.
    func testATallSentenceIsFollowedByItsSpokenWordPastTheBand() {
        let sentence = line(1_140, height: 600)
        XCTAssertTrue(FollowBand.isTall(sentence, in: viewport))
        XCTAssertFalse(FollowBand.isTall(line(1_140, height: 260), in: viewport), "260pt fits the band")

        // Parked on the landing line (140pt down), a word `down` into the
        // sentence ends at 140 + down + 30 in the viewport.
        let edge = FollowBand.bottom * viewport.height
        let early = line(1_140 + edge - 180)   // parked, it ends 10pt above the band's bottom
        XCTAssertEqual(FollowBand.followed(sentence: sentence, word: early, in: viewport), sentence)
        let late = line(1_140 + edge - 160)    // parked, it would end 10pt below it
        XCTAssertEqual(FollowBand.followed(sentence: sentence, word: late, in: viewport), late)
        XCTAssertFalse(FollowBand.contains(late, in: viewport), "so it glides up to the landing line")

        // The same word once the text has moved up for it: still the word.
        let scrolled = sentence.offsetBy(dx: 0, dy: -200)
        let lifted = late.offsetBy(dx: 0, dy: -200)
        XCTAssertEqual(FollowBand.followed(sentence: scrolled, word: lifted, in: viewport), lifted)
        XCTAssertTrue(FollowBand.contains(lifted, in: viewport), "in the band, so nothing moves")

        XCTAssertEqual(FollowBand.followed(sentence: sentence, word: nil, in: viewport), sentence)
        let short = line(1_140, height: 60)
        XCTAssertEqual(FollowBand.followed(sentence: short, word: line(1_170), in: viewport), short,
                       "a sentence that fits the band is followed whole")
    }

    // MARK: - Landing

    func testLandingPutsTheSentenceTopAtTwentyEightPercent() {
        let offset = FollowBand.landingContentOffsetY(sentenceMinY: 1_600, viewport: viewport,
                                                      contentOffsetY: 1_000, range: 0...10_000)
        XCTAssertEqual(offset, 1_460)
        XCTAssertEqual(1_600 - offset, FollowBand.landing * viewport.height, accuracy: 0.001)
    }

    /// With a 100pt top inset the visible rect starts 100pt below the offset.
    func testLandingAccountsForTheTopInset() {
        let offset = FollowBand.landingContentOffsetY(sentenceMinY: 1_600, viewport: viewport,
                                                      contentOffsetY: 900, range: 0...10_000)
        XCTAssertEqual(offset, 1_360)
    }

    func testLandingClampsToTheScrollableRange() {
        XCTAssertEqual(FollowBand.landingContentOffsetY(sentenceMinY: 9_000, viewport: viewport,
                                                        contentOffsetY: 1_000, range: 0...1_200), 1_200)
        XCTAssertEqual(FollowBand.landingContentOffsetY(sentenceMinY: 20, viewport: viewport,
                                                        contentOffsetY: 1_000, range: 0...1_200), 0)
    }

    // MARK: - Direction and motion

    func testDirectionPointsTowardTheVoice() {
        XCTAssertEqual(FollowBand.direction(of: line(900, height: 100), in: viewport), .up)
        XCTAssertEqual(FollowBand.direction(of: line(1_500), in: viewport), .down)
        XCTAssertNil(FollowBand.direction(of: line(980), in: viewport), "partly visible")
        XCTAssertNil(FollowBand.direction(of: line(1_480), in: viewport), "partly visible")
        XCTAssertNil(FollowBand.direction(of: line(1_200), in: viewport))
    }

    /// The band stops at the bar's top edge. The bar also paints the
    /// home-indicator strip, so its layout height alone falls short.
    func testTheObscuredBottomRunsFromTheBarsTopToTheTextsBottom() {
        // Text to the screen bottom at 852; a 220pt bar above a 34pt strip.
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: 852 - 34 - 220), 254)
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: nil, chromeMinY: 598), 0, "not measured yet")
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: nil), 0, "not measured yet")
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 500, chromeMinY: 600), 0, "a bar below the text covers none")
    }

    /// P034: the Voice & speed sheet resting at 60% covers the page above
    /// the bar, so the band is measured above the sheet while it's up (its
    /// edge and the text's bottom in the window's space), and above the bar
    /// alone once it's gone.
    func testASheetOverThePageCoversFromItsTopEdge() {
        // Screen space: the bar's top at 598 over text to 852. Window space:
        // the text's bottom at 852 again, the sheet's top at 382.
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: 598,
                                                 windowTextMaxY: 852, sheetMinY: 382), 470, "the sheet reaches higher")
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: 598,
                                                 windowTextMaxY: 852, sheetMinY: nil), 254, "no sheet: the bar")
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: 598,
                                                 windowTextMaxY: 852, sheetMinY: 700), 254, "a sheet below the bar")
        XCTAssertEqual(FollowBand.obscuredBottom(textMaxY: 852, chromeMinY: 598,
                                                 windowTextMaxY: nil, sheetMinY: 382), 254, "not measured yet")
    }

    func testGlidesOnlyWithinOneViewportAndNeverUnderReduceMotion() {
        XCTAssertTrue(FollowBand.glides(distance: 400, viewportHeight: 500, reduceMotion: false))
        XCTAssertTrue(FollowBand.glides(distance: -500, viewportHeight: 500, reduceMotion: false))
        XCTAssertFalse(FollowBand.glides(distance: 501, viewportHeight: 500, reduceMotion: false))
        XCTAssertFalse(FollowBand.glides(distance: 40, viewportHeight: 500, reduceMotion: true))
    }

    func testTimingTokens() {
        XCTAssertEqual(FollowBand.top, 0.18)
        #if os(iOS)
        XCTAssertEqual(FollowBand.bottom, 0.80, "the phone's short column")
        #else
        XCTAssertEqual(FollowBand.bottom, 0.70)
        #endif
        XCTAssertEqual(FollowBand.landing, 0.28)
        XCTAssertEqual(FollowBand.glideDuration, 0.45)
        XCTAssertEqual(FollowBand.glideCurve.0, CGPoint(x: 0.4, y: 0))
        XCTAssertEqual(FollowBand.glideCurve.1, CGPoint(x: 0.2, y: 1))
        let timing = FollowBand.timingParameters()
        XCTAssertEqual(timing.controlPoint1, CGPoint(x: 0.4, y: 0))
        XCTAssertEqual(timing.controlPoint2, CGPoint(x: 0.2, y: 1))
    }

    // MARK: - Simulation

    /// Follows 100 stacked sentences of `height` through a 557pt viewport
    /// (an iPhone reader between its bars) and counts the scrolls that
    /// moved the text.
    private func simulatedScrolls(sentenceHeight height: CGFloat, count: Int = 100,
                                  viewportHeight: CGFloat = 557) -> Int {
        let contentHeight = height * CGFloat(count) + 200
        let range: ClosedRange<CGFloat> = 0...(contentHeight - viewportHeight)
        var offset: CGFloat = 0
        var scrolls = 0
        for index in 0..<count {
            let sentence = CGRect(x: 0, y: CGFloat(index) * height, width: 300, height: height)
            let visible = CGRect(x: 0, y: offset, width: 300, height: viewportHeight)
            guard !FollowBand.contains(sentence, in: visible) else { continue }
            let target = FollowBand.landingContentOffsetY(sentenceMinY: sentence.minY, viewport: visible,
                                                          contentOffsetY: offset, range: range)
            if abs(target - offset) > 0.5 {
                offset = target
                scrolls += 1
            }
            XCTAssertTrue(FollowBand.contains(sentence, in: CGRect(x: 0, y: offset, width: 300,
                                                                   height: viewportHeight))
                          || offset == range.lowerBound || offset == range.upperBound,
                          "sentence \(index) lands in the band")
        }
        return scrolls
    }

    /// R16's budget is 15 or fewer follow scrolls per 100 lines read: one
    /// 30pt line per sentence here, so 100 sentences are 100 lines.
    func testOneLineSentencesScrollAtMostFifteenTimesPerHundredLines() {
        let scrolls = simulatedScrolls(sentenceHeight: 30)
        XCTAssertLessThanOrEqual(scrolls, 15, "the PRD's budget; the old follow scrolled ~100 times")
    }

    /// 100 sentences of 2.5 lines are 250 lines. Per sentence the band
    /// allows about 30 scrolls, which is why the budget counts lines.
    func testTwoAndAHalfLineSentencesStayWithinTheBudgetPerHundredLines() {
        let scrolls = simulatedScrolls(sentenceHeight: 75)
        let perHundredLines = Double(scrolls) * 100 / 250
        print("FollowBand: 2.5-line sentences scroll \(scrolls) times per 250 lines")
        XCTAssertLessThanOrEqual(perHundredLines, 15, "\(scrolls) scrolls over 250 lines")
    }
}
