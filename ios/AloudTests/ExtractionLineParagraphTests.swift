import XCTest
@testable import Aloud

/// Plain text written one paragraph per line (Word "Plain Text" exports,
/// Notepad, notes apps) keeps its paragraphs and chapters instead of
/// collapsing into one book-sized paragraph. Hard-wrapped text is unchanged.
final class ExtractionLineParagraphTests: XCTestCase {

    private func extract(_ contents: String) async throws -> DocContent {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aloud-lines-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try await ExtractionPipeline().extractText(fileURL: url, title: "Test", progress: nil)
    }

    func testWordExportKeepsParagraphsAndChapters() async throws {
        let content = try await extract([
            "Chapter 1",
            "It was a bright cold day in April, and the clocks were striking thirteen.",
            "Winston Smith slipped quickly through the glass doors of Victory Mansions.",
            "The hallway smelt of boiled cabbage and old rag mats.",
            "At one end of it a coloured poster had been tacked to the wall.",
            "Chapter 2",
            "Outside, even through the shut window-pane, the world looked cold.",
            "Down in the street little eddies of wind were whirling dust.",
            "The sun was shining and the sky was a harsh blue.",
        ].joined(separator: "\r\n"))
        XCTAssertEqual(content.paragraphs.count, 9)
        XCTAssertEqual(content.pageCount, 2)
        XCTAssertEqual(content.derivedChapters.count, 2)
        XCTAssertEqual(content.sentences.first?.text, "Chapter 1")
    }

    func testLongUnwrappedLinesArePerLineParagraphs() async throws {
        let long = String(repeating: "This paragraph was never wrapped by its editor, so it runs on. ", count: 3)
        let content = try await extract([long, long, long].joined(separator: "\n"))
        XCTAssertEqual(content.paragraphs.count, 3)
    }

    func testHardWrappedTextStillJoins() async throws {
        let content = try await extract("""
        Alice was beginning to get very tired of sitting by her sister on the
        bank, and of having nothing to do: once or twice she had peeped into
        the book her sister was reading, but it had no pictures or
        conversations in it, and what is the use of a book, thought Alice,
        without pictures or conversations?
        """)
        XCTAssertEqual(content.paragraphs.count, 1)
    }

    /// Words wrapped at `width` columns, one paragraph per `sentences` sentences.
    private func wrapped(_ topic: String, sentences: Int, width: Int, indent: String = "") -> [String] {
        let words = (1...sentences).map {
            "The \(topic) kept going for a good while in sentence number \($0), and nobody at all seemed to mind it."
        }.joined(separator: " ").split(separator: " ")
        var lines: [String] = []
        var line = indent
        for word in words {
            if line.count + word.count + 1 > width, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
                line = ""
            }
            line += (line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " ") + word
        }
        lines.append(line)
        return lines
    }

    func testWideWrappedParagraphsWithBlankLinesStillJoin() async throws {
        // 120-column hard wraps: the median line is long, but each line stops
        // mid-sentence just short of the wrap column.
        let first = wrapped("river", sentences: 14, width: 120)
        let second = wrapped("forest", sentences: 14, width: 120)
        XCTAssertGreaterThan(first.count, 10)
        let content = try await extract((first + [""] + second).joined(separator: "\n"))
        XCTAssertEqual(content.paragraphs.count, 2)
        XCTAssertTrue(content.sentences.allSatisfy { $0.text.hasSuffix(".") })
    }

    func testIndentedWrappedParagraphsAreNotSplitPerLine() {
        let lines = (1...12).flatMap { wrapped("topic \($0)", sentences: 3, width: 110, indent: "    ") }
        XCTAssertFalse(TextExtractor.isOneParagraphPerLine(lines.map { Substring($0) }))
    }

    func testDetection() {
        func lines(_ text: String) -> [Substring] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
        }
        // Gutenberg layout: blank lines between paragraphs.
        XCTAssertFalse(TextExtractor.isOneParagraphPerLine(lines("One line\nwraps here.\n\nNext one\nwraps too.")))
        // A single hard-wrapped paragraph.
        XCTAssertFalse(TextExtractor.isOneParagraphPerLine(lines("The quick brown fox\njumps over the lazy dog.")))
        // Every line a sentence, no blank lines.
        XCTAssertTrue(TextExtractor.isOneParagraphPerLine(lines("First one ends.\nSecond one ends.\nThird one ends.")))
        XCTAssertFalse(TextExtractor.isOneParagraphPerLine(lines("Just one line.")))
        // A verse export: each stanza on one long line of about the same length.
        let stanzas = (1...30).map {
            "Stanza \($0) begins here, and goes on with its rhymes; it turns and it returns, and it ends at last."
        }
        XCTAssertTrue(TextExtractor.isOneParagraphPerLine(stanzas.map { Substring($0) }))
    }
}
