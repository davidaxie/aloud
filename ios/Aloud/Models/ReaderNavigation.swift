import Foundation

/// The one rule for naming a place in a document.
///
/// Page indices may arrive 0- or 1-based — a content cache written by an older
/// extractor is reused without re-extraction — so every surface normalizes
/// through `DocContent.pageOffset` and displays pages starting at 1. PDF pages
/// carry no headings and read as "Page 12"; text books read as their chapter
/// title. Contents (its chapter list and its search), the player bar's
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

    init(kind: DocKind, pageOffset: Int, pageCount: Int, chapters: [DerivedChapter]) {
        self.kind = kind
        self.offset = pageOffset
        // PDFs never consult chapter titles; skip the dictionary entirely.
        self.titleByPage = kind == .pdf
            ? [:]
            : Dictionary(chapters.map { ($0.page, $0.title) },
                         uniquingKeysWith: { first, _ in first })
        self.spanEndByPage = kind == .pdf
            ? Self.spanEnds(chapters: chapters, pageOffset: pageOffset, pageCount: pageCount)
            : [:]
    }

    init(content: DocContent, kind: DocKind, chapters: [DerivedChapter]) {
        self.init(kind: kind,
                  pageOffset: content.pageOffset,
                  pageCount: content.pageCount,
                  chapters: chapters)
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

    /// What a page is called to the reader: its page range for PDFs, its
    /// chapter title for text books (falling back to the page label when a
    /// page has no derived chapter).
    func contextTitle(forPage page: Int) -> String {
        guard kind != .pdf, let title = titleByPage[page] else { return pageRangeLabel(page) }
        return title
    }
}

/// One Contents group (R17): the chapters under a Part, Book, Act or Epilogue
/// heading, or the untitled run before the first such heading. A book with
/// no such headings, a PDF and chapterless text are one untitled section.
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
struct ReaderNavigation {

    /// Reading order. For text, a folded chapter starts at its first
    /// container heading and keeps the leaf's page and title.
    let chapters: [DerivedChapter]
    /// Reading order; never empty unless `chapters` is.
    let sections: [ContentsSection]
    /// Built from the raw (unfolded) chapters, so a container's page still
    /// reads as its own heading.
    let labels: PageLabels
    let kind: DocKind
    private let wordsBefore: [Int]
    /// Every page inside a titled section, containers included.
    private let sectionTitleByPage: [Int: String]
    private let containerPages: Set<Int>

    init(content: DocContent, kind: DocKind) {
        // One pass for chapters and word sums: this runs at reader open, inside
        // the R13 open-time budget. Folding is one more pass over the chapters.
        let index = content.navigationIndex()
        let grouping = Self.grouping(index.chapters, kind: kind, sentences: content.sentences)
        self.chapters = grouping.chapters
        self.sections = grouping.sections
        self.labels = PageLabels(content: content, kind: kind, chapters: index.chapters)
        self.kind = kind
        self.wordsBefore = index.wordsBefore
        self.sectionTitleByPage = grouping.sectionTitleByPage
        self.containerPages = grouping.containerPages
    }

    /// A list worth opening: a book of one chapter shows Contents search only.
    var hasChapterList: Bool { chapters.count >= 2 }

    /// Contents draws section headers.
    var isGrouped: Bool { !containerPages.isEmpty }

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
    /// chapter (chaptered text), or to the end of the document (PDFs, and text
    /// with fewer than two chapters). `isFinished` replaces the time with
    /// "Finished".
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

        switch kind {
        case .pdf:
            return ReaderPositionLine(kind: .pages,
                                      title: labels.pageRangeLabel(chapter.page),
                                      minutesLeft: minutesLeft(through: sentenceCount - 1))
        case .text where hasChapterList:
            return ReaderPositionLine(kind: .chapter(number: index + 1, count: chapters.count),
                                      title: labels.contextTitle(forPage: chapter.page),
                                      minutesLeft: minutesLeft(through: chapter.lastSentence))
        case .text:
            return ReaderPositionLine(kind: .book, title: documentTitle,
                                      minutesLeft: minutesLeft(through: sentenceCount - 1))
        }
    }

    /// A Contents row or search hit named with its section: "BOOK ONE: 1805 ·
    /// CHAPTER I" for a chapter page, "BOOK ONE: 1805" for the container's own
    /// page. Ungrouped pages read as `labels.contextTitle(forPage:)`.
    func qualifiedTitle(forPage page: Int) -> String {
        guard let section = sectionTitleByPage[page] else { return labels.contextTitle(forPage: page) }
        return containerPages.contains(page) ? section : "\(section) · \(labels.contextTitle(forPage: page))"
    }

    // MARK: - Scrub (R12c, R17)

    /// What the scrub's track spans: the chapter holding `sentence` in
    /// chaptered text, else the whole document. 0...0 when empty.
    func scrubSpan(at sentence: Int) -> ClosedRange<Int> {
        guard sentenceCount > 0 else { return 0...0 }
        if kind == .text, hasChapterList, let index = chapterIndex(containing: sentence) {
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

    /// One VoiceOver adjust of the scrub: by chapter (text) or page row (PDF)
    /// when there are at least two, else ±1 minute. Backward goes to the
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

    /// `span` clamped into the document; nil when the document is empty.
    private func clamped(_ span: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard sentenceCount > 0 else { return nil }
        let lower = min(max(span.lowerBound, 0), sentenceCount - 1)
        let upper = min(max(span.upperBound, lower), sentenceCount - 1)
        return lower...upper
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
/// "Chapter IV · 4 of 61 · 8 min left", "<Title> · 12 min left" or
/// "Pages 12–14 · 1 hr 12 min left". Durations come from ListeningEstimate.
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
