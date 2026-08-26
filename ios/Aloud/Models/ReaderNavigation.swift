import Foundation

/// The one rule for naming a place in a document.
///
/// Page indices may arrive 0- or 1-based — a content cache written by an older
/// extractor is reused without re-extraction — so every surface normalizes
/// through `DocContent.pageOffset` and displays pages starting at 1. PDF pages
/// carry no headings and read as "Page 12"; text books read as their chapter
/// title. The chapter drawer, Search in Book, the player bar and the reader's
/// page marks all label through this, so no surface can say "Page 0" while
/// another says "PAGE 1".
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

/// Chapter list and labels derived once per loaded document.
///
/// `DocContent.derivedChapters` is an O(total-words) pass, so it must not run
/// inside a view initializer: SwiftUI re-invokes a presented sheet's content
/// closure on every parent body evaluation, which during playback is every
/// word-highlight tick. The reader derives this once when the document loads
/// and hands it to the chapter drawer and Search in Book.
struct ReaderNavigation {

    let chapters: [DerivedChapter]
    let labels: PageLabels

    init(content: DocContent, kind: DocKind) {
        let chapters = content.derivedChapters
        self.chapters = chapters
        self.labels = PageLabels(content: content, kind: kind, chapters: chapters)
    }
}
