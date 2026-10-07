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

    /// Return on "Show N earlier stops" (or "Show fewer"): the cursor goes
    /// onto the toggle in the list before the press, and the remap after
    /// the change carries it once, so the ring stays on the toggle, never
    /// on a chapter or the third stop, and the next Return toggles again
    /// (H022). A click on the toggle with the ring elsewhere lands it there.
    func testTheToggleKeepsTheCursorOnTheToggle() {
        for places in [4, 6, 8] {
            let collapsed = MacContents.listLayout(placeCount: places, expanded: false, chapterCount: 20,
                                                   hasChapterList: true)
            let expanded = MacContents.listLayout(placeCount: places, expanded: true, chapterCount: 20,
                                                  hasChapterList: true)
            let expanding = MacContents.cursorOnToggle(collapsed.index(of: .showEarlier), before: collapsed)
            XCTAssertEqual(expanded.row(at: MacContents.remap(expanding, from: collapsed, to: expanded,
                                                              in: .chapters)!),
                           .showEarlier, "\(places) stops, expanding")
            let collapsing = MacContents.cursorOnToggle(expanded.index(of: .showEarlier), before: expanded)
            XCTAssertEqual(collapsed.row(at: MacContents.remap(collapsing, from: expanded, to: collapsed,
                                                               in: .chapters)!),
                           .showEarlier, "\(places) stops, collapsing")
            let clicked = MacContents.cursorOnToggle(collapsed.index(of: .chapter(4)), before: collapsed)
            XCTAssertEqual(expanded.row(at: MacContents.remap(clicked, from: collapsed, to: expanded,
                                                              in: .chapters)!),
                           .showEarlier, "\(places) stops, clicked from a chapter")
            XCTAssertNil(MacContents.cursorOnToggle(nil, before: collapsed), "a click without a cursor sets none")
        }
    }

    /// A place picked while playing: the jump records the place just left
    /// on top, so the picked place moves down a row. The cursor follows it
    /// by its sentence, so the ring and the playhead bar share a row and
    /// Return replays the place picked (H023).
    func testAPlacesCursorFollowsItsPlaceWhenAStopLandsAboveIt() {
        func layout(_ sentences: [Int], expanded: Bool = false) -> MacContents.ListLayout {
            MacContents.listLayout(placeCount: sentences.count, expanded: expanded, chapterCount: 20,
                                   hasChapterList: true, placeSentences: sentences)
        }
        let three = layout([4000, 2500, 1200])
        let four = layout([4100, 4000, 2500, 1200])
        XCTAssertEqual(four.row(at: MacContents.remap(1, from: three, to: four, in: .chapters)!), .place(2))

        // Five places: three rows and the toggle either way, so only the
        // sentences tell the lists apart (and the panel remaps at all).
        let five = layout([4000, 2500, 1200, 800, 300])
        let six = layout([4100, 4000, 2500, 1200, 800, 300])
        XCTAssertEqual(five.placeCount, six.placeCount)
        XCTAssertNotEqual(five, six)
        XCTAssertEqual(six.row(at: MacContents.remap(1, from: five, to: six, in: .chapters)!), .place(2))
        XCTAssertEqual(six.row(at: MacContents.remap(2, from: five, to: six, in: .chapters)!), .showEarlier,
                       "pushed behind the toggle, the ring waits on it")
        let fiveOpen = layout([4000, 2500, 1200, 800, 300], expanded: true)
        let sixOpen = layout([4100, 4000, 2500, 1200, 800, 300], expanded: true)
        XCTAssertEqual(sixOpen.row(at: MacContents.remap(2, from: fiveOpen, to: sixOpen, in: .chapters)!), .place(3))

        // One sitting: the newest place is replaced, and every row stays.
        let resumed = layout([4010, 2500, 1200])
        XCTAssertEqual(MacContents.remap(0, from: three, to: resumed, in: .chapters), 0)
        XCTAssertEqual(MacContents.remap(1, from: three, to: resumed, in: .chapters), 1)
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
