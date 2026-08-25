import Foundation
import PDFKit

/// Extraction failure taxonomy, shared by the PDF and plain-text extractors.
enum ExtractionError: LocalizedError, Equatable {
    case invalidPDF
    case passwordProtected
    case emptyDocument
    case noReadableText
    case unreadableTextFile

    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "This file is not a valid PDF or is corrupted."
        case .passwordProtected:
            return "This PDF is password-protected. Please remove the password and try again."
        case .emptyDocument:
            return "The document has no readable pages."
        case .noReadableText:
            return "No readable text found. This may be a scanned document (images only)."
        case .unreadableTextFile:
            return "Could not read this text file."
        }
    }
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

        // Detect repeating headers/footers across the whole document.
        let running = Self.detectRunningHeaders(pageLines)

        // Pass 2: strip noise, fold into paragraphs, stitch across pages.
        var blocks: [TextBlock] = []
        for (index, lines) in pageLines.enumerated() {
            let cleaned = Self.stripNoise(lines, running: running)
            let paragraphs = Self.paragraphs(from: cleaned)
            Self.appendPageParagraphs(&blocks, paragraphs, page: index + 1)
        }

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return Output(title: title, pageCount: pageCount, blocks: blocks)
    }

    // MARK: - Geometry types

    struct Line {
        let text: String
        let y: CGFloat      // top edge in page space — a LARGER y is HIGHER
        let height: CGFloat // line box height (≈ font size + leading)
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
                              height: bounds.height > 0 ? bounds.height : 8))
        }
        // Top-to-bottom reading order (multi-column layouts remain a known
        // limitation, as on the web).
        return lines.sorted { $0.y > $1.y }
    }

    // MARK: - Lines → paragraphs

    /// Fold a page's lines into paragraphs: a break is a vertical gap
    /// noticeably (> 1.6x) larger than the page's typical leading. Wrapped
    /// lines are joined with conservative de-hyphenation, and every folded
    /// paragraph is normalized so the stitching heuristics see plain ASCII.
    static func paragraphs(from lines: [Line]) -> [String] {
        guard !lines.isEmpty else { return [] }

        var gaps: [CGFloat] = []
        for i in 1..<lines.count {
            gaps.append(lines[i - 1].y - lines[i].y)
        }
        let medianGap = median(gaps)
        let typical = medianGap != 0 ? medianGap : lines[0].height * 1.2

        var paragraphs: [String] = []
        var buffer = ""
        for (i, line) in lines.enumerated() {
            let gapBefore = i == 0 ? 0 : lines[i - 1].y - line.y
            let isNewParagraph = i > 0 && gapBefore > typical * 1.6
            if isNewParagraph && !buffer.isEmpty {
                paragraphs.append(buffer)
                buffer = ""
            }
            buffer = buffer.isEmpty ? line.text : appendLine(buffer, line.text)
        }
        if !buffer.isEmpty { paragraphs.append(buffer) }

        return paragraphs
            .map(TextNormalizer.normalize)
            .filter { !$0.isEmpty }
    }

    /// Append a wrapped line, de-hyphenating words broken across the break:
    /// "inter-" + "national" → "international". Only when a letter precedes the
    /// (normal or soft) hyphen and the next line starts lowercase.
    static func appendLine(_ buffer: String, _ next: String) -> String {
        let nextTrim = next.replacing(#/^\s+/#, with: "")
        if buffer.firstMatch(of: #/[A-Za-z][-\u{00AD}]$/#) != nil,
           nextTrim.firstMatch(of: #/^[a-z]/#) != nil {
            return buffer.replacing(#/[-\u{00AD}]$/#, with: "") + nextTrim
        }
        return buffer.replacing(#/\s+$/#, with: "") + " " + nextTrim
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: - Header / footer / page-number stripping

    /// Purely a page number or roman numeral (running-foot noise).
    static func isPageNumberLine(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.wholeMatch(of: #/\d{1,4}/#) != nil
            || t.wholeMatch(of: #/(?i)[ivxlcdm]{1,7}/#) != nil
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
        for lines in pageLines {
            let n = lines.count
            // Outer two lines at each edge — headers can be 1-2 lines.
            let indices = Set([0, 1, n - 1, n - 2]).filter { $0 >= 0 && $0 < n }
            for index in indices {
                let key = normalizeRunning(lines[index].text)
                if key.count >= 2 { counts[key, default: 0] += 1 }
            }
        }

        let threshold = max(2, Int((Double(pages) * 0.5).rounded(.up)))
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    /// Drop noise lines near the page edges: repeating headers/footers and
    /// standalone page numbers. Body lines that merely resemble them survive.
    static func stripNoise(_ lines: [Line], running: Set<String>) -> [Line] {
        let n = lines.count
        return lines.enumerated().compactMap { index, line in
            let nearEdge = index <= 1 || index >= n - 2
            if nearEdge && running.contains(normalizeRunning(line.text)) { return nil }
            if nearEdge && isPageNumberLine(line.text) { return nil }
            return line
        }
    }

    // MARK: - Cross-page stitching

    /// True if text ends a sentence (terminal punctuation, ignoring closers).
    static func looksFinished(_ text: String) -> Bool {
        text.firstMatch(of: #/[.!?…]["')\]]?\s*$/#) != nil
    }

    /// Stitch a page's paragraphs onto the growing block list, merging the
    /// page's first paragraph onto the previous block when that block clearly
    /// runs on (no terminal punctuation) and this one continues it (starts
    /// lowercase/digit, or the previous ended mid-hyphenation).
    static func appendPageParagraphs(_ blocks: inout [TextBlock],
                                     _ paragraphs: [String],
                                     page: Int) {
        for (index, paragraph) in paragraphs.enumerated() {
            if index == 0,
               let previous = blocks.last,
               !looksFinished(previous.text),
               paragraph.firstMatch(of: #/^[a-z0-9]/#) != nil
                   || previous.text.firstMatch(of: #/[A-Za-z]-$/#) != nil {
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
