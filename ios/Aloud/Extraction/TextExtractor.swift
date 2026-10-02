import Foundation

/// Plain-text ingestion for bookshelf classics and imported .txt files.
/// Paragraphs come from blank-line separation; chapter-style headings become
/// page boundaries so the reader can show section marks. A book with no
/// detectable chapters is a single logical page.
///
/// Front matter: Gutenberg-style classics open with a "Title by Author" line,
/// a Contents list, and dedications. When a Contents heading appears near the
/// top of the file, the list is dropped and reading starts at the book's
/// first section (the title is already in the UI).
struct TextExtractor {

    struct Output {
        let pageCount: Int
        let blocks: [TextBlock]
    }

    func extract(url: URL) throws -> Output {
        let text = try Self.read(url)
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Italic markers go first, so front-matter detection sees "_I_" as the
        // heading "I", exactly as the page loop below does.
        let paragraphs = Self.paragraphs(in: unified).map {
            RawParagraph(text: Self.strippingItalicMarkers($0.text), firstLine: $0.firstLine)
        }
        let kept = Self.strippingFrontMatter(paragraphs)

        var blocks: [TextBlock] = []
        var page = 1
        for (index, paragraph) in kept.enumerated() {
            if Self.isChapterHeading(paragraph) && !blocks.isEmpty && Self.headsText(index, in: kept) {
                page += 1
            }
            blocks.append(TextBlock(text: paragraph, page: page))
        }
        guard !blocks.isEmpty else { throw ExtractionError.emptyDocument }
        return Output(pageCount: page, blocks: blocks)
    }

    // MARK: - Paragraph splitting

    struct RawParagraph {
        let text: String
        /// Zero-based line number of the paragraph's first line in the file.
        let firstLine: Int

        /// Zero-based line number of its last line (paragraphs hold no blank lines).
        var lastLine: Int { firstLine + text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
    }

    static func paragraphs(in unified: String) -> [RawParagraph] {
        let lines = unified.split(separator: "\n", omittingEmptySubsequences: false)
        let lineIsParagraph = isOneParagraphPerLine(lines)

        var result: [RawParagraph] = []
        var current: [Substring] = []
        var firstLine = 0
        func flush() {
            guard !current.isEmpty else { return }
            result.append(RawParagraph(
                text: current.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                firstLine: firstLine))
            current = []
        }
        for (index, line) in lines.enumerated() {
            if isBlank(line) {
                flush()
            } else {
                if current.isEmpty { firstLine = index }
                current.append(line)
                if lineIsParagraph { flush() }
            }
        }
        flush()
        return result
    }

    /// Only spaces and tabs, as `trimmingCharacters(in: .whitespaces)` sees
    /// them, without allocating: ASCII is decided byte by byte.
    private static func isBlank(_ line: Substring) -> Bool {
        for byte in line.utf8 {
            if byte == 0x20 || byte == 0x09 { continue }
            if byte < 0x80 { return false }
            return line.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
        }
        return true
    }

    /// Word and Notepad exports put each paragraph on one line with no blank
    /// line between. Joining those lines as hard wraps would turn the whole
    /// file into one paragraph with no chapters, so every line stands alone
    /// when blank lines are rare and the lines are clearly not wrapped: nearly
    /// all end a sentence; or most do, or they are long and a fair share do,
    /// and the text isn't hard-wrapped. Text hard-wrapped at any width,
    /// indented or not, fails that last test: its lines that stop mid-sentence
    /// nearly all reach the wrap column, where a paragraph per line ends
    /// wherever the paragraph does.
    static func isOneParagraphPerLine(_ lines: [Substring]) -> Bool {
        // Cheap exit for the usual layout, blank lines between paragraphs.
        let blankCount = lines.reduce(0) { isBlank($1) ? $0 + 1 : $0 }
        let count = lines.count - blankCount
        guard count >= 2, blankCount * 10 < count else { return false }

        let text = lines.filter { !isBlank($0) }.map { $0.trimmingCharacters(in: .whitespaces) }
        let lengths = text.map(\.count)
        let endsSentence = text.map { $0.last.map { ".!?:\"”’".contains($0) } ?? false }
        let ended = endsSentence.filter { $0 }.count
        // Nearly every line a whole sentence or more: no wrapping to speak of.
        if ended * 20 >= count * 17 { return true }
        let sorted = lengths.sorted()
        let width = sorted[count * 9 / 10]
        let runOn = zip(lengths, endsSentence).filter { !$0.1 }.map(\.0)
        let wrapped = runOn.count >= 20 && runOn.filter { $0 * 5 >= width * 4 }.count * 2 >= runOn.count
        guard !wrapped else { return false }
        return ended * 10 >= count * 7 || (sorted[count / 2] > 100 && ended * 10 >= count * 3)
    }

    // MARK: - Front matter

    /// A Contents heading counts only within this many lines of the top. The
    /// first body paragraph, when it places the opening chapter heading, sits
    /// within this many lines of the end of the list.
    static let frontMatterLineLimit = 80

    /// The first Contents entry may recur as a heading at most this many lines
    /// past the end of the list. Whatever lies in between and reads as part of
    /// the book (a preface or prologue the Contents doesn't list) is still
    /// read, so the window can be wide.
    static let entryHeadingLineLimit = 1000

    /// A run of unnumbered titles is believed to be a Contents list only
    /// within this many lines of the heading (or of a numbered entry ahead).
    static let titleListLineLimit = 400

    /// A list longer than this that is also most of the text after its
    /// heading is not a Contents list; the fallback then keeps it.
    static let fallbackListLineLimit = 200

    /// No Contents list has more paragraphs than this.
    static let maxListParagraphs = 2_000

    /// Conservative skip: only fires when an explicit Contents heading sits
    /// within the first `frontMatterLineLimit` lines. Then the Contents list
    /// is dropped, and reading starts at the heading of the first listed
    /// section (or the chapter heading right above the first body paragraph).
    /// Title lines, dedications, epigraphs and production notes before it are
    /// excluded so the first spoken sentence is the book's opening — but an
    /// unlisted preface, foreword or prologue between the list and that
    /// heading is read, and so is a first listed section that comes before
    /// the Contents. With no opening found, only the heading and its list go
    /// — and nothing goes when nothing would be left after them.
    /// Books without a Contents block are returned untouched.
    static func strippingFrontMatter(_ paragraphs: [RawParagraph]) -> [String] {
        let texts = paragraphs.map(\.text)
        guard let cut = frontMatterCut(paragraphs) else { return texts }
        if let start = cut.start {
            return (cut.leadingSection.map { Array(texts[$0]) } ?? []) + texts[start...]
        }
        // No opening found: drop the heading and its list. A file that is
        // all Contents (or a Contents with no body) is the document itself,
        // so it is kept whole; so is a "list" that is long and most of the
        // text, which no Contents is.
        guard cut.listEnd < texts.count else { return texts }
        let listLines = paragraphs[(cut.contents + 1)..<cut.listEnd].reduce(0) { $0 + lineCount($1.text) }
        let restLines = paragraphs[(cut.contents + 1)...].reduce(0) { $0 + lineCount($1.text) }
        if listLines > fallbackListLineLimit && listLines * 2 > restLines {
            return Array(texts[..<cut.contents] + texts[(cut.contents + 1)...])
        }
        return Array(texts[..<cut.contents] + texts[cut.listEnd...])
    }

