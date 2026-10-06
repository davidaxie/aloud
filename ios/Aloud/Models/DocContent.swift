import Foundation

/// The extracted document — sentences are the atom of synthesis, highlight, and seek.

struct Sentence: Codable, Identifiable {
    let id: Int
    let text: String
    let para: Int
    let page: Int

    /// The word-count rule behind every listening estimate: whitespace-separated
    /// runs. Whole-book counts (`LibraryDocument.wordCount`) and per-chapter
    /// counts both sum this, so their estimates stay commensurable.
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

struct Paragraph: Codable, Identifiable {
    let id: Int
    let sentenceIDs: Range<Int>
    let page: Int
}

struct DocContent: Codable {
    let title: String
    let pageCount: Int
    let sentences: [Sentence]
    let paragraphs: [Paragraph]
    let contentHash: String   // SHA256 of joined sentence text
    /// PDFs only: the chapters worked out once, at import or on the first
    /// open after the update that added them. nil means never derived (a
    /// content cache older than chapter maps, a text book, synthetic test
    /// content). Not part of `contentHash`, so deriving one keeps progress.
    var chapterMap: ChapterMap? = nil
    /// PDFs only: the running header the extractor took off the top of
    /// each page, by page, so the running-header chapter tier can still
    /// read chapter titles from them when the map is worked out again. nil
    /// for content extracted before headers were taken off (they are still
    /// in its text). Not part of `contentHash`.
    var pageHeaders: [Int: String]? = nil

    private enum CodingKeys: String, CodingKey {
        case title, pageCount, sentences, paragraphs, contentHash, chapterMap, pageHeaders
    }
}

extension DocContent {

    /// Synthesized but for the chapter map, which decodes leniently: a cache
    /// written before the field existed has no key, and a map this build
    /// can't read is treated as never derived (it is worked out again)
    /// rather than costing the whole cache, and with it the book's progress.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        sentences = try container.decode([Sentence].self, forKey: .sentences)
        paragraphs = try container.decode([Paragraph].self, forKey: .paragraphs)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        chapterMap = (try? container.decodeIfPresent(ChapterMap.self, forKey: .chapterMap)) ?? nil
        pageHeaders = (try? container.decodeIfPresent([Int: String].self, forKey: .pageHeaders)) ?? nil
    }
}

// MARK: - Chapter map (PDFs)

/// A PDF's chapters, stored in its content cache. Worked out once by
/// `PDFChapterDetector` from the first source that yields at least two: the
/// PDF's own outline (bookmarks), chapter headings in the text, or running
/// headers at the tops of pages. `.none` means it was worked out and nothing
/// was found; Contents then lists page ranges.
struct ChapterMap: Codable, Equatable {

    enum Source: String, Codable {
        case outline, headings, runningHeaders, none
    }

    struct Entry: Codable, Equatable {
        /// Display-ready.
        let title: String
        /// The chapter's first sentence: strictly increasing, the first 0.
        let sentence: Int
        /// The Part or Book heading the chapter sits under; nil outside one.
        let section: String?
    }

    /// Bump whenever a detector changes: every PDF's map is worked out again
    /// on its next open.
    static let currentVersion = 2

    let version: Int
    let source: Source
    let entries: [Entry]

    /// The entries a navigation can trust, whatever the file holds: inside
    /// `0..<sentenceCount`, strictly increasing (a repeated start keeps the
    /// later entry), and starting at sentence 0 (a "Front matter" row is
    /// added when the first entry starts later).
    func sanitizedEntries(sentenceCount: Int) -> [Entry] {
        guard sentenceCount > 0 else { return [] }
        var result: [Entry] = []
        for entry in entries where entry.sentence >= 0 && entry.sentence < sentenceCount {
            if let last = result.last {
                if entry.sentence == last.sentence {
                    result[result.count - 1] = entry
                    continue
                }
                if entry.sentence < last.sentence { continue }
            }
            result.append(entry)
        }
        if let first = result.first, first.sentence > 0 {
            result.insert(Entry(title: PDFChapterDetector.frontMatterTitle, sentence: 0, section: nil), at: 0)
        }
        return result
    }
}

// MARK: - Whole-document measures

extension DocContent {

    /// Total words, summing the same per-sentence rule the chapter drawer uses.
    var wordCount: Int { sentences.reduce(0) { $0 + $1.wordCount } }

    /// Page indices may arrive 0- or 1-based — a content cache written by an
    /// older extractor is reused without re-extraction — so display adds this
    /// and starts at 1 either way. Label through `PageLabels` rather than
    /// applying it by hand.
    var pageOffset: Int { (sentences.first?.page ?? 1) == 0 ? 1 : 0 }
}

