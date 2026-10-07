import Foundation
import PDFKit

/// One node of a PDF's outline (its bookmarks), flattened in reading order.
struct PDFOutlineItem: Hashable, Sendable {
    let title: String
    /// 0-based, as PDFKit counts. The extractor numbers pages from 1, so the
    /// node's text is on content page `pageIndex + 1`.
    let pageIndex: Int
    /// 0 for a top-level node.
    let depth: Int
}

/// Works out a PDF's `ChapterMap`, once, from the first source that yields at
/// least two chapters: the PDF's own outline, chapter headings in the text,
/// then running headers at the tops of pages. Pure but for reading the
/// outline, which runs wherever PDFKit already runs (`ExtractionPipeline`),
/// never on the main actor.
///
/// Every tier's entries pass through one `normalized(_:in:)`, so a map always
/// starts at sentence 0 and only moves forward.
enum PDFChapterDetector {

    /// The row for everything before the first chapter.
    static let frontMatterTitle = "Front matter"

    /// Front text shorter than this joins the first chapter instead of
    /// getting a row of its own: a stray title line isn't front matter.
    static let frontMatterMinimumWords = 25

    /// Titles longer than this are truncated with an ellipsis.
    static let maxTitleLength = 80

    // MARK: Outline

    /// The outline to `maxDepth` levels, at most `limit` nodes. A grouping
    /// node with no destination takes its first descendant's page; a node
    /// with no title or no page is skipped and its children move up a level.
    static func outlineItems(of document: PDFDocument,
                             maxDepth: Int = 3,
                             limit: Int = 2_000) -> [PDFOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var items: [PDFOutlineItem] = []
        var visits = 0

        func pageIndex(of node: PDFOutline, level: Int) -> Int? {
            visits += 1
            if let page = (node.destination ?? (node.action as? PDFActionGoTo)?.destination)?.page {
                let index = document.index(for: page)
                return index == NSNotFound || index < 0 ? nil : index
            }
            guard level < 8, visits < limit * 4 else { return nil }
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i), let index = pageIndex(of: child, level: level + 1) {
                    return index
                }
            }
            return nil
        }

        func walk(_ node: PDFOutline, depth: Int, level: Int) {
            guard level < 8 else { return }
            for i in 0..<node.numberOfChildren {
                guard items.count < limit, visits < limit * 4, let child = node.child(at: i) else { return }
                visits += 1
                let title = (child.label ?? "")
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !title.isEmpty, let index = pageIndex(of: child, level: 0) {
                    items.append(PDFOutlineItem(title: title, pageIndex: index, depth: depth))
                    if depth + 1 < maxDepth { walk(child, depth: depth + 1, level: level + 1) }
                } else {
                    walk(child, depth: depth, level: level + 1)
                }
            }
        }

        walk(root, depth: 0, level: 0)
        return items
    }

    /// The outline of the PDF at `url`; empty when the file is unreadable or
    /// locked (the extractor's own unlock rule), or has no outline.
    static func outlineItems(at url: URL) -> [PDFOutlineItem] {
        guard let document = PDFDocument(url: url) else { return [] }
        if document.isLocked || (document.isEncrypted && !document.unlock(withPassword: "")) {
            return []
        }
        return outlineItems(of: document)
    }

    // MARK: Map

    /// The first tier that yields at least two chapters, else source `.none`.
    static func chapterMap(for content: DocContent, outline: [PDFOutlineItem]) -> ChapterMap {
        let tiers: [(ChapterMap.Source, () -> [ChapterMap.Entry]?)] = [
            (.outline, { OutlineChapters.entries(outline, in: content) }),
            (.headings, { HeadingChapters.entries(in: content) }),
            (.runningHeaders, { RunningHeaderChapters.entries(in: content) }),
        ]
        for (source, tier) in tiers {
            if let raw = tier(), let entries = normalized(raw, in: content) {
                return ChapterMap(version: ChapterMap.currentVersion, source: source, entries: entries)
            }
        }
        return ChapterMap(version: ChapterMap.currentVersion, source: .none, entries: [])
    }

    /// The shared last step: entries out of range or behind the one before
    /// are dropped, a repeated start keeps the later title, titles are
    /// cleaned for display, and the first entry starts at sentence 0 (short
    /// front text joins it; anything longer gets a "Front matter" row). nil
    /// when fewer than two entries are left.
    static func normalized(_ raw: [ChapterMap.Entry], in content: DocContent) -> [ChapterMap.Entry]? {
        let count = content.sentences.count
        var kept: [ChapterMap.Entry] = []
        for entry in raw where entry.sentence >= 0 && entry.sentence < count {
            let title = DocContent.cleanedChapterTitle(entry.title, maxLength: maxTitleLength)
            guard !title.isEmpty else { continue }
            let section = entry.section
                .map { DocContent.cleanedChapterTitle($0, maxLength: maxTitleLength) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let cleaned = ChapterMap.Entry(title: title, sentence: entry.sentence, section: section)
            if let last = kept.last {
                if cleaned.sentence == last.sentence {
                    kept[kept.count - 1] = cleaned
                    continue
                }
                if cleaned.sentence < last.sentence { continue }
            }
            kept.append(cleaned)
        }
        if let first = kept.first, first.sentence > 0 {
            let frontWords = content.sentences[0..<first.sentence].reduce(0) { $0 + $1.wordCount }
            if frontWords < frontMatterMinimumWords {
                kept[0] = ChapterMap.Entry(title: first.title, sentence: 0, section: first.section)
            } else {
                kept.insert(ChapterMap.Entry(title: frontMatterTitle, sentence: 0, section: nil), at: 0)
            }
        }
        return kept.count >= 2 ? kept : nil
    }

    /// Opens a section at each Part/Book heading (`parts`, by sentence) and
    /// folds the heading into the chapter after it, so the Part page is not
    /// the tail of the previous chapter. Back matter closes the open section:
    /// Notes and the Index don't belong to the last Part.
    static func applyingSections(to entries: [ChapterMap.Entry],
                                 parts: [(sentence: Int, title: String)]) -> [ChapterMap.Entry] {
        guard !parts.isEmpty else { return entries }
        let parts = parts.sorted { $0.sentence < $1.sentence }
        var result: [ChapterMap.Entry] = []
        var next = 0
        var section: String?
        var fold: Int?
        for entry in entries {
            while next < parts.count, parts[next].sentence <= entry.sentence {
                section = parts[next].title
                if parts[next].sentence > (result.last?.sentence ?? -1) {
                    fold = min(fold ?? parts[next].sentence, parts[next].sentence)
                }
                next += 1
            }
            if BookMatter.isBackMatter(entry.title) { section = nil }
            result.append(ChapterMap.Entry(title: entry.title,
                                           sentence: min(entry.sentence, fold ?? entry.sentence),
                                           section: section))
            fold = nil
        }
        return result
    }
}

