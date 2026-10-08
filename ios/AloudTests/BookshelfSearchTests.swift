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

    /// R1-34: the short shelf opens with its ranked books, by rank, at any
    /// speed; the rest follow in catalog order. An evening and Long reads
    /// stay unranked (CD-3): at 0.5× a ranked 34-minute book reads over an
    /// hour, and takes its catalog place in An evening. Search ignores the
    /// rank.
    func testRankedBooksOpenTheirShelf() {
        var cask = book(1063, "The Cask of Amontillado", "Edgar Allan Poe", words: 2_317)
        cask.rank = 1
        var rabbit = book(14838, "The Tale of Peter Rabbit", "Beatrix Potter", words: 1_012)
        rabbit.rank = 2
        var crossing = book(1934, "A Ranked Story", "C. Writer", words: 5_539)
        crossing.rank = 3
        XCTAssertLessThan(crossing.listeningMinutes(rate: 0.75), 60)
        XCTAssertGreaterThan(crossing.listeningMinutes(rate: 0.5), 60)
        let ranked = BookshelfIndex(books: [
            book(10, "A Short Pamphlet", "A. Writer", words: 3_000),
            rabbit,
            book(11, "Another Short Piece", "B. Writer", words: 4_000),
            book(12, "A Middling Story", "D. Writer", words: 20_000),
            book(1342, "Pride and Prejudice", "Jane Austen", words: 127_359),
            crossing,
            cask,
            book(158, "Emma", "Jane Austen", words: 160_000),
        ])
        for rate in [0.5, 0.75, 1, 2] {
            let shelves = ranked.shelves(rate: rate)
            let slow = rate == 0.5
            XCTAssertEqual(shelves.first?.section, .underAnHour, "\(rate)×")
            XCTAssertEqual(shelves.first?.books.map(\.gutenbergID),
                           slow ? [1063, 14838, 10, 11] : [1063, 14838, 1934, 10, 11],
                           "ranked first, by rank, then catalog order, at \(rate)×")
            XCTAssertEqual(shelves.first { $0.section == .anEvening }?.books.map(\.gutenbergID),
                           slow ? [12, 1934] : [12], "An evening keeps catalog order at \(rate)×")
        }
        XCTAssertEqual(ranked.shelves.last?.books.map(\.gutenbergID), [1342, 158],
                       "an unranked shelf keeps catalog order")
        XCTAssertEqual(ranked.search("short")?.map(\.gutenbergID), [10, 11], "search is unchanged")
    }

    func testEmptySectionsAreOmitted() {
        let short = BookshelfIndex(books: [book(1063, "The Cask of Amontillado",
                                                "Edgar Allan Poe", words: 2_317)])
        XCTAssertEqual(short.shelves.map(\.section), [.underAnHour])
    }

    /// L019: a shelf is chosen by the time its rows show, at the app-wide
    /// speed, so a heading never disagrees with the times under it. At
    /// 0.5× a 56-minute book reads 1 hr 52 min and moves to An evening.
    func testShelvesFollowTheSpeedTheRowsShow() {
        let bigFix = book(1, "The Big Fix", "A. Writer", words: 9_251)
        XCTAssertEqual(bigFix.listeningMinutes(rate: 1), 56)
        XCTAssertEqual(bigFix.listeningMinutes(rate: 0.5), 112)
        let single = BookshelfIndex(books: [bigFix])
        XCTAssertEqual(single.shelves(rate: 1).map(\.section), [.underAnHour])
        XCTAssertEqual(single.shelves(rate: 0.5).map(\.section), [.anEvening], "no hour-long row under Under an hour")

        XCTAssertEqual(index.shelves(rate: 1).map(\.section), index.shelves.map(\.section), "1× is the built shelving")
        for rate in [0.5, 0.75, 1, 1.25, 1.5, 2, 3] {
            let shelves = index.shelves(rate: rate)
            XCTAssertEqual(shelves.reduce(0) { $0 + $1.books.count }, index.books.count, "every book at \(rate)×")
            for shelf in shelves {
                for book in shelf.books {
                    XCTAssertEqual(BookshelfSection.section(forMinutes: book.listeningMinutes(rate: rate)),
                                   shelf.section, "\(book.title) at \(rate)×")
                }
            }
        }
    }

    // MARK: - Other names and spellings

    /// L017: the catalog shortens an author to the name it displays and
    /// keeps the header's in `headerAuthor`. A search by the fuller name, or
    /// the real name behind a pen name, finds every book by that display
    /// author, not only the one whose header spelled it out.
    func testSearchFindsTheNamesTheHeaderSpelledOut() {
        var tales = book(1597, "Andersen\u{2019}s Fairy Tales", "H. C. Andersen", words: 60_000)
        tales.headerAuthor = "H. C. (Hans Christian) Andersen"
        var river = book(245, "Life on the Mississippi", "Mark Twain", words: 140_000)
        river.headerAuthor = "Mark Twain (Samuel Clemens)"
        let tom = book(74, "The Adventures of Tom Sawyer", "Mark Twain", words: 70_000)
        var subtitled = book(500, "The Short Title", "A. Writer", words: 10_000)
        subtitled.headerTitle = "The Short Title; or, The Golden Afternoon"
        let named = BookshelfIndex(books: [tales, river, tom, subtitled,
                                           book(1342, "Pride and Prejudice", "Jane Austen", words: 127_359)])
        let found = { (query: String) in named.search(query)?.map(\.gutenbergID) }

        XCTAssertEqual(found("hans christian andersen"), [1597])
        XCTAssertEqual(found("hans"), [1597])
        XCTAssertEqual(found("samuel clemens"), [245, 74], "every Mark Twain book, in catalog order")
        XCTAssertEqual(found("clemens twain"), [245, 74])
        XCTAssertEqual(found("golden afternoon"), [500], "the header's own title")
        XCTAssertEqual(found("andersen"), [1597], "the display name still finds it")
        XCTAssertEqual(found("hans austen"), [], "every word must match one book")
        XCTAssertEqual(named.search("hans")?.first?.author, "H. C. Andersen", "the display name is unchanged")
    }

    /// L018: search splits a hyphen as it does any punctuation, so a title's
    /// "Case-Book" is "case book"; typed as one word, the usual modern
    /// spelling, it finds the book too.
    func testAHyphenatedWordMatchesWrittenAsOne() {
        let hyphenated = BookshelfIndex(books: [
            book(69700, "The Case-Book of Sherlock Holmes", "Arthur Conan Doyle", words: 90_000),
            book(7184, "A Heart-Song of To-Day", "A. Writer", words: 20_000),
            book(1342, "Pride and Prejudice", "Jane Austen", words: 127_359),
        ])
        for query in ["casebook", "caseb", "the casebook of sherlock holmes", "case book", "case-book"] {
            XCTAssertEqual(hyphenated.search(query)?.map(\.gutenbergID), [69700], query)
        }
        XCTAssertEqual(hyphenated.search("today")?.map(\.gutenbergID), [7184])
        XCTAssertEqual(hyphenated.search("heartsong")?.map(\.gutenbergID), [7184])
        XCTAssertEqual(BookshelfIndex.hyphenJoinedWords("The Case-Book of Sherlock Holmes"), ["casebook"])
        XCTAssertEqual(BookshelfIndex.hyphenJoinedWords("Pride and Prejudice"), [])
    }

    // MARK: - Shipped catalog

    func testShippedCatalog() throws {
        let books = BookshelfCatalog.load(from: .main)
        try XCTSkipIf(books.isEmpty, "no bundled catalog in this build")
        let shipped = BookshelfIndex(books: books)
        XCTAssertEqual(shipped.search("pride")?.first?.gutenbergID, 1342)
        XCTAssertTrue(shipped.search("chretien")?.contains { $0.gutenbergID == 831 } ?? false)
        XCTAssertEqual(shipped.book(gutenbergID: 1063)?.title, "The Cask of Amontillado")
        // L017, L018: the names and spellings a reader types.
        if shipped.book(gutenbergID: 1597) != nil {
            XCTAssertTrue(shipped.search("hans christian andersen")?.contains { $0.gutenbergID == 1597 } ?? false)
        }
        if shipped.book(gutenbergID: 69700) != nil {
            XCTAssertTrue(shipped.search("casebook")?.contains { $0.gutenbergID == 69700 } ?? false)
        }
    }

    /// R1-34: Under an hour opens with The Cask of Amontillado and the other
    /// ranked short classics, in the catalog's order of rank; the other
    /// shelves have no rank and keep catalog order. The counts are those of
    /// the 442-book catalog this was written against; a top-up changes them.
    func testTheShippedShortShelfOpensWithRecognisableClassics() throws {
        let books = BookshelfCatalog.load(from: .main)
        try XCTSkipIf(books.isEmpty, "no bundled catalog in this build")
        let shelves = BookshelfIndex(books: books).shelves(rate: 1)
        XCTAssertEqual(shelves.first?.section, .underAnHour)
        XCTAssertEqual(shelves.first?.books.first?.gutenbergID, 1063)
        let short = try XCTUnwrap(shelves.first).books
        let ranks = short.compactMap(\.rank)
        XCTAssertEqual(ranks, ranks.sorted(), "ranked books lead, by rank")
        XCTAssertEqual(short.prefix(ranks.count).map(\.rank), ranks.map { Optional($0) },
                       "every ranked book comes before every unranked one")
        for shelf in shelves.dropFirst() {
            XCTAssertTrue(shelf.books.allSatisfy { $0.rank == nil }, "\(shelf.section.title) is unranked")
            let order = shelf.books.map { book in books.firstIndex { $0.gutenbergID == book.gutenbergID } ?? -1 }
            XCTAssertEqual(order, order.sorted(), "\(shelf.section.title) keeps catalog order")
        }
        if books.count == 442 {
            XCTAssertEqual(shelves.map(\.books.count), [15, 93, 334])
        }
    }
}
