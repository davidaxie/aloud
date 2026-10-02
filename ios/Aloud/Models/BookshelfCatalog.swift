import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case gutenbergID = "gutenberg_id"
        case title, author, year, file, words
        case headerTitle = "header_title"
        case headerAuthor = "header_author"
    }
}

// MARK: - Sections

/// The Bookshelf's three shelves, by whole-book listening length at 1×.
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

/// The catalog, shelved and searchable. Built once at launch: every folded
/// string search compares against is precomputed here, so a keystroke is one
/// pass of substring checks over ~450 books.
struct BookshelfIndex {

    let books: [BookshelfBook]
    /// Sections in enum order, books in catalog order, empty sections omitted.
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
        /// What every query token must appear in: title, then author.
        let haystack: String

        init(_ book: BookshelfBook) {
            title = BookshelfIndex.fold(book.title)
            sortTitle = Self.droppingArticle(title)
            titleWords = Self.words(title)
            let author = BookshelfIndex.fold(book.author)
            authorWords = Self.words(author)
            haystack = title + " " + author
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

        // Apostrophes stay inside a word, so "aesop's" is one word.
        private static func words(_ text: String) -> [Substring] {
            text.split { !($0.isLetter || $0.isNumber || $0 == "'") }
        }
    }

    init(books: [BookshelfBook]) {
        self.books = books
        self.keys = books.map(SearchKey.init)
        self.byID = Dictionary(books.enumerated().map { ($1.gutenbergID, $0) },
                               uniquingKeysWith: { first, _ in first })
        // Dictionary(grouping:) keeps each group in sequence order.
        let grouped = Dictionary(grouping: books) {
            BookshelfSection.section(forMinutes: $0.estimatedListeningMinutes)
        }
        self.shelves = BookshelfSection.allCases.compactMap { section in
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
        let q = Self.fold(trimmed)
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var hits: [(rank: Int, index: Int)] = []
        for (index, key) in keys.enumerated()
        where tokens.allSatisfy({ key.haystack.contains($0) }) {
            hits.append((key.rank(query: q, tokens: tokens), index))
        }
        hits.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return hits.map { books[$0.index] }
    }

    /// Case-, diacritic- and width-insensitive, with curly apostrophes made
    /// straight, so "bronte" finds "Brontë" and "aesop's" finds "Aesop’s".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}

/// Loader for the bundled Classics Bookshelf (Resources/Bookshelf/catalog.json).
enum BookshelfCatalog {

    static func load(from bundle: Bundle = .main) -> [BookshelfBook] {
        guard let url = bundledURL(resource: "catalog", extension: "json", in: bundle),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return [] }
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

    private struct Catalog: Codable {
        let books: [BookshelfBook]
    }
}