// MARK: - Outline tier

/// Rows from the PDF's own outline. The top level is the rows, unless it is
/// made of Part-like containers: then the containers become section titles
/// and their children the rows. Deeper levels are never rows (subsections
/// would bring back a list of tiny rows).
enum OutlineChapters {

    static func entries(_ items: [PDFOutlineItem], in content: DocContent) -> [ChapterMap.Entry]? {
        guard items.count >= 2, !content.sentences.isEmpty else { return nil }
        // Auto-generated "Page 1 … Page N" bookmarks name no chapters.
        let pageLike = items.filter { $0.title.wholeMatch(of: pageBookmark) != nil }.count
        if pageLike * 5 >= items.count * 4 { return nil }

        // A book-title wrapper: descend while the top level is one node.
        var nodes = items
        while nodes.filter({ $0.depth == 0 }).count == 1, nodes.first?.depth == 0,
              nodes.contains(where: { $0.depth > 0 }) {
            nodes = nodes.dropFirst().map {
                PDFOutlineItem(title: $0.title, pageIndex: $0.pageIndex, depth: $0.depth - 1)
            }
        }

        var top: [(item: PDFOutlineItem, children: [PDFOutlineItem])] = []
        for item in nodes {
            if item.depth <= 0 || top.isEmpty {
                top.append((item, []))
            } else if item.depth == 1 {
                top[top.count - 1].children.append(item)
            }
        }

        var cache: [PDFOutlineItem: Int?] = [:]
        func start(_ item: PDFOutlineItem) -> Int? {
            if let hit = cache[item] { return hit }
            let value = Self.sentence(for: item, in: content)
            cache[item] = value
            return value
        }

        let isContainer = top.map { node -> Bool in
            guard node.children.count >= 2 else { return false }
            if node.item.title.firstMatch(of: partLabel) != nil { return true }
            guard let own = start(node.item), let first = start(node.children[0]) else { return false }
            return own == first
        }
        let containerCount = isContainer.filter { $0 }.count
        let namedContainers = zip(top, isContainer).filter { $1 && $0.item.title.firstMatch(of: partLabel) != nil }.count
        let useContainers = containerCount >= 2 || namedContainers >= 1

        var raw: [ChapterMap.Entry] = []
        for (index, node) in top.enumerated() {
            guard useContainers, isContainer[index] else {
                if let sentence = start(node.item) {
                    raw.append(ChapterMap.Entry(title: node.item.title, sentence: sentence, section: nil))
                }
                continue
            }
            // The Part's own page folds into its first chapter's row.
            var pendingIntro = start(node.item)
            for child in node.children {
                guard var sentence = start(child) else { continue }
                if let intro = pendingIntro, intro < sentence { sentence = intro }
                pendingIntro = nil
                let section = BookMatter.isBackMatter(child.title) ? nil : node.item.title
                raw.append(ChapterMap.Entry(title: child.title, sentence: sentence, section: section))
            }
        }

        // Reading order: a mostly shuffled outline is not a table of contents.
        var ordered: [ChapterMap.Entry] = []
        var disorder = 0
        for entry in raw {
            if let last = ordered.last {
                if entry.sentence == last.sentence {
                    ordered[ordered.count - 1] = entry   // the earlier had no text of its own
                    continue
                }
                if entry.sentence < last.sentence {
                    disorder += 1
                    continue
                }
            }
            ordered.append(entry)
        }
        if disorder * 3 > raw.count { return nil }

        // Leading title page, copyright, contents … fold into one row.
        var lead = 0
        while lead < ordered.count, BookMatter.isFrontMatter(ordered[lead].title) { lead += 1 }
        if lead > 0 {
            ordered = [ChapterMap.Entry(title: PDFChapterDetector.frontMatterTitle, sentence: 0, section: nil)]
                + ordered[lead...]
        }
        return ordered.count >= 2 ? ordered : nil
    }

