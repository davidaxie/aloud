import Foundation

/// The one rule for naming a place in a document.
///
/// Page indices may arrive 0- or 1-based — a content cache written by an older
/// extractor is reused without re-extraction — so every surface normalizes
/// through `DocContent.pageOffset` and displays pages starting at 1. Text
/// books read as their chapter title; a PDF with a chapter map reads as its
/// chapters' titles on the pages they start on, and every other PDF page as
/// "Page 12". Contents (its chapter list and its search), the player bar's
/// chapter line and the reader's page marks all label through this, so no
/// surface can say "Page 0" while another says "PAGE 1".
struct PageLabels {

    private let offset: Int
    private let kind: DocKind
    private let titleByPage: [Int: String]
    /// PDFs only: the last page each row covers. A page whose text is entirely
    /// the continuation of the previous page's paragraph produces no block of
    /// its own (`PDFTextExtractor.appendPageParagraphs` keeps the previous
    /// block's number), and neither does a blank or image-only page — so the
    /// rows are page RANGES, and a drawer that printed them as "Page 1, Page 2,
    /// Page 5" would read as if pages 3 and 4 had gone missing.
    private let spanEndByPage: [Int: Int]

    /// `chapterTitles`: a PDF whose rows are real chapters (its chapter map)
    /// names their start pages by title. Text books always do.
    init(kind: DocKind, pageOffset: Int, pageCount: Int, chapters: [DerivedChapter],
         chapterTitles: Bool = false) {
        self.kind = kind
        self.offset = pageOffset
        // Page-range PDFs never consult chapter titles; skip the dictionary.
        self.titleByPage = kind == .pdf && !chapterTitles
            ? [:]
            : Dictionary(chapters.map { ($0.page, $0.title) },
                         uniquingKeysWith: { first, _ in first })
        self.spanEndByPage = kind == .pdf
            ? Self.spanEnds(chapters: chapters, pageOffset: pageOffset, pageCount: pageCount)
            : [:]
    }

    init(content: DocContent, kind: DocKind, chapters: [DerivedChapter], chapterTitles: Bool = false) {
        self.init(kind: kind,
                  pageOffset: content.pageOffset,
                  pageCount: content.pageCount,
                  chapters: chapters,
                  chapterTitles: chapterTitles)
    }

    /// Each row runs up to the page before the next row starts; the last runs
    /// to the end of the document. Clamped so a row can never end before it
    /// begins, whatever `pageCount` claims.
    private static func spanEnds(chapters: [DerivedChapter],
                                 pageOffset: Int,
                                 pageCount: Int) -> [Int: Int] {
        let pages = chapters.map(\.page)
        guard let last = pages.last else { return [:] }
        // `pageCount` is a count; the raw index of the final page depends on
        // whether this content cache numbers pages from 0 (offset 1) or 1.
        let lastRawPage = max(pageCount - pageOffset, last)
        var ends: [Int: Int] = [:]
        for (index, page) in pages.enumerated() {
            let next = index + 1 < pages.count ? pages[index + 1] - 1 : lastRawPage
            ends[page] = max(next, page)
        }
        return ends
    }

    /// The user-facing number for a stored page index.
    func displayPage(_ page: Int) -> Int { page + offset }

    /// "Page 12" — the normalized page number, never the raw index.
    func pageLabel(_ page: Int) -> String { "Page \(displayPage(page))" }

    /// "Pages 12–14" when the row stands for more than one page, else
    /// "Page 12". Only PDFs have spanning rows.
    func pageRangeLabel(_ page: Int) -> String {
        guard let end = spanEndByPage[page], end > page else { return pageLabel(page) }
        return "Pages \(displayPage(page))\u{2013}\(displayPage(end))"
    }

    /// What a page is called to the reader: its chapter title for text books
    /// and for the start pages of a PDF's mapped chapters, else its page
    /// range (falling back to the page label when a page starts no row).
    func contextTitle(forPage page: Int) -> String {
        titleByPage[page] ?? pageRangeLabel(page)
    }
}

