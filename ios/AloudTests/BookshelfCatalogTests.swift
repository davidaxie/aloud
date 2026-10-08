import XCTest
@testable import Aloud

/// R9: the bundled catalog as ios/sync_bookshelf.sh builds it
/// (tools/catalog_normalize.py): title case, clean authors, and three
/// listening-length shelves that partition it. No counts are hard-coded:
/// the scheduled Gutenberg top-up grows the catalog.
final class BookshelfCatalogTests: XCTestCase {

    /// tools/catalog_normalize.py MINOR_WORDS; the two lists must match.
    private static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "for", "nor", "or", "so", "yet", "as", "at",
        "by", "from", "in", "into", "of", "off", "on", "onto", "per", "to", "up",
        "upon", "via", "with", "vs", "v", "da", "de", "del", "della", "der", "des",
        "di", "du", "et", "la", "le", "les", "van", "von", "y", "aux",
    ]

    private var books: [BookshelfBook] = []

    override func setUp() {
        super.setUp()
        books = BookshelfCatalog.load(from: .main)
        if books.isEmpty { XCTFail("run ios/sync_bookshelf.sh") }
    }

    func testNoTitleHasLowercaseMajorWords() {
        let violations = books.flatMap { book in
            Self.titleViolations(book.title).map { "#\(book.gutenbergID) \($0) in '\(book.title)'" }
        }
        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testNoAuthorStartsWithPunctuation() {
        for book in books {
            let first = book.author.first
            XCTAssertTrue(first?.isLetter == true && first?.isUppercase == true,
                          "#\(book.gutenbergID) author '\(book.author)'")
            XCTAssertFalse(book.author.contains("("), "#\(book.gutenbergID) author '\(book.author)'")
        }
    }

    /// R1-35, tools/catalog_normalize.py MAX_TITLE_LENGTH: the shelf shows a
    /// display title, never a subtitle-long one.
    func testNoTitleIsLongerThanTheShelfShows() {
        let long = books.filter { $0.title.count > Self.maxTitleLength }
            .map { "#\($0.gutenbergID) (\($0.title.count)) '\($0.title)'" }
        XCTAssertEqual(long, [], long.joined(separator: "\n"))
    }

    /// R1-35, tools/catalog_normalize.py author_violations: no pen name's
    /// gloss in the display author.
    func testNoAuthorCarriesAPseudonymGloss() {
        let glossed = books.filter { $0.author.contains("--") || $0.author.contains("Pseudonym") }
            .map { "#\($0.gutenbergID) '\($0.author)'" }
        XCTAssertEqual(glossed, [], glossed.joined(separator: "\n"))
    }

    /// R1-35: the critique's titles and authors read as a curated shelf,
    /// where the shipped catalog has those books.
    func testTheCuratedTitlesAndAuthorsShip() {
        let expected: [(id: Int, title: String?, author: String?)] = [
            (84, "Frankenstein", nil), (1063, "The Cask of Amontillado", nil),
            (41537, "The Inferno", nil), (24739, "Bidwell's Travels", nil),
            (15399, "The Interesting Narrative of the Life of Olaudah Equiano", nil),
            (44646, "The Memoirs of the Duchesse de Dino", nil),
            (500, nil, "Carlo Collodi"), (2680, nil, "Marcus Aurelius"), (44608, nil, "Babur"),
        ]
        let byID = Dictionary(books.map { ($0.gutenbergID, $0) }, uniquingKeysWith: { first, _ in first })
        for item in expected {
            guard let book = byID[item.id] else { continue }
            if let title = item.title { XCTAssertEqual(book.title, title, "#\(item.id)") }
            if let author = item.author { XCTAssertEqual(book.author, author, "#\(item.id)") }
        }
        if let frankenstein = byID[84] {
            XCTAssertEqual(frankenstein.fullTitle, "Frankenstein; or, The Modern Prometheus")
        }
    }

    /// tools/catalog_normalize.py MAX_TITLE_LENGTH; the two must match.
    private static let maxTitleLength = 60

    func testSectionsPartitionCatalog() {
        let shelves = BookshelfIndex(books: books).shelves
        let shelved = shelves.flatMap(\.books).map(\.gutenbergID)
        XCTAssertEqual(shelved.count, books.count, "the shelf counts sum to the catalog")
        XCTAssertEqual(Set(shelved).count, shelved.count, "no book is on two shelves")
        XCTAssertEqual(Set(shelved), Set(books.map(\.gutenbergID)), "every book is shelved")
    }

    func testSectionsMatchTheRule() {
        let shelves = BookshelfIndex(books: books).shelves
        for shelf in shelves {
            for book in shelf.books {
                XCTAssertEqual(shelf.section,
                               BookshelfSection.section(forMinutes: book.estimatedListeningMinutes),
                               "#\(book.gutenbergID) \(book.title)")
            }
        }
        print("Bookshelf shelves: "
              + shelves.map { "\($0.section.title) \($0.books.count)" }.joined(separator: ", "))
    }

    /// Every book the catalog lists ships beside it. A sync from an empty
    /// or half-synced books/ once emptied the folder but kept the old
    /// catalog, and every Classics row failed to open.
    func testEveryCatalogBookIsBundled() {
        let missing = books.filter { BookshelfCatalog.bundledURL(for: $0) == nil }
        XCTAssertEqual(missing.map(\.file), [], "run ios/sync_bookshelf.sh against a complete books/")
    }

    // MARK: - The catalog lint (tools/catalog_normalize.py title_violations)

    private static let word = try! NSRegularExpression(pattern: "[^\\W_](?:[\\w'\u{2019}-]*[^\\W_])?")
    private static let sentenceEnd = try! NSRegularExpression(pattern: "[^\\W\\d_]{3,}\\.\\s+$")
    private static let segmentOpeners = Set(":;!?\u{2014}\u{2013}(\"\u{201C}")

    /// A lowercase word that is not minor, or a lowercase minor word that
    /// starts a segment. Skips words inside [...], right after '&' ("&c."),
    /// and the alternative title's "or,".
    private static func titleViolations(_ title: String) -> [String] {
        let text = title as NSString
        let matches = word.matches(in: title, range: NSRange(location: 0, length: text.length))
        var previousIsAltOr = false
        var violations: [String] = []
        for (index, match) in matches.enumerated() {
            let token = text.substring(with: match.range)
            let before = text.substring(to: match.range.location)
            let after = text.substring(from: NSMaxRange(match.range))
            let tail = before.trimmingCharacters(in: .whitespaces)
            let isAltOr = token.lowercased() == "or"
                && after.trimmingCharacters(in: .whitespaces).hasPrefix(",")
            defer { previousIsAltOr = isAltOr }

            let insideBrackets = before.lastIndex(of: "[").map { open in
                before.lastIndex(of: "]").map { $0 < open } ?? true
            } ?? false
            if insideBrackets || tail.hasSuffix("&") || isAltOr { continue }

            let wholeBefore = NSRange(location: 0, length: (before as NSString).length)
            let startsSegment = index == 0
                || tail.last.map(segmentOpeners.contains) == true
                || sentenceEnd.firstMatch(in: before, range: wholeBefore) != nil
                || previousIsAltOr
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            let isMinor = minorWords.contains(token.lowercased())
            let lowercaseMajor = (parts[0].first?.isLowercase == true && !isMinor)
                || parts.dropFirst().contains { $0.first?.isLowercase == true && !minorWords.contains($0.lowercased()) }
            if lowercaseMajor {
                violations.append("lowercase major word '\(token)'")
            } else if token.first?.isLowercase == true, startsSegment {
                violations.append("lowercase word '\(token)' starts a segment")
            }
        }
        return violations
    }
}