    /// The node's first sentence: the first on its content page (pages
    /// never decrease through the sentences), moved to a later sentence on
    /// that page whose text is the label or the label's leading words, for
    /// a chapter that starts mid-page. Never a sentence that merely starts
    /// with the label: body text like "Sales is focused…" would match. A
    /// page without text resolves to the next sentence after it.
    static func sentence(for item: PDFOutlineItem, in content: DocContent) -> Int? {
        let sentences = content.sentences
        let page = item.pageIndex + 1
        var low = 0
        var high = sentences.count
        while low < high {
            let mid = (low + high) / 2
            if sentences[mid].page < page { low = mid + 1 } else { high = mid }
        }
        guard low < sentences.count else { return nil }
        let label = ChapterText.normalized(item.title)
        guard !label.isEmpty else { return low }
        let onPage = sentences[low].page
        var index = low
        while index < sentences.count, index < low + 40, sentences[index].page == onPage {
            let text = ChapterText.normalized(sentences[index].text)
            if text.count >= 3, text == label || label.hasPrefix(text + " ") { return index }
            index += 1
        }
        return low
    }

    private static let pageBookmark = #/(?i)\s*(?:page|p\.?)\s*\d+\s*/#
    private static let partLabel = #/^(?:PART|Part|BOOK|Book|VOLUME|Volume|SECTION|Section)\b/#
}

// MARK: - Heading tier

/// Rows from chapter headings in the text, for a PDF with no usable outline:
/// "CHAPTER ONE" (with its title line) and the named front and back matter
/// around the numbered run. Needs at least three numbered headings. A
/// running header that repeats "Chapter 3 The Return" on every other page
/// is that chapter, not more; numbering that starts again is new chapters.
enum HeadingChapters {

    static let minimumNumbered = 3

    private enum Kind { case numbered, front, back }

    private struct Candidate {
        let sentence: Int
        let title: String
        let kind: Kind
        let name: String
        var number: Int? = nil
    }