/// One Contents group (R17): the chapters under a Part, Book, Act or Epilogue
/// heading (a PDF's from its chapter map), or an untitled run outside one. A
/// book with no such headings, a page-range PDF and chapterless text are one
/// untitled section.
/// `chapterRange` indexes `ReaderNavigation.chapters`.
struct ContentsSection: Identifiable, Equatable {
    let title: String?
    let chapterRange: Range<Int>
    var id: Int { chapterRange.lowerBound }
}

/// Chapter list, Contents sections, labels and word sums derived once per
/// loaded document.
///
/// `DocContent.navigationIndex()` is an O(total-words) pass, so it must not
/// run inside a view initializer: SwiftUI re-invokes a presented sheet's
/// content closure on every parent body evaluation, which during playback is
/// every word-highlight tick. The reader derives this once when the document
/// loads and hands it to Contents (chapter list and Contents search); the
/// player bar's chapter line and scrub read from here, in O(log n) per tick.
///
/// Text books fold heading-only Part/Book/Act/Epilogue "container" chapters
/// into the chapter after them, so "4 of 61", the scrub span, chapter steps
/// and End of chapter all count real chapters, and Contents shows the
/// containers as section headers instead of rows that hold one line.
///
/// A PDF with a usable `ChapterMap` gets the same treatment from the map:
/// one chapter per entry, its Parts as sections, titles in the labels. Any
/// other PDF lists page ranges: its page runs as they are when there are at
/// most `maxPageRows`, else runs grouped into rows of about equal listening
/// time.
struct ReaderNavigation {

    /// What a row is: a chapter (text, and PDFs with a chapter map) or a
    /// page range (every other PDF).
    enum RowKind: Equatable {
        case chapters, pages
    }

    /// The most page-range rows Contents lists before grouping them.
    static let maxPageRows = 25
    /// Grouped page ranges: at least this many rows…
    static let minPageGroups = 15
    /// …of about this many minutes each at 1×, up to `maxPageRows`.
    static let minutesPerPageGroup = 20.0

    /// Reading order. For text, a folded chapter starts at its first
    /// container heading and keeps the leaf's page and title.
    let chapters: [DerivedChapter]
    /// Reading order; never empty unless `chapters` is.
    let sections: [ContentsSection]
    /// Built from the raw (unfolded) chapters, so a container's page still
    /// reads as its own heading.
    let labels: PageLabels
    let kind: DocKind
    let rowKind: RowKind
    private let wordsBefore: [Int]
    /// Each row's title, by index: entry titles for mapped chapters, which
    /// two chapters starting on one page can't share through `labels`.
    private let rowTitles: [String]
    /// Every page inside a titled section, containers included.
    private let sectionTitleByPage: [Int: String]
    private let containerPages: Set<Int>
    /// A page-range PDF's single pages, when Contents groups them into rows:
    /// Next Page still moves one page. Empty otherwise.
    private let pageRuns: [DerivedChapter]
    /// Labels over `pageRuns`, when Contents groups them: a search hit names
    /// its own run ("Page 6", "Pages 6–7"), never its group's "Pages 5–8".
    private let runLabels: PageLabels?