    /// The front-matter decision for a book with a Contents heading.
    struct FrontMatterCut: Equatable {
        /// Index of the Contents heading.
        let contents: Int
        /// One past the last paragraph of the Contents list. With no opening
        /// found, this stops before any verse or chapter opening the list
        /// walk ran on into.
        let listEnd: Int
        /// Where reading starts, when the book's opening was found.
        let start: Int?
        /// A section printed before the Contents heading (the first listed
        /// entry, or a preface), read ahead of `start`.
        let leadingSection: Range<Int>?
    }

    static func frontMatterCut(_ paragraphs: [RawParagraph]) -> FrontMatterCut? {
        guard let contents = paragraphs.firstIndex(where: {
            $0.firstLine < frontMatterLineLimit && isContentsHeading($0.text)
        }) else { return nil }
        let texts = paragraphs.map(\.text)
        let classifier = Classifier(texts)
        let listEnd = contentsList(classifier, paragraphs, heading: contents).end
        let entry = firstEntryKey(paragraphs, contents: contents)
        // A "list" that runs to the end of the file is verse or lyrics that
        // look like titles (or the file is all Contents): the first entry may
        // still recur as a heading inside it.
        let endLine = listEnd < texts.count ? paragraphs[listEnd].firstLine : nil
        let firstProse = endLine.flatMap { endLine in
            (listEnd..<texts.count).lazy
                .prefix { paragraphs[$0].firstLine <= endLine + frontMatterLineLimit }
                .first { classifier.isProse($0) }
        }

        guard var heading = entry.flatMap({
            firstEntryHeading(key: $0.key, after: $0.index, paragraphs, texts,
                              lineLimit: endLine.map { $0 + entryHeadingLineLimit } ?? .max)
        }) ?? firstProse.flatMap({ chapterHeading(above: $0, in: texts, notBefore: listEnd) }) else {
            return FrontMatterCut(contents: contents,
                                  listEnd: fallbackListEnd(classifier, heading: contents, end: listEnd),
                                  start: nil, leadingSection: nil)
        }
        // A title matched alone ("THE KING'S CAR"): the first chapter's number
        // sits right above it ("I").
        if let entry, heading - 1 > entry.index, isBareMarker(texts[heading - 1], number: 1),
           !isChapterHeading(texts[heading]), texts[heading].wholeMatch(of: bareNumberRegex) == nil,
           !isListed(heading - 1, in: texts) {
            heading -= 1
        }
        let start = listEnd < heading ? unlistedSectionStart(texts, in: listEnd..<heading) ?? heading : heading
        return FrontMatterCut(contents: contents, listEnd: listEnd, start: start,
                              leadingSection: leadingSection(key: entry?.key, texts, before: contents))
    }

    // MARK: Contents list

    /// Paragraph classifications, each worked out at most once per pass: the
    /// list walk looks ahead and back over the same paragraphs.
    private final class Classifier {
        let texts: [String]
        private var prose: [Int8]
        private var numbered: [Int8]
        private var titles: [Int8]

        init(_ texts: [String]) {
            self.texts = texts
            prose = Array(repeating: -1, count: texts.count)
            numbered = prose
            titles = prose
        }

        func isProse(_ index: Int) -> Bool {
            Self.cached(&prose, index) { TextExtractor.isProse(texts[index]) }
        }

        /// A Contents entry or a numbered list block.
        func isNumbered(_ index: Int) -> Bool {
            guard index >= 0 && index < texts.count else { return false }
            return Self.cached(&numbered, index) {
                isContentsEntry(texts[index]) || isContentsList(texts[index])
            }
        }

        func isTitleList(_ index: Int) -> Bool {
            Self.cached(&titles, index) { TextExtractor.isTitleList(texts[index]) }
        }

        private static func cached(_ cache: inout [Int8], _ index: Int, _ compute: () -> Bool) -> Bool {
            if cache[index] >= 0 { return cache[index] == 1 }
            let value = compute()
            cache[index] = value ? 1 : 0
            return value
        }
    }

    private struct ContentsList {
        var end: Int
        /// Section numbers and titles of the entries so far: the body's first
        /// heading repeats one of them.
        var numbers = Set<Int>()
        var titles = Set<String>()
        /// Seen an entry that carries a section number ("IV.", "CHAPTER 2"),
        /// not just a name ("Preface").
        var hasNumberedEntries = false
    }

    /// The list under the heading: one block, or one entry per paragraph,
    /// however long. Unnumbered titles (story titles, part names) belong to
    /// it while no numbered entry has come yet (a list of titles, within
    /// `titleListLineLimit` lines) or when more numbered entries follow them
    /// — never the poems or title paragraphs after the last numbered entry.
    /// It ends at running prose, or at the body's first heading: one that
    /// repeats an entry and is followed by text, not by more entries. A
    /// part heading stacked on that heading ("PART I" over "CHAPTER I") is
    /// the body's too.
    private static func contentsList(_ classifier: Classifier, _ paragraphs: [RawParagraph],
                                     heading: Int) -> ContentsList {
        let texts = classifier.texts
        var list = ContentsList(end: heading + 1)
        func record(_ index: Int) {
            for line in trimmedLines(texts[index]) {
                let entry = sectionParts(contentsKey(line))
                if let number = entry.number { list.numbers.insert(number) }
                if entry.title.count >= 3 { list.titles.insert(entry.title) }
            }
        }
        var index = heading + 1
        while index < texts.count {
            // Les Misérables lists 421 entries; thousands make a book, not a Contents.
            guard index - heading <= maxListParagraphs else { return ContentsList(end: heading + 1) }
            let text = texts[index]
            if classifier.isProse(index) {
                // "Chapter iv." / "Containing a necessary apology…" / "Chapter v. …":
                // an entry's description in a paragraph of its own.
                guard list.hasNumberedEntries, classifier.isNumbered(index - 1),
                      isEntryContinuation(index, classifier) else { break }
            } else if classifier.isNumbered(index) {
                if index > heading + 1 && opensBody(index, classifier, list, within: 6) {
                    list.end = partHeadingsAbove(index, in: texts, notBefore: heading + 2)
                    break
                }
                if trimmedLines(text).contains(where: { sectionParts(contentsKey($0)).number != nil }) {
                    list.hasNumberedEntries = true
                }
            } else if classifier.isTitleList(index) {
                if opensBody(index, classifier, list, within: 3) { break }
                if list.hasNumberedEntries {
                    guard let next = numberedEntry(after: index, classifier, paragraphs, list) else { break }
                    for title in index..<next { record(title) }
                    index = next
                    list.end = next
                    continue
                }
                if paragraphs[index].lastLine - paragraphs[heading].firstLine > titleListLineLimit {
                    // Too long for a list of titles: verse, not a Contents.
                    return ContentsList(end: heading + 1)
                }
            } else {
                break
            }
            record(index)
            index += 1
            list.end = index
        }
        return list
    }