    static func entries(in content: DocContent) -> [ChapterMap.Entry]? {
        let sentences = content.sentences
        let paragraphs = content.paragraphs
        guard !sentences.isEmpty, !paragraphs.isEmpty else { return nil }

        var seenPages = Set<Int>()
        var candidates: [Candidate] = []
        var parts: [(sentence: Int, title: String)] = []

        for (index, paragraph) in paragraphs.enumerated() {
            let firstOnPage = seenPages.insert(paragraph.page).inserted
            guard paragraph.sentenceIDs.count == 1,
                  let id = paragraph.sentenceIDs.first, id >= 0, id < sentences.count else { continue }
            let text = ChapterText.collapsed(sentences[id].text)
            let words = text.split(whereSeparator: \.isWhitespace)
            let localized = text.wholeMatch(of: localizedHeading)
            // "Глава 1" on its own is a heading, not a contents line's page number.
            guard !words.isEmpty, words.count <= 12, !ChapterText.hasLeader(text),
                  !ChapterText.endsWithPageNumber(text) || localized != nil && words.count == 2 else { continue }

            if let match = localized.map({ $0.output.1 ?? $0.output.2 ?? "" })
                ?? text.wholeMatch(of: numberedHeading)?.output.1 {
                let rest = String(match).trimmingCharacters(in: .whitespaces)
                // "Chapter 5 shows how." is a sentence about a chapter.
                guard rest.isEmpty || !text.hasSuffix(".") else { continue }
                var title = ChapterText.droppingTrailingPeriod(text)
                if rest.isEmpty, let next = titleLine(after: index, in: content) {
                    title += ": " + next
                }
                candidates.append(Candidate(sentence: id, title: title, kind: .numbered, name: "",
                                            number: chapterNumber(text)))
            } else if firstOnPage, words.count <= 8, text.wholeMatch(of: partHeading) != nil {
                parts.append((id, ChapterText.droppingTrailingPeriod(text)))
            } else if firstOnPage, let match = text.wholeMatch(of: namedHeading) {
                let first = String(words[0])
                guard first == first.uppercased() || first.hasSuffix(":") else { continue }
                let name = String(match.1).uppercased()
                let kind: Kind = frontNames.contains(name) ? .front : .back
                candidates.append(Candidate(sentence: id, title: ChapterText.droppingTrailingPeriod(text),
                                            kind: kind, name: name.components(separatedBy: " ")[0]))
            }
        }

        // A contents list: numbered lines within two sentences of each other.
        let numbered = candidates.filter { $0.kind == .numbered }.map(\.sentence)
        let listed = Set(numbered.indices.flatMap { i -> [Int] in
            guard i + 1 < numbered.count, numbered[i + 1] - numbered[i] <= 2 else { return [] }
            return [numbered[i], numbered[i + 1]]
        })
        candidates.removeAll { $0.kind == .numbered && listed.contains($0.sentence) }

        // A number straight after itself is the chapter's running header:
        // the first is its opening. Numbering that starts again ("VOLUME
        // II", "Book the Second", an omnibus's next novel) keeps every
        // chapter, Part heading or not.
        var lastNumber: Int?
        candidates.removeAll { candidate in
            guard candidate.kind == .numbered, let number = candidate.number else { return false }
            defer { lastNumber = number }
            return number == lastNumber
        }

        let chapters = candidates.filter { $0.kind == .numbered }
        guard chapters.count >= minimumNumbered,
              let firstNumbered = chapters.first?.sentence,
              let lastNumbered = chapters.last?.sentence else { return nil }

        // Named headings only outside the numbered run, once each: a
        // CONCLUSION at the top of a page inside chapter 15 is that
        // chapter's own section.
        var seen = Set<String>()
        var entries: [ChapterMap.Entry] = []
        for candidate in candidates {
            switch candidate.kind {
            case .numbered:
                break
            case .front:
                guard candidate.sentence < firstNumbered, seen.insert(candidate.name).inserted else { continue }
            case .back:
                guard candidate.sentence > lastNumbered, seen.insert(candidate.name).inserted else { continue }
            }
            entries.append(ChapterMap.Entry(title: candidate.title, sentence: candidate.sentence, section: nil))
        }
        return PDFChapterDetector.applyingSections(to: entries, parts: parts)
    }

    /// A bare "CHAPTER ONE"'s title: the next paragraph, on the same page,
    /// when it is short and unpunctuated ("Traction Channels").
    private static func titleLine(after index: Int, in content: DocContent) -> String? {
        let paragraphs = content.paragraphs
        guard index + 1 < paragraphs.count, paragraphs[index + 1].page == paragraphs[index].page else { return nil }
        let text = ChapterText.paragraphText(paragraphs[index + 1], in: content)
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 8, let last = text.last,
              !".!?\"\u{201D}".contains(last) else { return nil }
        return text
    }

    private static let frontNames: Set<String> = ["PREFACE", "FOREWORD", "INTRODUCTION", "PROLOGUE"]