    init(content: DocContent, kind: DocKind) {
        // One pass for chapters and word sums: this runs at reader open, inside
        // the R13 open-time budget. Folding is one more pass over the chapters.
        let index = content.navigationIndex()
        self.kind = kind
        self.wordsBefore = index.wordsBefore
        if kind == .pdf, let entries = Self.usableEntries(of: content) {
            let rows = Self.pdfChapterRows(entries, content: content, wordsBefore: index.wordsBefore)
            self.chapters = rows.chapters
            self.sections = rows.sections
            self.labels = PageLabels(content: content, kind: kind, chapters: rows.chapters, chapterTitles: true)
            self.rowKind = .chapters
            self.rowTitles = rows.chapters.map(\.title)
            self.sectionTitleByPage = [:]
            self.containerPages = []
            self.pageRuns = []
            self.runLabels = nil
            return
        }
        let raw = kind == .pdf ? Self.pageRows(index.chapters) : index.chapters
        let runs = kind == .pdf && raw.count < index.chapters.count ? index.chapters : []
        self.pageRuns = runs
        self.runLabels = runs.isEmpty ? nil : PageLabels(content: content, kind: kind, chapters: runs)
        let grouping = Self.grouping(raw, kind: kind, sentences: content.sentences)
        let labels = PageLabels(content: content, kind: kind, chapters: raw)
        self.chapters = grouping.chapters
        self.sections = grouping.sections
        self.labels = labels
        self.rowKind = kind == .pdf ? .pages : .chapters
        self.rowTitles = grouping.chapters.map { labels.contextTitle(forPage: $0.page) }
        self.sectionTitleByPage = grouping.sectionTitleByPage
        self.containerPages = grouping.containerPages
    }

    /// A list worth opening: a book of one chapter shows Contents search only.
    var hasChapterList: Bool { chapters.count >= 2 }

    /// Rows that are real chapters, at least two: "4 of 61", a chapter-wide
    /// scrub and End of chapter. Text with chapters, and mapped PDFs.
    var isChaptered: Bool { rowKind == .chapters && hasChapterList }

    /// Contents draws section headers.
    var isGrouped: Bool { sections.contains { $0.title != nil } }

    /// Row `index` as Contents names it: the chapter's title, or the page
    /// range ("Pages 21–37") of a page-range PDF.
    func title(ofChapter index: Int) -> String {
        rowTitles.indices.contains(index) ? rowTitles[index] : ""
    }

