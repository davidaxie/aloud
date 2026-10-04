import XCTest
@testable import Aloud

/// `SpokenYears` reads four-digit years the way people say them, for the
/// Kokoro voice only. The table is the behaviour contract; every row is
/// also checked for idempotence (a second pass changes nothing).
final class SpokenYearsTests: XCTestCase {

    private let table: [(input: String, spoken: String)] = [
        ("I graduated from New Haven in 1915, just a quarter", "I graduated from New Haven in nineteen fifteen, just a quarter"),
        ("in 1100.", "in eleven hundred."),
        ("in 1900.", "in nineteen hundred."),
        ("in 1905.", "in nineteen oh five."),
        ("in 1999.", "in nineteen ninety nine."),
        ("1776 was a year", "seventeen seventy six was a year"),
        ("in 2000.", "in two thousand."),
        ("in 2005.", "in two thousand five."),
        ("in 2009.", "in two thousand nine."),
        ("in 2010.", "in twenty ten."),
        ("in 2025.", "in twenty twenty five."),
        ("in 2099.", "in twenty ninety nine."),
        ("June 3, 1915, he", "June 3, nineteen fifteen, he"),
        ("3 June 1915", "3 June nineteen fifteen"),
        ("(1915)", "(nineteen fifteen)"),
        ("[1915]", "[nineteen fifteen]"),
        ("\"1915?\"", "\"nineteen fifteen?\""),
        ("1450 B.C.", "fourteen fifty B.C."),
        ("A.D. 1250", "A.D. twelve fifty"),
        ("at 1915 hours", "at nineteen fifteen hours"),
        ("1600 Pennsylvania Avenue", "sixteen hundred Pennsylvania Avenue"),
        ("in 1915\u{B9} the", "in nineteen fifteen\u{B9} the"),
        ("in 1066,", "in 1066,"),
        ("in 1000.", "in 1000."),
        ("in 1099.", "in 1099."),
        ("in 2100.", "in 2100."),
        ("in 0915.", "in 0915."),
        ("in 999.", "in 999."),
        ("in 19150.", "in 19150."),
        ("$1915", "$1915"),
        ("\u{A3}1915 a year", "\u{A3}1915 a year"),
        ("\u{20AC}1915", "\u{20AC}1915"),
        ("#1915", "#1915"),
        ("1,915 men", "1,915 men"),
        ("1915.5", "1915.5"),
        ("3.1915", "3.1915"),
        ("1915,000", "1915,000"),
        ("1915%", "1915%"),
        ("1915 %", "1915 %"),
        ("1915 percent", "1915 percent"),
        ("1915 per cent", "1915 per cent"),
        ("19:15", "19:15"),
        ("1915:30", "1915:30"),
        ("12:1915", "12:1915"),
        ("3/1915", "3/1915"),
        ("1915/16", "1915/16"),
        ("1915\u{B0}", "1915\u{B0}"),
        ("-1915", "-1915"),
        ("+1915", "+1915"),
        ("555-1915", "555-1915"),
        ("1-800-555-1915", "1-800-555-1915"),
        ("A1915", "A1915"),
        ("1915th", "1915th"),
        ("1915km", "1915km"),
        ("1915s", "1915s"),
        ("2015-03-14", "2015-03-14"),
        ("weighing 1507 tons", "weighing 1507 tons"),
        ("an altitude of 1269 metres", "an altitude of 1269 metres"),
        ("slew 2046 men", "slew 2046 men"),
        ("lived about 1350 years before", "lived about 1350 years before"),
        ("1500 soldiers", "fifteen hundred soldiers"),
        ("2000 men", "two thousand men"),
        ("1800 feet high", "eighteen hundred feet high"),
        ("In 1915 men were", "In nineteen fifteen men were"),
        ("the year 1909 marks", "the year nineteen oh nine marks"),
        ("June 1915 people", "June nineteen fifteen people"),
        ("1914-1918", "nineteen fourteen to nineteen eighteen"),
        ("1914 - 1918", "nineteen fourteen to nineteen eighteen"),
        ("1914-18", "nineteen fourteen to eighteen"),
        ("1990 - 95", "nineteen ninety to ninety five"),
        ("1905-07", "nineteen oh five to oh seven"),
        ("2005-08", "two thousand five to two thousand eight"),
        ("2008-12", "two thousand eight to twenty twelve"),
        ("2019-20", "twenty nineteen to twenty"),
        ("1999-2001", "nineteen ninety nine to two thousand one"),
        ("(1896 - 1940)", "(eighteen ninety six to nineteen forty)"),
        ("1918-1914", "1918-1914"),
        ("The winter of 1862-3 was", "The winter of eighteen sixty two to sixty three was"),
        ("February 2nd, 1644-5, and", "February 2nd, sixteen forty four to forty five, and"),
        ("1859-1", "1859-1"),
        ("2001-4", "2001-4"),
        ("In 1874-5-6-7 the", "In 1874-5-6-7 the"),
        ("1914-18-20", "1914-18-20"),
        ("1914-1918-1939", "1914-1918-1939"),
        ("1914-14", "1914-14"),
        ("1899-01", "1899-01"),
        ("1050 - 1150", "1050 - 1150"),
        ("1087-1100", "1087-1100"),
        ("1915-born", "nineteen fifteen-born"),
        ("in 1915 - the war raging - he", "in nineteen fifteen - the war raging - he"),
        ("1920s-1930s", "nineteen twenties to nineteen thirties"),
        ("the 1920s", "the nineteen twenties"),
        ("the 1920's", "the nineteen twenties"),
        ("the 1900s", "the nineteen hundreds"),
        ("the 1800s.", "the eighteen hundreds."),
        ("the 2000s", "the two thousands"),
        ("the 2010s", "the twenty tens"),
        ("the 1970s,", "the nineteen seventies,"),
        ("mid-1920s", "mid-nineteen twenties"),
        ("pre-1914 Europe", "pre-nineteen fourteen Europe"),
        ("1915's harvest", "nineteen fifteen's harvest"),
        ("the 1060s", "the 1060s"),
        ("No digits here.", "No digits here."),
        ("Chapter 12, page 345.", "Chapter 12, page 345."),
        // Review follow-ups: counts after a range, spaced chains, Unicode
        // hyphens, bare decimals, fractions, more count words.
        ("lived about 1350-1400 years before", "lived about 1350-1400 years before"),
        ("1507-1510 tons", "1507-1510 tons"),
        ("an army of 1250 - 1300 men", "an army of 1250 - 1300 men"),
        ("1500-1600 men", "fifteen hundred to sixteen hundred men"),
        ("In 1914 - 1918 men died", "In nineteen fourteen to nineteen eighteen men died"),
        ("1874 - 5 - 6 - 7", "1874 - 5 - 6 - 7"),
        ("1914 - 1918 - 1939", "1914 - 1918 - 1939"),
        ("Aet. 1-25 - 1469-94 OFFICE", "Aet. 1-25 - fourteen sixty nine to ninety four OFFICE"),
        ("555\u{2010}1915", "555\u{2010}1915"),
        ("1\u{2011}800\u{2011}555\u{2011}1915", "1\u{2011}800\u{2011}555\u{2011}1915"),
        ("1914\u{2010}1918", "nineteen fourteen to nineteen eighteen"),
        ("a ratio of .1250", "a ratio of .1250"),
        ("c.1250", "c.twelve fifty"),
        ("1250\u{BD} miles", "1250\u{BD} miles"),
        ("1250 square miles", "1250 square miles"),
        ("1347 houses", "1347 houses"),
        ("in 1347 houses burned", "in thirteen forty seven houses burned"),
    ]

