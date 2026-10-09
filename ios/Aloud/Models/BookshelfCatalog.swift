import Combine
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
    /// The normalized title before the catalog shortened it for the shelf
    /// (no alternative title, no generic subtitle), present only when it
    /// did; libraries made before the shortening are renamed from it once
    /// (`DocumentStore.retitlingClassics`).
    var fullTitle: String? = nil
    /// The book's place at the head of the short shelf, 1 first; unranked
    /// books follow in catalog order, and the longer shelves ignore it
    /// (`BookshelfIndex.shelves(rate:)`).
    var rank: Int? = nil

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
        case fullTitle = "full_title"
        case rank
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

/// The catalog, shelved and searchable. The books, shelves and IDs are
/// built at launch (the featured classic needs them on the first frame);
/// the search keys, every string search compares against folded to search
/// words, are built off the main thread just after (`SearchKeyBox`), so a
/// keystroke is one pass of substring checks over ~450 books.
struct BookshelfIndex {

    let books: [BookshelfBook]
    /// Sections in enum order, the short shelf's ranked books first, then
    /// the rest in catalog order, empty sections omitted, at 1×; the screens
    /// shelve at the app-wide speed (`shelves(rate:)`).
    let shelves: [BookshelfShelf]

    private let searchKeys: SearchKeyBox
    /// The off-main build `init` starts; nil when it was asked not to.
    private let searchKeysWarmUp: Task<Void, Never>?
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
            // Each string is folded once, for its search words and its
            // hyphen-joined words alike. Title and author fold apart, so
            // initials never join across them.
            let foldedTitle = BookshelfIndex.fold(book.title)
            let foldedAuthor = BookshelfIndex.fold(book.author)
            let foldedHeader = book.headerTitle.map(BookshelfIndex.fold)
            title = BookshelfIndex.searchWords(folded: foldedTitle).joined(separator: " ")
            sortTitle = Self.droppingArticle(title)
            titleWords = Self.words(title)
            let author = ([BookshelfIndex.searchWords(folded: foldedAuthor).joined(separator: " ")] + aliases)
                .joined(separator: " ")
            authorWords = Self.words(author)
            // The header's own title, where the catalog shortened it, and
            // each hyphenated word written as one, as a reader may type it.
            let headerTitle = foldedHeader.map { BookshelfIndex.searchWords(folded: $0) } ?? []
            let joined = BookshelfIndex.hyphenJoinedWords(folded: foldedTitle)
                + (foldedHeader.map { BookshelfIndex.hyphenJoinedWords(folded: $0) } ?? [])
                + BookshelfIndex.hyphenJoinedWords(folded: foldedAuthor)
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

    /// The search keys of `books`, with each author's aliases
    /// (`authorAliases`): about 90% of building the index, and only Classics
    /// search reads them, so they are built off the main thread after
    /// launch (`prewarm`). Built once, under the lock: a search that comes
    /// first builds them itself, or waits out the build already running
    /// (lending it its priority), at worst on the first keystroke.
    private final class SearchKeyBox: @unchecked Sendable {
        private let books: [BookshelfBook]
        private let built = OSAllocatedUnfairLock<[SearchKey]?>(initialState: nil)

        init(books: [BookshelfBook]) {
            self.books = books
        }

        var keys: [SearchKey] {
            built.withLockUnchecked { built in
                if let built { return built }
                let aliases = BookshelfIndex.authorAliases(in: books)
                let keys = books.map { SearchKey($0, aliases: aliases[BookshelfIndex.authorKey($0.author)] ?? []) }
                built = keys
                return keys
            }
        }

        var isBuilt: Bool { built.withLockUnchecked { $0 != nil } }

        /// Builds the keys at utility priority, off the launch path.
        func prewarm() -> Task<Void, Never> {
            Task.detached(priority: .utility) { [self] in _ = self.keys }
        }
    }

    /// `prewarmingSearch: false` leaves the keys to the first search (a
    /// test's cold path); the app always prewarms.
    init(books: [BookshelfBook], prewarmingSearch: Bool = true) {
        self.books = books
        let searchKeys = SearchKeyBox(books: books)
        self.searchKeys = searchKeys
        self.searchKeysWarmUp = prewarmingSearch ? searchKeys.prewarm() : nil
        self.byID = Dictionary(books.enumerated().map { ($1.gutenbergID, $0) },
                               uniquingKeysWith: { first, _ in first })
        self.shelves = Self.shelve(books, rate: 1)
    }

