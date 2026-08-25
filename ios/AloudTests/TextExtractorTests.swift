import XCTest
@testable import Aloud

final class TextExtractorTests: XCTestCase {

    private func makeTextFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-test-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func extract(_ contents: String, title: String = "Test Book") async throws -> DocContent {
        try await ExtractionPipeline()
            .extractText(fileURL: makeTextFile(contents), title: title, progress: nil)
    }

    // MARK: - Paragraphs and wrapping

    func testBlankLineSeparatedParagraphs() async throws {
        let content = try await extract("""
        First paragraph sentence one. Sentence two here.

        Second paragraph stands alone.
        """)
        XCTAssertEqual(content.paragraphs.count, 2)
        XCTAssertEqual(content.sentences.count, 3)
        XCTAssertEqual(content.pageCount, 1)
    }

    func testHardWrappedLinesJoin() async throws {
        let content = try await extract("The quick brown fox\njumps over the lazy dog.")
        XCTAssertEqual(content.sentences.map(\.text),
                       ["The quick brown fox jumps over the lazy dog."])
    }

    func testWrappedHyphenationRepaired() async throws {
        let content = try await extract("The council ratified the inter-\nnational treaty.")
        XCTAssertEqual(content.sentences.map(\.text),
                       ["The council ratified the international treaty."])
    }

    func testWindowsLineEndings() async throws {
        let content = try await extract("One paragraph here.\r\n\r\nAnother paragraph there.")
        XCTAssertEqual(content.paragraphs.count, 2)
    }

    // MARK: - Chapters as pages

    func testChapterHeadingsBecomePageBoundaries() async throws {
        let content = try await extract("""
        CHAPTER I

        It was the best of times in the village. Everyone said so.

        CHAPTER II

        It was the worst of times by the river.
        """)
        XCTAssertEqual(content.pageCount, 2)

        let heading1 = content.sentences.first { $0.text == "CHAPTER I" }
        let heading2 = content.sentences.first { $0.text == "CHAPTER II" }
        XCTAssertEqual(heading1?.page, 1)
        XCTAssertEqual(heading2?.page, 2)
        let best = content.sentences.first { $0.text.contains("best of times") }
        let worst = content.sentences.first { $0.text.contains("worst of times") }
        XCTAssertEqual(best?.page, 1)
        XCTAssertEqual(worst?.page, 2)
    }

    func testRomanNumeralHeadings() async throws {
        let content = try await extract("""
        Prelude text sits before the first section begins.

        II.

        Second section text follows the numeral.
        """)
        XCTAssertEqual(content.pageCount, 2)
    }

    func testNoChaptersMeansSinglePage() async throws {
        let content = try await extract("Just one plain paragraph. Nothing chapter-like at all.")
        XCTAssertEqual(content.pageCount, 1)
    }

