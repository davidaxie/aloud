import Foundation
import PDFKit

/// Extraction failure taxonomy, shared by the PDF and plain-text extractors.
/// Carries no user-facing text: ImportFailure owns the copy (R10).
enum ExtractionError: Error, Equatable {
    case invalidPDF
    case passwordProtected
    case emptyDocument
    case noReadableText
    case unreadableTextFile
}

/// A reconstructed paragraph plus the 1-based page it starts on.
struct TextBlock {
    let text: String
    let page: Int
}

/// PDFKit port of `frontend/src/lib/pdf.ts`: recovers layout by sampling
/// `characterBounds(at:)` per whitespace-delimited run, clusters runs into
/// baselines, folds lines into paragraphs, strips running headers/footers and
/// page numbers, de-hyphenates line wraps, and stitches paragraphs across
/// page breaks. Pure and synchronous; runs inside `ExtractionPipeline`.
struct PDFTextExtractor {

    struct Output {
        let title: String?
        let pageCount: Int
        let blocks: [TextBlock]
        /// The PDF's outline (bookmarks), read while the document is open,
        /// for `PDFChapterDetector`. Empty when it has none.
        var outline: [PDFOutlineItem] = []
        /// The running header taken off the top of each page, by 1-based
        /// page, normalized: gone from `blocks`, kept for the running-header
        /// chapter tier, which reads chapter titles from them.
        var pageHeaders: [Int: String] = [:]
    }

    func extract(url: URL, progress: ((Double) -> Void)? = nil) throws -> Output {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.invalidPDF
        }
        if document.isLocked || (document.isEncrypted && !document.unlock(withPassword: "")) {
            throw ExtractionError.passwordProtected
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ExtractionError.emptyDocument }