    /// Whether the search keys are built yet.
    var hasSearchKeys: Bool { searchKeys.isBuilt }

    /// Returns once the off-main build `init` started has finished (at
    /// once when none was started).
    func searchKeysPrewarmed() async {
        await searchKeysWarmUp?.value
    }

    /// The shelves at `rate`, the app-wide speed the rows show their times
    /// at: a book's shelf follows the time its row shows, so "Under an
    /// hour" never heads a row of more than an hour (L019). At 1× it is
    /// `shelves`; any other speed shelves the ~450 books again, one pass.
    func shelves(rate: Double) -> [BookshelfShelf] {
        rate == 1 ? shelves : Self.shelve(books, rate: rate)
    }

    /// The short shelf opens with its ranked books, by rank (the
    /// recognisable classics the catalog puts first), then the rest in
    /// catalog order. The longer shelves keep catalog order, a ranked book
    /// a slow speed carries into them included.
    private static func shelve(_ books: [BookshelfBook], rate: Double) -> [BookshelfShelf] {
        let grouped = Dictionary(grouping: books.indices) {
            BookshelfSection.section(forMinutes: books[$0].listeningMinutes(rate: rate))
        }
        return BookshelfSection.allCases.compactMap { section in
            guard let indices = grouped[section], !indices.isEmpty else { return nil }
            let ranks = section == .underAnHour
            let ordered = indices.sorted { (a: Int, b: Int) -> Bool in
                let first: (rank: Int, index: Int) = ((ranks ? books[a].rank : nil) ?? Int.max, a)
                let second: (rank: Int, index: Int) = ((ranks ? books[b].rank : nil) ?? Int.max, b)
                return first < second
            }
            return BookshelfShelf(section: section, books: ordered.map { books[$0] })
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
        for (index, key) in searchKeys.keys.enumerated()
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
    fileprivate static func authorKey(_ author: String) -> String {
        searchWords(author).joined(separator: " ")
    }

    /// Each hyphenated word of `text` written as one, in search words:
    /// "casebook" for "Case-Book". Search splits at a hyphen as at any
    /// punctuation, so "case book" already matches; this lets the one-word
    /// spelling match too.
    static func hyphenJoinedWords(_ text: String) -> [String] {
        hyphenJoinedWords(folded: fold(text))
    }

    /// `hyphenJoinedWords` of a string `fold` already folded.
    fileprivate static func hyphenJoinedWords(folded: String) -> [String] {
        let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]
        return folded.split(whereSeparator: \.isWhitespace).flatMap { chunk -> [String] in
            guard chunk.contains(where: hyphens.contains) else { return [] }
            return searchWords(folded: String(chunk.filter { !hyphens.contains($0) }))
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
        searchWords(folded: fold(text), lastWordUnfinished: lastWordUnfinished)
    }

    /// `searchWords` of a string `fold` already folded (folding twice
    /// changes nothing, so the words are the same).
    fileprivate static func searchWords(folded: String, lastWordUnfinished: Bool = false) -> [String] {
        let raw = folded
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

// MARK: - The library's copies

/// What a Classics row knows of the book's library copy, the same on both
/// apps: whether the copy a row opens is finished, and whether the player
/// is voicing it.
extension BookshelfCatalog {

    /// The classics whose library copy is finished. The copy is the one a
    /// row opens: the first in store order, as `DocumentStore` finds it.
    static func finishedClassicIDs(in documents: [LibraryDocument]) -> Set<Int> {
        var seen: Set<Int> = []
        var finished: Set<Int> = []
        for document in documents {
            guard let id = document.gutenbergID, seen.insert(id).inserted else { continue }
            if document.isFinished { finished.insert(id) }
        }
        return finished
    }

    /// The classic the player is voicing: its loaded book's, while it plays
    /// or synthesizes ahead; nil when paused, stopped, or not a classic.
    static func playingClassicID(of document: LibraryDocument?, status: PlayerStatus) -> Int? {
        status == .playing || status == .buffering ? document?.gutenbergID : nil
    }

    /// `playingClassicID` as it changes, and only then: a Classics screen
    /// follows this one value, never the controller itself, which
    /// republishes many times a second and would redraw every row.
    @MainActor
    static func playingClassicIDs(of playback: PlaybackController) -> AnyPublisher<Int?, Never> {
        playback.$document.combineLatest(playback.$status)
            .map { playingClassicID(of: $0, status: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
