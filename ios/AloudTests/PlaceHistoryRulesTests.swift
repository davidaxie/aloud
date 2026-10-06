import XCTest
@testable import Aloud

/// "Where you stopped": what one stop does to a book's places. Pure rules
/// (PlaceHistory.recording), so the 20 s floor and the 5 min sitting are
/// exercised without waiting.
final class PlaceHistoryRulesTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    /// A session that played from `start` (at `from` seconds) to `sentence`
    /// (at `to` seconds); listened time is the span unless given.
    private func stop(_ sentence: Int, start: Int, from: TimeInterval, to: TimeInterval,
                      moved: Bool = false, listened: TimeInterval? = nil) -> PlaceStop {
        PlaceStop(documentID: UUID(), contentHash: "hash", sentence: sentence, excerpt: "Line\(sentence)",
                  startSentence: start, startedAt: origin.addingTimeInterval(from),
                  stoppedAt: origin.addingTimeInterval(to), listenedSeconds: listened ?? to - from,
                  movedAway: moved)
    }

    private func record(_ stops: [PlaceStop], into places: [PlaceHistoryEntry] = []) -> [PlaceHistoryEntry] {
        stops.reduce(places) { PlaceHistory.recording($1, into: $0) }
    }

    private func sentences(_ places: [PlaceHistoryEntry]) -> [Int] { places.map(\.sentence) }

    func testAShortSessionLeavesNoStop() {
        XCTAssertEqual(record([stop(40, start: 10, from: 0, to: 19.9)]), [])
        let kept = record([stop(40, start: 10, from: 0, to: 20)])
        XCTAssertEqual(kept, [PlaceHistoryEntry(sentence: 40, stoppedAt: origin.addingTimeInterval(20),
                                                excerpt: "Line40")])
    }

    func testNewestFirstAndCappedAtEight() {
        let stops = (0..<10).map { stop(1_000 + $0 * 100, start: 950 + $0 * 100,
                                        from: Double($0) * 1_000, to: Double($0) * 1_000 + 600) }
        let places = record(stops)
        XCTAssertEqual(places.count, PlaceHistory.limit)
        XCTAssertEqual(sentences(places), [1_900, 1_800, 1_700, 1_600, 1_500, 1_400, 1_300, 1_200])
    }

    func testAStopNearAnEarlierOneReplacesIt() {
        let places = record([stop(100, start: 10, from: 0, to: 600),
                             stop(500, start: 400, from: 1_000, to: 1_600, moved: true),
                             stop(103, start: 50, from: 2_000, to: 2_600, moved: true)])
        XCTAssertEqual(sentences(places), [103, 500], "one entry per place, moved to the top")
        XCTAssertEqual(record([stop(104, start: 50, from: 3_000, to: 3_600, moved: true)], into: places).map(\.sentence),
                       [104, 500])
        XCTAssertEqual(record([stop(107, start: 50, from: 3_000, to: 3_600, moved: true)], into: places).map(\.sentence),
                       [107, 103, 500], "four sentences away is another place")
    }

    /// A quick pause and resume in place is one sitting: its last stop only.
    func testOneSittingKeepsItsLastStop() {
        let places = record([stop(500, start: 100, from: 0, to: 1_800),
                             stop(560, start: 499, from: 1_860, to: 2_100)])
        XCTAssertEqual(sentences(places), [560])
    }

    /// The night's sleep-timer stop survives the morning's rewind-resume.
    func testARestOverFiveMinutesStartsANewSitting() {
        let places = record([stop(500, start: 100, from: 0, to: 1_800),
                             stop(700, start: 498, from: 1_800 + 300, to: 2_400)])
        XCTAssertEqual(sentences(places), [700, 500])
    }

    func testAMoveAwayKeepsTheEarlierStop() {
        let places = record([stop(500, start: 100, from: 0, to: 1_800),
                             stop(4_000, start: 500, from: 1_830, to: 2_100, moved: true)])
        XCTAssertEqual(sentences(places), [4_000, 500])
    }

    func testResumingElsewhereKeepsTheEarlierStop() {
        let places = record([stop(500, start: 100, from: 0, to: 1_800),
                             stop(3_100, start: 3_000, from: 1_830, to: 2_100)])
        XCTAssertEqual(sentences(places), [3_100, 500])
    }

    /// The scenario places_rules_sim.py walked through, entry for entry.
    func testADayOfListening() {
        var places: [PlaceHistoryEntry] = []
        places = record([stop(500, start: 100, from: 0, to: 1_800)], into: places)
        places = record([stop(498, start: 498, from: day, to: day + 10)], into: places)
        XCTAssertEqual(sentences(places), [500], "a 10 s blip leaves nothing")
        places = record([stop(700, start: 498, from: day + 20, to: day + 900)], into: places)
        places = record([stop(760, start: 700, from: day + 960, to: day + 1_200)], into: places)
        XCTAssertEqual(sentences(places), [760, 500], "a 60 s pause folds into its sitting")
        places = record([stop(900, start: 3_000, from: day + 1_230, to: day + 1_500)], into: places)
        places = record([stop(4_000, start: 900, from: day + 1_530, to: day + 1_800, moved: true)], into: places)
        places = record([stop(4_002, start: 4_001, from: day + 1_830, to: day + 1_850)], into: places)
        XCTAssertEqual(sentences(places), [4_002, 900, 760, 500])
        XCTAssertEqual(places.first?.stoppedAt, origin.addingTimeInterval(day + 1_850))
    }

    func testVisibleRowsAndTheEarlierToggle() {
        XCTAssertEqual(PlaceHistory.visibleCount(total: 8, hasChapterList: true, expanded: false), 3)
        XCTAssertEqual(PlaceHistory.visibleCount(total: 2, hasChapterList: true, expanded: false), 2)
        XCTAssertEqual(PlaceHistory.visibleCount(total: 8, hasChapterList: true, expanded: true), 8)
        XCTAssertEqual(PlaceHistory.visibleCount(total: 8, hasChapterList: false, expanded: false), 8,
                       "a book without chapters lists them all")
        XCTAssertTrue(PlaceHistory.offersEarlier(total: 4, hasChapterList: true))
        XCTAssertFalse(PlaceHistory.offersEarlier(total: 3, hasChapterList: true))
        XCTAssertFalse(PlaceHistory.offersEarlier(total: 8, hasChapterList: false))
    }

    func testTheExcerptIsTheSentencesStart() {
        let long = String(repeating: "word ", count: 40)
        XCTAssertEqual(PlaceHistory.excerpt(of: long).count, PlaceHistory.excerptLength)
        XCTAssertEqual(PlaceHistory.excerpt(of: "Short."), "Short.")
    }

    /// iOS ended the app mid-speech: the marker's place, timed from its
    /// start; a marker from before sessions were recorded still qualifies.
    func testARecoveredSessionIsAStop() throws {
        let id = UUID()
        let started = origin
        let live = LiveSession(documentID: id, sentenceIndex: 42, wallClock: started.addingTimeInterval(95),
                               startedAt: started, startSentence: 30)
        let recovered = PlaceStop.recovered(from: live)
        XCTAssertEqual(recovered.documentID, id)
        XCTAssertNil(recovered.contentHash)
        XCTAssertEqual(recovered.sentence, 42)
        XCTAssertEqual(recovered.startSentence, 30)
        XCTAssertEqual(recovered.listenedSeconds, 95, accuracy: 0.001)
        XCTAssertEqual(PlaceHistory.recording(recovered, into: []).map(\.sentence), [42])

        let oldJSON = #"{"documentID":"\#(id.uuidString)","sentenceIndex":7,"wallClock":0}"#
        let old = try JSONDecoder().decode(LiveSession.self, from: Data(oldJSON.utf8))
        XCTAssertNil(old.startedAt)
        XCTAssertEqual(PlaceHistory.recording(.recovered(from: old), into: []).map(\.sentence), [7])
    }
}
