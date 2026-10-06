import Foundation

/// Rows from running headers, for a PDF with neither an outline nor chapter
/// headings: the layout where every recto carries the chapter's title at the
/// top ("TINY SPECK 63") and every verso the book's ("THE COLD START
/// PROBLEM"). Found The Cold Start Problem's 40 rows under 6 Parts with no
/// false positives; a book without that layout fails the gate and falls
/// through to page ranges.
///
/// 1. A page's header is the one the extractor took off its top
///    (`DocContent.pageHeaders`) or, in content extracted before it did,
///    its first paragraph when that is one short caps sentence; its key
///    drops a leading or trailing page number. A header
///    the extractor glued onto the previous page's run-on sentence ("In
///    contemporary par- WHAT'S A NETWORK EFFECT, ANYWAY?") counts for the
///    next page.
/// 2. Keys on at least a fifth of the pages, or equal to the title, are the
///    book's own (ignored).
/// 3. Chapter keys are seen on two pages, or once with a title page just
///    before; a key whose pages lie inside another key's run is dropped.
/// 4. A chapter starts at its title page: the page whose leading caps lines
///    read as the key (a prefix such as CONCLUSION becomes a label).
/// 5. Stacked caps title pages without any header (ABOUT THE / AUTHOR) are
///    chapters too; PART pages open sections.
/// 6. Gate: most body pages carry a header, most starts have a title page,
///    at least three chapters, none holding half the book.
enum RunningHeaderChapters {

    static let maxHeaderWords = 10
    static let constantShare = 0.2
    static let minimumCoverage = 0.6
    static let minimumConfirmed = 0.5
    static let minimumChapters = 3
    static let maximumShare = 0.5

    private struct Found {
        let key: String
        let page: Int
        let sentence: Int
        let confirmed: Bool
        let label: String?
        let lastPage: Int
    }