    func testOrdinaryParagraphNotMistakenForHeading() {
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Chapter membership grew rapidly through the spring, and the committee "
            + "voted to extend invitations to every household in the county."))
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER XII"))
        XCTAssertTrue(TextExtractor.isChapterHeading("Chapter 1. Down the Rabbit-Hole"))
        XCTAssertTrue(TextExtractor.isChapterHeading("IV."))
    }

    // MARK: - Gutenberg front matter

    private let gatsbyHeader = """
    The Great Gatsby by F. Scott Fitzgerald

    Table of Contents

    I II III IV V VI VII VIII IX

    Once again to Zelda

    Then wear the gold hat, if that will move her;
    If you can bounce high, bounce for her too.

    Thomas Parke d'Invilliers

    I

    In my younger and more vulnerable years my father gave me some advice.

    II

    Second chapter text follows here.
    """

    func testGutenbergFrontMatterExcluded() async throws {
        let content = try await extract(gatsbyHeader, title: "The Great Gatsby")

        // Reading starts at the Chapter I heading — page 1.
        XCTAssertEqual(content.sentences.first?.text, "I")
        XCTAssertEqual(content.sentences.first?.page, 1)
        XCTAssertEqual(
            content.sentences.dropFirst().first?.text,
            "In my younger and more vulnerable years my father gave me some advice.")
        XCTAssertEqual(content.pageCount, 2)

        // Title line, Contents list, dedication, and epigraph are all gone.
        let joined = content.sentences.map(\.text).joined(separator: " ")
        XCTAssertFalse(joined.contains("Table of Contents"))
        XCTAssertFalse(joined.contains("Fitzgerald"))
        XCTAssertFalse(joined.contains("Zelda"))
        XCTAssertFalse(joined.contains("gold hat"))
        XCTAssertFalse(joined.contains("d'Invilliers"))
    }

    func testContentsListedOnePerLineExcluded() async throws {
        let content = try await extract("""
        A Tale of Chapters by Someone

        CONTENTS

        I. The Beginning
        II. The Middle
        III. The End

        CHAPTER I

        The story opens on a rainy night.
        """)
        XCTAssertEqual(content.sentences.first?.text, "CHAPTER I")
        XCTAssertEqual(content.sentences.first?.page, 1)
        let joined = content.sentences.map(\.text).joined(separator: " ")
        XCTAssertFalse(joined.contains("The Middle"))
        XCTAssertFalse(joined.contains("Someone"))
    }

    func testContentsWithoutNearbyChapterDropsOnlyContents() async throws {
        let content = try await extract("""
        Contents

        1. First things
        2. Second things

        For my mother, who read everything aloud.
        """)
        XCTAssertEqual(content.sentences.map(\.text),
                       ["For my mother, who read everything aloud."])
    }

    func testNoContentsHeadingLeavesTextUntouched() async throws {
        // Front matter without an explicit Contents heading is preserved —
        // the skip is deliberately conservative.
        let content = try await extract("""
        Prelude text sits before the first section begins.

        II.

        Second section text follows the numeral.
        """)
        XCTAssertTrue(content.sentences.first?.text.contains("Prelude") == true)
    }

    func testContentsPastLineLimitIsBodyText() async throws {
        let filler = Array(repeating: "Body paragraph keeps going here.", count: 90)
            .joined(separator: "\n\n")
        let content = try await extract(filler + """


        Table of Contents

        I II III
        """)
        let joined = content.sentences.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("Table of Contents"))
    }

    func testContentsHeadingDetection() {
        XCTAssertTrue(TextExtractor.isContentsHeading("Contents"))
        XCTAssertTrue(TextExtractor.isContentsHeading("CONTENTS"))
        XCTAssertTrue(TextExtractor.isContentsHeading("Table of Contents"))
        XCTAssertFalse(TextExtractor.isContentsHeading("The contents of the box spilled."))
        XCTAssertFalse(TextExtractor.isContentsHeading("Discontents"))
    }

    func testContentsListDetection() {
        XCTAssertTrue(TextExtractor.isContentsList("I II III IV V VI VII VIII IX"))
        XCTAssertTrue(TextExtractor.isContentsList("I. Down the Rabbit-Hole\nII. The Pool of Tears"))
        XCTAssertTrue(TextExtractor.isContentsList("Chapter 1\nChapter 2"))
        XCTAssertFalse(TextExtractor.isContentsList("Once again to Zelda"))
        XCTAssertFalse(TextExtractor.isContentsList(
            "In my younger and more vulnerable years my father gave me some advice."))
    }

    // MARK: - Title and metadata

    func testProvidedTitleIsAuthoritative() async throws {
        let content = try await extract("CHAPTER I\n\nSome text follows here.",
                                        title: "The Great Gatsby")
        XCTAssertEqual(content.title, "The Great Gatsby")
    }

    func testContentHashIsStable() async throws {
        let text = "A stable paragraph of text. It never changes."
        let first = try await extract(text)
        let second = try await extract(text)
        XCTAssertEqual(first.contentHash, second.contentHash)
        XCTAssertEqual(first.contentHash.count, 64)
    }

    func testEmptyFileThrows() async throws {
        do {
            _ = try await extract("   \n\n  ")
            XCTFail("expected ExtractionError.emptyDocument")
        } catch let error as ExtractionError {
            XCTAssertEqual(error, .emptyDocument)
        }
    }
}
