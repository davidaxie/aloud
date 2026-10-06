import XCTest
@testable import Aloud

/// "Where you stopped" in the Mac's Contents panel: the keyboard walks the
/// places, the toggle and the chapters as one flat list, entering on the
/// newest place; a book without chapters still opens its places.
@MainActor
final class MacContentsPlacesTests: XCTestCase {

    /// A stop recorded while the list is open: the cursor keeps its chapter
    /// (Return opens what the ring is on, not its neighbour).
    func testTheCursorKeepsItsRowWhenTheListChanges() {
        let before = MacContents.listLayout(placeCount: 1, expanded: false, chapterCount: 10, hasChapterList: true)
        let after = MacContents.listLayout(placeCount: 2, expanded: false, chapterCount: 10, hasChapterList: true)
        let onChapter4 = before.index(of: .chapter(4))
        XCTAssertEqual(after.row(at: MacContents.remap(onChapter4, from: before, to: after, in: .chapters)!),
                       .chapter(4))
        let many = MacContents.listLayout(placeCount: 6, expanded: false, chapterCount: 10, hasChapterList: true)
        XCTAssertEqual(many.row(at: MacContents.remap(onChapter4, from: before, to: many, in: .chapters)!),
                       .chapter(4), "past the toggle too")
        let onToggle = many.index(of: .showEarlier)
        let expanded = MacContents.listLayout(placeCount: 6, expanded: true, chapterCount: 10, hasChapterList: true)
        XCTAssertEqual(expanded.row(at: MacContents.remap(onToggle, from: many, to: expanded, in: .chapters)!),
                       .showEarlier)
        XCTAssertNil(MacContents.remap(nil, from: before, to: after, in: .chapters), "no cursor stays none")
        let empty = MacContents.listLayout(placeCount: 0, expanded: false, chapterCount: 0, hasChapterList: false)
        XCTAssertNil(MacContents.remap(0, from: before, to: empty, in: .chapters))
    }

    /// A stop recorded while the keyboard walks search results: the
    /// cursor is a result's index, which the places never move, so the ring
    /// stays on its result and Return opens it (never the next result, or
    /// one past the last).
    func testAResultsCursorStaysOnItsResultWhenAStopIsRecorded() {
        let before = MacContents.listLayout(placeCount: 2, expanded: false, chapterCount: 20, hasChapterList: true)
        let after = MacContents.listLayout(placeCount: 3, expanded: false, chapterCount: 20, hasChapterList: true)
        XCTAssertNotEqual(before, after, "the stop changes the chapter list under the results")
        XCTAssertEqual(MacContents.remap(5, from: before, to: after, in: .results), 5)

        let bare = MacContents.listLayout(placeCount: 2, expanded: false, chapterCount: 1, hasChapterList: false)
        let more = MacContents.listLayout(placeCount: 3, expanded: false, chapterCount: 1, hasChapterList: false)
        XCTAssertEqual(MacContents.remap(12, from: bare, to: more, in: .results), 12, "never clamped to the places")

        let none = MacContents.listLayout(placeCount: 0, expanded: false, chapterCount: 20, hasChapterList: true)
        let one = MacContents.listLayout(placeCount: 1, expanded: false, chapterCount: 20, hasChapterList: true)
        XCTAssertEqual(MacContents.remap(2, from: none, to: one, in: .results), 2, "never pushed past the last result")
        XCTAssertNil(MacContents.remap(nil, from: none, to: one, in: .searching))

        // The chapter list under the same change still keeps its chapter.
        let onChapter3 = before.index(of: .chapter(3))
        XCTAssertEqual(after.row(at: MacContents.remap(onChapter3, from: before, to: after, in: .chapters)!),
                       .chapter(3))
    }

    func testPlacesThenTheToggleThenChapters() {
        let layout = MacContents.listLayout(placeCount: 6, expanded: false, chapterCount: 10, hasChapterList: true)
        XCTAssertEqual(layout.placeCount, 3)
        XCTAssertTrue(layout.hasShowEarlier)
        XCTAssertEqual(layout.count, 3 + 1 + 10)
        XCTAssertEqual((0..<5).map { layout.row(at: $0) },
                       [.place(0), .place(1), .place(2), .showEarlier, .chapter(0)])
        XCTAssertEqual(layout.row(at: 13), .chapter(9))
        XCTAssertNil(layout.row(at: 14))
        XCTAssertNil(layout.row(at: -1))
        XCTAssertEqual(layout.index(of: .chapter(4)), 8)
        XCTAssertEqual(layout.index(of: .showEarlier), 3)
    }

    func testExpandedShowsEveryPlaceAboveTheToggle() {
        let layout = MacContents.listLayout(placeCount: 6, expanded: true, chapterCount: 10, hasChapterList: true)
        XCTAssertEqual(layout.placeCount, 6)
        XCTAssertEqual(layout.index(of: .showEarlier), 6)
        XCTAssertEqual(layout.row(at: 7), .chapter(0))
    }

    func testWithoutPlacesTheIndicesAreTheChapters() {
        let layout = MacContents.listLayout(placeCount: 0, expanded: false, chapterCount: 10, hasChapterList: true)
        XCTAssertEqual(layout.chapterOffset, 0)
        XCTAssertEqual(layout.row(at: 4), .chapter(4))
        XCTAssertEqual(layout.entry(currentChapter: 7), 7, "the keyboard enters on the current chapter")
        XCTAssertEqual(MacContents.listLayout(placeCount: 2, expanded: false, chapterCount: 10, hasChapterList: true)
                        .entry(currentChapter: 7), 0, "and on the newest place when there is one")
    }

    func testABookWithoutChaptersListsAllItsPlaces() {
        let layout = MacContents.listLayout(placeCount: 6, expanded: false, chapterCount: 1, hasChapterList: false)
        XCTAssertEqual(layout.placeCount, 6)
        XCTAssertFalse(layout.hasShowEarlier)
        XCTAssertEqual(layout.count, 6)
        XCTAssertEqual(MacContents.mode(hasChapterList: false, hasPlaces: true, query: "", searchedQuery: nil,
                                        resultCount: 0), .chapters)
        XCTAssertEqual(MacContents.mode(hasChapterList: false, query: "", searchedQuery: nil, resultCount: 0),
                       .searchOnly)
        XCTAssertEqual(MacContents.listLayout(placeCount: 0, expanded: false, chapterCount: 1, hasChapterList: false)
                        .entry(currentChapter: nil), nil)
    }
}
