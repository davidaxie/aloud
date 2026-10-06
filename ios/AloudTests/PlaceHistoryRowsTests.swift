import XCTest
@testable import Aloud

/// "Where you stopped" rows: when a place was left, read against a fixed
/// clock, calendar and locale; what the place is called; which row is at
/// the playhead; and what VoiceOver says.
@MainActor
final class PlaceHistoryRowsTests: XCTestCase {

    // MARK: - When

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let posix = Locale(identifier: "en_US_POSIX")

    /// Tuesday, October 6, 2026, noon UTC.
    private var now: Date { date(2026, 10, 6, 12, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// The formatter's narrow no-break space before AM/PM, read as a space.
    private func when(_ date: Date, locale: Locale? = nil) -> String {
        PlaceHistoryCopy.when(date, now: now, calendar: Self.utc, locale: locale ?? posix)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testTodayAndYesterdayReadAsAClock() {
        XCTAssertEqual(when(date(2026, 10, 6, 8, 23)), "Today, 8:23 AM")
        XCTAssertEqual(when(date(2026, 10, 6, 0, 0)), "Today, 12:00 AM")
        XCTAssertEqual(when(date(2026, 10, 5, 22, 41)), "Yesterday, 10:41 PM")
    }

    func testThisWeekReadsAsAWeekday() {
        XCTAssertEqual(when(date(2026, 10, 4, 19, 5)), "Sunday, 7:05 PM")
        XCTAssertEqual(when(date(2026, 9, 30, 19, 5)), "Wednesday, 7:05 PM", "six days back")
    }

    func testOlderReadsAsADate() {
        XCTAssertEqual(when(date(2026, 9, 29, 19, 5)), "Sep 29, 7:05 PM", "a week back")
        XCTAssertEqual(when(date(2026, 1, 2, 9, 0)), "Jan 2, 9:00 AM")
        XCTAssertEqual(when(date(2025, 9, 28, 19, 5)), "Sep 28, 2025", "last year: no clock")
    }

    /// The clock moved back: a place after "now" is a date, never "Today".
    func testAFutureDateReadsAsADate() {
        XCTAssertEqual(when(date(2026, 10, 6, 18, 0)), "Oct 6, 6:00 PM")
        XCTAssertEqual(when(date(2026, 10, 9, 18, 0)), "Oct 9, 6:00 PM")
    }

    func testTheClockFollowsTheLocale() {
        // A 24-hour clock in Britain (whether the hour is padded is the
        // system's call): no AM or PM.
        let morning = when(date(2026, 10, 6, 8, 23), locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(morning == "Today, 8:23" || morning == "Today, 08:23", morning)
        XCTAssertEqual(when(date(2026, 10, 5, 20, 23), locale: Locale(identifier: "en_GB")), "Yesterday, 20:23")
    }

    func testTheEarlierToggleCountsStops() {
        XCTAssertEqual(PlaceHistoryCopy.showEarlier(1), "Show 1 earlier stop")
        XCTAssertEqual(PlaceHistoryCopy.showEarlier(5), "Show 5 earlier stops")
        XCTAssertEqual(PlaceHistoryCopy.header, "Where you stopped")
    }

    // MARK: - Rows

    /// "BOOK ONE: 1805" alone on page 0 folds into CHAPTER I (page 1);
    /// CHAPTER II is page 2 (ScrubAccessibilityTests' book).
    private static func groupedContent() -> DocContent {
        let lines: [(text: String, page: Int)] = [
            ("BOOK ONE: 1805", 0),
            ("CHAPTER I", 1), ("Well, Prince, so Genoa and Lucca are now just family estates.", 1),
            ("CHAPTER II", 2), ("Anna Pavlovna had had a cough for some days.", 2),
        ]
        let sentences = lines.enumerated().map { index, line in
            Sentence(id: index, text: line.text, para: index, page: line.page)
        }
        let paragraphs = lines.enumerated().map { index, line in
            Paragraph(id: index, sentenceIDs: index..<(index + 1), page: line.page)
        }
        return DocContent(title: "Grouped", pageCount: 3, sentences: sentences,
                          paragraphs: paragraphs, contentHash: "places-rows")
    }

    private func entry(_ sentence: Int, _ stoppedAt: Date) -> PlaceHistoryEntry {
        PlaceHistoryEntry(sentence: sentence, stoppedAt: stoppedAt, excerpt: nil)
    }

    private func rows(_ entries: [PlaceHistoryEntry], content: DocContent, kind: DocKind,
                      playhead: Int) -> [PlaceRow] {
        PlaceHistoryRows.rows(entries, content: content, navigation: ReaderNavigation(content: content, kind: kind),
                              playhead: playhead, now: now, calendar: Self.utc, locale: posix)
            .map { row in
                PlaceRow(index: row.index, sentence: row.sentence,
                         when: row.when.replacingOccurrences(of: "\u{202F}", with: " "),
                         location: row.location, text: row.text, isCurrent: row.isCurrent)
            }
    }

    func testAChapterPlaceIsNamedWithItsSection() throws {
        let content = Self.groupedContent()
        let built = rows([entry(2, date(2026, 10, 6, 8, 23)), entry(4, date(2026, 10, 5, 22, 41))],
                         content: content, kind: .text, playhead: 2)
        XCTAssertEqual(built.count, 2)
        let newest = built[0]
        XCTAssertEqual(newest.location, "BOOK ONE: 1805 · CHAPTER I")
        XCTAssertEqual(newest.detail, "Today, 8:23 AM · BOOK ONE: 1805 · CHAPTER I")
        XCTAssertEqual(newest.text, "Well, Prince, so Genoa and Lucca are now just family estates.")
        XCTAssertTrue(newest.isCurrent)
        XCTAssertEqual(newest.identifier, "places.row.0")
        XCTAssertEqual(newest.accessibilityLabel,
                       "Today, 8:23 AM, BOOK ONE: 1805, CHAPTER I, "
                       + "Well, Prince, so Genoa and Lucca are now just family estates., current")

        let older = built[1]
        XCTAssertFalse(older.isCurrent, "current only at the exact playhead")
        XCTAssertTrue(try XCTUnwrap(older.location).hasSuffix("CHAPTER II"))
        XCTAssertFalse(older.accessibilityLabel.hasSuffix(", current"))
        XCTAssertFalse(older.accessibilityLabel.contains("·"), "VoiceOver never reads the middle dot")
    }

    /// A PDF place is its exact page, never the row's run of pages.
    func testAPDFPlaceIsItsPage() {
        let content = PlaybackTestRig.makeContent(hash: "pdf", count: 6, pages: [0, 0, 1, 1, 2, 2])
        let built = rows([entry(3, date(2026, 10, 6, 8, 23))], content: content, kind: .pdf, playhead: 0)
        XCTAssertEqual(built.map(\.location), ["Page 2"])
        XCTAssertEqual(built.first?.detail, "Today, 8:23 AM · Page 2")
        XCTAssertTrue(PlaceHistoryRows.listsPages(ReaderNavigation(content: content, kind: .pdf)))
    }

    /// A PDF with real chapters: the chapter that holds the sentence, then
    /// its page, once, even with two chapters starting on one page.
    func testAMappedPDFPlaceNamesItsChapterAndPageOnce() {
        var content = PlaybackTestRig.makeContent(hash: "mapped", count: 8, pages: [0, 0, 1, 1, 1, 2, 2, 2])
        content.chapterMap = ChapterMap(version: ChapterMap.currentVersion, source: .outline, entries: [
            ChapterMap.Entry(title: "Front matter", sentence: 0, section: nil),
            ChapterMap.Entry(title: "Short", sentence: 2, section: nil),
            ChapterMap.Entry(title: "Next", sentence: 4, section: nil),
            ChapterMap.Entry(title: "Last", sentence: 5, section: nil),
        ])
        let built = rows([entry(3, date(2026, 10, 6, 8, 23)), entry(7, date(2026, 10, 6, 7, 0))],
                         content: content, kind: .pdf, playhead: 0)
        XCTAssertEqual(built.map(\.location), ["Short · Page 2", "Last · Page 3"],
                       "the sentence's own chapter, though Next also starts on page 2")
        XCTAssertFalse(PlaceHistoryRows.listsPages(ReaderNavigation(content: content, kind: .pdf)))
    }

    /// Without a chapter list the sentence is the place: no location.
    func testAChapterlessPlaceHasNoLocation() {
        let content = PlaybackTestRig.makeContent(hash: "plain", count: 6)
        let built = rows([entry(3, date(2026, 10, 5, 22, 41))], content: content, kind: .text, playhead: 3)
        XCTAssertEqual(built.count, 1)
        XCTAssertNil(built[0].location)
        XCTAssertEqual(built[0].detail, "Yesterday, 10:41 PM")
        XCTAssertEqual(built[0].text, "Line3 word word.")
        XCTAssertEqual(built[0].accessibilityLabel, "Yesterday, 10:41 PM, Line3 word word., current")
    }

    /// Places outside the content are dropped, and the rows count on from 0.
    func testAPlaceOutsideTheContentIsDropped() {
        let content = PlaybackTestRig.makeContent(hash: "plain", count: 6)
        let built = rows([entry(5, now), entry(99, now), entry(-1, now), entry(1, now)],
                         content: content, kind: .text, playhead: 0)
        XCTAssertEqual(built.map(\.sentence), [5, 1])
        XCTAssertEqual(built.map(\.index), [0, 1])
        XCTAssertEqual(built.map(\.identifier), ["places.row.0", "places.row.1"])
    }
}
