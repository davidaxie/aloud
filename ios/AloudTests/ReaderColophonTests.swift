import XCTest
import UIKit
@testable import Aloud

/// R24's colophon as values: its copy, its length, and the end mark it
/// types into the column. Pure: no view, no controller, nothing plays.
@MainActor
final class ReaderColophonTests: XCTestCase {

    // MARK: - Copy

    func testListeningLineUsesTheOneDurationFormat() {
        XCTAssertEqual(ColophonCopy.listening(minutes: 14), "About 14 min of listening")
        XCTAssertEqual(ColophonCopy.listening(minutes: 72), "About 1 hr 12 min of listening")
        XCTAssertEqual(ColophonCopy.listening(minutes: 120), "About 2 hr of listening")

        XCTAssertEqual(ColophonCopy.spokenListening(minutes: 14), "About 14 minutes of listening")
        XCTAssertEqual(ColophonCopy.spokenListening(minutes: 72), "About 1 hour 12 minutes of listening")
        XCTAssertEqual(ColophonCopy.spokenListening(minutes: 120), "About 2 hours of listening")
        XCTAssertEqual(ColophonCopy.theEnd, "The End")
    }

    func testSpokenTextIsOneLabel() {
        let colophon = ReaderColophon(title: "Pride and Prejudice", author: "Jane Austen",
                                      words: 72 * 165, rate: 1)
        XCTAssertEqual(colophon.minutes, 72)
        XCTAssertEqual(colophon.listeningLine, "About 1 hr 12 min of listening")
        XCTAssertEqual(colophon.spokenText,
                       "The End, Pride and Prejudice, Jane Austen, About 1 hour 12 minutes of listening")
    }

    func testABlankAuthorIsOmittedAndTheTitleIsOneLine() {
        for author in [nil, "", "   ", "\n"] as [String?] {
            let colophon = ReaderColophon(title: "A Title\nOn Two Lines", author: author, words: 165, rate: 1)
            XCTAssertNil(colophon.author, "\(String(describing: author))")
            XCTAssertEqual(colophon.title, "A Title On Two Lines")
            XCTAssertEqual(colophon.spokenText, "The End, A Title On Two Lines, About 1 minute of listening")
        }
        XCTAssertEqual(ReaderColophon(title: "T", author: "  Poe \n", words: 1, rate: 1).author, "Poe")
    }

    // MARK: - Length

    func testForBookPrefersTheRecordsWordCount() {
        var document = LibraryDocument(id: UUID(), title: "Book", fileName: "b.txt", addedAt: Date(),
                                       pageCount: 1, sentenceCount: 10, contentHash: "h", kind: .text,
                                       author: "Author", wordCount: 165 * 30)
        XCTAssertEqual(ReaderColophon.forBook(document, textWords: 165 * 90, rate: 1).minutes, 30,
                       "the card's figure wins")
        document.wordCount = 0
        XCTAssertEqual(ReaderColophon.forBook(document, textWords: 165 * 90, rate: 1).minutes, 90,
                       "the loaded text's words when the record has none")
        let colophon = ReaderColophon.forBook(document, textWords: 10, rate: 1)
        XCTAssertEqual(colophon.title, "Book")
        XCTAssertEqual(colophon.author, "Author")
    }

    /// The colophon and the card round the same way, at any speed.
    func testMinutesMatchTheCardsEstimate() {
        for words in [1, 400, 2_317, 10_000, 123_456] {
            for rate in [1.0, 1.5] {
                let document = LibraryDocument(id: UUID(), title: "T", fileName: "t.txt", addedAt: Date(),
                                               pageCount: 1, sentenceCount: 1, contentHash: "h", kind: .text,
                                               wordCount: words)
                guard let seconds = document.estimatedTotalSeconds(rate: rate) else {
                    XCTFail("\(words) words have an estimate")
                    continue
                }
                let card = ListeningEstimate.wholeMinutes(seconds: seconds)
                XCTAssertEqual(ReaderColophon.forBook(document, textWords: 0, rate: rate).minutes, card,
                               "\(words) words at \(rate)x")
            }
        }
        XCTAssertEqual(ReaderColophon(title: "T", author: nil, words: 0, rate: 1).minutes, 1,
                       "never under a minute")
    }

    // MARK: - The end mark

    private func book(_ count: Int = 6) -> DocContent {
        let sentences = (0..<count).map { Sentence(id: $0, text: "Sentence \($0) reads \"aloud\".", para: $0 / 2, page: 1) }
        let paragraphs = stride(from: 0, to: count, by: 2).map {
            Paragraph(id: $0 / 2, sentenceIDs: $0..<min($0 + 2, count), page: 1)
        }
        return DocContent(title: "Book", pageCount: 1, sentences: sentences, paragraphs: paragraphs,
                          contentHash: "colophon-\(count)")
    }

    private let colophon = ReaderColophon(title: "Hard \"Times\"", author: "Charles Dickens",
                                          words: 165 * 72, rate: 1)

    func testNoColophonIsTheDots() {
        let traits = UITraitCollection(legibilityWeight: .regular)
        XCTAssertEqual(ReaderTextView.Coordinator.makeEndMark(colophon: nil, fontSize: 19, traits: traits).string,
                       "· · ·")
        let built = ReaderTextView.Coordinator.makeAttributedString(content: book(), fontSize: 19, traits: traits)
        XCTAssertEqual((built.string.string as NSString).substring(with: built.endMarkRange), "· · ·")
        XCTAssertEqual(NSMaxRange(built.endMarkRange), built.string.length, "the mark is the tail")
    }

