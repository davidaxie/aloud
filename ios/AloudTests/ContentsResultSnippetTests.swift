import SwiftUI
import XCTest
@testable import Aloud

/// The first hit of `query` in a one-sentence book, found the way Contents
/// search finds it (case- and diacritic-insensitive).
private func firstMatch(of query: String, in sentence: String) throws -> SentenceMatch {
    let content = DocContent(title: "Snippet", pageCount: 1,
                             sentences: [Sentence(id: 0, text: sentence, para: 0, page: 1)],
                             paragraphs: [], contentHash: "snippet")
    return try XCTUnwrap(content.matches(of: query).first, "no \"\(query)\" in \"\(sentence)\"")
}

/// A search result shows its sentence cut to start a few words before the
/// hit, behind an ellipsis, so the accent-tinted hit is always on the first
/// line; a hit deep in a long sentence used to sit in the truncated tail.
final class ContentsResultSnippetTests: XCTestCase {

    private typealias Snippet = ContentsSearch.Snippet

    private static let longSentence = "When the countess came back from the ball at the Bezukhovs' "
        + "with the whole household behind her, Natasha was already asleep."

    private func snippet(_ query: String, in sentence: String, leadLimit: Int = 16) throws -> Snippet {
        ContentsSearch.snippet(for: try firstMatch(of: query, in: sentence), leadLimit: leadLimit)
    }

    // MARK: - Where the hit falls

    func testAHitAtTheStartHasNoLead() throws {
        XCTAssertEqual(try snippet("Natasha", in: "Natasha ran into the drawing room."),
                       Snippet(lead: "", hit: "Natasha", tail: " ran into the drawing room."))
    }

    func testAShortLeadIsKeptWhole() throws {
        XCTAssertEqual(try snippet("Natasha", in: "So Natasha ran."),
                       Snippet(lead: "So ", hit: "Natasha", tail: " ran."))
    }

    /// The hit 98 characters in: the lead keeps its last whole words.
    func testAHitDeepInALongSentenceKeepsTheLastFewWords() throws {
        XCTAssertEqual(try snippet("Natasha", in: Self.longSentence),
                       Snippet(lead: "\u{2026}behind her, ", hit: "Natasha", tail: " was already asleep."))
    }

    /// The accessibility sizes' limit leaves the ellipsis and the hit.
    func testTheAccessibilityLimitLeavesLittleMoreThanTheEllipsis() throws {
        let limit = ContentsSearch.leadLimit(for: .accessibility3)
        XCTAssertEqual(try snippet("Natasha", in: Self.longSentence, leadLimit: limit),
                       Snippet(lead: "\u{2026}", hit: "Natasha", tail: " was already asleep."))
    }