    func testTable() {
        for row in table {
            let got = SpokenYears.apply(to: row.input)
            XCTAssertEqual(got, row.spoken, "input: \(row.input)")
            XCTAssertEqual(SpokenYears.apply(to: got), got, "not idempotent: \(row.input)")
        }
    }

    func testBritishVoicesSayTwoThousandAndFive() {
        XCTAssertEqual(SpokenYears.apply(to: "in 2005.", british: true), "in two thousand and five.")
        XCTAssertEqual(SpokenYears.apply(to: "in 2000.", british: true), "in two thousand.")
        XCTAssertEqual(SpokenYears.apply(to: "in 2025.", british: true), "in twenty twenty five.")
        XCTAssertEqual(SpokenYears.apply(to: "in 1915.", british: true), "in nineteen fifteen.")
    }

    func testEveryYearInRangeIsSpelledWithoutDigits() {
        for n in 1100...2099 {
            let spoken = SpokenYears.apply(to: "in \(n).")
            XCTAssertFalse(spoken.contains(where: \.isNumber), "\(n) -> \(spoken)")
            XCTAssertFalse(spoken.contains("-"), "hyphen in \(n) -> \(spoken)")
        }
    }

    func testOutputAddsNoSentencePunctuation() {
        let input = "From 1914-1918, in the 1920s and in 2005; see (1896 - 1940)."
        let marks: (String) -> Int = { $0.filter { ".!?;:".contains($0) }.count }
        XCTAssertEqual(marks(SpokenYears.apply(to: input)), marks(input))
    }

    /// Kokoro is handed the normalized text with its years spelled; a
    /// British voice adds the "and".
    func testKokoroSpeaksTheSpelledYears() {
        XCTAssertEqual(KokoroSherpaEngine.spokenText("In 1915\u{2013}1918 \u{201C}war\u{201D}", lang: "en-US"),
                       "In nineteen fifteen to nineteen eighteen \"war\"")
        XCTAssertEqual(KokoroSherpaEngine.spokenText("in 2005.", lang: "en-GB"), "in two thousand and five.")
        XCTAssertEqual(KokoroSherpaEngine.spokenText("in 2005.", lang: "en-US"), "in two thousand five.")
    }

    /// The display text keeps its digits: years are spoken-only.
    func testTextNormalizerLeavesYearsAsDigits() {
        XCTAssertEqual(TextNormalizer.normalize("in 1915, 1914\u{2013}1918"), "in 1915, 1914 - 1918")
    }
}