    /// Where the list ends when the book's opening wasn't found. The walk may
    /// have run on through what follows a list of titles: stanzas whose
    /// capitalised, unpunctuated lines look like titles, or a chapter's title
    /// and opening lines of dialogue. Those belong to the book, so the list
    /// ends before them: at a listed title that recurs; at the first stanza
    /// (sentence-case verse, or lines without the page numbers the entries
    /// carry), with its heading; or before the short lines that lead into
    /// running prose.
    private static func fallbackListEnd(_ classifier: Classifier, heading: Int, end: Int) -> Int {
        let texts = classifier.texts
        let first = heading + 1
        guard end > first + 1 else { return end }
        let lastPaged = (first..<end).last { hasPageNumbers(texts[$0]) }
        var titles = Set<String>()
        var inIllustrations = false
        for index in first..<end {
            let text = texts[index]
            if index > first {
                if isIllustrationsHeading(text) { inIllustrations = true }
                if !inIllustrations, !classifier.isNumbered(index), !hasPageNumbers(text) {
                    if !text.contains("\n") {
                        if titles.contains(sectionParts(contentsKey(text)).title) { return index }
                    } else if !classifier.isProse(index),
                              isVerse(text) || (lastPaged.map { index > $0 } ?? false) && classifier.isTitleList(index) {
                        // The stanza's heading ("POEM 1", "XII.") is the poem's too.
                        return index - 1 > first && !texts[index - 1].contains("\n")
                            && !hasPageNumbers(texts[index - 1]) ? index - 1 : index
                    }
                }
            }
            for line in trimmedLines(text) {
                let title = sectionParts(contentsKey(line)).title
                if title.contains(" ") { titles.insert(title) }
            }
        }
        // "A COLD NIGHT" / "Who is there?" / "Only me." over the first prose,
        // after a block of titles.
        if end < texts.count, classifier.isProse(end) {
            var start = end
            while start - 1 > first, end - (start - 1) <= 6, !texts[start - 1].contains("\n"),
                  !classifier.isNumbered(start - 1), !hasPageNumbers(texts[start - 1]) {
                start -= 1
            }
            if start < end, texts[start - 1].contains("\n"), !classifier.isNumbered(start - 1) {
                return start
            }
        }
        return end
    }

    /// A short prose paragraph with more numbered entries right after it.
    private static func isEntryContinuation(_ index: Int, _ classifier: Classifier) -> Bool {
        lineCount(classifier.texts[index]) <= 3
            && classifier.isNumbered(index + 1) && classifier.isNumbered(index + 2)
    }

    /// The next numbered entry in an unbroken run of titles, if one comes
    /// within `titleListLineLimit` lines — and isn't the body's first heading.
    private static func numberedEntry(after index: Int, _ classifier: Classifier,
                                      _ paragraphs: [RawParagraph], _ list: ContentsList) -> Int? {
        var next = index + 1
        while next < paragraphs.count,
              paragraphs[next].firstLine - paragraphs[index].firstLine <= titleListLineLimit {
            if classifier.isProse(next) { return nil }
            if classifier.isNumbered(next) {
                return opensBody(next, classifier, list, within: 6) ? nil : next
            }
            guard classifier.isTitleList(next) else { return nil }
            next += 1
        }
        return nil
    }

    /// Whether the paragraph at `index` is the body's first heading rather
    /// than one more entry: it repeats an entry already listed (the numbering
    /// restarts at "CHAPTER I", or a title recurs), and running text follows
    /// within `within` paragraphs (a title, a line or two of dialogue), before
    /// any further entry.
    private static func opensBody(_ index: Int, _ classifier: Classifier, _ list: ContentsList,
                                  within: Int) -> Bool {
        let text = classifier.texts[index]
        guard text.utf8.count <= 600 else { return false }
        let entry = sectionParts(contentsKey(trimmedLines(text).joined(separator: " ")))
        guard entry.number.map(list.numbers.contains) ?? false || list.titles.contains(entry.title) else {
            return false
        }
        for next in (index + 1)..<min(index + 1 + within, classifier.texts.count) {
            if classifier.isProse(next) { return !isEntryContinuation(next, classifier) }
            if classifier.isNumbered(next) { return false }
        }
        return false
    }

    /// The opening heading at `index`, or the part heading stacked right above
    /// it ("PART I" / "Book I. …" over "Chapter I.", "BOOK FIRST." over
    /// "CHAPTER I."): same number, a different section word.
    private static func partHeadingsAbove(_ index: Int, in texts: [String], notBefore lowest: Int) -> Int {
        let opening = sectionParts(contentsKey(trimmedLines(texts[index]).joined(separator: " ")))
        guard let number = opening.number else { return index }
        var start = index
        while start - 1 >= lowest, trimmedLines(texts[start - 1]).count <= 2,
              isContentsEntry(texts[start - 1]) {
            let part = sectionParts(contentsKey(trimmedLines(texts[start - 1]).joined(separator: " ")))
            guard part.number == number, part.word != nil, part.word != opening.word else { break }
            start -= 1
        }
        return start
    }

    // MARK: Reading start

    /// The first Contents entry, as a key ("chapter i down the rabbit hole"),
    /// and the paragraph it comes from (after any "CHAPTER  PAGE" labels).
    private static func firstEntryKey(_ paragraphs: [RawParagraph], contents: Int) -> (key: String, index: Int)? {
        for index in (contents + 1)..<min(contents + 4, paragraphs.count) {
            for line in trimmedLines(paragraphs[index].text)
            where line.wholeMatch(of: contentsColumnRegex) == nil {
                let key = contentsKey(line)
                if !key.isEmpty { return (key, index) }
            }
        }
        return nil
    }

    /// Where the first Contents entry recurs as a heading in the text. A copy
    /// followed by more entries is still inside the Contents and is skipped.
    private static func firstEntryHeading(key: String, after entry: Int, _ paragraphs: [RawParagraph],
                                          _ texts: [String], lineLimit: Int) -> Int? {
        guard entry + 1 < paragraphs.count else { return nil }
        for index in (entry + 1)..<paragraphs.count {
            guard paragraphs[index].firstLine <= lineLimit else { break }
            if matchesEntry(key, at: index, texts) && !isListed(index, in: texts) { return index }
        }
        return nil
    }