    func testTheAccessibilitySizesKeepLessThanTheOthers() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            XCTAssertLessThan(ContentsSearch.leadLimit(for: size),
                              ContentsSearch.leadLimit(for: .large), "\(size)")
        }
        XCTAssertEqual(ContentsSearch.leadLimit(for: .xxxLarge), ContentsSearch.leadLimit(for: .large))
    }

    /// A window that already starts on a word keeps that word.
    func testAWindowStartingOnAWordKeepsIt() throws {
        XCTAssertEqual(try snippet("Natasha", in: "Pierre said to the old prince that Natasha was right.").lead,
                       "\u{2026}old prince that ")
    }

    // MARK: - Typesetting

    /// The sentence is typeset whole before the cut, so the quote before the
    /// hit still opens and the one after it still closes.
    func testQuotesAreTypesetInContext() throws {
        XCTAssertEqual(try snippet("Natasha", in: "The count laughed and said to his wife, \"Natasha is right.\""),
                       Snippet(lead: "\u{2026}to his wife, \u{201C}", hit: "Natasha", tail: " is right.\u{201D}"))
    }

    /// "--" typesets to an em dash and a word joiner, two UTF-16 units for
    /// two, so the hit after it is still the hit.
    func testTheHitStaysPutAfterADoubleHyphen() throws {
        let sentence = "\"Well, Prince, so Genoa and Lucca are now just family estates of the "
            + "Buonapartes--but I warn you,\" said Anna Pavlovna."
        XCTAssertEqual(try snippet("but I warn", in: sentence),
                       Snippet(lead: "\u{2026}Buonapartes\u{2014}\u{2060}", hit: "but I warn",
                               tail: " you,\u{201D} said Anna Pavlovna."))
    }

    // MARK: - Unicode

    /// Decomposed accents are two UTF-16 units and one character: the split
    /// lands on the hit and the cut counts the accented letters once.
    func testDecomposedAccentsAndADiacriticInsensitiveHit() throws {
        let sentence = "Le pre\u{0301}sident de la Re\u{0301}publique a dit que l'e\u{0301}tat c'est moi."
        let result = try snippet("etat", in: sentence)
        XCTAssertEqual(result.lead, "\u{2026}a dit que l\u{2019}")
        XCTAssertEqual(Array(result.hit.unicodeScalars), Array("e\u{0301}tat".unicodeScalars),
                       "the hit is the sentence's own letters, accent included")
        XCTAssertEqual(result.tail, " c\u{2019}est moi.")
    }

    func testCyrillic() throws {
        XCTAssertEqual(try snippet("наташа", in: "Когда графиня вернулась с бала у Безуховых, Наташа уже спала."),
                       Snippet(lead: "\u{2026}у Безуховых, ", hit: "Наташа", tail: " уже спала."))
    }

    /// No spaces to cut at: the plain cut, still whole characters.
    func testTextWithoutSpacesKeepsThePlainCut() throws {
        XCTAssertEqual(try snippet("娜塔莎", in: "那天晚上安德烈公爵在舞会上第一次看见了娜塔莎。"),
                       Snippet(lead: "\u{2026}上安德烈公爵在舞会上第一次看见了", hit: "娜塔莎", tail: "。"))
    }

    /// Counted in characters: an emoji sequence or a decomposed accent at
    /// the window's edge is kept whole or dropped whole.
    func testTheCutNeverSplitsACharacter() {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(ContentsSearch.trimmedLead(String(repeating: family, count: 20), limit: 16),
                       "\u{2026}" + String(repeating: family, count: 16))
        let accented = String(repeating: "e\u{0301}", count: 20)
        let trimmed = ContentsSearch.trimmedLead(accented, limit: 16)
        XCTAssertEqual(Array(trimmed.unicodeScalars),
                       Array(("\u{2026}" + String(repeating: "e\u{0301}", count: 16)).unicodeScalars))
    }

    // MARK: - Invariants

    /// Every word of a long sentence as the query, at several limits: the
    /// runs rebuild the typeset sentence's end, the hit is the query, the
    /// lead stays within its limit and a cut starts on a word.
    func testEveryHitKeepsItsEmphasisAndAWordStart() throws {
        let sentence = "\"Well,\" said the old prince--who had been listening from the doorway all the while-- "
            + "\"I'll tell Natasha myself, and you may tell Pierre that the carriage is waiting.\""
        let typeset = ReaderTypography.typeset(sentence)
        let words = Set(sentence.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for word in words {
            let match = try firstMatch(of: word, in: sentence)
            let prefix = String(typeset.utf16.prefix(match.range.lowerBound.utf16Offset(in: sentence)))!
            for limit in [0, 2, 16, 40] {
                let result = ContentsSearch.snippet(for: match, leadLimit: limit)
                let context = "\"\(word)\" at \(limit): \(result)"
                XCTAssertEqual(result.hit.compare(word, options: DocContent.searchOptions), .orderedSame, context)
                XCTAssertTrue(typeset.hasSuffix(result.hit + result.tail), context)
                XCTAssertEqual(String(typeset.dropLast((result.hit + result.tail).count)), prefix, context)
                guard result.lead != prefix else {
                    XCTAssertLessThanOrEqual(prefix.count, limit, context)
                    continue
                }
                XCTAssertTrue(result.lead.hasPrefix("\u{2026}"), context)
                let kept = String(result.lead.dropFirst())
                XCTAssertLessThanOrEqual(kept.count, limit, context)
                XCTAssertTrue(prefix.hasSuffix(kept), context)
                XCTAssertFalse(kept.first?.isWhitespace ?? false, context)
                // Starts on a word unless the window held no space at all.
                let window = prefix.suffix(limit)
                let before = prefix.dropLast(kept.count).last
                if window.contains(where: \.isWhitespace), !kept.isEmpty {
                    XCTAssertTrue(before.map { $0.isWhitespace || !$0.isLetter } ?? true,
                                  "the cut should start on a word: \(context)")
                }
            }
        }
    }
}

/// The result row at real widths: the text through the hit fits the first
/// line at every size, and at the accessibility sizes the sentence gets five
/// lines and its chapter wraps (both were cut at three and one).
@MainActor
final class ContentsResultLabelLayoutTests: XCTestCase {