    static func entries(in content: DocContent) -> [ChapterMap.Entry]? {
        let sentences = content.sentences
        guard !sentences.isEmpty, !content.paragraphs.isEmpty else { return nil }

        var parasByPage: [Int: [Paragraph]] = [:]
        for paragraph in content.paragraphs where !paragraph.sentenceIDs.isEmpty {
            parasByPage[paragraph.page, default: []].append(paragraph)
        }
        let pages = parasByPage.keys.sorted()
        func text(_ paragraph: Paragraph) -> String { ChapterText.paragraphText(paragraph, in: content) }
        func isOneLine(_ paragraph: Paragraph) -> Bool { paragraph.sentenceIDs.count == 1 }

        // Part pages: the page's only paragraph is one caps PART/BOOK line.
        var partTitleByPage: [Int: String] = [:]
        for page in pages {
            guard let paras = parasByPage[page], paras.count == 1, isOneLine(paras[0]) else { continue }
            let line = text(paras[0])
            if isCapsLine(line, maxWords: 12), let title = partTitle(line) { partTitleByPage[page] = title }
        }

        // 1. Page-top header candidates, and headers stitched onto the
        //    previous page's last paragraph.
        var headerAt: [Int: String] = [:]
        for page in pages where partTitleByPage[page] == nil {
            if let header = content.pageHeaders?[page] {
                let headerKey = Self.key(of: header)
                if isCapsLine(header, maxWords: maxHeaderWords), headerKey.count >= 2, !isPageNumber(headerKey) {
                    headerAt[page] = headerKey
                }
                continue
            }
            guard let first = parasByPage[page]?.first, isOneLine(first) else { continue }
            let line = text(first)
            guard isCapsLine(line, maxWords: maxHeaderWords) else { continue }
            let headerKey = Self.key(of: line)
            if headerKey.count >= 2, !isPageNumber(headerKey) { headerAt[page] = headerKey }
        }
        var counts: [String: Int] = [:]
        for key in headerAt.values { counts[key, default: 0] += 1 }
        var stitched: [Int: String] = [:]
        let known = counts.keys.filter { $0.count >= 6 }.sorted { $0.count > $1.count }
        if !known.isEmpty {
            for sentence in sentences {
                let original = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = original.uppercased()
                for key in known where upper.hasSuffix(" " + key) {
                    if ChapterText.capsRatio(original.suffix(key.count)) >= 0.8,
                       let next = Self.firstPage(after: sentence.page, in: pages), headerAt[next] == nil {
                        stitched[next] = key
                    }
                    break
                }
            }
        }
        for key in stitched.values { counts[key, default: 0] += 1 }

        // 2. The book's own headers.
        let titleKey = Self.key(of: content.title)
        let constant = Set(counts.filter {
            Double($0.value) >= constantShare * Double(pages.count) || $0.key == titleKey
        }.keys)
        var occurrences: [String: [Int]] = [:]
        for (page, key) in headerAt where !constant.contains(key) { occurrences[key, default: []].append(page) }
        for (page, key) in stitched where !constant.contains(key) { occurrences[key, default: []].append(page) }

        func capsStack(_ page: Int, maxWords: Int) -> (lines: [String], paragraphCount: Int) {
            let paras = parasByPage[page] ?? []
            var lines: [String] = []
            for paragraph in paras.prefix(6) {
                let line = text(paragraph)
                guard isOneLine(paragraph), isCapsLine(line, maxWords: maxWords),
                      !ChapterText.hasLeader(line), !ChapterText.endsWithPageNumber(line) else { break }
                lines.append(line)
            }
            return (lines, paras.count)
        }

        /// The first page in `range` whose title stack reads as `key`, and
        /// the label a longer stack puts before it.
        func titlePage(for key: String, in range: ClosedRange<Int>) -> (page: Int, label: String?)? {
            for page in range where parasByPage[page] != nil && partTitleByPage[page] == nil {
                let stack = capsStack(page, maxWords: 6).lines
                guard !stack.isEmpty else { continue }
                let joined = Self.key(of: stack.joined(separator: " "))
                if joined == key { return (page, nil) }
                if joined.hasSuffix(" " + key) {
                    let label = String(joined.dropLast(key.count)).trimmingCharacters(in: .whitespaces)
                    return (page, label.isEmpty ? nil : label)
                }
                // A caps subtitle stacked under the title ("ROCKETSHIP GROWTH T2D3").
                if joined.hasPrefix(key + " ") { return (page, nil) }
            }
            return nil
        }

        // 3. Chapter keys.
        var keyPages: [String: [Int]] = [:]
        for (key, seen) in occurrences {
            let sorted = seen.sorted()
            guard let first = sorted.first else { continue }
            let before = max(1, first - 4)...max(1, first - 1)
            if sorted.count >= 2 || (first - 1 >= before.lowerBound && titlePage(for: key, in: before) != nil) {
                keyPages[key] = sorted
            }
        }
        let ordered = keyPages.keys.sorted { (keyPages[$0]![0], $0) < (keyPages[$1]![0], $1) }
        let kept = ordered.filter { key in
            let run = keyPages[key]!
            return !ordered.contains { other in
                let outer = keyPages[other]!
                return other != key && outer[0] < run[0] && run[run.count - 1] < outer[outer.count - 1]
            }
        }

        // 4. Starts: the title page between the previous chapter's last
        //    header page and this one's first.
        var found: [Found] = []
        var previousLast = 0
        for key in kept {
            let run = keyPages[key]!
            let first = run[0]
            let low = min(previousLast + 1, first)
            let start: Int
            var label: String?
            var confirmed = false
            if let hit = titlePage(for: key, in: low...first) {
                start = hit.page
                label = hit.label
                confirmed = true
            } else {
                start = (low...first).first { page in
                    parasByPage[page] != nil && partTitleByPage[page] == nil && stitched[page] == nil
                        && (headerAt[page].map { (counts[$0] ?? 0) < 2 } ?? true)
                } ?? first
            }
            if let sentence = parasByPage[start]?.first?.sentenceIDs.lowerBound {
                found.append(Found(key: key, page: start, sentence: sentence, confirmed: confirmed,
                                   label: label, lastPage: run[run.count - 1]))
            }
            previousLast = run[run.count - 1]
        }

        // 5. Stacked title pages with no header of their own.
        let used = Set(found.map(\.page))
        for page in pages where !used.contains(page) && partTitleByPage[page] == nil {
            if let key = headerAt[page], (counts[key] ?? 0) >= 2 { continue }
            let stack = capsStack(page, maxWords: 4)
            guard stack.lines.count >= 2, stack.paragraphCount > stack.lines.count,
                  let sentence = parasByPage[page]?.first?.sentenceIDs.lowerBound else { continue }
            found.append(Found(key: Self.key(of: stack.lines.joined(separator: " ")), page: page,
                               sentence: sentence, confirmed: true, label: nil, lastPage: page))
        }
        found.sort { $0.sentence < $1.sentence }

        // 6. Gate.
        guard found.count >= minimumChapters,
              let bodyStart = found.first?.page,
              let bodyEnd = found.map(\.lastPage).max() else { return nil }
        let body = pages.filter { $0 >= bodyStart && $0 <= bodyEnd }
        let headed = body.filter { page in
            if stitched[page] != nil { return true }
            guard let key = headerAt[page] else { return false }
            return constant.contains(key) || keyPages[key] != nil
        }
        let coverage = Double(headed.count) / Double(max(1, body.count))
        let confirmed = Double(found.filter(\.confirmed).count) / Double(found.count)
        let starts = found.map(\.sentence) + [sentences.count]
        let biggest = zip(starts, starts.dropFirst()).map { $1 - $0 }.max() ?? 0
        let share = Double(biggest) / Double(sentences.count)
        guard coverage >= minimumCoverage, confirmed >= minimumConfirmed, share <= maximumShare else { return nil }

        let entries = found.map { chapter -> ChapterMap.Entry in
            let title = chapter.label.map { "\(displayTitle($0)): \(displayTitle(chapter.key))" }
                ?? displayTitle(chapter.key)
            return ChapterMap.Entry(title: title, sentence: chapter.sentence, section: nil)
        }
        var parts: [(sentence: Int, title: String)] = []
        for (page, title) in partTitleByPage {
            if let first = parasByPage[page]?.first { parts.append((first.sentenceIDs.lowerBound, title)) }
        }
        return PDFChapterDetector.applyingSections(to: entries, parts: parts)
    }

