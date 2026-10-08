import Foundation
import os

/// One public-domain classic bundled with the app (Bookshelf/*.txt).
struct BookshelfBook: Codable, Identifiable, Hashable {
    let gutenbergID: Int
    let title: String
    let author: String
    let year: Int?
    let file: String
    let words: Int
    /// The Gutenberg header's own spelling, present only when the catalog
    /// build step changed it; the backfill matches pre-normalization records
    /// against these.
    var headerTitle: String? = nil
    var headerAuthor: String? = nil

    var id: Int { gutenbergID }

    /// Whole-book listening estimate at 1.0× (165 wpm).
    var estimatedListeningMinutes: Int {
        ListeningEstimate.minutes(words: words)
    }

    /// Whole-book listening length at `rate`: what a Classics row shows and
    /// what its shelf is chosen by, so a shelf's heading and the times
    /// under it are one measure at any speed (L019).
    func listeningMinutes(rate: Double) -> Int {
        ListeningEstimate.minutes(words: words, wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate)
    }

    private enum CodingKeys: String, CodingKey {
        case gutenbergID = "gutenberg_id"
        case title, author, year, file, words
        case headerTitle = "header_title"
        case headerAuthor = "header_author"
    }
}

// MARK: - Sections

/// The Bookshelf's three shelves, by whole-book listening length at the
/// app-wide speed, as the rows under them show it (`shelves(rate:)`).
enum BookshelfSection: String, CaseIterable, Identifiable {
    case underAnHour, anEvening, longReads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .underAnHour: return "Under an hour"
        case .anEvening: return "An evening"
        case .longReads: return "Long reads"
        }
    }

    static func section(forMinutes minutes: Int) -> BookshelfSection {
        if minutes < 60 { return .underAnHour }
        if minutes <= 300 { return .anEvening }
        return .longReads
    }
}

struct BookshelfShelf: Identifiable {
    let section: BookshelfSection
    let books: [BookshelfBook]

    var id: BookshelfSection { section }
}

// MARK: - Index

/// The catalog, shelved and searchable. Built once at launch: every string
/// search compares against is folded to search words here, so a keystroke is
/// one pass of substring checks over ~450 books.
struct BookshelfIndex {

    let books: [BookshelfBook]
    /// Sections in enum order, books in catalog order, empty sections
    /// omitted, at 1×; the screens shelve at the app-wide speed
    /// (`shelves(rate:)`).
    let shelves: [BookshelfShelf]

    private let keys: [SearchKey]
    private let byID: [Int: Int]

    private struct SearchKey {
        let title: String
        /// The folded title without a leading article, so "pride" ranks
        /// "The Pride of Jennico" as a title-prefix hit.
        let sortTitle: String
        let titleWords: [Substring]
        let authorWords: [Substring]
        /// What every query token must appear in: title, then author, then
        /// the other names and spellings the book goes by.
        let haystack: String

        /// `aliases`: the author's names the display author leaves out
        /// (`BookshelfIndex.authorAliases`), already search words.
        init(_ book: BookshelfBook, aliases: [String] = []) {
            // Title and author fold apart, so initials never join across them.
            title = BookshelfIndex.searchWords(book.title).joined(separator: " ")
            sortTitle = Self.droppingArticle(title)
            titleWords = Self.words(title)
            let author = ([BookshelfIndex.searchWords(book.author).joined(separator: " ")] + aliases)
                .joined(separator: " ")
            authorWords = Self.words(author)
            // The header's own title, where the catalog shortened it, and
            // each hyphenated word written as one, as a reader may type it.
            let headerTitle = book.headerTitle.map { BookshelfIndex.searchWords($0) } ?? []
            let joined = BookshelfIndex.hyphenJoinedWords(book.title)
                + (book.headerTitle.map(BookshelfIndex.hyphenJoinedWords) ?? [])
                + BookshelfIndex.hyphenJoinedWords(book.author)
            haystack = ([title, author] + headerTitle + joined).joined(separator: " ")
        }