    /// A 375pt phone's row: the screen minus the sheet's 24pt gutters.
    private static let width: CGFloat = 375 - 2 * Theme.Space.sheetGutter
    private static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3,
                                                   .accessibility5]
    private static let longSentence = "When the countess came back from the ball at the Bezukhovs' "
        + "with the whole household behind her, Natasha was already asleep."

    private func height(of view: some View, size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
            .height
    }

    private func labelHeight(_ sentence: String, location: String = "CHAPTER I",
                             size: DynamicTypeSize) throws -> CGFloat {
        height(of: ContentsResultLabel(match: try firstMatch(of: "Natasha", in: sentence), location: location),
               size: size)
    }

    /// The lead and the hit measure one line, as tall as the hit alone.
    func testTheHitSitsOnTheFirstLineAtEverySize() throws {
        let match = try firstMatch(of: "Natasha", in: Self.longSentence)
        for size in Self.sizes {
            let snippet = ContentsSearch.snippet(for: match, leadLimit: ContentsSearch.leadLimit(for: size))
            let oneLine = height(of: Text(snippet.hit).font(Theme.font(.body)), size: size)
            let throughHit = height(of: Text(snippet.lead + snippet.hit).font(Theme.font(.body)), size: size)
            XCTAssertEqual(throughHit, oneLine, accuracy: 0.5,
                           "\(size): \"\(snippet.lead + snippet.hit)\" should fit the first line")
        }
    }

    /// Three lines below the accessibility sizes, five at them.
    func testTheSentenceGetsMoreLinesAtAccessibilitySizes() throws {
        let long = "Natasha" + String(repeating: " and the old count laughed", count: 20) + "."
        for size in Self.sizes {
            let one = try labelHeight("Natasha.", size: size)
            let line = try labelHeight("Natasha.\nNatasha.", size: size) - one
            XCTAssertGreaterThan(line, 10, "\(size): fixture should add a line")
            let lines = 1 + (try labelHeight(long, size: size) - one) / line
            XCTAssertEqual(lines, size.isAccessibilitySize ? 5 : 3, accuracy: 0.25, "\(size)")
        }
    }

    /// "BOOK ONE: 1805 · CHAPTER XVIII" tells same-phrase hits apart: it
    /// wraps at the accessibility sizes and stays one line below them.
    func testTheLocationWrapsOnlyAtAccessibilitySizes() throws {
        let long = String(repeating: "BOOK ONE: 1805 \u{00B7} ", count: 6) + "CHAPTER XXVIII"
        for size in Self.sizes {
            let short = try labelHeight("Natasha.", location: "CHAPTER I", size: size)
            let wrapped = try labelHeight("Natasha.", location: long, size: size)
            if size.isAccessibilitySize {
                XCTAssertGreaterThan(wrapped, short + 10, "\(size): the location should wrap")
            } else {
                XCTAssertEqual(wrapped, short, accuracy: 0.5, "\(size): the location should stay one line")
            }
        }
    }

    // MARK: - Spoken results

    /// Focus stays in the search field, so VoiceOver hears a search land:
    /// the count, or the no-matches line, once per change of count. Typing
    /// on through the same results, or on into nothing, says nothing more.
    func testALandedSearchIsAnnouncedOncePerCount() {
        func line(_ count: Int, _ previous: Int?) -> String? {
            ContentsSearch.resultsAnnouncement(count: count, query: "whale", previousCount: previous)
        }
        XCTAssertEqual(line(3, nil), "3 matches")
        XCTAssertEqual(line(1, nil), "1 match")
        XCTAssertEqual(line(0, nil), "No matches for \u{201C}whale\u{201D}")
        XCTAssertEqual(line(2, 3), "2 matches")
        XCTAssertEqual(line(0, 3), "No matches for \u{201C}whale\u{201D}")
        XCTAssertNil(line(3, 3))
        XCTAssertNil(line(0, 0))
    }

    /// Through the app's one announcement path: a muted process only logs it.
    @MainActor
    func testTheResultsAnnouncementGoesThroughTheOneAnnouncementPath() {
        #if DEBUG
        let log = UITestAnnouncementLog.shared
        let query = "q\(UUID().uuidString.prefix(6))"
        ContentsSearch.announceResults(count: 0, query: query, previousCount: nil, muted: true)
        XCTAssertEqual(log.entries.last, ContentsSearch.noMatchesLabel(query))
        let before = log.entries
        ContentsSearch.announceResults(count: 0, query: query + "x", previousCount: 0, muted: true)
        XCTAssertEqual(log.entries, before, "typing on into nothing stays quiet")
        #endif
    }
}
