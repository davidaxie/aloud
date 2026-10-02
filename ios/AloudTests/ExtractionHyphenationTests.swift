import XCTest
import NaturalLanguage
@testable import Aloud

/// Gutenberg wraps real compounds at their hyphen ("public-⏎house"), so a
/// split keeps its hyphen when both halves are words and the joined form is
/// not; every other split ("inter-⏎national", "hon-⏎our") is re-joined.
final class ExtractionHyphenationTests: XCTestCase {

    /// The compound rule needs the OS's English word list; without one the
    /// normalizer re-joins every split, as it always did.
    private func requireWordList() throws {
        if NLEmbedding.wordEmbedding(for: .english) == nil {
            throw XCTSkip("No built-in English word embedding on this system")
        }
    }

    func testWrappedCompoundsKeepTheirHyphen() throws {
        try requireWordList()
        XCTAssertEqual(TextNormalizer.normalize("the public-\nhouse door"), "the public-house door")
        XCTAssertEqual(TextNormalizer.normalize("the sitting-\nroom"), "the sitting-room")
        XCTAssertEqual(TextNormalizer.normalize("the sixty-\nfourth"), "the sixty-fourth")
        XCTAssertEqual(TextNormalizer.normalize("a four-\nwheeled cab"), "a four-wheeled cab")
        // British halves count as words through their American spelling.
        XCTAssertEqual(TextNormalizer.normalize("a rose-\ncoloured dress"), "a rose-coloured dress")
        XCTAssertEqual(TextNormalizer.normalize("his ill-\nhumour"), "his ill-humour")
        XCTAssertEqual(TextNormalizer.normalize("my fellow-\ntravellers"), "my fellow-travellers")
        // Each wrap of a chained compound sees whole words.
        XCTAssertEqual(TextNormalizer.normalize("the sitting-\nroom-\nwindow"), "the sitting-room-window")
    }

    func testSuspendedHyphensAreLeftAlone() throws {
        try requireWordList()
        XCTAssertEqual(TextNormalizer.normalize("first- and second-class"), "first- and second-class")
        XCTAssertEqual(TextNormalizer.normalize("two- or three-day"), "two- or three-day")
        // The halves spell "tenor", but "or" marks a suspended compound.
        XCTAssertEqual(TextNormalizer.normalize("ten- or twelve-syllable"), "ten- or twelve-syllable")
    }

    func testSyllableSplitsStillRejoin() throws {
        try requireWordList()
        XCTAssertEqual(TextNormalizer.normalize("be-\ncause"), "because")
        XCTAssertEqual(TextNormalizer.normalize("mat-\nters"), "matters")
        // Neither half is a word: a split name.
        XCTAssertEqual(TextNormalizer.normalize("Archi-\nmedes"), "Archimedes")
    }

    func testSplitWithOnlyOneWordHalfRejoins() throws {
        try requireWordList()
        // A typesetter's syllable split often leaves one half that happens
        // to be a word ("row", "let", "our"); keeping the hyphen there made
        // the voice read "hon-our" as "hon hour".
        XCTAssertEqual(TextNormalizer.normalize("the mor-\nrow"), "the morrow")
        XCTAssertEqual(TextNormalizer.normalize("a bul-\nlet"), "a bullet")
        XCTAssertEqual(TextNormalizer.normalize("his hon-\nour"), "his honour")
        XCTAssertEqual(TextNormalizer.normalize("a neigh-\nbour"), "a neighbour")
    }

    func testBritishSpellingsAndListGapsRejoin() throws {
        try requireWordList()
        // Both halves are words, but so is the joined form once respelled
        // ("labor", "humor") or added to the list's few gaps ("cannot").
        XCTAssertEqual(TextNormalizer.normalize("hard lab-\nour"), "hard labour")
        XCTAssertEqual(TextNormalizer.normalize("good hum-\nour"), "good humour")
        XCTAssertEqual(TextNormalizer.normalize("I can-\nnot go"), "I cannot go")
    }

    func testExistingRejoinCasesHold() {
        // Holds with or without the word list.
        XCTAssertEqual(TextNormalizer.normalize("inter- national"), "international")
        XCTAssertEqual(TextNormalizer.normalize("inter-\nnational"), "international")
        XCTAssertEqual(TextNormalizer.normalize("well-being matters"), "well-being matters")
    }

    func testKeptFormsAreIdempotent() throws {
        try requireWordList()
        for input in ["the public-\nhouse door", "first- and second-class", "a quick- witted man"] {
            let once = TextNormalizer.normalize(input)
            XCTAssertEqual(TextNormalizer.normalize(once), once, input)
        }
    }

    func testCompoundSurvivesTheTextPipeline() async throws {
        try requireWordList()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-hyphen-\(UUID().uuidString).txt")
        try Data("Mr. Pickwick went into the public-\nhouse at noon.".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let content = try await ExtractionPipeline().extractText(fileURL: url, title: "T", progress: nil)
        XCTAssertEqual(content.sentences.map(\.text), ["Mr. Pickwick went into the public-house at noon."])
    }
}