        /// Lower is better; see `search(_:)`. `tokens` is never empty.
        func rank(query q: String, tokens: [String]) -> Int {
            if title.hasPrefix(q) { return 0 }
            if sortTitle.hasPrefix(q) { return 1 }
            if titleWords.contains(where: { $0.hasPrefix(tokens[0]) }) { return 2 }
            if tokens.allSatisfy({ title.contains($0) }) { return 3 }
            if authorWords.contains(where: { $0.hasPrefix(tokens[0]) }) { return 4 }
            return 5
        }

        private static func droppingArticle(_ title: String) -> String {
            for article in ["the ", "a ", "an "] where title.hasPrefix(article) {
                return String(title.dropFirst(article.count))
            }
            return title
        }

        /// `text` is already search words, one space apart.
        private static func words(_ text: String) -> [Substring] {
            text.split(separator: " ")
        }
    }

    init(books: [BookshelfBook]) {
        self.books = books
        let aliases = Self.authorAliases(in: books)
        self.keys = books.map { SearchKey($0, aliases: aliases[Self.authorKey($0.author)] ?? []) }
        self.byID = Dictionary(books.enumerated().map { ($1.gutenbergID, $0) },
                               uniquingKeysWith: { first, _ in first })
        self.shelves = Self.shelve(books, rate: 1)
    }

    /// The shelves at `rate`, the app-wide speed the rows show their times
    /// at: a book's shelf follows the time its row shows, so "Under an
    /// hour" never heads a row of more than an hour (L019). At 1× it is
    /// `shelves`; any other speed shelves the ~450 books again, one pass.
    func shelves(rate: Double) -> [BookshelfShelf] {
        rate == 1 ? shelves : Self.shelve(books, rate: rate)
    }

    private static func shelve(_ books: [BookshelfBook], rate: Double) -> [BookshelfShelf] {
        // Dictionary(grouping:) keeps each group in sequence order.
        let grouped = Dictionary(grouping: books) {
            BookshelfSection.section(forMinutes: $0.listeningMinutes(rate: rate))
        }
        return BookshelfSection.allCases.compactMap { section in
            guard let books = grouped[section], !books.isEmpty else { return nil }
            return BookshelfShelf(section: section, books: books)
        }
    }

    func book(gutenbergID: Int) -> BookshelfBook? {
        byID[gutenbergID].map { books[$0] }
    }

    /// nil for a blank query (show the shelves); otherwise one flat list of
    /// the books whose title or author contains every query word, ranked:
    /// title prefix, title prefix after an article, a title word starting
    /// with the first query word, every word in the title, an author word
    /// starting with the first query word, then the rest. Ties keep catalog
    /// order.
    func search(_ query: String) -> [BookshelfBook]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A letter last is a word still being typed: "h. g. w" is on its way
        // to "wells", not a third initial.
        let typing = trimmed.last.map { $0.isLetter || $0.isNumber } ?? false
        let tokens = Self.searchWords(trimmed, lastWordUnfinished: typing)
        guard !tokens.isEmpty else { return nil }
        let q = tokens.joined(separator: " ")

