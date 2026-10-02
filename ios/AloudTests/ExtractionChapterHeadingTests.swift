import XCTest
@testable import Aloud

/// Chapter headings whose title sits on its own line(s) under the number —
/// the most common Gutenberg layout — start chapters; look-alikes don't.
final class ExtractionChapterHeadingTests: XCTestCase {

    private func extract(_ contents: String) async throws -> DocContent {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-headings-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try await ExtractionPipeline().extractText(fileURL: url, title: "Test", progress: nil)
    }

    private let body = """
    Alice was beginning to get very tired of sitting by her sister on the
    bank, and of having nothing to do: once or twice she had peeped into
    the book her sister was reading, but it had no pictures in it.
    """

    func testTwoLineHeadingsStartChapters() async throws {
        // Alice's Adventures in Wonderland, after its Contents block.
        let content = try await extract("""
        Alice’s Adventures in Wonderland

        by Lewis Carroll

        Contents

         CHAPTER I.     Down the Rabbit-Hole
         CHAPTER II.    The Pool of Tears

        CHAPTER I.
        Down the Rabbit-Hole

        \(body)

        CHAPTER II.
        The Pool of Tears

        \(body)
        """)
        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.derivedChapters.count, 2)
        XCTAssertEqual(content.sentences.first?.text.hasPrefix("CHAPTER I."), true)
        XCTAssertFalse(content.sentences.contains { $0.text.contains("Carroll") })
        let second = content.sentences.first { $0.text.contains("Pool of Tears") }
        XCTAssertEqual(second?.page, 2)
    }

    func testMultiLineHeadingShapes() {
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER I.\nDown the Rabbit-Hole"))
        XCTAssertTrue(TextExtractor.isChapterHeading(
            "CHAPTER I.\nIN WHICH PHILEAS FOGG AND PASSEPARTOUT ACCEPT EACH OTHER, THE ONE AS\nMASTER, THE OTHER AS MAN"))
        XCTAssertTrue(TextExtractor.isChapterHeading("I\nThe Old Sea-dog at the Admiral Benbow"))
        XCTAssertTrue(TextExtractor.isChapterHeading("BOOK THE SECOND\n    The Pilgrimage"))
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER\nXIII IN WHICH IS ENDED THE STORY OF THE SHEPHERDESS"))
        XCTAssertTrue(TextExtractor.isChapterHeading("Chapter viii -- What passed between Jones and old Mr Nightingale\nwith the arrival of a person not yet mentioned."))
    }

    func testProseOpeningWithASectionWordIsNotAHeading() {
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Part of the crew went ashore at dawn,\nand the rest stayed aboard to mend the sails."))
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Book and news dealers, sellers of edibles, drinkables, and cigars, who\nseemed to have plenty of customers."))
        // A transcriber's correction note citing a chapter.
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Chapter XV, paragraph 12. The word \"his\" has been inserted in\nthe sentence for clarity."))
    }

    func testProseAfterTheMarkerIsNotAHeading() {
        // A section word, a full stop, then a sentence.
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Part. The moment had come at last. Where to go now? The road\nlay open before him and nobody stood in the way of\nthe traveller at all."))
        // A numeral running straight on in lowercase prose.
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Book 9 of the tides and their rise and fall in narrow seas. The\nsame happens in the open ocean, where straits cause it.\nAnd currents cause it too."))
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "Part the second commenced with a long march across the hills,\nand the men were weary by nightfall."))
        // An endnote keyed to a book number.
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "BOOK II \"To attend\" (4). Gr. τὸ μή, a reading the editor prefers;\nthe received text is probably right."))
    }

    func testNumberWordHeadingsAreHeadings() {
        XCTAssertTrue(TextExtractor.isChapterHeading("PART ONE\nTHE SEA"))
        XCTAssertTrue(TextExtractor.isChapterHeading("Book the First\nThe Sacrifice"))
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER THE FIRST\nMr Stratton Writes Home"))
        XCTAssertTrue(TextExtractor.isChapterHeading("Part Three of the Current Novel\nBy A. Writer"))
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER I.\nMR. SHERLOCK HOLMES."))
    }

    func testContentsLinesAreNotHeadings() {
        // A play's per-act scene list.
        XCTAssertFalse(TextExtractor.isChapterHeading(
            "ACT I\nScene I. A hall in the Duke’s palace\nScene II. A public place"))
        // An entry with its page number.
        XCTAssertFalse(TextExtractor.isChapterHeading("CHAPTER IV.–Treaty of 1804                    34"))
        XCTAssertFalse(TextExtractor.isChapterHeading("Loomings ............ 12"))
    }

    func testLongParagraphsAreNotHeadings() {
        XCTAssertFalse(TextExtractor.isChapterHeading("CHAPTER I.\nOne\nTwo\nThree"))
        XCTAssertFalse(TextExtractor.isChapterHeading(""))
    }

    /// Pepys' month headings and War and Peace's ordinal epilogues (R17):
    /// all caps, one short line. Prose dates and title-case lines stay body.
    func testDatedAndOrdinalHeadings() {
        XCTAssertTrue(TextExtractor.isChapterHeading("JANUARY 1659-1660"))
        XCTAssertTrue(TextExtractor.isChapterHeading("APRIL 1660"))
        XCTAssertTrue(TextExtractor.isChapterHeading("FEBRUARY 1660-61"))
        XCTAssertTrue(TextExtractor.isChapterHeading("FIRST EPILOGUE: 1813 - 20"))
        XCTAssertTrue(TextExtractor.isChapterHeading("SECOND EPILOGUE"))

        XCTAssertFalse(TextExtractor.isChapterHeading("March 1660 was cold."))
        XCTAssertFalse(TextExtractor.isChapterHeading("January 1660"))
        XCTAssertFalse(TextExtractor.isChapterHeading("MAY I COME IN?"))
        XCTAssertFalse(TextExtractor.isChapterHeading("First epilogue of the play"))
        XCTAssertFalse(TextExtractor.isChapterHeading("JANUARY 1660\nIt was a cold month."))
    }

    func testThreeMonthDiaryExtractsToThreePages() async throws {
        let content = try await extract("""
        JANUARY 1659-1660

        Blessed be God, at the end of the last year I was in very good health,
        without any sense of my old pain, but upon taking of cold.

        FEBRUARY 1659-1660

        Up and to my office, where I found all things in good order, and so
        home to dinner with my wife.

        MARCH 1659-1660

        This morning I rose early and went by water to Whitehall, where I
        met with my Lord and stayed till noon.
        """)
        XCTAssertEqual(content.pageCount, 3)
        XCTAssertEqual(content.derivedChapters.map(\.title),
                       ["JANUARY 1659-1660", "FEBRUARY 1659-1660", "MARCH 1659-1660"])
    }

    // MARK: - Lists inside the book

    func testContentsPrintedInsideTheBookAddsNoChapters() async throws {
        // Grant's Memoirs: Volume II opens with its own Contents, whose
        // entries wrap onto a second line like two-line headings.
        let entries = (40...47).map {
            "CHAPTER \($0). FIRST MEETING AT THE RIVER--THE MARCH OF\nTHE ARMY--ARRIVAL AT THE TOWN NUMBER \($0)."
        }.joined(separator: "\n\n")
        let content = try await extract("""
        MEMOIRS

        CONTENTS

        CHAPTER I. Early Days
        CHAPTER II. The War

        CHAPTER I.

        \(body)

        CHAPTER II.

        \(body)

        VOLUME II.

        CONTENTS.

        \(entries)

        CHAPTER XL.

        \(body)

        CHAPTER XLI.

        \(body)
        """)
        XCTAssertEqual(content.pageCount, 4)
        let volume = content.sentences.first { $0.text.hasPrefix("VOLUME II") }?.page
        XCTAssertEqual(content.sentences.first { $0.text.contains("TOWN NUMBER 47") }?.page, volume)
    }

    func testBookHeadingsOverListsWithPageNumbersAreNotChapters() async throws {
        // The Consolation of Philosophy: an index of verse interludes, each
        // book's two-line heading over its numbered songs and pages.
        let index = (1...3).map { book in
            "BOOK \(String(repeating: "I", count: book)).\nTHE SORROWS OF THE PRISONER.\n\n"
                + (1...4).map { "\(romanNumeral($0)). A SONG OF COMPLAINT          \(book * 20 + $0 * 3)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let content = try await extract("""
        THE CONSOLATION

        \(body)

        INDEX OF VERSE INTERLUDES.

        \(index)

        BOOK I.

        \(body)
        """)
        XCTAssertEqual(content.pageCount, 2)
    }

    func testDittoMarkedEntriesAreNotChapters() async throws {
        // The Kama Sutra's index: "Chapter II. …" then ditto marks for the
        // section word on the entries under it.
        let content = try await extract("""
        THE BOOK

        \(body)

        PART I.

        Chapter II. Observations on the three aims of
        a life well spent, and how they are weighed.

        " III. On the study of the arts.

        " IV. On the arrangement of a house, and
        about the daily life of the citizen, his friends
        and his amusements.

        " V. About the friends of the citizen, and of messengers,
        and of their several duties at the court.

        PART II.

        Chapter I. Kinds of union according to their
        measure and their force and their time.

        " II. Of the embrace.

        " III. On kissing.

        CHAPTER I.

        \(body)
        """)
        XCTAssertEqual(content.pageCount, 4)
        XCTAssertEqual(content.sentences.first { $0.text.contains("Observations on the three aims") }?.page,
                       content.sentences.first { $0.text == "PART I." }?.page)
    }

    func testPageColumnLabelIsNotAHeadingTitle() {
        XCTAssertFalse(TextExtractor.isChapterHeading("PART I.\nPAGE"))
        XCTAssertFalse(TextExtractor.isChapterHeading("BOOK II.\nCHAPTER PAGE"))
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER I.\nTHE PAGE BOY"))
    }

    func testPartHeadingOverATwoLineChapterHeadingStillStartsAPage() async throws {
        let content = try await extract("""
        PART ONE
        THE START OF IT

        CHAPTER I.
        THE START

        \(body)

        PART TWO
        THE END OF IT

        CHAPTER II.
        THE END

        \(body)
        """)
        XCTAssertEqual(content.pageCount, 4)
    }

    private func romanNumeral(_ value: Int) -> String {
        ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][value - 1]
    }

    func testSingleLineHeadingsUnchanged() {
        XCTAssertTrue(TextExtractor.isChapterHeading("CHAPTER XII"))
        XCTAssertTrue(TextExtractor.isChapterHeading("Chapter 1. Down the Rabbit-Hole"))
        XCTAssertTrue(TextExtractor.isChapterHeading("IV."))
        XCTAssertTrue(TextExtractor.isChapterHeading("PROLOGUE"))
        XCTAssertFalse(TextExtractor.isChapterHeading("It was the best of times."))
    }
}