    /// A section of the book printed before the Contents heading: a
    /// preface, foreword or note under its own heading, with at least 30
    /// words of text ("TO THE HESITATING PURCHASER" and its verse in
    /// Treasure Island); the first listed entry ("Editor's Preface" above the
    /// Contents that lists it first) with at least 40; or a titled prefatory
    /// note of 100 words or more of prose right above the Contents ("The
    /// Great Seal" in The Prince and the Pauper). It runs up to the Contents
    /// heading. Under a heading, text is prose however narrowly it is set (A
    /// Christmas Carol's preface) or verse. Title pages, dedications,
    /// publishers' blurbs and production notes are none of these.
    private static func leadingSection(key: String?, _ texts: [String], before contents: Int) -> Range<Int>? {
        func textWords(_ range: Range<Int>, proseOnly: Bool = false) -> Int {
            texts[range].filter { (proseOnly ? isProse($0) : isRunningText($0)) && !isProductionMatter($0) }
                .reduce(0) { $0 + wordCount($1) }
        }
        for index in 0..<contents {
            let text = texts[index]
            let minimum = isFrontSectionHeading(text) && text.firstMatch(of: dedicationRegex) == nil
                ? leadingSectionMinimumWords
                : key.map { matchesEntry($0, at: index, texts) } == true ? unlistedProseMinimumWords : nil
            if let minimum, textWords((index + 1)..<contents) >= minimum { return index..<contents }
        }
        // A signature or date line or two may sit between the note and the Contents.
        var end = contents
        while end > 0, contents - end < 2, isHeadingLike(texts[end - 1]), !isProse(texts[end - 1]) {
            end -= 1
        }
        var first = end
        while first > 0, isProse(texts[first - 1]), !isProductionMatter(texts[first - 1]) { first -= 1 }
        guard first > 0, first < end, textWords(first..<end, proseOnly: true) >= 100 else { return nil }
        let title = texts[first - 1]
        guard !title.contains("\n"), title.contains(where: \.isLetter), !isProductionMatter(title),
              title.split(whereSeparator: \.isWhitespace).count <= 6, isHeadingLike(title) else { return nil }
        return (first - 1)..<contents
    }

    /// Words of text under a front-section heading above the Contents
    /// (An Old Man's Love has a 35-word note).
    static let leadingSectionMinimumWords = 30

    /// Running text: prose, or verse and narrowly set prose (lines under
    /// prose width) — mostly lowercase, and neither a heading nor a list.
    private static func isRunningText(_ paragraph: String) -> Bool {
        isProse(paragraph)
            || (isMostlyLowercase(paragraph) && !isHeadingLike(paragraph) && !isTitleList(paragraph)
                && !isContentsList(paragraph) && !isContentsEntry(paragraph))
    }

    private static let dedicationRegex = #/dedicat/#.ignoresCase()

    private static let bareNumberRegex = #/\d{1,4}\.?/#

    /// Whether the paragraph at `index` is a heading that repeats the entry
    /// `key`: "CHAPTER I.\nDown the Rabbit-Hole" for "CHAPTER I. Down the
    /// Rabbit-Hole", "ETYMOLOGY." for "ETYMOLOGY.", "PART ONE" for "PART I",
    /// a marker whose title is the next paragraph ("CHAPTER I" + "SOMETHING
    /// ABOUT THE ROVER BOYS" for "I. SOMETHING ABOUT THE ROVER BOYS"), or the
    /// title alone ("SILENT RAIN" for "1. Silent Rain ..... 3") when it isn't
    /// one line of a list of titles (an illustration list echoes chapter titles).
    private static func matchesEntry(_ key: String, at index: Int, _ texts: [String]) -> Bool {
        let text = texts[index]
        guard text.utf8.count <= 600 else { return false }
        let lines = trimmedLines(text)
        guard lines.count <= 4, lines.allSatisfy({ $0.count <= 140 }),
              text.firstMatch(of: pageNumberRegex) == nil else { return false }
        let isMarker = isChapterHeading(text) || text.wholeMatch(of: bareNumberRegex) != nil
        switch entryMatch(key, contentsKey(lines.joined(separator: " ")), isHeading: isMarker) {
        case .heading:
            return true
        case .titleOnly:
            func isTitleLine(_ neighbor: Int) -> Bool {
                neighbor >= 0 && neighbor < texts.count && !texts[neighbor].contains("\n")
                    && isTitleList(texts[neighbor])
            }
            if !isTitleLine(index - 1) && !isTitleLine(index + 1) { return true }
        case .none:
            break
        }
        guard isMarker, lines.count == 1, index + 1 < texts.count else { return false }
        let title = trimmedLines(texts[index + 1])
        guard title.count <= 2, title.allSatisfy({ $0.count <= 80 }), !isProse(texts[index + 1]) else {
            return false
        }
        return entryMatch(key, contentsKey(lines[0] + " " + title.joined(separator: " ")),
                          isHeading: true) == .heading
    }

    private enum EntryMatch { case none, heading, titleOnly }

    private static func entryMatch(_ entryKey: String, _ candidateKey: String, isHeading: Bool) -> EntryMatch {
        guard !candidateKey.isEmpty else { return .none }
        // "CHAPTER I" in the body for a bare "I." entry, and the reverse.
        let candidate = droppingChapterWord(candidateKey)
        var entries = [droppingChapterWord(entryKey)]
        // A page number after a single space: "the custom house introductory 1".
        let tokens = entries[0].split(separator: " ")
        if tokens.count >= 3, let last = tokens.last, last.allSatisfy(\.isNumber) {
            entries.append(tokens.dropLast().joined(separator: " "))
        }
        for entry in entries {
            if entry.count < 3 {
                // A bare "I" entry only matches a heading that is exactly "I".
                if candidate == entry && isHeading { return .heading }
                continue
            }
            if candidate == entry || candidate.hasPrefix(entry + " ") { return .heading }
            // The heading leaves off the entry's title, or its page number.
            if entry.hasPrefix(candidate + " ")
                && (isHeading || entry.dropFirst(candidate.count + 1).allSatisfy(\.isNumber)) {
                return .heading
            }
        }
        // Same section and number, restyled ("PART ONE" for "PART I", "CHAPTER
        // THE FIRST" + its title for "I. Its Title"), or the same title alone.
        let heading = sectionParts(candidateKey)
        func word(_ word: String?) -> String? { word == "chapter" || word == "chap" ? nil : word }
        var match = EntryMatch.none
        for entry in entries.map(sectionParts) {
            if let number = entry.number, number == heading.number, word(entry.word) == word(heading.word),
               entry.title == heading.title || (isHeading && (entry.title.isEmpty || heading.title.isEmpty)) {
                return .heading
            }
            if heading.number == nil, entry.title.contains(" "), entry.title == heading.title {
                match = .titleOnly
            }
        }
        return match
    }

    private static func droppingChapterWord(_ key: String) -> String {
        for word in ["chapter ", "chap "] where key.hasPrefix(word) {
            return String(key.dropFirst(word.count))
        }
        return key
    }

    /// The chapter heading among the short paragraphs just above the first
    /// body paragraph (heading, title, a line or two of opening dialogue).
    /// Never inside the Contents list, nor in an unrecognised run of entries.
    private static func chapterHeading(above firstProse: Int, in texts: [String],
                                       notBefore listEnd: Int) -> Int? {
        var start = firstProse
        while start - 1 >= listEnd, firstProse - (start - 1) <= 6, isHeadingLike(texts[start - 1]) {
            start -= 1
        }
        return (start..<firstProse).first { index in
            isChapterHeading(texts[index])
                && !(index - 2 >= listEnd
                     && isContentsEntry(texts[index - 1]) && isContentsEntry(texts[index - 2]))
        }
    }