// MARK: - Derived chapters

/// One entry in the reader's chapter drawer, derived from the page grouping
/// the extractor already produces (text books: chapter headings become pages;
/// PDFs: physical pages), or, for a PDF with a chapter map, one map entry.
/// `title` is the group's first sentence, cleaned for display, or the entry's
/// title; a PDF without chapters is labelled by page range instead.
struct DerivedChapter: Identifiable, Equatable {
    let page: Int
    let title: String
    let startSentence: Int
    let sentenceCount: Int
    let wordCount: Int

    /// The start, not the page: two PDF chapters can start on one page.
    var id: Int { startSentence }

    var lastSentence: Int { startSentence + sentenceCount - 1 }

    func contains(sentence: Int) -> Bool {
        sentence >= startSentence && sentence <= lastSentence
    }

    /// Whole-minute listening estimate at the shared spoken-word rate
    /// (165 wpm at 1×); never less than a minute for a non-empty chapter.
    /// Pass `spokenWordsPerMinute * playback.rate` for a rate-aware estimate.
    func estimatedMinutes(wordsPerMinute: Double = LibraryDocument.spokenWordsPerMinute) -> Int {
        ListeningEstimate.minutes(words: wordCount, wordsPerMinute: wordsPerMinute)
    }
}

/// Everything the reader's navigation needs from one pass over the text: the
/// chapters and the running word total the chapter line's time-left reads.
struct NavigationIndex {
    let chapters: [DerivedChapter]
    /// Words before each sentence: `wordsBefore[0] == 0` and
    /// `wordsBefore[i + 1] == wordsBefore[i] + sentences[i].wordCount`, so
    /// `count == sentences.count + 1` and any span's words are one subtraction.
    let wordsBefore: [Int]
}

extension DocContent {

    /// Chapters derived from the extractor's page grouping, in reading order.
    /// Sentences are grouped by contiguous `page` runs; each group's first
    /// sentence is the heading. A book with no detected chapters is a single
    /// chapter; an empty document has none.
    var derivedChapters: [DerivedChapter] { navigationIndex().chapters }

    /// The chapters plus prefix word sums, in one O(total-words) pass: each
    /// sentence is split once, for its chapter's count and the running total.
    func navigationIndex() -> NavigationIndex {
        var chapters: [DerivedChapter] = []
        var wordsBefore: [Int] = [0]
        wordsBefore.reserveCapacity(sentences.count + 1)
        var total = 0
        var start = 0
        while start < sentences.count {
            let page = sentences[start].page
            var end = start
            var words = 0
            while end < sentences.count, sentences[end].page == page {
                let count = sentences[end].wordCount
                words += count
                total += count
                wordsBefore.append(total)
                end += 1
            }
            chapters.append(DerivedChapter(
                page: page,
                title: Self.cleanedChapterTitle(sentences[start].text),
                startSentence: sentences[start].id,
                sentenceCount: end - start,
                wordCount: words))
            start = end
        }
        return NavigationIndex(chapters: chapters, wordsBefore: wordsBefore)
    }

    /// Display cleanup for a heading sentence: internal whitespace collapsed,
    /// a lone trailing period dropped ("IV." → "IV"), a bare numeral spelled
    /// out as a chapter ("IV" → "Chapter IV") so it doesn't read as a stray
    /// mark in a list, and long body-text "headings" (chapterless books)
    /// truncated with an ellipsis.
    static func cleanedChapterTitle(_ text: String, maxLength: Int = 60) -> String {
        var title = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if title.hasSuffix("."), !title.hasSuffix("..") {
            title = String(title.dropLast())
        }
        if isBareNumeral(title) {
            title = "Chapter \(title)"
        }
        if title.count > maxLength {
            title = String(title.prefix(maxLength))
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        return title
    }

    /// A heading that is nothing but a roman numeral or an arabic number —
    /// the common Gutenberg chapter style ("I", "XVII", "3"). The roman test
    /// demands well-formed numerals rather than merely roman-numeral letters,
    /// so real one-word titles built from those letters ("CIVIL", "MILD",
    /// "VIVID") are left alone.
    private static func isBareNumeral(_ title: String) -> Bool {
        guard !title.isEmpty, title.count <= 7 else { return false }
        if title.allSatisfy({ $0.isNumber }) { return true }
        let upper = title.uppercased()
        return upper.wholeMatch(of: Self.romanNumeral) != nil
    }

    private static let romanNumeral = /M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})/
}

// MARK: - Search