    func testTheColophonsText() {
        let traits = UITraitCollection(legibilityWeight: .regular)
        let mark = ReaderTextView.Coordinator.makeEndMark(colophon: colophon, fontSize: 19, traits: traits)
        let expected = "\u{FFFC}\nThe End\n" + ReaderTypography.typeset(colophon.title) + "\n"
            + "Charles Dickens\n" + "About 1 hr 12 min of listening"
        XCTAssertEqual(mark.string, expected)

        let authorless = ReaderColophon(title: "T", author: nil, words: 165, rate: 1)
        XCTAssertEqual(ReaderTextView.Coordinator.makeEndMark(colophon: authorless, fontSize: 19, traits: traits).string,
                       "\u{FFFC}\nThe End\nT\nAbout 1 min of listening")
    }

    func testTheColophonsTypography() throws {
        let traits = UITraitCollection(legibilityWeight: .regular)
        let mark = ReaderTextView.Coordinator.makeEndMark(colophon: colophon, fontSize: 19, traits: traits)
        let text = mark.string as NSString

        let attachment = try XCTUnwrap(mark.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.bounds.size, ReaderPageStyle.ruleSize, "the chapter opening's rule")

        let theEnd = text.range(of: "The End")
        let heading = try XCTUnwrap(mark.attribute(.font, at: theEnd.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitItalic), "\(heading)")
        XCTAssertEqual(heading.pointSize, ReaderPageStyle(fontSize: 19).headingSize)

        let titleAt = text.range(of: ReaderTypography.typeset(colophon.title)).location
        let title = try XCTUnwrap(mark.attribute(.font, at: titleAt, effectiveRange: nil) as? UIFont)
        let settings = title.fontDescriptor.object(forKey: .featureSettings) as? [[UIFontDescriptor.FeatureKey: Int]]
        XCTAssertTrue(settings?.contains { $0[.type] == kLowerCaseType && $0[.selector] == kLowerCaseSmallCapsSelector }
                      ?? false, "the title is in small caps")

        let line = text.range(of: colophon.listeningLine)
        let detail = try XCTUnwrap(mark.attribute(.font, at: line.location, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(detail.pointSize, ReaderPageStyle(fontSize: 19).colophonDetailSize)

        // Every paragraph centered and unhyphenated; text never in accent
        // (the rule is an image).
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolving = UITraitCollection(userInterfaceStyle: style)
            let accent = UIColor(Theme.accent).resolvedColor(with: resolving)
            mark.enumerateAttributes(in: NSRange(location: 0, length: mark.length)) { attributes, range, _ in
                let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
                XCTAssertEqual(paragraph?.alignment, .center, "\(text.substring(with: range))")
                XCTAssertEqual(paragraph?.hyphenationFactor, 0, "\(text.substring(with: range))")
                let color = (attributes[.foregroundColor] as? UIColor)?.resolvedColor(with: resolving)
                XCTAssertNotEqual(color, accent, "accent is never text: \(text.substring(with: range))")
            }
        }
    }

    func testBoldTextGivesABoldItalic() throws {
        let bold = UITraitCollection(legibilityWeight: .bold)
        let mark = ReaderTextView.Coordinator.makeEndMark(colophon: colophon, fontSize: 19, traits: bold)
        let at = (mark.string as NSString).range(of: "The End").location
        let heading = try XCTUnwrap(mark.attribute(.font, at: at, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]), "\(heading)")
        XCTAssertTrue(ReaderPageStyle.italicSerif(size: 19, bold: true).fontDescriptor.symbolicTraits
            .contains([.traitBold, .traitItalic]))
        XCTAssertFalse(ReaderPageStyle.italicSerif(size: 19).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testSentenceRangesNeverMove() {
        let content = book()
        let traits = UITraitCollection(legibilityWeight: .regular)
        let plain = ReaderTextView.Coordinator.makeAttributedString(content: content, fontSize: 19, traits: traits)
        let ended = ReaderTextView.Coordinator.makeAttributedString(content: content, fontSize: 19,
                                                                    colophon: colophon, traits: traits)
        XCTAssertEqual(plain.sentenceRanges, ended.sentenceRanges)
        XCTAssertEqual(plain.endMarkRange.location, ended.endMarkRange.location)
        XCTAssertGreaterThanOrEqual(ended.endMarkRange.location, NSMaxRange(ended.sentenceRanges[content.sentences.count - 1]),
                                    "the colophon starts after the last sentence")
        XCTAssertEqual(NSMaxRange(ended.endMarkRange), ended.string.length)
        XCTAssertEqual((ended.string.string as NSString).substring(with: ended.endMarkRange),
                       ReaderTextView.Coordinator.makeEndMark(colophon: colophon, fontSize: 19, traits: traits).string)
        XCTAssertEqual(ReaderPageStyle(fontSize: 19).colophonDetailSize, 16)   // round(0.85 × 19)
    }

    // MARK: - One spelling each (quoted needles, comment lines skipped)

    func testTheEndCopyIsSpelledOnce() throws {
        let app = try SourceTree.sources().mapValues(Self.withoutCommentLines)
        let pins: [(needle: String, files: [String])] = [
            ("\"The End\"", ["Models/ReaderColophon.swift"]),
            ("of listening\"", ["Models/ReaderColophon.swift"]),
            ("\"Listen again\"", ["Reader/PlayCircleFace.swift"]),
            ("\"arrow.counterclockwise\"", ["Reader/PlayCircleFace.swift"]),
            ("\"More classics\"", ["Library/EmptyLibraryView.swift", "Reader/ReaderChip.swift"]),
        ]
        for pin in pins {
            XCTAssertEqual(SourceTree.files(containing: pin.needle, in: app), pin.files, pin.needle)
        }
    }

    private static func withoutCommentLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
