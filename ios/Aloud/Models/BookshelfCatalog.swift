import Foundation

/// One public-domain classic bundled with the app (Bookshelf/*.txt).
struct BookshelfBook: Codable, Identifiable, Hashable {
    let gutenbergID: Int
    let title: String
    let author: String
    let year: Int?
    let file: String
    let words: Int

    var id: Int { gutenbergID }

    /// Whole-book listening estimate at 1.0× (165 wpm).
    var estimatedListeningMinutes: Int {
        max(1, Int((Double(words) / LibraryDocument.spokenWordsPerMinute).rounded()))
    }

    private enum CodingKeys: String, CodingKey {
        case gutenbergID = "gutenberg_id"
        case title, author, year, file, words
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
