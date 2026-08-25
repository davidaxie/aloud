import Foundation

/// Plain-text ingestion for bookshelf classics and imported .txt files.
/// Paragraphs come from blank-line separation; chapter-style headings become
/// page boundaries so the reader can show section marks. A book with no
/// detectable chapters is a single logical page.
///
/// Front matter: Gutenberg-style classics open with a "Title by Author" line,
/// a Contents list, and dedications. When a Contents heading appears near the
/// top of the file, everything up to the first real chapter heading is
/// excluded so playback starts at the story (the title is already in the UI).
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

        let kept = Self.strippingFrontMatter(Self.paragraphs(in: unified))

        var blocks: [TextBlock] = []
        var page = 1
        for paragraph in kept {
            if Self.isChapterHeading(paragraph) && !blocks.isEmpty {
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
    }

    static func paragraphs(in unified: String) -> [RawParagraph] {
        var result: [RawParagraph] = []
        var current: [Substring] = []
        var firstLine = 0
        for (index, line) in unified.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(RawParagraph(
                        text: current.joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        firstLine: firstLine))
                    current = []
                }
            } else {
                if current.isEmpty { firstLine = index }
                current.append(line)
            }
        }
        if !current.isEmpty {
            result.append(RawParagraph(
                text: current.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                firstLine: firstLine))
        }
        return result
    }

    // MARK: - Front matter

    /// Front-matter detection only looks this far into the file. Everything
    /// past it is body text, no matter what it resembles.
    static let frontMatterLineLimit = 80

    /// Conservative skip: only fires when an explicit Contents heading sits
    /// within the first `frontMatterLineLimit` lines. Then the Contents list
    /// is dropped, and if a real chapter heading follows (still near the top),
    /// reading starts there — title lines, dedications, and epigraphs before
    /// it are excluded so the first spoken sentence is the chapter opening.
    /// Books without a Contents block are returned untouched.
    static func strippingFrontMatter(_ paragraphs: [RawParagraph]) -> [String] {
        guard let contentsIndex = paragraphs.firstIndex(where: {
            $0.firstLine < frontMatterLineLimit && isContentsHeading($0.text)
        }) else {
            return paragraphs.map(\.text)
        }

        // Drop the list block(s) directly under the Contents heading.
        var afterList = contentsIndex + 1
        while afterList < paragraphs.count,
              paragraphs[afterList].firstLine < frontMatterLineLimit,
              !isChapterHeading(paragraphs[afterList].text),
              isContentsList(paragraphs[afterList].text) {
            afterList += 1
        }

        // Start reading at the first real chapter heading after the Contents.
        if let chapterIndex = paragraphs[afterList...].firstIndex(where: {
            $0.firstLine < frontMatterLineLimit && isChapterHeading($0.text)
        }) {
            return paragraphs[chapterIndex...].map(\.text)
        }

        // No chapter nearby: drop only the Contents heading and its list.
        return (paragraphs[..<contentsIndex] + paragraphs[afterList...]).map(\.text)
    }

    private static let contentsHeadingRegex = #/^(?:table\s+of\s+)?contents\.?$/#
        .ignoresCase()

    static func isContentsHeading(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 40 else { return false }
        return paragraph
            .trimmingCharacters(in: .whitespaces)
            .wholeMatch(of: contentsHeadingRegex) != nil
    }

    /// A Contents list block: every line is short and starts like a table
    /// entry — a roman numeral, a number, or "Chapter …".
    private static let contentsEntryRegex = #/^\s*(?:[IVXLCDM]+\b\.?|\d+\.?|CHAPTER\b|Chapter\b)/#

    static func isContentsList(_ paragraph: String) -> Bool {
        let lines = paragraph.split(separator: "\n")
        guard !lines.isEmpty, lines.count <= 40 else { return false }
        return lines.allSatisfy {
            $0.count <= 60 && $0.firstMatch(of: contentsEntryRegex) != nil
        }
    }

    // MARK: - Chapter detection

    private static let headingRegex =
        #/^(?:CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act|PROLOGUE|Prologue|EPILOGUE|Epilogue)\b|^[IVXLC]+\.?$/#

    /// A heading is a short, single-line paragraph that looks like a section
    /// marker ("CHAPTER I", "Part 2. The Return", "XII.").
    static func isChapterHeading(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 80 else { return false }
        return paragraph.firstMatch(of: headingRegex) != nil
    }

    // MARK: - Reading

    private static func read(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        throw ExtractionError.unreadableTextFile
    }
}