        // Pass 1: per-page line reconstruction (needed before header detection).
        var pageLines: [[Line]] = []
        pageLines.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            try Task.checkCancellation()
            if let page = document.page(at: index) {
                pageLines.append(Self.lines(of: page))
            } else {
                pageLines.append([])
            }
            progress?(Double(index + 1) / Double(pageCount))
        }

        // Detect repeating headers/footers: across the whole document, and
        // per page for the ones that run through a chapter or alternate.
        let running = Self.runningHeadersByPage(pageLines)
        let romanFolios = Self.romanFolioLines(pageLines)

        // Pass 2: strip noise, fold into paragraphs, stitch across pages.
        var blocks: [TextBlock] = []
        var pageHeaders: [Int: String] = [:]
        var pagesWithText = 0
        for (index, lines) in pageLines.enumerated() {
            if let header = Self.topHeader(lines, running: running[index]) {
                pageHeaders[index + 1] = header
            }
            let cleaned = Self.stripNoise(lines, running: running[index], romanFolios: romanFolios[index])
            let paragraphs = Self.paragraphs(from: cleaned)
            if !paragraphs.isEmpty { pagesWithText += 1 }
            Self.appendPageParagraphs(&blocks, paragraphs, page: index + 1)
        }
        // A scan whose only text layer is a cover sheet or a usage notice
        // reads as having no text, not as a book of a few sentences.
        if Self.isMostlyScanned(pagesWithText: pagesWithText, pageCount: pageCount) {
            throw ExtractionError.noReadableText
        }

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || Self.isPlaceholderTitle($0) ? nil : $0 }

        return Output(title: title, pageCount: pageCount, blocks: blocks,
                      outline: PDFChapterDetector.outlineItems(of: document),
                      pageHeaders: pageHeaders)
    }

    /// Five or more pages, under a tenth of them with text: page images
    /// with a text page or two.
    static func isMostlyScanned(pagesWithText: Int, pageCount: Int) -> Bool {
        pageCount >= 5 && pagesWithText * 10 < pageCount
    }

    /// A Title the authoring tool wrote rather than the author: Word's
    /// "Microsoft Word - draft.docx", "Untitled-1", "Document1", a file
    /// name. The picked file's name is the better title.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.firstMatch(of: placeholderTitle) != nil
    }

    private static let placeholderTitle =
        #/(?i)^(?:microsoft\s+(?:word|powerpoint|excel)\s+-\s.*|untitled(?:[\s_-]*\d+)?|document\s*\d*|powerpoint\s+presentation|presentation\s*\d*|.*\.(?:docx?|pptx?|xlsx?|rtf|odt|pages|key|indd|qxd|tex|dvi|ps|txt|pdf))$/#

    // MARK: - Geometry types

    struct Line {
        let text: String
        let y: CGFloat      // top edge in page space — a LARGER y is HIGHER
        let height: CGFloat // line box height (≈ font size + leading)
        var minX: CGFloat = 0 // left edge of the first glyph, for first-line indents
        var maxX: CGFloat = 0 // right edge of the last glyph, for short last lines
    }

    // MARK: - Selections → lines

    /// Reconstruct a page's visual lines via `PDFSelection.selectionsByLine()`,
    /// which yields one selection per rendered line with reliable bounds.
    /// (Per-character `characterBounds(at:)` sampling was tried first, but its
    /// index basis drifts from `page.string` offsets at line breaks.)
    static func lines(of page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }

        var lines: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            guard let raw = lineSelection.string else { continue }
            let text = sanitize(raw)
                .replacing(#/[ \t]{2,}/#, with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let bounds = lineSelection.bounds(for: page)
            lines.append(Line(text: text,
                              y: bounds.maxY,
                              height: bounds.height > 0 ? bounds.height : 8,
                              minX: bounds.minX,
                              maxX: bounds.maxX))
        }
        // Top-to-bottom reading order (multi-column layouts remain a known
        // limitation, as on the web).
        return lines.sorted { $0.y > $1.y }
    }

    // MARK: - Lines → paragraphs

    /// Fold a page's lines into paragraphs: a break is a vertical gap
    /// noticeably (> 1.6x) larger than the page's typical leading, or a
    /// first-line indent (`indentBreaks`). Wrapped lines are joined with
    /// conservative de-hyphenation, and every folded paragraph is
    /// normalized so the stitching heuristics see plain ASCII.
    static func paragraphs(from lines: [Line]) -> [String] {
        guard !lines.isEmpty else { return [] }

        let typical = typicalGap(lines)
        let indented = indentBreaks(lines)

        var paragraphs: [String] = []
        var buffer = ""
        for (i, line) in lines.enumerated() {
            let gapBefore = i == 0 ? 0 : lines[i - 1].y - line.y
            let isNewParagraph = i > 0 && (gapBefore > typical * 1.6 || indented.contains(i))
            if isNewParagraph && !buffer.isEmpty {
                paragraphs.append(buffer)
                buffer = ""
            }
            buffer = buffer.isEmpty ? line.text : appendLine(buffer, line.text)
        }
        if !buffer.isEmpty { paragraphs.append(buffer) }

        return paragraphs
            .map { paragraph in
                // normalize() deletes soft hyphens; keep a trailing one so the
                // next page's opening can still rejoin "inter\u{AD}" + "national".
                let normalized = TextNormalizer.normalize(paragraph)
                return endsInSoftHyphen(paragraph) ? normalized + "\u{00AD}" : normalized
            }
            .filter { !$0.isEmpty }
    }

    /// The page's usual line-to-line distance: a paragraph break is a gap
    /// over 1.6 times it.
    static func typicalGap(_ lines: [Line]) -> CGFloat {
        guard let first = lines.first else { return 0 }
        var gaps: [CGFloat] = []
        for i in lines.indices.dropFirst() {
            gaps.append(lines[i - 1].y - lines[i].y)
        }
        let medianGap = median(gaps)
        return medianGap != 0 ? medianGap : first.height * 1.2
    }

    /// The lines that open a paragraph by a first-line indent alone, as a
    /// typeset book sets them, with even leading and no space between. Only
    /// on a page where at least half the lines start at one margin: a line
    /// set in by the page's usual indent (half a line to four lines high)
    /// after one that ended a sentence or, in justified text, stopped short
    /// of the right edge. Lines that share the inset and run on (a block
    /// quote) stay together; a centred heading sits further in.
    static func indentBreaks(_ lines: [Line]) -> Set<Int> {
        guard lines.count >= 3 else { return [] }
        let height = median(lines.map(\.height))
        let tolerance = max(1.5, height * 0.15)
        guard let margin = mostCommon(lines.map(\.minX)) else { return [] }
        let atMargin = lines.filter { abs($0.minX - margin) <= tolerance }.count
        let insets = lines.map(\.minX).filter { $0 - margin > height * 0.5 && $0 - margin < height * 4 }
        guard atMargin * 2 >= lines.count, let indent = mostCommon(insets),
              let right = mostCommon(lines.map(\.maxX)) else { return [] }
        let justified = lines.filter { abs($0.maxX - right) <= tolerance }.count * 2 >= lines.count
        func isIndented(_ line: Line) -> Bool { abs(line.minX - indent) <= tolerance }

        var breaks = Set<Int>()
        for i in lines.indices.dropFirst() where isIndented(lines[i]) {
            let previous = lines[i - 1]
            let stopsShort = justified && previous.maxX < right - height && !isIndented(previous)
            if looksFinished(previous.text) || stopsShort { breaks.insert(i) }
        }
        return breaks
    }

    /// Append a wrapped line, de-hyphenating words broken across the break.
    /// A soft hyphen only ever marks a break inside a word, so any script's
    /// "Schwarzwäl\u{AD}" + "der" is joined here. A normal hyphen after an
    /// ASCII letter, before a lowercase one, is kept with a line break
    /// ("inter-⏎national"): `TextNormalizer.normalize`, which runs on every
    /// folded paragraph and stitched block, re-joins a syllable split and
    /// keeps a compound wrapped at its own hyphen ("well-⏎known").
    static func appendLine(_ buffer: String, _ next: String) -> String {
        let nextTrim = next.replacing(#/^\s+/#, with: "")
        if buffer.firstMatch(of: #/[A-Za-z]-$/#) != nil && nextTrim.firstMatch(of: #/^[a-z]/#) != nil {
            return buffer + "\n" + nextTrim
        }
        if endsInSoftHyphen(buffer) && nextTrim.firstMatch(of: #/^\p{Ll}/#) != nil {
            return buffer.replacing(#/\u{00AD}$/#, with: "") + nextTrim
        }
        let head = buffer.replacing(#/\s+$/#, with: "")
        // Chinese and Japanese put no space between words: a wrap there
        // is no word break. (Korean does space its words.)
        if let last = head.unicodeScalars.last, let first = nextTrim.unicodeScalars.first,
           isUnspacedCJK(last), isUnspacedCJK(first) {
            return head + nextTrim
        }
        return head + " " + nextTrim
    }

    /// Han, kana, and the CJK and fullwidth punctuation set between them.
    static func isUnspacedCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF01...0xFF60, 0xFF65...0xFF9F,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Chinese or Japanese on both sides of a page break: Han and kana
    /// have no case, so the lowercase test can't see a sentence go on.
    static func continuesUnspacedCJK(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.replacing(#/\s+$/#, with: "").unicodeScalars.last,
              let first = next.unicodeScalars.first else { return false }
        return isUnspacedCJK(last) && isUnspacedCJK(first)
    }

    /// A letter of any script, then a soft hyphen, at the very end.
    static func endsInSoftHyphen(_ text: String) -> Bool {
        text.firstMatch(of: #/\p{L}\u{00AD}$/#) != nil
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The most frequent value to the nearest point (the smaller on a tie).
    private static func mostCommon(_ values: [CGFloat]) -> CGFloat? {
        let counts = Dictionary(values.map { ($0.rounded(), 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    // MARK: - Header / footer / page-number stripping

    /// Purely a page number: up to four digits or a well-formed roman
    /// numeral ("xii"; not "Did" or "vivid", spelled with its letters).
    static func isPageNumberLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.wholeMatch(of: #/\d{1,4}/#) != nil || ChapterText.isRomanNumeral(t)
    }

    /// A well-formed roman numeral's value ("xiv" is 14), else nil.
    static func romanValue(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChapterText.isRomanNumeral(t) else { return nil }
        let digits = t.uppercased().compactMap { romanDigits[$0] }
        return digits.indices.reduce(0) { total, i in
            i + 1 < digits.count && digits[i] < digits[i + 1] ? total - digits[i] : total + digits[i]
        }
    }

    private static let romanDigits: [Character: Int] =
        ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]

    /// Each page's edge lines that are roman folios: a roman numeral with
    /// another on a page up to two away, at about the same height, that
    /// counts on by the pages between, as front matter numbers its pages
    /// ("vii", "viii"). A bare "II" opening a chapter has none, so it stays.
    static func romanFolioLines(_ pageLines: [[Line]]) -> [Set<Int>] {
        let numerals = pageLines.map { lines in
            let n = lines.count
            return Set([0, 1, n - 2, n - 1]).filter { $0 >= 0 && $0 < n }.compactMap { index in
                romanValue(lines[index].text).map { (index: index, line: lines[index], value: $0) }
            }
        }
        return numerals.indices.map { page in
            let nearby = max(0, page - 2)...min(numerals.count - 1, page + 2)
            return Set(numerals[page].filter { numeral in
                nearby.contains { other in
                    other != page && numerals[other].contains {
                        abs($0.line.y - numeral.line.y) <= max(2, numeral.line.height * 0.25)
                            && $0.value - numeral.value == other - page
                    }
                }
            }.map(\.index))
        }
    }

    /// Normalize a header/footer candidate so "Page 3" and "Page 4" collapse.
    static func normalizeRunning(_ text: String) -> String {
        text.lowercased()
            .replacing(#/\d+/#, with: "#")
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detect running headers/footers: an outer-edge line whose normalized form
    /// repeats across at least half the pages (min 2). Only meaningful for
    /// documents of 3+ pages. Each page contributes a candidate line once,
    /// even when the edge windows overlap on short pages.
    static func detectRunningHeaders(_ pageLines: [[Line]]) -> Set<String> {
        let pages = pageLines.count
        guard pages >= 3 else { return [] }

        var counts: [String: Int] = [:]
        var texts: [String: [String]] = [:]
        for lines in pageLines {
            let n = lines.count
            // Outer two lines at each edge — headers can be 1-2 lines.
            let indices = Set([0, 1, n - 1, n - 2]).filter { $0 >= 0 && $0 < n }
            for index in indices {
                let key = normalizeRunning(lines[index].text)
                if key.count >= 2 {
                    counts[key, default: 0] += 1
                    texts[key, default: []].append(lines[index].text)
                }
            }
        }

        let threshold = max(2, Int((Double(pages) * 0.5).rounded(.up)))
        return Set(counts.filter { $0.value >= threshold && !areChapterOpenings(texts[$0.key] ?? []) }.keys)
    }

    /// "CHAPTER 12", "Day 3": a label numbered afresh at every hit is a run
    /// of chapter openings, not a running header, which repeats its
    /// chapter's number ("Chapter 3 The Return" through chapter 3).
    static func areChapterOpenings(_ texts: [String]) -> Bool {
        let numbers = texts.compactMap { $0.firstMatch(of: openingLabel).flatMap { Int($0.1) } }
        return !numbers.isEmpty && numbers.count == texts.count && Set(numbers).count == numbers.count
    }

    private static let openingLabel = #/(?i)^(?:chapter|day|letter|lesson|week|part|book|volume|section)\s+(\d{1,4})\b/#

    /// Each page's running headers and footers: the document-wide ones,
    /// plus a line that runs through part of the book. A printed book puts
    /// its title on left-hand pages and the chapter's on right-hand ones,
    /// so neither reaches half the pages. Such a line is set apart from the
    /// body by a paragraph gap, sits at the same height in the same size,
    /// and recurs at least `minimumRun` times no more than `maximumRunGap`
    /// pages apart (a chapter opening or a blank page between). A chapter's
    /// title on its opening page sits lower or larger, so it stays, and so
    /// do short chapters' "CHAPTER 12" openings, numbered afresh each time.
    static func runningHeadersByPage(_ pageLines: [[Line]]) -> [Set<String>] {
        let global = detectRunningHeaders(pageLines)
        var byPage = Array(repeating: global, count: pageLines.count)
        guard pageLines.count >= minimumRun else { return byPage }

        var seen: [String: [(page: Int, y: CGFloat, height: CGFloat, text: String)]] = [:]
        for (page, lines) in pageLines.enumerated() {
            let n = lines.count
            guard n >= 3 else { continue }
            let breakGap = typicalGap(lines) * 1.6
            var keys = Set<String>()
            for index in Set([0, 1, n - 1, n - 2]) {
                let line = lines[index]
                let apart = index <= 1
                    ? line.y - lines[index + 1].y > breakGap
                    : lines[index - 1].y - line.y > breakGap
                let key = normalizeRunning(line.text)
                guard apart, key.count >= 2, !isPageNumberLine(line.text),
                      keys.insert(key).inserted else { continue }
                seen[key, default: []].append((page, line.y, line.height, line.text))
            }
        }

        for (key, hits) in seen where hits.count >= minimumRun && !global.contains(key) {
            let y = median(hits.map(\.y))
            let height = median(hits.map(\.height))
            let placed = hits.filter {
                abs($0.y - y) <= max(2, height * 0.25) && abs($0.height - height) <= max(1, height * 0.2)
            }
            var run: [(page: Int, y: CGFloat, height: CGFloat, text: String)] = []
            func close() {
                if run.count >= minimumRun, !areChapterOpenings(run.map(\.text)) {
                    for hit in run { byPage[hit.page].insert(key) }
                }
                run = []
            }
            for hit in placed {
                if let last = run.last, hit.page - last.page > maximumRunGap { close() }
                run.append(hit)
            }
            close()
        }
        return byPage
    }

    static let minimumRun = 3
    static let maximumRunGap = 4

    /// The page's running header as text, when the noise pass drops one
    /// from its top: the first of its top two lines that is one.
    static func topHeader(_ lines: [Line], running: Set<String>) -> String? {
        for line in lines.prefix(2) where !isPageNumberLine(line.text) {
            if running.contains(normalizeRunning(line.text)) {
                let header = TextNormalizer.normalize(line.text)
                return header.isEmpty ? nil : header
            }
        }
        return nil
    }

    /// Drop noise lines near the page edges: repeating headers/footers and
    /// standalone page numbers. Body lines that merely resemble them survive:
    /// a roman numeral goes only when it is one of the page's
    /// `romanFolios` (`romanFolioLines`).
    static func stripNoise(_ lines: [Line], running: Set<String>, romanFolios: Set<Int> = []) -> [Line] {
        let n = lines.count
        return lines.enumerated().compactMap { index, line in
            let nearEdge = index <= 1 || index >= n - 2
            if nearEdge && running.contains(normalizeRunning(line.text)) { return nil }
            if nearEdge && isPageNumberLine(line.text)
                && (romanValue(line.text) == nil || romanFolios.contains(index)) { return nil }
            return line
        }
    }

    // MARK: - Cross-page stitching

    /// True if text ends a sentence (terminal punctuation, ignoring closers),
    /// Chinese and Japanese "。" and "」" included (NFKC has already made
    /// "！" and "？" plain), and the Devanagari danda "।" and "॥", the
    /// Arabic "؟" and the Urdu "۔".
    static func looksFinished(_ text: String) -> Bool {
        text.firstMatch(of: #/[.!?…。।॥؟۔]["')\]」』]?\s*$/#) != nil
    }

    /// Korean, Arabic, Hebrew, Devanagari, Thai: a letter of a script with
    /// no case (Chinese and Japanese aside) on both sides of a page break,
    /// where the lowercase test can't see a sentence go on either. The
    /// previous page's trailing vowel signs and marks are looked past.
    static func continuesCaseless(_ previous: String, _ next: String) -> Bool {
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
        guard let last = previous.unicodeScalars.reversed().first(where: {
                  !$0.properties.isWhitespace && !marks.contains($0.properties.generalCategory)
              }),
              let first = next.unicodeScalars.first else { return false }
        return isCaselessLetter(last) && isCaselessLetter(first)
    }

    private static func isCaselessLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .otherLetter && !isUnspacedCJK(scalar)
    }

    /// Stitch a page's paragraphs onto the growing block list, merging the
    /// page's first paragraph onto the previous block when that block clearly
    /// runs on (no terminal punctuation) and this one continues it (starts
    /// lowercase or with a digit, in any script, goes on in Chinese or
    /// Japanese from Chinese or Japanese, or in another caseless script from
    /// the same kind, or the previous ended mid-hyphenation, normal or soft).
    static func appendPageParagraphs(_ blocks: inout [TextBlock],
                                     _ paragraphs: [String],
                                     page: Int) {
        for (index, paragraph) in paragraphs.enumerated() {
            if index == 0,
               let previous = blocks.last,
               !looksFinished(previous.text),
               paragraph.firstMatch(of: #/^[\p{Ll}\p{N}]/#) != nil
                   || continuesUnspacedCJK(previous.text, paragraph)
                   || continuesCaseless(previous.text, paragraph)
                   || previous.text.firstMatch(of: #/[A-Za-z]-$/#) != nil
                   || endsInSoftHyphen(previous.text) {
                blocks[blocks.count - 1] = TextBlock(text: appendLine(previous.text, paragraph),
                                                     page: previous.page)
            } else {
                blocks.append(TextBlock(text: paragraph, page: page))
            }
        }
    }

    // MARK: - Character helpers

    /// Strip control characters from a line (tabs and line breaks become
    /// spaces; other C0 controls plus DEL are dropped). The comprehensive
    /// Unicode cleanup happens later in `TextNormalizer`.
    private static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return " "
            case ..<0x20, 0x7F: return nil
            default: return scalar
            }
        }))
    }
}
