import Foundation

/// One "Where you stopped" row, as Contents draws it and VoiceOver reads it,
/// on both apps: when ("Yesterday, 10:41 PM") and where ("CHAPTER THREE")
/// over the place's text, two lines of it.
struct PlaceRow: Equatable, Identifiable {
    /// The row's position, newest first (0 is the newest place shown).
    let index: Int
    let sentence: Int
    let when: String
    /// The chapter (with its Part or Book) or the page; nil in a book
    /// without a chapter list, whose place is only its sentence.
    let location: String?
    /// The whole sentence, typeset as the reader shows it: what VoiceOver
    /// reads and the Mac's cursor says.
    let text: String
    /// What the row draws: the sentence, then the ones after it, read on
    /// past its paragraph within its chapter, enough of the book to know
    /// the place by (`PlaceHistoryRows.snippet`). It always opens on the
    /// stop; the row's line limit cuts it.
    let snippet: String
    /// At the playhead: the current-chapter bar and `.isSelected`.
    let isCurrent: Bool

    /// `snippet` defaults to the sentence alone.
    init(index: Int, sentence: Int, when: String, location: String?, text: String,
         snippet: String? = nil, isCurrent: Bool) {
        self.index = index
        self.sentence = sentence
        self.when = when
        self.location = location
        self.text = text
        self.snippet = snippet ?? text
        self.isCurrent = isCurrent
    }

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
                            snippet: snippet(at: entry.sentence, in: content, navigation: navigation),
                            isCurrent: entry.sentence == playhead)
        }
    }

    /// About how much text a row draws: more than its four lines hold at
    /// the accessibility sizes' widths is never seen.
    static let snippetLength = 160

    /// The stop's sentence, then the sentences after it while the text is
    /// under `snippetLength` characters: first the rest of its paragraph,
    /// then on across paragraph breaks (joined with one space), so a short
    /// line of dialogue that ends its paragraph still gains the narration
    /// that follows it (R2-35). Nothing before the stop is added: the
    /// half-height row shows one line, and it opens on the stop. It stops
    /// at the chapter's edge and at the end of the book. Typeset as one
    /// run, so quote direction keeps its context.
    /// A stop that opens inside a quotation (a closing quote with no
    /// opening one before it) starts with "…", as a cut search result
    /// does; a quote mark is never added.
    static func snippet(at index: Int, in content: DocContent, navigation: ReaderNavigation) -> String {
        let sentences = content.sentences
        guard sentences.indices.contains(index) else { return "" }
        let stop = sentences[index]
        let chapter = navigation.chapterIndex(containing: index)
        var raw = stop.text
        var next = index + 1
        while raw.count < snippetLength, sentences.indices.contains(next),
              navigation.chapterIndex(containing: next) == chapter {
            raw += " " + sentences[next].text
            next += 1
        }
        let typeset = ReaderTypography.typeset(raw)
        return opensInsideQuote(ReaderTypography.typeset(stop.text)) ? "\u{2026}" + typeset : typeset
    }

    /// Whether `sentence` (typeset) closes a quotation it never opened.
    static func opensInsideQuote(_ sentence: String) -> Bool {
        guard let close = sentence.firstIndex(of: "\u{201D}") else { return false }
        return !sentence[..<close].contains("\u{201C}")
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
