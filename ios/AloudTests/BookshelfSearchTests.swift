import XCTest
@testable import Aloud

/// R9: the Bookshelf's search (title or author, diacritic-insensitive, one
/// ranked list) and its three listening-length shelves.
final class BookshelfSearchTests: XCTestCase {

    private func book(_ id: Int, _ title: String, _ author: String, words: Int) -> BookshelfBook {
        BookshelfBook(gutenbergID: id, title: title, author: author, year: nil,
                      file: "\(id).txt", words: words)
    }

    /// Word counts put books on all three shelves (165 words a minute at 1×).
    private lazy var index = BookshelfIndex(books: [
        book(1342, "Pride and Prejudice", "Jane Austen", words: 127_359),
        book(20, "The Pride of Jennico", "Charles Major", words: 40_000),
        book(1260, "Jane Eyre", "Charlotte Brontë", words: 188_455),
        book(158, "Emma", "Jane Austen", words: 160_000),
        book(19994, "Three Hundred Aesop\u{2019}s Fables", "Aesop", words: 5_000),
        book(108, "The Return of Sherlock Holmes", "Arthur Conan Doyle", words: 49_500),
    ])

    private func ids(_ query: String) -> [Int]? {
        index.search(query)?.map(\.gutenbergID)
    }

    // MARK: - Search

    func testBlankQueryShowsTheShelves() {
        XCTAssertNil(index.search(""))
        XCTAssertNil(index.search("   "))
    }

    func testNoMatchIsAnEmptyList() {
        XCTAssertEqual(ids("zzzz"), [])
    }

    func testTitlePrefixRanksFirst() {
        XCTAssertEqual(ids("pride")?.first, 1342)
        XCTAssertEqual(ids("pride"), [1342, 20], "a leading article ranks just behind")
    }

    func testSearchIgnoresCaseDiacriticsAndPadding() {
        for query in ["bronte", "BRONTË", " brontë "] {
            XCTAssertEqual(ids(query), [1260], query)
        }
    }

    func testTitleMatchesRankAboveAuthorMatches() {
        let found = ids("jane") ?? []
        XCTAssertEqual(found.first, 1260)
        XCTAssertEqual(Set(found), [1260, 1342, 158])
    }

    func testStraightApostropheFindsACurlyOne() {
        XCTAssertEqual(ids("aesop's"), [19994])
    }

    func testWordsMatchInAnyOrder() {
        XCTAssertEqual(ids("sherlock return"), [108])
    }

    // MARK: - Punctuation and initials

    /// The catalog spells initials "H. G." and keeps "&" and apostrophes;
    /// people type "h.g.", "hg", "and" and "gullivers".
    private lazy var punctuated = BookshelfIndex(books: [
        book(35, "The Time Machine", "H. G. Wells", words: 32_000),
        book(1719, "The Man Who Was Thursday", "G. K. Chesterton", words: 58_000),
        book(829, "Gulliver\u{2019}s Travels", "Jonathan Swift", words: 104_000),
        book(42, "The Strange Case of Dr. Jekyll and Mr. Hyde", "Robert Louis Stevenson", words: 25_000),
        book(7, "Aladdin & Co.", "Herbert Quick", words: 90_000),
        book(46, "A Christmas Carol", "Charles Dickens", words: 29_000),
    ])

    private func punctuatedIDs(_ query: String) -> [Int]? {
        punctuated.search(query)?.map(\.gutenbergID)
    }

    func testInitialsMatchHoweverTheyArePunctuated() {
        for query in ["h.g. wells", "H. G. Wells", "hg wells", "h g wells", "h.g.wells", "h.g."] {
            XCTAssertEqual(punctuatedIDs(query), [35], query)
        }
        for query in ["g.k. chesterton", "gk chesterton", "g. k. chesterton"] {
            XCTAssertEqual(punctuatedIDs(query), [1719], query)
        }
    }

    /// Typing "h.g. wells" a letter at a time never drops to no match.
    func testInitialsKeepMatchingWhileTyped() {
        let typed = "h.g. wells"
        for end in typed.indices.dropFirst() + [typed.endIndex] {
            let prefix = String(typed[..<end])
            XCTAssertTrue(punctuatedIDs(prefix)?.contains(35) == true, prefix)
        }
        XCTAssertEqual(punctuatedIDs("h. g. w"), [35], "a last letter may start the next word")
    }

