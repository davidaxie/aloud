import XCTest
@testable import Aloud

/// "No." is a numbering abbreviation only before a number, and "I." is the
/// pronoun, not an initial. After "No." a lone "I" is the pronoun; after
/// "Vol.", "pp.", "Fig." or "Eq." it is the roman numeral.
final class ExtractionAbbreviationTests: XCTestCase {

    private func split(_ text: String) -> [String] {
        SentenceSegmenter.splitIntoSentences(text)
    }

    func testNoAsAReplyEndsTheSentence() {
        XCTAssertEqual(split("\"Do you know German?\" \"No.\" \"So much the worse.\""),
                       ["\"Do you know German?\"", "\"No.\"", "\"So much the worse.\""])
        XCTAssertEqual(split("\"No.\" I shook my head."), ["\"No.\"", "I shook my head."])
        XCTAssertEqual(split("Why, no. I that do speak a word may call it back."),
                       ["Why, no.", "I that do speak a word may call it back."])
    }

    func testNumberingAbbreviationsBeforeANumberHold() {
        XCTAssertEqual(split("He lives at No. 5 Baker Street. It is nice."),
                       ["He lives at No. 5 Baker Street.", "It is nice."])
        XCTAssertEqual(split("See Vol. II for details. Done."), ["See Vol. II for details.", "Done."])
        XCTAssertEqual(split("Fig. 3 shows it. Done."), ["Fig. 3 shows it.", "Done."])
        XCTAssertEqual(split("Book No. I. The Beginning."), ["Book No. I. The Beginning."])
    }

    func testLoneIAfterVolumeIsANumeral() {
        XCTAssertEqual(split("See Vol. I By Mary J. Holmes. Done."),
                       ["See Vol. I By Mary J. Holmes.", "Done."])
        XCTAssertEqual(split("It is given in Vol. I No. 695. Then more."),
                       ["It is given in Vol. I No. 695.", "Then more."])
        XCTAssertEqual(split("As shown in Fig. I the arch is round. Next."),
                       ["As shown in Fig. I the arch is round.", "Next."])
        XCTAssertEqual(split("From Eq. I we get the rest. Done."),
                       ["From Eq. I we get the rest.", "Done."])
        // After "No." the same "I" is still the pronoun.
        XCTAssertEqual(split("\"No.\" I shook my head."), ["\"No.\"", "I shook my head."])
    }

    func testFigAsAWordEndsTheSentence() {
        XCTAssertEqual(split("The fig. It was ripe."), ["The fig.", "It was ripe."])
    }

    func testInitialsStillHold() {
        XCTAssertEqual(split("J. Smith wrote the book. It sold well."),
                       ["J. Smith wrote the book.", "It sold well."])
        XCTAssertEqual(split("Footnote: see p. 12. Then go."), ["Footnote: see p. 12.", "Then go."])
        XCTAssertEqual(split("Dr. Smith arrived at 3 p.m. and left quickly.").count, 1)
    }

    func testItalicAbbreviationIsRecognized() {
        XCTAssertEqual(split("[784] _Then tenderly, etc._: The wound had healed."),
                       ["[784] _Then tenderly, etc._: The wound had healed."])
    }
}
