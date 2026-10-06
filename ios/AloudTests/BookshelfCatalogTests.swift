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
