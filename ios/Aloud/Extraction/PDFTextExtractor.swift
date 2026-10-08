import Foundation
import NaturalLanguage
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
    var text: String
    let page: Int
    /// A paragraph stitched across page breaks: where each later page
    /// begins in it, so each sentence keeps the page it starts on (L009).
    /// Empty for a paragraph on one page.
    var laterPages: [PageStart] = []
    /// The letters in `text`, kept up as pages are stitched on; nil until
    /// the first one is.
    var letters: Int?

    struct PageStart: Equatable {
        /// The letters in the paragraph before the page.
        let letters: Int
        let page: Int
    }

    /// Letters and marks only: what normalizing white space, quotes,
    /// dashes and hyphens leaves alone.
    static func letters(in text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.properties.isAlphabetic ? 1 : 0) }
    }

    /// The page each of `chunks`, this paragraph normalized and split,
    /// starts on: a later page begins where the share of letters read
    /// passes its share in the raw text.
    func pages(of chunks: [String]) -> [Int] {
        guard let letters, letters > 0, !laterPages.isEmpty else {
            return Array(repeating: page, count: chunks.count)
        }
        let counts = chunks.map { Self.letters(in: $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return Array(repeating: page, count: chunks.count) }
        var current = page
        var starts = laterPages[...]
        var read = 0
        return counts.map { count in
            while let next = starts.first, next.letters * total <= read * letters {
                current = next.page
                starts.removeFirst()
            }
            read += count
            return current
        }
    }
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

    /// Pages read through one opening of the document. PDFKit keeps every
    /// page it has laid out until the document goes, about half a megabyte
    /// a dense page: a 3,000-page book read through one opening outgrows
    /// an iPhone's memory (L005).
    var pagesPerOpening = 100

    /// `progress` runs 0…1 over the two passes over the pages: the first
    /// half reads them with PDFKit, the second folds them into paragraphs.
    func extract(url: URL, progress: ((Double) -> Void)? = nil) throws -> Output {
        // The title and outline come from an opening of their own.
        let (pageCount, title, outline) = try autoreleasepool { () throws -> (Int, String?, [PDFOutlineItem]) in
            let document = try Self.open(url)
            guard document.pageCount > 0 else { throw ExtractionError.emptyDocument }
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty || Self.isPlaceholderTitle($0) ? nil : $0 }
            return (document.pageCount, title, PDFChapterDetector.outlineItems(of: document))
        }

        // Pass 1: per-page line reconstruction (needed before header
        // detection), reopening the document every `pagesPerOpening` pages
        // so only the lines stay.
        var pageLines: [[Line]] = []
        pageLines.reserveCapacity(pageCount)
        var document: PDFDocument?
        let perOpening = max(1, pagesPerOpening)
        for index in 0..<pageCount {
            try Task.checkCancellation()
            let lines = try autoreleasepool { () throws -> [Line] in
                if index % perOpening == 0 {
                    document = nil
                    document = try Self.open(url)
                }
                return document?.page(at: index).map(Self.lines(of:)) ?? []
            }
            pageLines.append(lines)
            progress?(Double(index + 1) / Double(pageCount) / 2)
        }
        document = nil

        // Detect repeating headers/footers: across the whole document, and
        // per page for the ones that run through a chapter or alternate.
        let running = Self.runningHeadersByPage(pageLines)
        let folios = Self.folioLines(pageLines)
        let english = Self.readsAsEnglish(Self.languageSample(pageLines))

        // Pass 2: strip noise, fold into paragraphs column by column,
        // stitch across columns and pages.
        var blocks: [TextBlock] = []
        var pageHeaders: [Int: String] = [:]
        var pagesWithText = 0
        for (index, lines) in pageLines.enumerated() {
            try Task.checkCancellation()
            if let header = Self.topHeader(lines, running: running[index]) {
                pageHeaders[index + 1] = header
            }
            let cleaned = Self.stripNoise(lines, running: running[index], folios: folios[index])
            var hasText = false
            for run in Self.columnRuns(cleaned) {
                let paragraphs = Self.paragraphs(from: run, english: english)
                if !paragraphs.isEmpty { hasText = true }
                Self.appendPageParagraphs(&blocks, paragraphs, page: index + 1, english: english)
            }
            if hasText { pagesWithText += 1 }
            progress?(0.5 + Double(index + 1) / Double(pageCount) / 2)
        }
        // A scan whose only text layer is a cover sheet or a usage notice
        // reads as having no text, not as a book of a few sentences.
        if Self.isMostlyScanned(pagesWithText: pagesWithText, pageCount: pageCount) {
            throw ExtractionError.noReadableText
        }

        return Output(title: title, pageCount: pageCount, blocks: blocks,
                      outline: outline,
                      pageHeaders: pageHeaders)
    }

    /// The document at `url`, unlocked if it opens with no password.
    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.invalidPDF
        }
        if document.isLocked || (document.isEncrypted && !document.unlock(withPassword: "")) {
            throw ExtractionError.passwordProtected
        }
        return document
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
        let y: CGFloat      // top edge in the page's `readingFrame` — a LARGER y is HIGHER
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
        let box = page.bounds(for: .mediaBox)
        guard let selection = page.selection(for: box) else { return [] }

        var placed: [(text: String, bounds: CGRect)] = []
        for lineSelection in selection.selectionsByLine() {
            guard let raw = lineSelection.string else { continue }
            let text = lineText(raw)
            guard !text.isEmpty else { continue }
            placed.append((text, lineSelection.bounds(for: page)))
        }
        let frame = readingFrame(placed, box: box, rotation: page.rotation)
        // Top to bottom, so the edge passes see the page's top and foot; a
        // page set in two columns is read column by column after them
        // (`columnRuns`).
        let lines = placed.map { line($0.text, $0.bounds, in: frame) }.sorted { $0.y > $1.y }
        return splitAtGutter(lines, on: page, frame: frame)
    }

    private static func lineText(_ raw: String) -> String {
        sanitize(raw)
            .replacing(#/[ \t]{2,}/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A line from its selection's bounds, measured in `frame`.
    private static func line(_ text: String, _ bounds: CGRect, in frame: CGAffineTransform) -> Line {
        let bounds = frame.isIdentity ? bounds : bounds.applying(frame)
        return Line(text: text,
                    y: bounds.maxY,
                    height: bounds.height > 0 ? bounds.height : 8,
                    minX: bounds.minX,
                    maxX: bounds.maxX)
    }

    /// The frame a page's lines read level in. A page turned a quarter
    /// (`/Rotate 90` or `270`) to show text set sideways on it level, as a
    /// landscape page or table is, has lines taller than wide on the page:
    /// they are measured as the reader sees them, the page turned. A page
    /// not turned, or turned with its text level on it, keeps its own frame.
    static func readingFrame(_ lines: [(text: String, bounds: CGRect)], box: CGRect,
                             rotation: Int) -> CGAffineTransform {
        let sideways = lines.filter { $0.bounds.height > $0.bounds.width }.map(\.text.count).reduce(0, +)
        let level = lines.filter { $0.bounds.height <= $0.bounds.width }.map(\.text.count).reduce(0, +)
        guard sideways > level else { return .identity }
        switch (rotation % 360 + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: return .identity
        }
    }

    /// The page's lines, each that crosses the gutter inside the columns
    /// (`straddlers`) read again as its two halves: PDFKit joins a left
    /// line run into the gutter (a long address, a wide equation) with
    /// the right column's line beside it. Kept whole when a column's line
    /// stands beside it already, or unless both halves hold text.
    private static func splitAtGutter(_ lines: [Line], on page: PDFPage, frame: CGAffineTransform) -> [Line] {
        guard let gutter = gutter(lines) else { return lines }
        let straddling = Set(straddlers(lines, gutter: gutter))
        guard !straddling.isEmpty else { return lines }
        let toPage = frame.inverted()
        return lines.indices.flatMap { index -> [Line] in
            let whole = lines[index]
            guard straddling.contains(index), !lines.contains(where: {
                ($0.maxX <= gutter || $0.minX >= gutter) && abs($0.y - whole.y) <= whole.height / 2
            }) else { return [whole] }
            let inset = whole.height * 0.25
            let halves = [(whole.minX, gutter), (gutter, whole.maxX)].compactMap { start, end -> Line? in
                let rect = CGRect(x: start, y: whole.y - whole.height + inset,
                                  width: end - start, height: whole.height - inset * 2)
                guard let half = page.selection(for: frame.isIdentity ? rect : rect.applying(toPage)),
                      let raw = half.string else { return nil }
                let text = lineText(raw)
                return text.isEmpty ? nil : line(text, half.bounds(for: page), in: frame)
            }
            return halves.count == 2 ? halves : [whole]
        }.sorted { $0.y > $1.y }
    }

    // MARK: - Columns

    /// A page's body lines as runs to fold in reading order: the page
    /// itself, or on a page set in two columns each band's left column,
    /// then its right (its right, then its left, in Arabic or Hebrew),
    /// between the lines that span the gutter (a title, an abstract, a
    /// wide figure's caption). A line that crosses the gutter inside the
    /// columns (`straddlers`) stays in its band, on the side lines open
    /// from, and a spanning paragraph's short last line, with nothing
    /// beside it across the gutter, stays with the paragraph. Sorted top
    /// to bottom alone, the two columns read a line of each in turn.
    static func columnRuns(_ lines: [Line]) -> [[Line]] {
        guard let gutter = gutter(lines) else { return [lines] }
        let rightToLeft = readsRightToLeft(lines)
        let height = median(lines.map(\.height))
        let straddling = Set(straddlers(lines, gutter: gutter))
        func crosses(_ line: Line) -> Bool { line.minX < gutter && line.maxX > gutter }
        func onLeft(_ line: Line) -> Bool { line.maxX <= gutter }
        func endsSpan(_ line: Line, under last: Line) -> Bool {
            let short = rightToLeft ? line.minX > gutter + height : line.maxX < gutter - height
            return short && onLeft(line) != rightToLeft && last.y - line.y <= height * 2
                && !lines.contains { !crosses($0) && onLeft($0) != onLeft(line) && abs($0.y - line.y) <= height }
        }
        var runs: [[Line]] = []
        var across: [Line] = [], left: [Line] = [], right: [Line] = []
        func closeBand() {
            runs += rightToLeft ? [right, left] : [left, right]
            left = []
            right = []
        }
        for (index, line) in lines.enumerated() {
            if crosses(line) && !straddling.contains(index) {
                closeBand()
                across.append(line)
            } else if let last = across.last, !crosses(line), endsSpan(line, under: last) {
                across.append(line)
            } else {
                if !across.isEmpty { runs.append(across) }
                across = []
                let leftSide = straddling.contains(index) ? !rightToLeft : onLeft(line)
                if leftSide { left.append(line) } else { right.append(line) }
            }
        }
        runs.append(across)
        closeBand()
        return runs.filter { !$0.isEmpty }
    }

    /// The lines that cross the gutter inside the columns, not between
    /// them: column lines sit above and below it on both sides, within a
    /// couple of lines. A title, an abstract or a caption spanning the
    /// page stands apart from the columns' lines.
    static func straddlers(_ lines: [Line], gutter: CGFloat) -> [Int] {
        let reach = median(lines.map(\.height)) * 2.5
        func crosses(_ line: Line) -> Bool { line.minX < gutter && line.maxX > gutter }
        return lines.indices.filter { index in
            let line = lines[index]
            guard crosses(line) else { return false }
            func columnLine(above: Bool, left: Bool) -> Bool {
                lines.contains { other in
                    let rise = other.y - line.y
                    return !crosses(other) && (other.maxX <= gutter) == left
                        && (above ? rise > 0 : rise < 0) && abs(rise) <= reach
                }
            }
            return columnLine(above: true, left: true) && columnLine(above: true, left: false)
                && columnLine(above: false, left: true) && columnLine(above: false, left: false)
        }
    }

    /// Mostly Hebrew, Arabic or another right-to-left script's letters:
    /// a page whose lines, and columns, open on the right.
    static func readsRightToLeft(_ lines: [Line]) -> Bool {
        var rightToLeft = 0, other = 0
        for line in lines {
            for scalar in line.text.unicodeScalars where scalar.properties.isAlphabetic {
                switch scalar.value {
                case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                    rightToLeft += 1
                default:
                    other += 1
                }
            }
        }
        return rightToLeft > other
    }

    /// Where a page set in two columns divides: just left of the right
    /// column's margin, in the middle of the text, with `minimumColumnLines`
    /// or more lines wholly on each side. Each column's lines mostly start
    /// at one margin (the right one in Arabic or Hebrew) and run a third of
    /// the text's width or more (not a contents page's page numbers or a
    /// centred heading), and the columns stand side by side, line beside
    /// line. Nil on a page of one column.
    static func gutter(_ lines: [Line]) -> CGFloat? {
        guard lines.count >= minimumColumnLines * 2,
              let textLeft = lines.map(\.minX).min(), let textRight = lines.map(\.maxX).max() else { return nil }
        let width = textRight - textLeft
        let height = median(lines.map(\.height))
        let tolerance = max(1.5, height * 0.15)
        guard width > height * 10 else { return nil }

        let middle = (textLeft + width * 0.3)...(textLeft + width * 0.7)
        var best: (x: CGFloat, left: [Line], right: [Line])?
        for start in Set(lines.map { $0.minX.rounded(.down) }).sorted() where middle.contains(start) {
            let x = start - tolerance
            let left = lines.filter { $0.maxX <= x }, right = lines.filter { $0.minX >= x }
            guard left.count >= minimumColumnLines, right.count >= minimumColumnLines,
                  left.count + right.count > (best.map { $0.left.count + $0.right.count } ?? 0) else { continue }
            best = (x, left, right)
        }
        guard let best else { return nil }

        let rightToLeft = readsRightToLeft(lines)
        func isColumn(_ column: [Line]) -> Bool {
            let starts = column.map { rightToLeft ? $0.maxX : $0.minX }
            guard let margin = mostCommon(starts) else { return false }
            let atMargin = starts.filter { abs($0 - margin) <= tolerance }.count
            return atMargin * 2 >= column.count && median(column.map { $0.maxX - $0.minX }) >= width / 3
        }
        let beside = best.right.filter { line in best.left.contains { abs($0.y - line.y) <= height } }.count
        guard isColumn(best.left), isColumn(best.right), beside >= minimumColumnLines,
              beside * 2 >= min(best.left.count, best.right.count) else { return nil }
        return best.x
    }

    static let minimumColumnLines = 3

    // MARK: - Lines → paragraphs

    /// Fold a page's lines into paragraphs: a break is a vertical gap
    /// noticeably (> 1.6x) larger than the page's typical leading, or a
    /// first-line indent (`indentBreaks`). Wrapped lines are joined with
    /// conservative de-hyphenation, and every folded paragraph is
    /// normalized so the stitching heuristics see plain ASCII. `english`
    /// is the book's language for a line-end hyphen (see `appendLine`).
    static func paragraphs(from lines: [Line], english: Bool? = nil) -> [String] {
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
            if buffer.isEmpty {
                buffer = line.text
            } else {
                appendLine(&buffer, line.text, english: english)
            }
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
    /// quote) stay together; a centred heading sits further in. On a page
    /// of one-line exchanges the indent is the commonest start, and the
    /// margin is where the few wrapped lines run on (`setOutMargin`).
    static func indentBreaks(_ lines: [Line]) -> Set<Int> {
        guard lines.count >= 3 else { return [] }
        let height = median(lines.map(\.height))
        let tolerance = max(1.5, height * 0.15)
        guard let common = mostCommon(lines.map(\.minX)) else { return [] }
        let margin = setOutMargin(lines, from: common, height: height, tolerance: tolerance) ?? common
        let atMargin = lines.filter { abs($0.minX - margin) <= tolerance || abs($0.minX - common) <= tolerance }.count
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

    /// The margin to the left of the commonest start, when that start is
    /// the indent: a column half a line to four lines further out, of two
    /// or more lines that mostly run on from an unfinished one, as a
    /// wrapped paragraph's do, while the commonest start's lines mostly
    /// follow a finished one, as one-line paragraphs do. A hanging
    /// indent's set-out lines open entries after finished ones: nil.
    private static func setOutMargin(_ lines: [Line], from common: CGFloat,
                                     height: CGFloat, tolerance: CGFloat) -> CGFloat? {
        let outside = lines.map(\.minX).filter { common - $0 > height * 0.5 && common - $0 < height * 4 }
        guard let column = mostCommon(outside) else { return nil }
        func starts(at x: CGFloat) -> (count: Int, afterFinished: Int) {
            let starts = lines.indices.dropFirst().filter { abs(lines[$0].minX - x) <= tolerance }
            return (starts.count, starts.filter { looksFinished(lines[$0 - 1].text) }.count)
        }
        let out = starts(at: column), inner = starts(at: common)
        guard out.count >= 2, out.afterFinished * 2 < out.count,
              inner.afterFinished * 2 > inner.count else { return nil }
        return column
    }

    /// Append a wrapped line, de-hyphenating words broken across the break.
    /// A soft hyphen only ever marks a break inside a word, so any script's
    /// "Schwarzwäl\u{AD}" + "der" is joined here. A normal hyphen after an
    /// ASCII letter, before a lowercase one, is kept with a line break
    /// ("inter-⏎national") in English: `TextNormalizer.normalize`, which
    /// runs on every folded paragraph and stitched block, re-joins a
    /// syllable split and keeps a compound wrapped at its own hyphen
    /// ("well-⏎known"). Its word list is English, so in other languages
    /// the split is re-joined here ("main-⏎tenant"). `english` is the
    /// book's; nil reads the text either side of the break.
    static func appendLine(_ buffer: String, _ next: String, english: Bool? = nil) -> String {
        var buffer = buffer
        appendLine(&buffer, next, english: english)
        return buffer
    }

    /// `appendLine` in place, reading only the end of `buffer`: a paragraph
    /// that runs on for hundreds of lines or pages grows in linear time,
    /// never copied or rescanned from its start for each one (L009).
    static func appendLine(_ buffer: inout String, _ next: String, english: Bool? = nil) {
        let nextTrim = next.replacing(#/^\s+/#, with: "")
        if endsInLetterHyphen(buffer) && nextTrim.firstMatch(of: #/^[a-z]/#) != nil {
            if english ?? readsAsEnglish(String(buffer.suffix(300)) + " " + nextTrim.prefix(100)) {
                buffer += "\n" + nextTrim
            } else {
                buffer.removeLast()
                buffer += nextTrim
            }
            return
        }
        if endsInSoftHyphen(buffer) && nextTrim.firstMatch(of: #/^\p{Ll}/#) != nil {
            buffer.removeLast()
            buffer += nextTrim
            return
        }
        while buffer.last?.isWhitespace == true { buffer.removeLast() }
        // Chinese and Japanese put no space between words: a wrap there
        // is no word break. (Korean does space its words.)
        if let last = buffer.unicodeScalars.last, let first = nextTrim.unicodeScalars.first,
           isUnspacedCJK(last), isUnspacedCJK(first) {
            buffer += nextTrim
        } else {
            buffer += " " + nextTrim
        }
    }

    /// An ASCII letter, then a hyphen, at the very end.
    static func endsInLetterHyphen(_ text: String) -> Bool {
        tail(text).firstMatch(of: #/[A-Za-z]-$/#) != nil
    }

    /// The end of `text`: its last 16 characters before any trailing white
    /// space, and that space. All an end-anchored pattern needs, without
    /// scanning a long paragraph from its start.
    static func tail(_ text: String) -> String {
        let last = text.lastIndex { !$0.isWhitespace } ?? text.startIndex
        return String(text[(text.index(last, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex)...])
    }

    /// Whether the on-device recognizer reads `text` as English, the one
    /// language `TextNormalizer`'s hyphen rule has a word list for.
    static func readsAsEnglish(_ text: String) -> Bool {
        NLLanguageRecognizer.dominantLanguage(for: text) == .english
    }

    /// A few lines from the middle of pages spread across the book, past
    /// their running heads: its language in one look, not one per page.
    static func languageSample(_ pageLines: [[Line]]) -> String {
        let step = max(1, pageLines.count / 20)
        return stride(from: 0, to: pageLines.count, by: step).flatMap { index in
            let lines = pageLines[index]
            return lines.dropFirst(lines.count / 3).prefix(5).map(\.text)
        }.joined(separator: " ")
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
        guard let last = previous.last(where: { !$0.isWhitespace })?.unicodeScalars.last,
              let first = next.unicodeScalars.first else { return false }
        return isUnspacedCJK(last) && isUnspacedCJK(first)
    }

    /// A letter of any script, then a soft hyphen, at the very end.
    static func endsInSoftHyphen(_ text: String) -> Bool {
        tail(text).firstMatch(of: #/\p{L}\u{00AD}$/#) != nil
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

    /// A page number's value: up to four digits ("41") or a well-formed
    /// roman numeral ("xiv"), else nil.
    static func folioValue(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.wholeMatch(of: #/[0-9]{1,4}/#) != nil ? Int(t) : romanValue(t)
    }

    /// Each page's edge lines that are folios: a page number with another
    /// on a page up to two away, at about the same height, that counts on
    /// by the pages between, as a book numbers its pages ("vii", "viii";
    /// "41", "42"). A bare "II" or "7" opening a chapter has none.
    static func folioLines(_ pageLines: [[Line]]) -> [Set<Int>] {
        let numerals = pageLines.map { lines in
            let n = lines.count
            return Set([0, 1, n - 2, n - 1]).filter { $0 >= 0 && $0 < n }.compactMap { index in
                folioValue(lines[index].text).map { (index: index, line: lines[index], value: $0) }
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

    /// "CHAPTER 12", "Day 3", "Глава 12", "第十二章": a label numbered afresh
    /// at every hit is a run of chapter openings, not a running header,
    /// which repeats its chapter's number ("Chapter 3 The Return" through
    /// chapter 3).
    static func areChapterOpenings(_ texts: [String]) -> Bool {
        let numbers = texts.compactMap(openingNumber)
        return !numbers.isEmpty && numbers.count == texts.count && Set(numbers).count == numbers.count
    }

    /// An opening label's number: an English one ("CHAPTER 12", "Day 3")
    /// or a localized chapter marker the headings tier lists ("Глава 12",
    /// "Kapitel 12", "Chapitre 12", "第十二章", "제12장").
    static func openingNumber(_ text: String) -> Int? {
        text.firstMatch(of: openingLabel).flatMap { Int($0.1) } ?? HeadingChapters.localizedNumber(text)
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
    /// do short chapters' "CHAPTER 12" or "Глава 12" openings, numbered
    /// afresh each time.
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
    /// a roman numeral goes only when it is one of the page's `folios`
    /// (`folioLines`), and so does a bare number set larger than the
    /// page's text. A chapter's "7" or "1984" on its opening page counts
    /// on from no other page, so it stays.
    static func stripNoise(_ lines: [Line], running: Set<String>, folios: Set<Int> = []) -> [Line] {
        let n = lines.count
        let textHeight = median(lines.map(\.height))
        return lines.enumerated().compactMap { index, line in
            let nearEdge = index <= 1 || index >= n - 2
            if nearEdge && running.contains(normalizeRunning(line.text)) { return nil }
            if nearEdge && isPageNumberLine(line.text)
                && (folios.contains(index)
                    || romanValue(line.text) == nil && line.height <= textHeight * headingScale) { return nil }
            return line
        }
    }

    /// A heading's least size over the page's text: a folio is set no larger.
    static let headingScale: CGFloat = 1.3

    // MARK: - Cross-page stitching

    /// True if text ends a sentence (terminal punctuation, ignoring closers),
    /// Chinese and Japanese "。" and "」" included (NFKC has already made
    /// "！" and "？" plain), and the Devanagari danda "।" and "॥", the
    /// Arabic "؟" and the Urdu "۔". A page's raw lines still have curly
    /// closing quotes ("Out.”"), so those count too.
    static func looksFinished(_ text: String) -> Bool {
        tail(text).firstMatch(of: #/[.!?…。।॥؟۔]["'\u{201D}\u{2019})\]」』]?\s*$/#) != nil
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
    /// The merged block grows in place and notes where `page` begins in it.
    static func appendPageParagraphs(_ blocks: inout [TextBlock],
                                     _ paragraphs: [String],
                                     page: Int,
                                     english: Bool? = nil) {
        for (index, paragraph) in paragraphs.enumerated() {
            if index == 0, blocks.last.map({ runsOn($0.text, into: paragraph) }) == true {
                var block = blocks.removeLast()
                if page != (block.laterPages.last?.page ?? block.page) {
                    let before = block.letters ?? TextBlock.letters(in: block.text)
                    block.laterPages.append(TextBlock.PageStart(letters: before, page: page))
                    block.letters = before
                }
                appendLine(&block.text, paragraph, english: english)
                block.letters = block.letters.map { $0 + TextBlock.letters(in: paragraph) }
                blocks.append(block)
            } else {
                blocks.append(TextBlock(text: paragraph, page: page))
            }
        }
    }

    /// Whether `next` carries on the paragraph `previous` across a break.
    private static func runsOn(_ previous: String, into next: String) -> Bool {
        !looksFinished(previous)
            && (next.firstMatch(of: #/^[\p{Ll}\p{N}]/#) != nil
                || continuesUnspacedCJK(previous, next)
                || continuesCaseless(previous, next)
                || endsInLetterHyphen(previous)
                || endsInSoftHyphen(previous))
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
