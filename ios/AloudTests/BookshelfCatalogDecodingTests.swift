import XCTest
@testable import Aloud

/// R9: catalog.json decodes one entry at a time. A hand-edited queue can
/// carry a year of "c. 1600" or an id in quotes through the fetcher and the
/// normalizer; that entry is skipped, and the other ~440 still shelve.
final class BookshelfCatalogDecodingTests: XCTestCase {

    private func entry(_ id: String, year: String = "null") -> String {
        """
        {"gutenberg_id": \(id), "title": "Emma", "author": "Jane Austen", "year": \(year),
         "file": "book.txt", "words": 160000}
        """
    }

    private func books(_ entries: [String]) -> [BookshelfBook] {
        let json = #"{"books": ["# + entries.joined(separator: ", ") + "]}"
        return BookshelfCatalog.books(inCatalog: Data(json.utf8))
    }

    func testEveryGoodEntryDecodes() {
        let decoded = books([entry("158", year: "1815"), entry("1342")])
        XCTAssertEqual(decoded.map(\.gutenbergID), [158, 1342])
        XCTAssertEqual(decoded.map(\.year), [1815, nil])
    }

    func testOneBadEntryDoesNotEmptyTheShelf() {
        let decoded = books([
            entry("158"),
            entry("1234", year: #""c. 1600""#),
            entry(#""99999""#),
            entry("1342"),
        ])
        XCTAssertEqual(decoded.map(\.gutenbergID), [158, 1342], "the bad rows are skipped, the rest kept in order")
    }

    func testEntriesThatAreNotBooksAreSkipped() {
        let decoded = books(["null", "42", #""x""#, "[]", "{}", entry("158")])
        XCTAssertEqual(decoded.map(\.gutenbergID), [158])
    }

    func testAnUnreadableCatalogIsEmpty() {
        for text in ["", "not json", "{}", #"{"books": 3}"#, "[]"] {
            XCTAssertEqual(BookshelfCatalog.books(inCatalog: Data(text.utf8)), [], text)
        }
    }

    func testTheHeaderSpellingsStillDecode() {
        let json = #"""
        {"books": [{"gutenberg_id": 1719, "title": "The Man Who Was Thursday",
          "author": "G. K. Chesterton", "year": null, "file": "1719.txt", "words": 58000,
          "header_author": "G.K. Chesterton"}]}
        """#
        let decoded = BookshelfCatalog.books(inCatalog: Data(json.utf8))
        XCTAssertEqual(decoded.first?.headerAuthor, "G.K. Chesterton")
        XCTAssertNil(decoded.first?.headerTitle)
    }

    /// R1-34, R1-35: the full title and the rank the catalog build writes
    /// decode, and a catalog from before them still does, without either.
    func testTheFullTitleAndRankDecodeAndAreOptional() {
        let json = #"""
        {"books": [{"gutenberg_id": 84, "title": "Frankenstein", "author": "Mary Wollstonecraft Shelley",
          "year": null, "file": "84.txt", "words": 75042,
          "header_title": "Frankenstein; or, the modern prometheus",
          "full_title": "Frankenstein; or, The Modern Prometheus"},
         {"gutenberg_id": 1063, "title": "The Cask of Amontillado", "author": "Edgar Allan Poe",
          "year": null, "file": "1063.txt", "words": 2317, "rank": 1}]}
        """#
        let decoded = BookshelfCatalog.books(inCatalog: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.gutenbergID), [84, 1063])
        XCTAssertEqual(decoded.first?.fullTitle, "Frankenstein; or, The Modern Prometheus")
        XCTAssertNil(decoded.first?.rank)
        XCTAssertEqual(decoded.last?.rank, 1)
        XCTAssertNil(decoded.last?.fullTitle)
        let old = books([entry("158")])
        XCTAssertEqual(old.map(\.gutenbergID), [158], "a catalog without them decodes")
        XCTAssertNil(old.first?.fullTitle)
        XCTAssertNil(old.first?.rank)
    }
}