    /// Followed by at least two more Contents entries before any prose. A
    /// stack of headings with the same number ("PART I" / "Book I." /
    /// "Chapter I.") is the body's opening, not a list.
    private static func isListed(_ index: Int, in texts: [String]) -> Bool {
        let number = sectionParts(contentsKey(trimmedLines(texts[index]).joined(separator: " "))).number
        var entries = 0
        for next in texts[(index + 1)..<min(index + 5, texts.count)] {
            if isProse(next) { break }
            let key = contentsKey(next)
            if isContentsEntry(next) && key.split(separator: " ").count >= 2
                && (number == nil || sectionParts(key).number != number) {
                entries += 1
            }
        }
        return entries >= 2
    }

    // MARK: Unlisted front sections

    /// Where reading starts when material between the Contents list and the
    /// book's first listed heading is part of the book: at an unlisted
    /// section's heading ("FOREWORD", "Prologue") with text under it, at
    /// running prose (a short preface or prefatory note, with any heading
    /// right above it), or at a long stretch of verse. Production matter
    /// (transcriber's notes, credits, [Illustration] tags) never counts, nor
    /// does a list of illustrations, nor title-page repeats, dedications and
    /// epigraphs: short lines that aren't running text. A section heading
    /// that ended the list ("Prologue" over the verse it heads) is included.
    private static func unlistedSectionStart(_ texts: [String], in range: Range<Int>) -> Int? {
        let lowest = range.lowerBound > 0 && isFrontSectionHeading(texts[range.lowerBound - 1])
            ? range.lowerBound - 1 : range.lowerBound
        var inNote = false
        var inIllustrations = false
        var sectionHeading: Int? = lowest < range.lowerBound ? lowest : nil
        var firstProse: Int?, proseWords = 0
        var firstVerse: Int?, verseLines = 0
        var textAfterHeading = false
        for index in range {
            let text = texts[index]
            if isFrontSectionHeading(text) {
                inNote = false
                inIllustrations = false
                if sectionHeading == nil { sectionHeading = index }
                continue
            }
            if inIllustrations { continue }
            if isIllustrationsHeading(text) {
                inIllustrations = true
                continue
            }
            if isProductionMatter(text) {
                inNote = inNote || opensEditionNote(text.trimmingCharacters(in: .whitespaces))
                continue
            }
            let prose = isProse(text)
            // The body of a transcriber's note runs on until the next heading;
            // a copyright line or an [Illustration] tag has no body.
            if inNote && prose { continue }
            inNote = false
            if prose {
                if firstProse == nil { firstProse = index }
                proseWords += wordCount(text)
                textAfterHeading = textAfterHeading || sectionHeading != nil
            } else if !isHeadingLike(text) && !isTitleList(text) && !isContentsList(text) {
                if firstVerse == nil { firstVerse = index }
                verseLines += lineCount(text)
                textAfterHeading = textAfterHeading || sectionHeading != nil
            }
        }
        var candidates: [Int] = []
        if let sectionHeading, textAfterHeading { candidates.append(sectionHeading) }
        if let firstProse, proseWords >= unlistedProseMinimumWords {
            candidates.append(headingAbove(firstProse, in: texts, notBefore: lowest))
        }
        if let firstVerse, verseLines >= unlistedVerseMinimumLines {
            candidates.append(headingAbove(firstVerse, in: texts, notBefore: lowest))
        }
        return candidates.min()
    }

    private static let illustrationsHeadingRegex =
        #/^(?:list\s+of\s+)?(?:full[- ]page\s+)?(?:illustrations|plates|maps|figures|engravings|portraits)\b/#
        .ignoresCase()

    /// "ILLUSTRATIONS", "LIST OF PLATES": captions follow, not text.
    private static func isIllustrationsHeading(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 60 else { return false }
        return paragraph.trimmingCharacters(in: .whitespaces).firstMatch(of: illustrationsHeadingRegex) != nil
    }

    /// Prose under this many words between the list and the first heading is
    /// a dedication or epigraph, not a preface.
    static let unlistedProseMinimumWords = 40

    /// Verse under this many lines there is an epigraph, not a prologue.
    static let unlistedVerseMinimumLines = 20

    /// Back up over a short heading or two ("PREFATORY NOTE") right above.
    private static func headingAbove(_ index: Int, in texts: [String], notBefore lowerBound: Int) -> Int {
        var start = index
        while start - 1 >= lowerBound, index - (start - 1) <= 2,
              isHeadingLike(texts[start - 1]), !isProductionMatter(texts[start - 1]),
              trimmedLines(texts[start - 1]).count <= 2 {
            start -= 1
        }
        return start
    }

    private static let frontSectionRegex =
        #/^(?:(?:the|an?|author['’]?s|translator['’]?s|editor['’]?s|publisher['’]?s|prefatory|introductory|explanatory|preliminary)\s+)*(?:preface|foreword|forward|prologue|prelude|proem|introduction|note|notice|advertisement|induction|invocation|dedication|to\s+the\s+(?:[a-z]+\s+)?(?:reader|purchaser|buyer|public))s?\b/#
        .ignoresCase()

    /// "PREFACE", "FOREWORD", "Prologue", "AUTHOR'S NOTE", "TO THE READER",
    /// "TO THE HESITATING PURCHASER" — never "To My Wife", a dedication.
    private static func isFrontSectionHeading(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 60 else { return false }
        return paragraph.trimmingCharacters(in: .whitespaces).firstMatch(of: frontSectionRegex) != nil
    }

    /// Words only notes about an edition use: a transcriber's note, an
    /// e-text's credits ("Produced by …"), a rights notice.
    private static let editionNoteRegex =
        #/transcriber|gutenberg|all\s+rights\s+reserved|^\s*produced\s+by|^\s*acknowledg|\bthis\s+(?:file|e-?text|e-?book)\b|\be-?texts?\b|\be-?books?\b|^\s*credits?\b|proof-?read|html\s+version|digiti[sz]ed|internet\s+archive|\bpgdp\b/#
        .ignoresCase()

    /// Words prose uses too ("the copyright question", "first produced by
    /// Mr. Daly", "scanning these lines"): edition matter only in a short
    /// paragraph ("Copyright, 1907, by …", "Typographical errors corrected.").
    private static let editionWordRegex =
        #/\bcopyright\b|produced\s+by|by\s+(?:kind\s+)?permission\s+of|reprinted\s+by\s+permission|permission\s+to\s+reprint|scann(?:ed|ing)\b|typographical/#
        .ignoresCase()

    /// A paragraph this short with one of those words is a notice, not prose.
    private static let editionNoticeMaximumWords = 60

    /// Notes about the edition rather than the book: transcriber's notes,
    /// production credits, copyright and permission notices,
    /// acknowledgments, "[Illustration]" tags and other bracketed notes.
    static func isProductionMatter(_ paragraph: String) -> Bool {
        let text = paragraph.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") && text.hasSuffix("]") { return true }
        guard text.utf8.count <= 4_000 else { return false }
        return opensEditionNote(text)
            || (text.firstMatch(of: editionWordRegex) != nil && wordCount(text) <= editionNoticeMaximumWords)
    }

    /// A transcriber's note or e-text credit, whose body may run on over the
    /// next paragraphs; a bracketed tag or a copyright line has none.
    private static func opensEditionNote(_ text: String) -> Bool {
        text.utf8.count <= 4_000 && !text.hasPrefix("[") && text.firstMatch(of: editionNoteRegex) != nil
    }

