import Foundation

/// One "Where you stopped" row, as Contents draws it and VoiceOver reads it,
/// on both apps: when ("Yesterday, 10:41 PM") and where ("CHAPTER THREE")
/// over the sentence, two lines of it.
struct PlaceRow: Equatable, Identifiable {
    /// The row's position, newest first (0 is the newest place shown).
    let index: Int
    let sentence: Int
    let when: String
    /// The chapter (with its Part or Book) or the page; nil in a book
    /// without a chapter list, whose place is only its sentence.
    let location: String?
    /// The whole sentence, typeset as the reader shows it.
    let text: String
    /// At the playhead: the current-chapter bar and `.isSelected`.
    let isCurrent: Bool

    var id: Int { index }

    /// "Yesterday, 10:41 PM · CHAPTER THREE".
    var detail: String { [when, location].compactMap { $0 }.joined(separator: " · ") }

    /// "Yesterday, 10:41 PM, CHAPTER THREE, <sentence>, current".
    var accessibilityLabel: String {
        PlaybackCopy.spoken([detail, text].joined(separator: " · ")) + (isCurrent ? ", current" : "")
    }

    var identifier: String { "places.row.\(index)" }
}

/// The rows for a book's places: what each one is called and which is at
/// the playhead. Pure, so it is tested without a view (PlaceHistoryRowsTests).
enum PlaceHistoryRows {

    /// `entries` (newest first) as rows. An entry outside the content is
    /// dropped: places belong to one content hash, so this is only a guard.
    static func rows(_ entries: [PlaceHistoryEntry],
                     content: DocContent,
                     navigation: ReaderNavigation,
                     playhead: Int,
                     now: Date = Date(),
                     calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> [PlaceRow] {
        let shown = entries.filter { content.sentences.indices.contains($0.sentence) }
        return shown.enumerated().map { index, entry in
            let sentence = content.sentences[entry.sentence]
            return PlaceRow(index: index,
                            sentence: entry.sentence,
                            when: PlaceHistoryCopy.when(entry.stoppedAt, now: now, calendar: calendar, locale: locale),
                            location: location(of: sentence, in: navigation),
                            text: ReaderTypography.typeset(sentence.text),
                            isCurrent: entry.sentence == playhead)
        }
    }

    /// A place named the way a search result names its hit, through the
    /// reader's navigation:
    /// - text with a chapter list: the chapter with its section, "BOOK ONE:
    ///   1805 · CHAPTER I";
    /// - text without one: nil (the sentence says where);
    /// - a PDF: its exact page, "Page 41" (never a row's "Pages 40–42"),
    ///   after the chapter when its Contents lists titled chapters rather
    ///   than pages, "CHAPTER THREE · Page 41".
    static func location(of sentence: Sentence, in navigation: ReaderNavigation) -> String? {
        guard navigation.kind == .pdf else {
            guard navigation.hasChapterList,
                  let index = navigation.chapterIndex(containing: sentence.id) else { return nil }
            return navigation.qualifiedTitle(forPage: navigation.chapters[index].page)
        }
        guard navigation.hasChapterList, !listsPages(navigation) else {
            return navigation.labels.pageLabel(sentence.page)
        }
        // The chapter that holds the sentence, then its own page, once.
        return navigation.location(ofSentence: sentence.id, page: sentence.page)
    }

    /// Whether Contents lists pages ("Page 12", "Pages 12–14") rather than
    /// titled chapters: a PDF with no chapters found.
    static func listsPages(_ navigation: ReaderNavigation) -> Bool {
        navigation.kind == .pdf && navigation.rowKind == .pages
    }
}

/// "Where you stopped" copy, both apps.
enum PlaceHistoryCopy {

    static let header = "Where you stopped"
    /// Over the chapter list when stops show above an untitled first section.
    static let chaptersHeader = "Chapters"
    static let pagesHeader = "Pages"
    static let showFewer = "Show fewer"

    /// "Show 5 earlier stops", "Show 1 earlier stop".
    static func showEarlier(_ count: Int) -> String {
        count == 1 ? "Show 1 earlier stop" : "Show \(count) earlier stops"
    }

    /// When a place was left, as a clock and a day the listener knows:
    /// "Today, 8:23 AM", "Yesterday, 10:41 PM", "Tuesday, 7:05 PM" within a
    /// week, "Sep 28, 7:05 PM" this year, "Sep 28, 2025" before. A date
    /// after `now` (the clock moved back) reads as a date. The time follows
    /// the locale's 12- or 24-hour setting. This file is the one place a
    /// date is formatted for display.
    static func when(_ date: Date, now: Date,
                     calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? -1
        switch days {
        case 0 where date <= now: return "Today, \(time)"
        case 1: return "Yesterday, \(time)"
        case 2...6: return "\(date.formatted(base.weekday(.wide))), \(time)"
        default:
            let monthDay = base.month(.abbreviated).day()
            if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                return "\(date.formatted(monthDay)), \(time)"
            }
            return date.formatted(monthDay.year())
        }
    }
}
