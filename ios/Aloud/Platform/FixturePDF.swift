#if DEBUG
import CoreGraphics
import CoreText
import Foundation

/// Test PDFs drawn with CoreGraphics and CoreText alone, so the UI-test
/// fixtures and the extraction tests write the same file on every platform
/// (UIKit's PDF renderer has no Mac counterpart). Text is 14 pt Helvetica on
/// US Letter, and PDFKit reads it back as real text. (S12)
enum FixturePDF {

    static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// One inch: the left edge of every line, and each side of a page's
    /// text frame.
    static let margin: CGFloat = 72

    /// One page per string, wrapped inside one-inch margins; an empty string
    /// is a blank page. `title` goes into the document info, where
    /// `PDFDocument.documentAttributes` finds it.
    static func write(pages: [String], to url: URL, title: String? = nil) throws {
        try render(to: url, pageCount: pages.count, title: title) { context, index in
            guard !pages[index].isEmpty else { return }
            let framesetter = CTFramesetterCreateWithAttributedString(styled(pages[index]))
            let path = CGPath(rect: pageBounds.insetBy(dx: margin, dy: margin), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }
    }

    /// One page per list of lines, each drawn at x = 72 with its top `y`
    /// points below the top edge: the top-left convention of UIKit's
    /// `draw(at:)`, which the extraction tests' layouts were written against.
    /// The gaps between lines are exactly the gaps between their `y`s.
    static func write(lines pages: [[(text: String, y: CGFloat)]], to url: URL, title: String? = nil) throws {
        try render(to: url, pageCount: pages.count, title: title) { context, index in
            for (text, y) in pages[index] {
                // CoreGraphics counts up from the bottom and draws on the
                // baseline, one ascent below the line's top.
                context.textPosition = CGPoint(x: margin, y: pageBounds.height - y - CTFontGetAscent(font))
                CTLineDraw(CTLineCreateWithAttributedString(styled(text)), context)
            }
        }
    }

    private static let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)

    private static func styled(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    }

    private static func render(to url: URL, pageCount: Int, title: String?,
                               drawPage: (CGContext, Int) -> Void) throws {
        var mediaBox = pageBounds
        let info = title.map { [kCGPDFContextTitle as String: $0] as CFDictionary }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            drawPage(context, index)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
#endif