    // MARK: Classifiers

    private static let contentsHeadingRegex =
        #/^(?:table\s+of\s+)?contents[.:]?(?:\s+(?:of\s+)?(?:volume|vol\.|book|part)\s+[ivxlc\d]+\.?)?$/#
        .ignoresCase()

    static func isContentsHeading(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 40 else { return false }
        return paragraph
            .trimmingCharacters(in: .whitespaces)
            .wholeMatch(of: contentsHeadingRegex) != nil
    }

    /// A line that opens like a Contents entry: a section word followed by a
    /// numeral or capital ("CHAPTER I.", "Book the First"; never "Part of…"),
    /// a front-matter section name, or a numeral ("XII.", "3", "I II III").
    private static let entryWordRegex =
        #/^(?:(?:CHAPTER|Chapter|CHAP|Chap|BOOK|Book|PART|Part|VOLUME|Volume|ACT|Act|SCENE|Scene|CANTO|Canto|LETTER|Letter|STAVE|Stave)(?:\s*$|[\s.:—–-]+(?:[IVXLCDM]+\b|[ivxlc]+\b|\d|[A-Z]))|(?:PROLOGUE|Prologue|EPILOGUE|Epilogue|PREFACE|Preface|INTRODUCTION|Introduction|APPENDIX|Appendix)\b)/#
    private static let entryNumeralRegex =
        #/^(?:[IVXLCDM]+(?:\.|$|\s{2,}|\s+[IVXLCDM]+\b)|\d+\.?(?:\s|$))/#
    /// A ditto mark that repeats the section word of the entry above it
    /// ("Chapter II. Observations …", then `" III. On the study …`).
    private static let dittoEntryRegex = #/^["”]\s+[IVXLCDM]+\.\s/#

    private static func startsLikeEntry(_ line: String) -> Bool {
        line.firstMatch(of: entryWordRegex) != nil || line.firstMatch(of: entryNumeralRegex) != nil
            || line.firstMatch(of: dittoEntryRegex) != nil
    }

    /// Contents lines run long ("CHAPTER XIV. IN WHICH PHILEAS FOGG…"), but
    /// not without limit.
    private static func hasListLength(_ line: String) -> Bool {
        let length = line.count
        return length <= 140 || (length <= 300 && startsLikeEntry(line))
    }

    /// No list block runs longer than this; a paragraph that does is text.
    private static let maxListLines = 3_000

    /// A Contents list block: at least half its lines start like a table
    /// entry, and none is a run-on paragraph.
    static func isContentsList(_ paragraph: String) -> Bool {
        let lines = trimmedLines(paragraph)
        guard !lines.isEmpty, lines.count <= maxListLines, lines.allSatisfy(hasListLength) else {
            return false
        }
        return lines.filter(startsLikeEntry).count * 2 >= lines.count
    }

    /// A list of titles without numbers (story titles, illustrations): short
    /// (or all-capital) lines that aren't sentences or lowercase verse. A
    /// stray quoted line is tolerated.
    static func isTitleList(_ paragraph: String) -> Bool {
        let lines = trimmedLines(paragraph)
        guard !lines.isEmpty, lines.count <= maxListLines, lines.allSatisfy(hasListLength) else {
            return false
        }
        let titles = lines.filter {
            ($0.count <= 80 || !$0.contains(where: \.isLowercase))
                && !$0.hasSuffix(",") && !$0.hasSuffix(";") && !$0.hasSuffix(":")
                && !($0.first?.isLowercase ?? false) && !isSentence($0)
        }
        return titles.count * 10 >= lines.count * 9
    }

    /// One Contents entry in its own paragraph: a heading, or a few lines
    /// opening with a section word ("Chapter v -- Containing a few common
    /// matters…"), or a short numbered title.
    static func isContentsEntry(_ paragraph: String) -> Bool {
        guard paragraph.utf8.count <= 12_000 else { return false }
        let lines = trimmedLines(paragraph)
        guard let first = lines.first, lines.count <= 10, lines.allSatisfy(hasListLength) else {
            return false
        }
        if isChapterHeading(paragraph) { return true }
        if first.firstMatch(of: entryWordRegex) != nil || first.firstMatch(of: dittoEntryRegex) != nil {
            return true
        }
        if first.firstMatch(of: entryNumeralRegex) != nil {
            return lines.count <= 2 && !isSentence(lines.joined(separator: " "))
        }
        return false
    }

    /// Running text: mostly lowercase, and either hard-wrapped lines of
    /// prose width or a single line that is a full sentence. A paragraph
    /// longer than any list is always text.
    static func isProse(_ paragraph: String) -> Bool {
        let lines = trimmedLines(paragraph)
        guard !lines.isEmpty, isMostlyLowercase(paragraph), !isContentsEntry(paragraph) else {
            return false
        }
        if lines.count > maxListLines { return true }
        if lines.count >= 2 {
            if lines.filter(startsLikeEntry).count * 2 >= lines.count { return false }
            if lines.dropLast().allSatisfy({ $0.count >= 50 }) { return true }
        } else if isSentence(lines[0]) {
            return true
        }
        return !lines.allSatisfy(hasListLength)
    }