    /// Row `index`'s accessibility identifier, "chapters.row.<page>", with
    /// ".<k>" for the k-th row (k ≥ 2) starting on the same page.
    func rowIdentifier(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "chapters.row" }
        let page = chapters[index].page
        var k = 1
        var earlier = index - 1
        while earlier >= 0, chapters[earlier].page == page {
            k += 1
            earlier -= 1
        }
        let base = "chapters.row.\(labels.displayPage(page))"
        return k == 1 ? base : "\(base).\(k)"
    }

    /// Where a search hit is: "Tiny Speck · Page 63" in a mapped PDF (the
    /// sentence picks the chapter, so two on one page stay apart); in a
    /// page-range PDF whose runs Contents groups, the hit's own run, as the
    /// ungrouped rows would name it (a group's "Pages 5–8" would claim four
    /// pages for a hit on page 5, and only for one at a group's start);
    /// else `qualifiedTitle(forPage:)`.
    func location(ofSentence sentence: Int, page: Int) -> String {
        if let runLabels { return runLabels.pageRangeLabel(page) }
        guard kind == .pdf, rowKind == .chapters, let index = chapterIndex(containing: sentence) else {
            return qualifiedTitle(forPage: page)
        }
        return "\(rowTitles[index]) · \(labels.pageLabel(page))"
    }

    /// A search result's footnote: `location(ofSentence:page:)`, or nil in
    /// text without a chapter list. Its one chapter is titled by the book's
    /// first sentence, which would sit under every hit alike and read like a
    /// chapter name; the hit's own sentence says where, as in "Where you
    /// stopped" (`PlaceHistoryRows.location`).
    func searchLocation(ofSentence sentence: Int, page: Int) -> String? {
        guard kind == .pdf || hasChapterList else { return nil }
        return location(ofSentence: sentence, page: page)
    }

    private var sentenceCount: Int { wordsBefore.count - 1 }

    /// The chapter holding `sentence`, clamped into the document. nil only
    /// when there are no chapters.
    func chapterIndex(containing sentence: Int) -> Int? {
        guard let last = chapters.last else { return nil }
        let target = min(max(sentence, 0), max(last.lastSentence, 0))
        // The last chapter starting at or before the target.
        var low = 0
        var high = chapters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chapters[mid].startSentence <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Words in sentences `from...through`, both clamped into the document;
    /// 0 when the span is empty.
    func wordsRemaining(from sentence: Int, through lastSentence: Int) -> Int {
        guard sentenceCount > 0 else { return 0 }
        let first = min(max(sentence, 0), sentenceCount - 1)
        let last = min(max(lastSentence, 0), sentenceCount - 1)
        guard last >= first else { return 0 }
        return wordsBefore[last + 1] - wordsBefore[first]
    }

    /// The chapter line's position: where the listener is and how long is
    /// left at `rate`, counted from the current sentence to the end of its
    /// chapter (chaptered text and mapped PDFs), or to the end of the
    /// document (page-range PDFs, and text with fewer than two chapters).
    /// `isFinished` replaces the time with "Finished".
    func positionLine(at sentence: Int,
                      rate: Double,
                      documentTitle: String,
                      isFinished: Bool = false) -> ReaderPositionLine {
        guard sentenceCount > 0, let index = chapterIndex(containing: sentence) else {
            return ReaderPositionLine(kind: .book, title: documentTitle,
                                      minutesLeft: isFinished ? nil : 0)
        }
        let current = min(max(sentence, 0), sentenceCount - 1)
        let chapter = chapters[index]
        let wordsPerMinute = LibraryDocument.spokenWordsPerMinute * rate
        func minutesLeft(through last: Int) -> Int? {
            guard !isFinished else { return nil }
            return ListeningEstimate.minutes(words: wordsRemaining(from: current, through: last),
                                             wordsPerMinute: wordsPerMinute)
        }

        if isChaptered {
            return ReaderPositionLine(kind: .chapter(number: index + 1, count: chapters.count),
                                      title: title(ofChapter: index),
                                      minutesLeft: minutesLeft(through: chapter.lastSentence))
        }
        switch kind {
        case .pdf:
            return ReaderPositionLine(kind: .pages,
                                      title: title(ofChapter: index),
                                      minutesLeft: minutesLeft(through: sentenceCount - 1))
        case .text:
            return ReaderPositionLine(kind: .book, title: documentTitle,
                                      minutesLeft: minutesLeft(through: sentenceCount - 1))
        }
    }

    /// A Contents row or search hit named with its section: "BOOK ONE: 1805 ·
    /// CHAPTER I" for a chapter page, "BOOK ONE: 1805" for the container's own
    /// page. Ungrouped pages read as `labels.contextTitle(forPage:)`; a mapped
    /// PDF's as "Tiny Speck · Page 63", the chapter holding the page.
    func qualifiedTitle(forPage page: Int) -> String {
        if kind == .pdf, rowKind == .chapters, let index = lastChapter(startingAtOrBefore: page) {
            return "\(rowTitles[index]) · \(labels.pageLabel(page))"
        }
        guard let section = sectionTitleByPage[page] else { return labels.contextTitle(forPage: page) }
        return containerPages.contains(page) ? section : "\(section) · \(labels.contextTitle(forPage: page))"
    }

    // MARK: - Scrub (R12c, R17)

    /// What the scrub's track spans: the chapter holding `sentence` in
    /// chaptered text and mapped PDFs, else the whole document. 0...0 when
    /// empty.
    func scrubSpan(at sentence: Int) -> ClosedRange<Int> {
        guard sentenceCount > 0 else { return 0...0 }
        if isChaptered, let index = chapterIndex(containing: sentence) {
            let chapter = chapters[index]
            return chapter.startSentence...max(chapter.startSentence, min(chapter.lastSentence, sentenceCount - 1))
        }
        return 0...(sentenceCount - 1)
    }

    /// Where `sentence` starts along `span`, 0...1, by words, so a long
    /// sentence takes up as much track as it takes time. A span without
    /// words falls back to sentence counts.
    func scrubFraction(of sentence: Int, in span: ClosedRange<Int>) -> Double {
        guard let span = clamped(span) else { return 0 }
        let current = min(max(sentence, span.lowerBound), span.upperBound)
        let base = wordsBefore[span.lowerBound]
        let total = wordsBefore[span.upperBound + 1] - base
        guard total > 0 else { return Double(current - span.lowerBound) / Double(span.count) }
        return Double(wordsBefore[current] - base) / Double(total)
    }

    /// The scrub's fill for the playhead: where `sentence` starts, or the
    /// whole track once the book is finished, when its last sentence has
    /// been heard, not just begun.
    func scrubFill(of sentence: Int, in span: ClosedRange<Int>, isFinished: Bool) -> Double {
        isFinished ? 1 : scrubFraction(of: sentence, in: span)
    }

    /// The sentence whose start is nearest `fraction` of the way through
    /// `span` by words (ties go to the earlier one), clamped into the span.
    /// The inverse of `scrubFraction(of:in:)`.
    func sentence(atFraction fraction: Double, in span: ClosedRange<Int>) -> Int {
        guard let span = clamped(span) else { return 0 }
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let base = wordsBefore[span.lowerBound]
        let total = wordsBefore[span.upperBound + 1] - base
        guard total > 0 else {
            return span.lowerBound + min(Int((fraction * Double(span.count)).rounded()), span.count - 1)
        }
        let goal = Double(base) + fraction * Double(total)
        // The first start at or past the goal, then whichever neighbour is nearer.
        var low = span.lowerBound
        var high = span.upperBound
        while low < high {
            let mid = (low + high) / 2
            if Double(wordsBefore[mid]) < goal { low = mid + 1 } else { high = mid }
        }
        if low > span.lowerBound,
           goal - Double(wordsBefore[low - 1]) <= abs(Double(wordsBefore[low]) - goal) {
            return low - 1
        }
        return low
    }

    /// How far into `span` `sentence` starts, at the shared 165 wpm × `rate`:
    /// the time the scrub preview shows.
    func secondsIntoSpan(of sentence: Int, in span: ClosedRange<Int>, rate: Double) -> TimeInterval {
        guard let span = clamped(span), rate > 0 else { return 0 }
        let current = min(max(sentence, span.lowerBound), span.upperBound)
        let words = wordsBefore[current] - wordsBefore[span.lowerBound]
        return Double(words) / (LibraryDocument.spokenWordsPerMinute * rate) * 60
    }

    /// One VoiceOver adjust of the scrub: by chapter (text, mapped PDFs) or
    /// page row (other PDFs) when there are at least two, else ±1 minute. Backward goes to the
    /// current row's start when the playhead is past it. nil when there is
    /// nowhere to go; never `sentence` itself.
    func adjustmentTarget(from sentence: Int, forward: Bool, rate: Double) -> Int? {
        guard sentenceCount > 0 else { return nil }
        let current = min(max(sentence, 0), sentenceCount - 1)
        // Text chapters and PDF page rows are both `chapters`.
        if hasChapterList, let index = chapterIndex(containing: current) {
            if forward {
                return index + 1 < chapters.count ? chapters[index + 1].startSentence : nil
            }
            let start = chapters[index].startSentence
            if current > start { return start }
            return index > 0 ? chapters[index - 1].startSentence : nil
        }
        let target = PlaybackController.skipTarget(
            from: current, seconds: forward ? 60 : -60, sentenceCount: sentenceCount,
            wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate,
            words: { wordsBefore[$0 + 1] - wordsBefore[$0] })
        return target == current ? nil : target
    }

    /// Next or Previous Chapter (Page, in a PDF that lists pages): the next
    /// or previous step's start, or this step's start when the playhead is
    /// past it. A step is a chapter, or one page where Contents groups pages
    /// into rows. Without steps, as `adjustmentTarget`.
    func stepTarget(from sentence: Int, forward: Bool, rate: Double) -> Int? {
        guard !pageRuns.isEmpty, sentenceCount > 0 else {
            return adjustmentTarget(from: sentence, forward: forward, rate: rate)
        }
        let current = min(max(sentence, 0), sentenceCount - 1)
        guard let index = Self.run(containing: current, in: pageRuns) else { return nil }
        if forward { return index + 1 < pageRuns.count ? pageRuns[index + 1].startSentence : nil }
        let start = pageRuns[index].startSentence
        if current > start { return start }
        return index > 0 ? pageRuns[index - 1].startSentence : nil
    }

    /// What the Chapters (Pages) rotor steps through: the Contents rows, or
    /// the single pages where Contents groups a page-range PDF's pages into
    /// rows, so the rotor named Pages moves one page, as Next Page does
    /// (`stepTarget`), never a whole "Pages 13–24" row (J019).
    var rotorSteps: [DerivedChapter] { pageRuns.isEmpty ? chapters : pageRuns }

    /// The name of the rotor step holding `sentence`: its Contents row's
    /// title, or its own page ("Page 13") where rows group pages, as a
    /// search hit names it. nil only when there are no rows.
    func rotorStepTitle(containing sentence: Int) -> String? {
        if let runLabels, let index = Self.run(containing: sentence, in: pageRuns) {
            return runLabels.pageRangeLabel(pageRuns[index].page)
        }
        return chapterIndex(containing: sentence).map { title(ofChapter: $0) }
    }

    /// The first sentence of the step holding `sentence` (`stepTarget`).
    func stepStart(containing sentence: Int) -> Int? {
        if !pageRuns.isEmpty {
            return Self.run(containing: sentence, in: pageRuns).map { pageRuns[$0].startSentence }
        }
        return chapterIndex(containing: sentence).map { chapters[$0].startSentence }
    }

    /// The last of `runs` starting at or before `sentence` (binary search).
    private static func run(containing sentence: Int, in runs: [DerivedChapter]) -> Int? {
        guard !runs.isEmpty else { return nil }
        var low = 0, high = runs.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if runs[mid].startSentence <= sentence { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// `span` clamped into the document; nil when the document is empty.
    private func clamped(_ span: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard sentenceCount > 0 else { return nil }
        let lower = min(max(span.lowerBound, 0), sentenceCount - 1)
        let upper = min(max(span.upperBound, lower), sentenceCount - 1)
        return lower...upper
    }

    // MARK: - PDF rows

    /// The map's entries when they make a list: a PDF whose map found
    /// chapters and still holds two once sanitized against this text.
    private static func usableEntries(of content: DocContent) -> [ChapterMap.Entry]? {
        guard let map = content.chapterMap, map.source != ChapterMap.Source.none else { return nil }
        let entries = map.sanitizedEntries(sentenceCount: content.sentences.count)
        return entries.count >= 2 ? entries : nil
    }

    /// One chapter per entry, running to the next entry's start; sections
    /// are the runs of entries sharing a `section`.
    private static func pdfChapterRows(_ entries: [ChapterMap.Entry],
                                       content: DocContent,
                                       wordsBefore: [Int]) -> (chapters: [DerivedChapter], sections: [ContentsSection]) {
        let sentences = content.sentences
        var chapters: [DerivedChapter] = []
        chapters.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let start = entry.sentence
            let end = index + 1 < entries.count ? entries[index + 1].sentence : sentences.count
            chapters.append(DerivedChapter(page: sentences[start].page,
                                           title: entry.title,
                                           startSentence: start,
                                           sentenceCount: end - start,
                                           wordCount: wordsBefore[end] - wordsBefore[start]))
        }
        var sections: [ContentsSection] = []
        var runStart = 0
        for index in 1...entries.count where index == entries.count
            || entries[index].section != entries[runStart].section {
            sections.append(ContentsSection(title: entries[runStart].section, chapterRange: runStart..<index))
            runStart = index
        }
        return (chapters, sections)
    }

    /// Page runs as rows when there are at most `maxPageRows`; else grouped,
    /// at run boundaries, into `minPageGroups`…`maxPageRows` contiguous rows
    /// of about equal words, `minutesPerPageGroup` each at 1×.
    private static func pageRows(_ runs: [DerivedChapter]) -> [DerivedChapter] {
        guard runs.count > maxPageRows else { return runs }
        let total = runs.reduce(0) { $0 + $1.wordCount }
        let minutes = Double(total) / (LibraryDocument.spokenWordsPerMinute * minutesPerPageGroup)
        let target = min(maxPageRows, max(minPageGroups, Int(minutes.rounded())))
        var rows: [DerivedChapter] = []
        var group: [DerivedChapter] = []
        var words = 0
        func close() {
            guard let first = group.first else { return }
            rows.append(DerivedChapter(page: first.page,
                                       title: first.title,
                                       startSentence: first.startSentence,
                                       sentenceCount: group.reduce(0) { $0 + $1.sentenceCount },
                                       wordCount: group.reduce(0) { $0 + $1.wordCount }))
            group.removeAll()
        }
        for run in runs {
            // Close a row at a run boundary once it holds its share of words.
            if !group.isEmpty, rows.count < target - 1,
               Double(words) >= Double(total) * Double(rows.count + 1) / Double(target) {
                close()
            }
            group.append(run)
            words += run.wordCount
        }
        close()
        return rows
    }

    /// The last chapter starting on or before `page` (chapter pages never
    /// decrease); nil before the first.
    private func lastChapter(startingAtOrBefore page: Int) -> Int? {
        guard let first = chapters.first, first.page <= page else { return nil }
        var low = 0
        var high = chapters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chapters[mid].page <= page { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - Container folding (R17)

    private struct Grouping {
        var chapters: [DerivedChapter] = []
        var sections: [ContentsSection] = []
        var sectionTitleByPage: [Int: String] = [:]
        var containerPages: Set<Int> = []
    }

    /// Folds each run of container chapters into the chapter after it and
    /// opens a section titled by the run. A container with nothing after it
    /// stays an ordinary chapter. PDFs pass through as one untitled section.
    private static func grouping(_ raw: [DerivedChapter], kind: DocKind, sentences: [Sentence]) -> Grouping {
        var result = Grouping()
        result.chapters.reserveCapacity(raw.count)
        var pending: [DerivedChapter] = []
        var sectionTitle: String?
        var sectionStart = 0

        func closeSection() {
            guard result.chapters.count > sectionStart else { return }
            result.sections.append(ContentsSection(title: sectionTitle,
                                                   chapterRange: sectionStart..<result.chapters.count))
        }

        for (index, chapter) in raw.enumerated() {
            if kind == .text, index + 1 < raw.count, isContainer(chapter, sentences: sentences) {
                pending.append(chapter)
                continue
            }
            if let first = pending.first {
                closeSection()
                let title = pending.map(\.title).joined(separator: " · ")
                sectionTitle = title
                sectionStart = result.chapters.count
                for container in pending {
                    result.containerPages.insert(container.page)
                    result.sectionTitleByPage[container.page] = title
                }
                result.chapters.append(DerivedChapter(
                    page: chapter.page,
                    title: chapter.title,
                    startSentence: first.startSentence,
                    sentenceCount: pending.reduce(chapter.sentenceCount) { $0 + $1.sentenceCount },
                    wordCount: pending.reduce(chapter.wordCount) { $0 + $1.wordCount }))
                pending.removeAll()
            } else {
                result.chapters.append(chapter)
            }
            if let sectionTitle { result.sectionTitleByPage[chapter.page] = sectionTitle }
        }
        closeSection()
        return result
    }

    /// A chapter that is nothing but a Part/Book/Act/Epilogue heading: its
    /// first and last sentence share one paragraph. Never CHAPTER or
    /// PROLOGUE, and "Part of this book…" never matches.
    private static func isContainer(_ chapter: DerivedChapter, sentences: [Sentence]) -> Bool {
        let first = chapter.startSentence
        let last = chapter.lastSentence
        guard chapter.sentenceCount > 0, first >= 0, last < sentences.count,
              sentences[first].para == sentences[last].para else { return false }
        return chapter.title.wholeMatch(of: epilogueContainer) != nil
            || chapter.title.wholeMatch(of: partContainer) != nil
    }

    private static let epilogueContainer =
        #/^(?:(?i:first|second|third|fourth|final|last)\s+)?(?:EPILOGUE|Epilogue)\b.*$/#

    private static let partContainer =
        #/^(?:PART|Part|BOOK|Book|ACT|Act)(?:\s*$|[\s.:—–-]+(?:(?i:the)\s+)?(?:[IVXLCDM]+|\d+|(?i:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|last|final))\b.*)$/#
}

/// What the player bar's chapter line says when no message holds the slot:
/// "Chapter IV · 4 of 61 · 8 min left" (a mapped PDF too: "Tiny Speck · 6 of
/// 40 · 12 min left"), "<Title> · 12 min left" or "Pages 12–14 · 1 hr 12 min
/// left". Durations come from ListeningEstimate.
struct ReaderPositionLine: Equatable {

    enum Kind: Equatable {
        case chapter(number: Int, count: Int)
        case book
        case pages
    }

    let kind: Kind
    /// "Chapter IV", the document title, or "Pages 12–14" / "Page 12".
    let title: String
    /// nil means finished.
    let minutesLeft: Int?

    private var timeText: String {
        minutesLeft.map { ListeningEstimate.leftPhrase(minutes: $0) } ?? "Finished"
    }

    /// "4 of 61 · 8 min left", "12 min left" or "1 hr 12 min left".
    var detail: String {
        if case let .chapter(number, count) = kind {
            return "\(number) of \(count) · \(timeText)"
        }
        return timeText
    }

    var text: String { "\(title) · \(detail)" }

    /// Spelled out for VoiceOver: "Chapter IV, 4 of 61, 8 minutes left in
    /// chapter", "<Title>, 12 minutes left", "…, finished".
    var accessibilityLabel: String {
        if case let .chapter(number, count) = kind {
            let time = minutesLeft.map {
                "\(ListeningEstimate.spokenPhrase(minutes: $0)) left in chapter"
            } ?? "finished"
            return "\(title), \(number) of \(count), \(time)"
        }
        let time = minutesLeft.map { "\(ListeningEstimate.spokenPhrase(minutes: $0)) left" } ?? "finished"
        return "\(title), \(time)"
    }
}

// MARK: - Search results, spoken

extension ContentsSearch {

    /// "1 match", "12 matches": the count over a search's results.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count) matches"
    }

    /// What a search with no results shows.
    static func noMatchesLabel(_ query: String) -> String {
        "No matches for \u{201C}\(query)\u{201D}"
    }

    /// What VoiceOver hears as a search lands, nil to stay quiet. Focus stays
    /// in the field, so the count (or the no-matches line) is otherwise
    /// silent. Only when the count changed since the last search that landed
    /// (`previousCount`, nil after the field was cleared): typing on through
    /// the same results, or on into nothing, says nothing more.
    static func resultsAnnouncement(count: Int, query: String, previousCount: Int?) -> String? {
        guard count != previousCount else { return nil }
        return count == 0 ? noMatchesLabel(query) : countLabel(count)
    }

    /// Speaks `resultsAnnouncement` through the app's one announcement path,
    /// so a muted process only logs it. Contents on the iPhone and the Mac
    /// call this as each search lands.
    @MainActor
    static func announceResults(count: Int, query: String, previousCount: Int?, muted: Bool) {
        guard let line = resultsAnnouncement(count: count, query: query, previousCount: previousCount) else { return }
        PlaybackController.postAnnouncement(line, muted: muted)
    }
}