    /// The number after "Chapter": digits, a roman numeral or a number
    /// word ("twenty-one"), so "CHAPTER THREE" and "Chapter 3" agree. The
    /// localized markers' too: "第十二章", "제3장", "Глава первая", "Erstes Kapitel".
    static func chapterNumber(_ heading: String) -> Int? {
        if let first = heading.first, first == "第" || first == "제" {
            return cjkNumber(heading.dropFirst().drop(while: \.isWhitespace)
                .prefix(while: { !$0.isWhitespace && !"章回話话장화".contains($0) }))
        }
        let words = heading.split(whereSeparator: { $0.isWhitespace || ".:".contains($0) })
        guard words.count >= 2 else { return nil }
        let token = words[1].lowercased()
        if token == "kapitel" { return ordinalWords[words[0].lowercased()] }
        if let value = Int(token) { return value }
        if let value = romanValue(token) { return value }
        if let value = ordinalWords[token] { return value }
        let parts = token.split(separator: "-").map(String.init)
        guard let head = numberWords[parts[0]] else { return nil }
        guard parts.count == 2 else { return parts.count == 1 ? head : nil }
        return numberWords[parts[1]].map { head + $0 }
    }

    private static func romanValue(_ token: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        let digits = token.compactMap { values[$0] }
        guard !digits.isEmpty, digits.count == token.count else { return nil }
        var total = 0
        for (index, value) in digits.enumerated() {
            total += index + 1 < digits.count && value < digits[index + 1] ? -value : value
        }
        return total
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    ]

    /// The localized markers' ordinals: Russian, German, French, Spanish, Italian.
    private static let ordinalWords: [String: Int] = [
        "первая": 1, "вторая": 2, "третья": 3, "четвертая": 4, "четвёртая": 4, "пятая": 5,
        "шестая": 6, "седьмая": 7, "восьмая": 8, "девятая": 9, "десятая": 10,
        "erstes": 1, "zweites": 2, "drittes": 3, "viertes": 4, "fünftes": 5, "sechstes": 6,
        "siebentes": 7, "siebtes": 7, "achtes": 8, "neuntes": 9, "zehntes": 10, "elftes": 11,
        "zwölftes": 12, "premier": 1, "première": 1, "primero": 1, "primo": 1,
    ]

    /// "12", "１２", "十二", "一百零五", "一二〇": a CJK chapter numeral.
    private static func cjkNumber(_ numeral: Substring) -> Int? {
        guard !numeral.isEmpty else { return nil }
        var total = 0
        var current = 0
        for character in numeral {
            if "0123456789０１２３４５６７８９".contains(character), let digit = character.wholeNumberValue {
                current = current * 10 + digit
            } else if let digit = cjkDigits[character] {
                current = current * 10 + digit
            } else if let unit = cjkUnits[character] {
                total += max(current, 1) * unit
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }

    private static let cjkDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6,
        "七": 7, "八": 8, "九": 9,
    ]

    private static let cjkUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    private static let numberedHeading =
        #/(?:CHAPTER|Chapter)\s+(?i:\d{1,3}|[ivxlc]{1,7}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty)(?:-(?i:one|two|three|four|five|six|seven|eight|nine))?\b[.:]?\s*(.*)/#

    /// The chapter markers TextExtractor knows in other languages: "第一章
    /// 山村少年", "第十二回", "第3話", "제1장", "Глава 1", "ГЛАВА ПЕРВАЯ",
    /// "Kapitel 3", "Erstes Kapitel", "Chapitre premier", "Capítulo I",
    /// "Capitolo 3". Chapters only: 卷, 部, 篇, 節, 편, Часть are Parts or
    /// sections. A title may follow, starting with a capital or an
    /// ideograph and with no sentence break in it, so "第一章就讲完了。" and
    /// "Глава семьи сказал" (the head of the family) stay prose.
    private static let localizedHeading =
        #/(?:(?:第[0-9０-９〇零一二三四五六七八九十百千两兩]{1,6}[章回話话]|제\s?[0-9]{1,3}\s?[장화])(?:[\s:：.．、·—–-]+([^。！？.!?]{0,30}))?|(?:(?:ГЛАВА|Глава)\s+(?:[IVXLCDM]{1,7}|[0-9]{1,3}|(?i:первая|вторая|третья|четвертая|четвёртая|пятая|шестая|седьмая|восьмая|девятая|десятая|последняя))|(?:KAPITEL|Kapitel)\s+(?:[IVXLCDM]{1,7}|[0-9]{1,3})|(?i:erstes|zweites|drittes|viertes|fünftes|sechstes|siebentes|siebtes|achtes|neuntes|zehntes|elftes|zwölftes|letztes)\s+(?:KAPITEL|Kapitel)|(?:CHAPITRE|Chapitre)\s+(?:[IVXLCDM]{1,7}|[0-9]{1,3}|(?i:premier|première|dernier))|(?:CAPÍTULO|Capítulo|CAPITULO|Capitulo|CAPITOLO|Capitolo)\s+(?:[IVXLCDM]{1,7}|[0-9]{1,3}|(?i:primero|primo|único|unico)))(?!\w)[.:]?(?:[\s.:—–-]+(?=[\p{Lu}\p{Lt}\p{Lo}0-9"«„“(])([^.!?…]*[.!?…]?))?)/#

    private static let namedHeading =
        #/(?i)(preface|foreword|introduction|prologue|conclusion|epilogue|afterword|acknowledge?ments?|appendix(?:\s+[a-z0-9]+)?|notes|endnotes|index|bibliography|references|glossary|about the authors?)\b[.:]?\s*(.*)/#

    private static let partHeading =
        #/(?:PART|Part|BOOK|Book|VOLUME|Volume)\s+(?i:[ivxlc]{1,7}|\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|the\s+(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth))\b.*/#
}

// MARK: - Book matter

/// Names of the pages around a book's chapters.
enum BookMatter {