    /// Words a title leaves in lowercase ("The Man of the Hill").
    private static let minorWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "and", "or", "nor", "but", "for", "with",
        "by", "from", "as", "into", "upon", "de", "la", "le", "du", "des", "von", "van",
    ]

    /// Stanza lines, set in sentence case ("Grey are the roofs and grey the
    /// sky"): at least two thirds of the lines have three or more words, two
    /// of them lowercase words that a title would capitalise.
    private static func isVerse(_ paragraph: String) -> Bool {
        let lines = trimmedLines(paragraph)
        guard lines.count >= 2, lines.count <= 60 else { return false }
        let verse = lines.filter { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count >= 3 else { return false }
            return words.dropFirst().filter {
                $0.first?.isLowercase == true && !minorWords.contains($0.lowercased())
            }.count >= 2
        }
        return verse.count * 3 >= lines.count * 2
    }

    /// Some line ends in a page number after a leader ("Loomings ..... 12").
    private static func hasPageNumbers(_ paragraph: String) -> Bool {
        paragraph.utf8.count <= 20_000
            && trimmedLines(paragraph).contains { $0.firstMatch(of: pageNumberRegex) != nil }
    }

    /// The section number `number` standing alone: "I", "I.", "CHAPTER I", "1".
    private static func isBareMarker(_ paragraph: String, number: Int) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 30,
              isChapterHeading(paragraph) || paragraph.wholeMatch(of: bareNumberRegex) != nil else { return false }
        let parts = sectionParts(contentsKey(paragraph))
        return parts.number == number && parts.title.isEmpty
    }

    private static func isHeadingLike(_ paragraph: String) -> Bool {
        guard paragraph.utf8.count <= 1_000 else { return false }
        let lines = trimmedLines(paragraph)
        return lines.count <= 3 && lines.allSatisfy { $0.count <= 80 } && !isProse(paragraph)
    }

    private static let sentenceEndRegex = #/[.!?]["”’)]?$/#

    /// Six or more words ending a sentence, not in Title Case
    /// ("Who Do You Reckon It Is?" is a title).
    private static func isSentence(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 6, line.firstMatch(of: sentenceEndRegex) != nil else { return false }
        let initials = words.compactMap { $0.first { $0.isASCII && $0.isLetter } }
        return initials.filter(\.isUppercase).count * 2 < initials.count
    }

    /// Judged on the first 20,000 characters, which is plenty for a verdict.
    private static func isMostlyLowercase(_ text: String) -> Bool {
        var letters = 0
        var lowercase = 0
        for character in text.prefix(20_000) where character.isLetter {
            letters += 1
            if character.isLowercase { lowercase += 1 }
        }
        return lowercase * 2 >= letters
    }

    /// Column labels over a Contents list ("CHAPTER", "Chapter Page").
    private static let contentsColumnRegex =
        #/(?:chapter|chap|page|pages|part|book)s?\.?(?:\s+(?:page|pages)\.?)?/#.ignoresCase()

    /// A trailing page number after a leader: "Loomings ....... 12".
    private static let pageNumberRegex = #/(?:\s{2,}|\.{2,}\s*|\s\.\s)\d+$/#

    /// Comparable form of an entry or heading: lowercase ASCII words, page
    /// number dropped.
    static func contentsKey(_ text: String) -> String {
        let stripped = text.trimmingCharacters(in: .whitespaces).replacing(pageNumberRegex, with: "")
        return String(stripped.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let sectionWords: Set<Substring> = [
        "chapter", "chap", "book", "part", "volume", "vol", "act", "scene",
        "canto", "letter", "stave", "section",
    ]

    private static let numberWords: [Substring: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "twenty": 20,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
    ]

    /// A key split into its section word, number and title: "chapter iv the
    /// gate" → ("chapter", 4, "the gate"); "xii" → (nil, 12, ""); "book the
    /// first" → ("book", 1, ""); "the gate" → (nil, nil, "the gate").
    static func sectionParts(_ key: String) -> (word: String?, number: Int?, title: String) {
        var tokens = key.split(separator: " ")[...]
        var word: String?
        if let first = tokens.first, sectionWords.contains(first) {
            word = String(first)
            tokens = tokens.dropFirst()
            if tokens.first == "the" { tokens = tokens.dropFirst() }
        }
        guard let token = tokens.first, let number = numberValue(token) else {
            return (word, nil, tokens.joined(separator: " "))
        }
        return (word, number, tokens.dropFirst().joined(separator: " "))
    }

    /// A well-formed roman numeral ("xiv", never "civil").
    private static let romanRegex = #/m{0,3}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})/#

    private static func numberValue(_ token: Substring) -> Int? {
        if token.allSatisfy(\.isNumber) { return token.count <= 4 ? Int(token) : nil }
        if let word = numberWords[token] { return word }
        guard token.count <= 9, token.wholeMatch(of: romanRegex) != nil else { return nil }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var total = 0
        var largest = 0
        for character in token.reversed() {
            guard let value = values[character] else { return nil }
            if value < largest { total -= value } else { total += value; largest = value }
        }
        return total
    }

    private static func trimmedLines(_ paragraph: String) -> [String] {
        paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func lineCount(_ paragraph: String) -> Int {
        paragraph.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    private static func wordCount(_ paragraph: String) -> Int {
        paragraph.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Chapter detection

    private static let headingRegex =
        #/^(?:CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act|PROLOGUE|Prologue|EPILOGUE|Epilogue)\b|^[IVXLC]+\.?$/#

    /// First line of a multi-line heading: the marker alone, or followed by a
    /// numeral or number word ("CHAPTER I.", "BOOK THE SECOND", "PART ONE")
    /// — never prose that opens with "Part of…", "Part. The moment is now",
    /// or a note citing "Chapter XV, paragraph 12".
    private static let headingFirstLineRegex =
        #/^(?:(?:CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act)(?:\s*$|[\s.:—–-]+(?!\w*,)(?:(?:[IVXLCDM]+|[ivxlc]+|\d+)\b|(?i:(?:the\s+)?(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|twentieth|thirtieth|fortieth|fiftieth|last|final))\b))|PROLOGUE|Prologue|EPILOGUE|Epilogue|[IVXLC]+\.?$)/#

    /// Prose after the marker: a full stop followed by a lowercase word
    /// ("BOOK II "Both to frequent" (4). Gr. τὸ μή…", an endnote).
    private static let midSentenceRegex = #/[.!?]["”’)]?\s+\p{Ll}/#

    /// The number runs straight on in lowercase ("Book 9 of the meeting…",
    /// "Part the second commenced…"): a heading only when the line is short
    /// and unpunctuated ("Part Three of the Current Novel").
    private static let runOnRegex =
        #/^(?:CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act)[\s.:—–-]+(?:(?i:the)\s+)?\w+[ \t]+[a-z]/#

    private static func isRunOnProse(_ line: String) -> Bool {
        line.firstMatch(of: runOnRegex) != nil
            && (line.count > 50 || line.contains(where: { ".!?;".contains($0) }))
    }

    /// A heading is a short paragraph that looks like a section marker
    /// ("CHAPTER I", "Part 2. The Return", "XII."). Its title may sit on the
    /// next line or two ("CHAPTER I.\nDown the Rabbit-Hole") — a title, not
    /// more entries, as in a play's "ACT I\nScene I. …\nScene II. …" list.
    static func isChapterHeading(_ paragraph: String) -> Bool {
        // Pepys' "JANUARY 1659-1660" and War and Peace's "FIRST EPILOGUE:
        // 1813 - 20" start with letters the cheap exit turns away. One short
        // all-caps line only, so prose dates ("March 1660 was cold.") and
        // "First epilogue of the play" stay body text. The first-word switch
        // keeps the regexes off every "CHAPTER I".
        if paragraph.utf8.count <= 80, !paragraph.contains("\n") {
            let line = paragraph.trimmingCharacters(in: .whitespaces)
            if line.count <= 40 {
                switch line.prefix(while: \.isLetter) {
                case "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST",
                     "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER":
                    if line == line.uppercased(),
                       line.firstMatch(of: #/^(?:JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+\d{4}(?:\s*[-–]\s*\d{2,4})?\.?$/#) != nil {
                        return true
                    }
                case "FIRST", "SECOND", "THIRD", "FOURTH", "FINAL", "LAST":
                    if line == line.uppercased(),
                       line.firstMatch(of: #/^(?:FIRST|SECOND|THIRD|FOURTH|FINAL|LAST)\s+(?:EPILOGUE|PROLOGUE)\b/#) != nil {
                        return true
                    }
                default:
                    break
                }
            }
        }
        // Cheap exit for body text: every marker starts with one of these.
        guard paragraph.utf8.count <= 600,
              let initial = paragraph.first(where: { !$0.isWhitespace }),
              "CBPAEIVXL".contains(initial) else { return false }
        let newlines = paragraph.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        guard newlines <= 2 else { return false }
        if newlines == 0 {
            let line = paragraph.first?.isWhitespace == true
                ? paragraph.trimmingCharacters(in: .whitespaces) : paragraph
            // "CHAPTER IV.–Treaty of 1804      34" is a Contents line, not a heading.
            return line.count <= 80 && line.firstMatch(of: pageNumberRegex) == nil
                && line.firstMatch(of: headingRegex) != nil
        }
        let lines = trimmedLines(paragraph)
        guard let first = lines.first, lines.count <= 3, lines.allSatisfy({ $0.count <= 80 }),
              paragraph.firstMatch(of: pageNumberRegex) == nil else {
            return false
        }
        return first.firstMatch(of: headingFirstLineRegex) != nil
            && first.firstMatch(of: midSentenceRegex) == nil && !isRunOnProse(first)
            && !lines.dropFirst().contains(where: startsLikeEntry)
            && !lines.dropFirst().contains(where: { $0.wholeMatch(of: pageColumnRegex) != nil })
    }

    /// A Contents column label under a part heading ("PART I.\nPAGE").
    private static let pageColumnRegex = #/(?:(?:chapter|chap|part|book)s?\.?\s+)?(?:pages?|pp?)\.?/#.ignoresCase()

    /// Whether a heading starts a page. One whose title runs onto a second
    /// line ("CHAPTER XL. FIRST MEETING WITH …\n…") does only when the book's
    /// text follows it — not when more entries or a list with page numbers
    /// do, as in a Contents printed inside the book (Grant's second volume)
    /// or a list of verse interludes under each "BOOK I.\nTHE SORROWS …",
    /// nor when it ends a run of entries. A heading over another heading
    /// ("PART ONE" over "CHAPTER I.\n…") still does.
    private static func headsText(_ index: Int, in paragraphs: [String]) -> Bool {
        guard paragraphs[index].contains("\n") else { return true }
        func isEntry(_ paragraph: String) -> Bool {
            isContentsEntry(paragraph) || isChapterHeading(paragraph)
                || (paragraph.contains("\n") && isContentsList(paragraph))
        }
        // The last of a run of two-line entries, over the body's first heading.
        if index >= 2, paragraphs[(index - 2)..<index].allSatisfy({ $0.contains("\n") && isChapterHeading($0) }) {
            return false
        }
        var entries = 0
        for next in paragraphs[(index + 1)..<min(index + 7, paragraphs.count)] {
            if hasPageNumbers(next) { return false }
            if isEntry(next) {
                entries += 1
                if entries == 2 { return false }
            } else if isRunningText(next) {
                return true
            }
        }
        return entries == 0
    }

    // MARK: - Italics

    /// Gutenberg plain text marks italics as _word_; the reader shows text
    /// verbatim, so the markers go. "snake_case" and "____" blanks stay.
    /// A pair is an underscore after a non-word character (or at the start),
    /// the next underscore before a non-word character (or at the end), and
    /// between them text that neither starts nor ends with a space — the same
    /// pairs as the pattern `(^|[^\w])_([^\s_](?:[^_]*[^\s_])?)_(?!\w)`,
    /// found in one pass instead of by a regex.
    static func strippingItalicMarkers(_ paragraph: String) -> String {
        let utf8 = paragraph.utf8
        guard utf8.contains(0x5F) else { return paragraph }
        // Underscores that are characters of their own: not "_" + a combining
        // mark, nor inside a cluster that a prepended mark (U+0600) opens,
        // where stepping back from the underscore would leave the string.
        let marks = utf8.indices.filter {
            utf8[$0] == 0x5F && String.Index($0, within: paragraph) != nil && paragraph[$0] == "_"
        }
        func isWord(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        var result = ""
        var copied = paragraph.startIndex
        var next = 0
        while next + 1 < marks.count {
            let open = marks[next], close = marks[next + 1]
            let afterOpen = paragraph.index(after: open)
            if afterOpen < close,
               open == paragraph.startIndex || !isWord(paragraph[paragraph.index(before: open)]),
               !paragraph[afterOpen].isWhitespace,
               !paragraph[paragraph.index(before: close)].isWhitespace {
                let afterClose = paragraph.index(after: close)
                if afterClose == paragraph.endIndex || !isWord(paragraph[afterClose]) {
                    result += paragraph[copied..<open]
                    result += paragraph[afterOpen..<close]
                    copied = afterClose
                    next += 2
                    continue
                }
            }
            next += 1
        }
        guard copied != paragraph.startIndex else { return paragraph }
        result += paragraph[copied...]
        return result
    }

    // MARK: - Reading

    private static func read(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        // UTF-8 with a few stray Windows bytes (a ’ pasted in from Word).
        if let data = try? Data(contentsOf: url), let text = repairingStrayBytes(data) { return text }
        // Windows "ANSI" text: CP1252 has curly quotes and dashes at
        // 0x80–0x9F, where Latin-1 has control characters the normalizer
        // deletes. Latin-1 remains for the five bytes CP1252 leaves undefined.
        if let text = try? String(contentsOf: url, encoding: .windowsCP1252) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        throw ExtractionError.unreadableTextFile
    }

    /// Windows-1252 at 0x80–0x9F; zero where it leaves a byte undefined.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    /// Mostly-UTF-8 data with a few invalid bytes: valid sequences decode as
    /// UTF-8 and each stray byte as Windows-1252 (Latin-1 where 1252 has no
    /// character). Nil unless valid multi-byte sequences outnumber the stray
    /// bytes — a genuine Windows-1252 file has almost none, and is decoded
    /// whole as 1252 instead.
    static func repairingStrayBytes(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var scalars = String.UnicodeScalarView()
        var multiByte = 0
        var stray = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                scalars.append(Unicode.Scalar(byte))
                index += 1
            } else if let (scalar, length) = utf8Sequence(bytes, at: index) {
                scalars.append(scalar)
                multiByte += 1
                index += length
            } else {
                let mapped = byte < 0xA0 ? cp1252High[Int(byte) - 0x80] : 0
                scalars.append(Unicode.Scalar(mapped == 0 ? UInt32(byte) : mapped) ?? Unicode.Scalar(byte))
                stray += 1
                index += 1
            }
        }
        guard stray > 0, multiByte > stray else { return nil }
        return String(scalars)
    }

    /// One well-formed UTF-8 multi-byte sequence at `index` (no overlongs or
    /// surrogates), as a scalar and its length.
    private static func utf8Sequence(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        let length: Int
        var value: UInt32
        var lowest: UInt8 = 0x80, highest: UInt8 = 0xBF
        switch lead {
        case 0xC2...0xDF: length = 2; value = UInt32(lead & 0x1F)
        case 0xE0: length = 3; value = 0; lowest = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3; value = UInt32(lead & 0x0F)
        case 0xED: length = 3; value = 0x0D; highest = 0x9F
        case 0xF0: length = 4; value = 0; lowest = 0x90
        case 0xF1...0xF3: length = 4; value = UInt32(lead & 0x07)
        case 0xF4: length = 4; value = 4; highest = 0x8F
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        for offset in 1..<length {
            let byte = bytes[index + offset]
            let range = offset == 1 ? lowest...highest : 0x80...0xBF
            guard range.contains(byte) else { return nil }
            value = value << 6 | UInt32(byte & 0x3F)
        }
        return Unicode.Scalar(value).map { ($0, length) }
    }
}