/// One Contents search hit: the sentence, its page (chapter context), and the
/// first matched range within `text` (which is the sentence's own text, so
/// the range stays valid for emphasis rendering).
struct SentenceMatch: Identifiable, Equatable {
    let sentenceID: Int
    let page: Int
    let text: String
    let range: Range<String.Index>

    var id: Int { sentenceID }

    /// The matched substring as it appears in the sentence.
    var matchedText: String { String(text[range]) }
}

extension DocContent {

    /// Case- and diacritic-insensitive comparison used by Contents search.
    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Linear scan over all sentences, in reading order. At most one match per
    /// sentence — the first occurrence. Whitespace-only queries match nothing;
    /// the query is trimmed and folded to the stored text's punctuation
    /// (`searchNeedles(for:)`) before matching.
    ///
    /// The scan is not instant at book scale: a no-hit query over a 500k-word
    /// classic costs hundreds of milliseconds, so Contents search runs it off
    /// the main thread and abandons it when the next keystroke supersedes it.
    /// `isCancelled` is polled per sentence and defaults to the enclosing
    /// task's cancellation; a cancelled scan yields no results.
    func matches(of query: String,
                 isCancelled: () -> Bool = { Task.isCancelled }) -> [SentenceMatch] {
        let needles = Self.searchNeedles(for: query)
        guard !needles.isEmpty else { return [] }
        var found: [SentenceMatch] = []
        for sentence in sentences {
            if isCancelled() { return [] }
            // The earliest hit among the needle's spellings.
            var first: Range<String.Index>?
            for needle in needles {
                guard let range = sentence.text.range(of: needle, options: Self.searchOptions)
                else { continue }
                if first.map({ range.lowerBound < $0.lowerBound }) ?? true { first = range }
            }
            guard let range = first else { continue }
            found.append(SentenceMatch(sentenceID: sentence.id,
                                       page: sentence.page,
                                       text: sentence.text,
                                       range: range))
        }
        return found
    }

    /// The trimmed query spelled the way stored sentences spell it; empty for
    /// a blank query. TextNormalizer folds smart quotes, dashes and the
    /// ellipsis to ASCII before sentences are stored, but the reader and the
    /// search results show them typeset, so a pasted, dictated or Smart
    /// Punctuation query arrives curly ("Daisy’s") and would match nothing.
    ///
    /// A dash has two stored spellings, both shown as an em dash: " - " (a
    /// real dash in the source) and "--" (Gutenberg's ASCII dash). A query
    /// with a dash yields a needle for each.
    ///
    /// Spaces are stored plain and single, with none before , . ; : ! ? so
    /// a query's no-break, narrow and typographic spaces, and its runs of
    /// spaces, are folded the same way ("Mr.\u{00A0}Darcy", "Mr.  Darcy").
    /// A ZWJ or ZWNJ the normalizer keeps (an emoji sequence, a non-Latin
    /// word) is kept, with a needle without it for books imported before.
    static func searchNeedles(for query: String) -> [String] {
        var folded = ""
        var hasDash = false
        var keptJoiner = false
        let scalars = Array(query.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x200C, 0x200D:
                if TextNormalizer.keepsJoiner(before: folded.unicodeScalars.last,
                                              after: index + 1 < scalars.count ? scalars[index + 1] : nil) {
                    folded.unicodeScalars.append(scalar)
                    keptJoiner = true
                }
            case 0x0085, 0x00A0, 0x202F, 0x2028, 0x2029, 0x2000...0x200A:
                folded.append(" ")
            case 0x2018...0x201B:
                folded.append("'")
            case 0x201C...0x201F:
                folded.append("\"")
            case 0x2026:
                folded.append("...")
            // The word joiner the reader sets after a typeset "--" (it comes
            // along when text is copied), and the invisibles the normalizer
            // deletes.
            case 0x00AD, 0x200B, 0x2060, 0xFEFF:
                continue
            case 0x2012...0x2015:
                folded.append(dash)
                hasDash = true
            default:
                folded.unicodeScalars.append(scalar)
            }
        }
        let needle = folded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var needles = [needle]
        if hasDash {
            // "said—and" → "said--and"; spacing kept as typed.
            let ascii = needle.replacingOccurrences(of: String(dash), with: "--")
            // "said—and" and "said — and" → "said - and", the normalizer's form.
            let spaced = needle.replacingOccurrences(of: "\\s*\(dash)\\s*", with: " - ",
                                                     options: .regularExpression)
            needles = [ascii, spaced]
        }
        if keptJoiner {
            needles += needles.map {
                $0.replacingOccurrences(of: "[\\u200C\\u200D]", with: "", options: .regularExpression)
            }
        }
        return needles
    }

    /// Every query dash becomes this one before it is respelled.
    private static let dash: Character = "\u{2014}"
}