        var hits: [(rank: Int, index: Int)] = []
        for (index, key) in keys.enumerated()
        where tokens.allSatisfy({ key.haystack.contains($0) }) {
            hits.append((key.rank(query: q, tokens: tokens), index))
        }
        hits.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return hits.map { books[$0.index] }
    }

    /// The names each display author goes by in the Gutenberg headers but
    /// not in the display name (a full name behind initials, a real name
    /// behind a pen name), gathered across all of that author's books, so a
    /// search by the name a reader knows finds every one of them, not only
    /// the books whose header spelled it out.
    static func authorAliases(in books: [BookshelfBook]) -> [String: [String]] {
        var aliases: [String: [String]] = [:]
        for book in books {
            guard let header = book.headerAuthor else { continue }
            let key = authorKey(book.author)
            let known = Set(searchWords(book.author))
            for word in searchWords(header) where !known.contains(word) {
                if aliases[key]?.contains(word) != true { aliases[key, default: []].append(word) }
            }
        }
        return aliases
    }

    /// One display author however it is spaced or cased.
    private static func authorKey(_ author: String) -> String {
        searchWords(author).joined(separator: " ")
    }

    /// Each hyphenated word of `text` written as one, in search words:
    /// "casebook" for "Case-Book". Search splits at a hyphen as at any
    /// punctuation, so "case book" already matches; this lets the one-word
    /// spelling match too.
    static func hyphenJoinedWords(_ text: String) -> [String] {
        let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]
        return fold(text).split(whereSeparator: \.isWhitespace).flatMap { chunk -> [String] in
            guard chunk.contains(where: hyphens.contains) else { return [] }
            return searchWords(String(chunk.filter { !hyphens.contains($0) }))
        }
    }

    /// Case-, diacritic- and width-insensitive, with curly apostrophes made
    /// straight, so "bronte" finds "Brontë" and "aesop's" finds "Aesop’s".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The words search compares, the same for a book and a query: folded,
    /// "&" read as "and", apostrophes dropped (so "gullivers" finds
    /// "Gulliver’s"), split at any other punctuation, and a run of
    /// single-letter initials joined, so "H.G.", "H. G." and "HG" are all
    /// "hg". With `lastWordUnfinished`, a single letter at the end stays its
    /// own word, since it may be the start of the next one.
    static func searchWords(_ text: String, lastWordUnfinished: Bool = false) -> [String] {
        let raw = fold(text)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .split { !($0.isLetter || $0.isNumber) }
        var words: [String] = []
        var initials = ""
        for (index, word) in raw.enumerated() {
            let isInitial = word.count == 1 && word.first?.isLetter == true
            let keptApart = lastWordUnfinished && index == raw.count - 1 && !initials.isEmpty
            if isInitial && !keptApart {
                initials += word
                continue
            }
            if !initials.isEmpty { words.append(initials) }
            initials = ""
            words.append(String(word))
        }
        if !initials.isEmpty { words.append(initials) }
        return words
    }
}

/// Loader for the bundled Classics Bookshelf (Resources/Bookshelf/catalog.json).
enum BookshelfCatalog {

    private static let log = Logger(subsystem: "com.davidxie.Aloud", category: "bookshelf")

    static func load(from bundle: Bundle = .main) -> [BookshelfBook] {
        guard let url = bundledURL(resource: "catalog", extension: "json", in: bundle),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return books(inCatalog: data)
    }

    /// The books of a catalog.json, one entry at a time: an entry that
    /// doesn't decode (a year of "c. 1600", an id in quotes) is skipped and
    /// logged, so one bad row never empties the shelf. Empty when the file
    /// itself doesn't read.
    static func books(inCatalog data: Data) -> [BookshelfBook] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            log.error("catalog.json doesn't decode; the Classics shelf is empty")
            return []
        }
        for (index, error) in catalog.skipped {
            log.error("catalog.json skips books[\(index)]: \(String(describing: error), privacy: .public)")
        }
        return catalog.books
    }

    /// Bundle URL of a book's text file, if present.
    static func bundledURL(for book: BookshelfBook, in bundle: Bundle = .main) -> URL? {
        let name = (book.file as NSString).deletingPathExtension
        let ext = (book.file as NSString).pathExtension
        return bundledURL(resource: name, extension: ext, in: bundle)
    }

    // Bookshelf ships as a folder reference (subdirectory preserved); fall back to flat.
    private static func bundledURL(resource: String, extension ext: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: resource, withExtension: ext, subdirectory: "Bookshelf")
            ?? bundle.url(forResource: resource, withExtension: ext)
    }

    private struct Catalog: Decodable {
        let books: [BookshelfBook]
        /// The entries left out, by position, and why.
        let skipped: [(index: Int, error: Error)]

        private enum CodingKeys: String, CodingKey { case books }

        init(from decoder: Decoder) throws {
            var entries = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .books)
            var books: [BookshelfBook] = []
            var skipped: [(index: Int, error: Error)] = []
            while !entries.isAtEnd {
                let index = entries.currentIndex
                do {
                    books.append(try entries.decode(BookshelfBook.self))
                } catch {
                    skipped.append((index, error))
                    // A failed decode leaves the cursor in place; step over the entry.
                    _ = try entries.decode(Skipped.self)
                }
            }
            self.books = books
            self.skipped = skipped
        }
    }

    /// Any one entry, read as nothing.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
