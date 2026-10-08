import Foundation
import CryptoKit

/// Off-main extraction: PDF or plain text → normalized blocks → sentences and
/// paragraphs → `DocContent`. The actor serializes extraction work and keeps
/// PDFKit traversal off the main thread.
actor ExtractionPipeline {

    private let pdfExtractor = PDFTextExtractor()
    private let textExtractor = TextExtractor()

    init() {}

    /// Extract a PDF into a fully-chunked `DocContent`. Progress runs 0…1,
    /// dominated by per-page parsing. `fallbackTitle` names a PDF without
    /// Title metadata — pass the picked file's name, because the library copy
    /// at `pdfURL` is named by UUID.
    func extract(pdfURL: URL,
                 fallbackTitle: String? = nil,
                 progress: (@Sendable (Double) -> Void)?) async throws -> DocContent {
        let output = try pdfExtractor.extract(url: pdfURL) { fraction in
            progress?(fraction * 0.9)
        }
        let rawTitle = output.title ?? fallbackTitle ?? Self.fileTitle(of: pdfURL)
        let normalizedTitle = TextNormalizer.normalize(rawTitle)
        let title = normalizedTitle.isEmpty ? "Untitled" : normalizedTitle

        var content = try Self.buildContent(title: title,
                                            pageCount: output.pageCount,
                                            blocks: output.blocks)
        content.pageHeaders = output.pageHeaders.isEmpty ? nil : output.pageHeaders
        content.chapterMap = PDFChapterDetector.chapterMap(for: content, outline: output.outline)
        progress?(1.0)
        return content
    }

    /// `content` with a current chapter map: the PDF at `pdfURL` is opened
    /// only for its outline (no text extraction; an unreadable or missing
    /// file just has none), then the detectors run on the cached text. For
    /// a book imported before chapter maps, or by an older detector. The
    /// text and `contentHash` are untouched, so saved progress stays valid.
    /// Touches no state of the pipeline, so it never waits behind an import
    /// running on it.
    nonisolated func addingChapters(to content: DocContent, pdfURL: URL) -> DocContent {
        Self.addingChapters(to: content, pdfURL: pdfURL)
    }

    nonisolated static func addingChapters(to content: DocContent, pdfURL: URL) -> DocContent {
        var content = content
        let outline = PDFChapterDetector.outlineItems(at: pdfURL)
        content.chapterMap = PDFChapterDetector.chapterMap(for: content, outline: outline)
        return content
    }

    /// Extract a plain-text book. The provided title is authoritative — it is
    /// never parsed from the text.
    func extractText(fileURL: URL,
                     title: String,
                     progress: (@Sendable (Double) -> Void)?) async throws -> DocContent {
        progress?(0.1)
        let output = try textExtractor.extract(url: fileURL)
        progress?(0.6)
        let content = try Self.buildContent(title: title,
                                            pageCount: output.pageCount,
                                            blocks: output.blocks)
        progress?(1.0)
        return content
    }

    /// The file name without its extension, unless that is a UUID (the
    /// library copy's name), which is never a title: "" becomes "Untitled".
    /// The name Finder shows (`URL.displayStem`): "AC/DC Live", not "AC:DC Live".
    static func fileTitle(of url: URL) -> String {
        let stem = url.displayStem
        return UUID(uuidString: stem) == nil ? stem : ""
    }

    // MARK: - Assembly

    private static func buildContent(title: String,
                                     pageCount: Int,
                                     blocks: [TextBlock]) throws -> DocContent {
        var sentences: [Sentence] = []
        var paragraphs: [Paragraph] = []

        for block in blocks {
            try Task.checkCancellation()
            let normalized = TextNormalizer.normalize(block.text)
            let chunks = SentenceSegmenter.chunkParagraph(normalized)
            guard !chunks.isEmpty else { continue }

            let paragraphID = paragraphs.count
            let start = sentences.count
            for chunk in chunks {
                sentences.append(Sentence(id: sentences.count,
                                          text: chunk,
                                          para: paragraphID,
                                          page: block.page))
            }
            paragraphs.append(Paragraph(id: paragraphID,
                                        sentenceIDs: start..<sentences.count,
                                        page: block.page))
        }

        guard !sentences.isEmpty else { throw ExtractionError.noReadableText }

        return DocContent(title: title,
                          pageCount: pageCount,
                          sentences: sentences,
                          paragraphs: paragraphs,
                          contentHash: contentHash(of: sentences))
    }

    /// SHA256 over the joined sentence text — invalidates saved progress when
    /// extractor output changes.
    private static func contentHash(of sentences: [Sentence]) -> String {
        let joined = sentences.map(\.text).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