    /// Title page, copyright, contents and the like: folded into one row.
    static func isFrontMatter(_ title: String) -> Bool {
        let name = ChapterText.normalized(title)
        return frontNames.contains(name) || name.hasPrefix("also by ") || name.hasPrefix("praise for ")
    }

    /// Conclusion, acknowledgments, notes, index and the like: rows of their
    /// own, outside any Part.
    static func isBackMatter(_ title: String) -> Bool {
        let name = ChapterText.normalized(title)
        guard let first = name.split(separator: " ").first.map(String.init) else { return false }
        return backFirstWords.contains(first)
            || first.hasPrefix("acknowledg")
            || first.hasPrefix("appendi")
            || name.hasPrefix("about the author")
    }

    private static let frontNames: Set<String> = [
        "cover", "front cover", "half title", "halftitle", "half title page", "title", "title page",
        "copyright", "copyright page", "contents", "table of contents", "dedication", "epigraph",
        "frontispiece", "about this book",
    ]

    private static let backFirstWords: Set<String> = [
        "conclusion", "epilogue", "afterword", "notes", "endnotes", "bibliography", "references",
        "glossary", "index",
    ]
}

// MARK: - Text helpers

/// Small text tests the chapter tiers share.
enum ChapterText {

    /// Lowercased letters and digits, every other run one space: "CHAPTER
    /// ONE: Traction" → "chapter one traction".
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// Internal whitespace collapsed, ends trimmed.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The share of letters that are uppercase; 0 without letters.
    static func capsRatio<S: StringProtocol>(_ text: S) -> Double {
        var letters = 0
        var upper = 0
        for character in text where character.isLetter {
            letters += 1
            if character.isUppercase { upper += 1 }
        }
        return letters == 0 ? 0 : Double(upper) / Double(letters)
    }

    /// A contents line's dot leader (or the replacement characters some PDFs
    /// draw it as).
    static func hasLeader(_ text: String) -> Bool {
        text.contains("\u{FFFD}") || text.contains("...") || text.contains("\u{2026}") || text.contains(". . .")
    }

    /// "Traction Channels 9": a contents line's trailing page number.
    static func endsWithPageNumber(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let last = words.last else { return false }
        return last.count <= 4 && last.allSatisfy(\.isNumber)
    }

    static func droppingTrailingPeriod(_ text: String) -> String {
        text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) : text
    }

    /// A well-formed roman numeral, either case ("xii", "IV"); "MILD" and
    /// "DID" are not.
    static func isRomanNumeral<S: StringProtocol>(_ word: S) -> Bool {
        guard !word.isEmpty, word.count <= 7 else { return false }
        return String(word).uppercased().wholeMatch(of: romanNumeral) != nil
    }

    static func paragraphText(_ paragraph: Paragraph, in content: DocContent) -> String {
        let range = paragraph.sentenceIDs.clamped(to: 0..<content.sentences.count)
        return collapsed(content.sentences[range].map(\.text).joined(separator: " "))
    }

    private static let romanNumeral = #/M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})/#
}