    func testAmpersandIsAnd() {
        XCTAssertEqual(punctuatedIDs("jekyll & hyde"), [42])
        XCTAssertEqual(punctuatedIDs("dr jekyll & mr hyde"), [42])
        XCTAssertEqual(punctuatedIDs("aladdin & co"), [7])
        XCTAssertEqual(punctuatedIDs("aladdin and co"), [7], "both ways")
    }

    func testApostrophesAndStrayPunctuationAreOptional() {
        XCTAssertEqual(punctuatedIDs("gullivers travels"), [829])
        XCTAssertEqual(punctuatedIDs("gulliver's travels"), [829])
        XCTAssertEqual(punctuatedIDs("gulliver"), [829])
        XCTAssertEqual(punctuatedIDs("time machine,"), [35])
        XCTAssertEqual(punctuatedIDs("dr. jekyll"), [42])
        XCTAssertEqual(ids("aesops fables"), [19994])
        XCTAssertEqual(ids("sherlock holmes,"), [108])
    }

    /// A lone "a" is a word, not an initial joined to the next one.
    func testSingleLetterWordsStillMatch() {
        XCTAssertEqual(punctuatedIDs("a christmas carol"), [46])
        XCTAssertEqual(punctuatedIDs("christmas carol"), [46])
    }

    func testPunctuationAloneShowsTheShelves() {
        XCTAssertNil(punctuated.search("..."))
        XCTAssertNil(punctuated.search(" , "))
    }

    func testBookLookupByID() {
        XCTAssertEqual(index.book(gutenbergID: 158)?.title, "Emma")
        XCTAssertNil(index.book(gutenbergID: 1))
    }

    // MARK: - Shelves

    func testSectionBoundaries() {
        XCTAssertEqual(BookshelfSection.section(forMinutes: 1), .underAnHour)
        XCTAssertEqual(BookshelfSection.section(forMinutes: 59), .underAnHour)
        XCTAssertEqual(BookshelfSection.section(forMinutes: 60), .anEvening)
        XCTAssertEqual(BookshelfSection.section(forMinutes: 300), .anEvening)
        XCTAssertEqual(BookshelfSection.section(forMinutes: 301), .longReads)
    }

    func testSectionTitles() {
        XCTAssertEqual(BookshelfSection.allCases.map(\.title),
                       ["Under an hour", "An evening", "Long reads"])
    }

    func testShelvesPartitionTheCatalogInOrder() {
        let shelves = index.shelves
        XCTAssertEqual(shelves.map(\.section), [.underAnHour, .anEvening, .longReads])
        XCTAssertEqual(shelves.reduce(0) { $0 + $1.books.count }, index.books.count)

        let shelved = shelves.flatMap { $0.books.map(\.gutenbergID) }
        XCTAssertEqual(Set(shelved).count, shelved.count, "every book is on exactly one shelf")
        XCTAssertEqual(Set(shelved), Set(index.books.map(\.gutenbergID)))

        for shelf in shelves {
            for book in shelf.books {
                XCTAssertEqual(BookshelfSection.section(forMinutes: book.estimatedListeningMinutes),
                               shelf.section, book.title)
            }
            let catalogOrder = index.books.filter { book in
                shelf.books.contains { $0.gutenbergID == book.gutenbergID }
            }
            XCTAssertEqual(shelf.books.map(\.gutenbergID), catalogOrder.map(\.gutenbergID),
                           "books keep catalog order within a shelf")
        }
    }

    func testEmptySectionsAreOmitted() {
        let short = BookshelfIndex(books: [book(1063, "The Cask of Amontillado",
                                                "Edgar Allan Poe", words: 2_317)])
        XCTAssertEqual(short.shelves.map(\.section), [.underAnHour])
    }

    // MARK: - Shipped catalog

    func testShippedCatalog() throws {
        let books = BookshelfCatalog.load(from: .main)
        try XCTSkipIf(books.isEmpty, "no bundled catalog in this build")
        let shipped = BookshelfIndex(books: books)
        XCTAssertEqual(shipped.search("pride")?.first?.gutenbergID, 1342)
        XCTAssertTrue(shipped.search("chretien")?.contains { $0.gutenbergID == 831 } ?? false)
        XCTAssertEqual(shipped.book(gutenbergID: 1063)?.title, "The Cask of Amontillado")
    }
}
