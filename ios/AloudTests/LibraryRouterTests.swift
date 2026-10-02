import XCTest
@testable import Aloud

/// R4: every way into a book ends in `LibraryRouter.open`. A reader on top is
/// replaced rather than stacked, and the screens below it are kept, so Back
/// from a book opened in the Bookshelf returns to the Bookshelf.
@MainActor
final class LibraryRouterTests: XCTestCase {

    private func document() -> LibraryDocument {
        LibraryDocument(id: UUID(), title: "T", fileName: "x", addedAt: Date(),
                        pageCount: 1, sentenceCount: 1, contentHash: "h", kind: .text)
    }

    func testOpenFromRootPushesTheReader() {
        let router = LibraryRouter()
        let book = document()
        router.open(book)
        XCTAssertEqual(router.path, [.reader(book.id)])
    }

    func testOpenFromTheBookshelfKeepsItUnderTheReader() {
        let router = LibraryRouter()
        router.showBookshelf()
        let book = document()
        router.open(book)
        XCTAssertEqual(router.path, [.bookshelf, .reader(book.id)])
    }

    func testOpenOverAnotherReaderReplacesIt() {
        let router = LibraryRouter()
        router.showBookshelf()
        let first = document(), second = document()
        router.open(first)
        router.open(second)
        XCTAssertEqual(router.path, [.bookshelf, .reader(second.id)])
    }

    func testOpeningTheSameBookTwiceAddsNothing() {
        let router = LibraryRouter()
        let book = document()
        router.open(book)
        router.open(book)
        XCTAssertEqual(router.path, [.reader(book.id)])
    }

    func testPopToRootEmptiesThePath() {
        let router = LibraryRouter()
        router.showBookshelf()
        router.open(document())
        router.popToRoot()
        XCTAssertEqual(router.path, [])
    }

    func testShowBookshelfAndSettingsNeverStackDuplicates() {
        let router = LibraryRouter()
        router.showBookshelf()
        router.showBookshelf()
        XCTAssertEqual(router.path, [.bookshelf])

        router.popToRoot()
        router.showSettings()
        router.showSettings()
        XCTAssertEqual(router.path, [.settings])
    }

    func testShowBookshelfFromAReaderAppends() {
        let router = LibraryRouter()
        let book = document()
        router.open(book)
        router.showBookshelf()
        XCTAssertEqual(router.path, [.reader(book.id), .bookshelf])
    }

    // MARK: - More classics from the reader (R24)

    /// The Bookshelf takes the reader's place: never two Bookshelves on the
    /// stack, and Back from it is the Library.
    func testShowBookshelfFromReaderReplacesTheReader() {
        let book = document()
        let cases: [(start: [LibraryRouter.Route], end: [LibraryRouter.Route])] = [
            ([.reader(book.id)], [.bookshelf]),
            ([.bookshelf, .reader(book.id)], [.bookshelf]),
            ([], [.bookshelf]),
            ([.bookshelf], [.bookshelf]),
        ]
        for (start, end) in cases {
            let router = LibraryRouter()
            router.path = start
            let generation = router.navigationGeneration
            router.showBookshelfFromReader()
            XCTAssertEqual(router.path, end, "from \(start)")
            XCTAssertEqual(router.navigationGeneration, generation + (start == end ? 0 : 1),
                           "one path assignment per change, from \(start)")
        }
    }

    // MARK: - Navigation generation (the importer's open rule)

    func testGenerationCountsOnlyRealPathChanges() {
        let router = LibraryRouter()
        let start = router.navigationGeneration

        router.popToRoot()                 // already at the root
        router.path = []
        XCTAssertEqual(router.navigationGeneration, start, "no change, no move")

        router.showBookshelf()
        XCTAssertEqual(router.navigationGeneration, start + 1)
        router.showBookshelf()             // a no-op
        XCTAssertEqual(router.navigationGeneration, start + 1)

        let book = document()
        router.open(book)
        router.open(book)                  // the same book: a no-op
        XCTAssertEqual(router.navigationGeneration, start + 2)

        router.open(document())            // swaps the reader
        router.path.removeLast()           // the NavigationStack's own Back
        XCTAssertEqual(router.navigationGeneration, start + 4)
    }

    /// Opening a root modal covers the screen, so it counts as moving away;
    /// closing one returns the user where they were, so it never does.
    func testOpeningARootModalCountsButClosingDoesNot() {
        let router = LibraryRouter()
        let start = router.navigationGeneration

        router.rootPresentation = .filePicker
        XCTAssertEqual(router.navigationGeneration, start + 1)
        router.rootPresentation = .filePicker
        XCTAssertEqual(router.navigationGeneration, start + 1)
        router.rootPresentation = nil
        XCTAssertEqual(router.navigationGeneration, start + 1)
    }

    func testDismissRootPresentationClosesOnlyTheNamedOne() {
        let router = LibraryRouter()
        router.rootPresentation = .rename
        router.dismissRootPresentation(.filePicker)
        XCTAssertEqual(router.rootPresentation, .rename, "a stale close is a no-op")
        router.dismissRootPresentation(.rename)
        XCTAssertNil(router.rootPresentation)
    }

    /// Open-in lands on the bare Library root: stack popped, modal closed.
    func testClearForOpenInPopsAndClosesTheRootModal() {
        let router = LibraryRouter()
        router.rootPresentation = .deleteConfirmation
        router.showSettings()
        router.clearForOpenIn()
        XCTAssertEqual(router.path, [])
        XCTAssertNil(router.rootPresentation)
    }
}