    // MARK: Keys and titles

    /// A header's identity: one leading or trailing page number dropped
    /// ("TINY SPECK 63", "xii PREFACE"), whitespace collapsed, uppercased,
    /// end dots trimmed.
    static func key(of text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1, let last = words.last, isPageNumber(last) { words.removeLast() }
        if words.count > 1, let first = words.first, isPageNumber(first) { words.removeFirst() }
        return words.joined(separator: " ").uppercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// "PART II THE COLD START PROBLEM" → "Part II: The Cold Start Problem";
    /// nil for anything that isn't a Part or Book heading.
    static func partTitle(_ text: String) -> String? {
        let line = ChapterText.collapsed(text).uppercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard let match = line.wholeMatch(of: partLine) else { return nil }
        let kind = String(match.1) == "BOOK" ? "Book" : "Part"
        let number = String(match.2)
        let shown = number.allSatisfy(\.isNumber) || number.allSatisfy({ "IVXLC".contains($0) })
            ? number : String(number.prefix(1)) + number.dropFirst().lowercased()
        let rest = String(match.3).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? "\(kind) \(shown)" : "\(kind) \(shown): \(displayTitle(rest))"
    }

    /// An all-caps header in display case: every word capitalized, small
    /// words lowercased but for the first, short roman numerals and short
    /// vowel-less words (TV, PR) kept in caps; each part of a hyphenated word
    /// too ("ANTI-NETWORK" → "Anti-Network"). Mixed-case text is returned as
    /// it is.
    static func displayTitle(_ caps: String) -> String {
        guard ChapterText.capsRatio(caps) >= 0.8 else { return caps }
        var words: [String] = []
        for (wordIndex, word) in caps.split(whereSeparator: \.isWhitespace).enumerated() {
            var parts: [String] = []
            for (partIndex, part) in word.split(separator: "-", omittingEmptySubsequences: false).enumerated() {
                let core = part.filter(\.isLetter)
                let isFirst = wordIndex == 0 && partIndex == 0
                if core.isEmpty {
                    parts.append(String(part))
                } else if core.count <= 4, core != "I", core.allSatisfy({ "IVXLC".contains($0) }) {
                    parts.append(String(part))
                } else if !isFirst, smallWords.contains(core.lowercased()) {
                    parts.append(part.lowercased())
                } else if core.count <= 3, !core.contains(where: { "AEIOUY".contains($0) }) {
                    parts.append(String(part))
                } else {
                    let lower = part.lowercased()
                    if let letter = lower.firstIndex(where: \.isLetter) {
                        parts.append(String(lower[..<letter]) + lower[letter].uppercased()
                                     + String(lower[lower.index(after: letter)...]))
                    } else {
                        parts.append(lower)
                    }
                }
            }
            words.append(parts.joined(separator: "-"))
        }
        return words.joined(separator: " ")
    }

    // MARK: Helpers

    private static func isCapsLine(_ text: String, maxWords: Int) -> Bool {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return count > 0 && count <= maxWords && ChapterText.capsRatio(text) >= 0.8
    }

    private static func isPageNumber<S: StringProtocol>(_ word: S) -> Bool {
        (word.count <= 4 && !word.isEmpty && word.allSatisfy(\.isNumber)) || ChapterText.isRomanNumeral(word)
    }

    /// The first page with text after `page`.
    private static func firstPage(after page: Int, in pages: [Int]) -> Int? {
        var low = 0
        var high = pages.count
        while low < high {
            let mid = (low + high) / 2
            if pages[mid] <= page { low = mid + 1 } else { high = mid }
        }
        return low < pages.count ? pages[low] : nil
    }

    private static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or",
        "over", "the", "to", "versus", "via", "vs", "with",
    ]

    private static let partLine =
        #/(PART|BOOK)\s+([IVXLC]+|\d+|ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)\b[\s.:\-]*(.*)/#
}
