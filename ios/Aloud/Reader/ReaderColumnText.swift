#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import SwiftUI

#if canImport(UIKit)
private typealias MarkFont = UIFont
#else
private typealias MarkFont = NSFont
#endif

/// The colors the column is set in, and how its rule images are drawn, as
/// the host's appearance has them. The iOS host passes the theme's own
/// `UIColor`s (`init(traits:)`), the same values the column always used.
struct ReaderInk {
    #if canImport(UIKit)
    typealias Tint = UIColor
    typealias RuleImage = UIImage
    #else
    typealias Tint = NSColor
    typealias RuleImage = NSImage
    #endif

    var text: Tint
    var textMuted: Tint
    var accent: Tint
    var lineStrong: Tint
    /// A solid rule image of `size` in a color: chapter openings and the
    /// colophon (accent), PDF page marks (hairline).
    var ruleImage: (CGSize, Tint) -> RuleImage
}

extension NSAttributedString.Key {
    /// The page's furniture, never a sentence's words: a PDF page's
    /// numeral, the "· · ·" end mark and the colophon. The Mac's Copy
    /// leaves it out of a quote (L023).
    static let readerFurniture = NSAttributedString.Key("AloudReaderFurniture")
}

/// The reading column's attributed string: every paragraph, page mark and
/// chapter opening, then the end mark. Pure: the host passes Bold Text as
/// `bold` and its colors as `ReaderInk`, so both columns build the same text.
enum ReaderColumnText {

    /// The whole column. The end mark (`makeEndMark`) comes last, so
    /// `endMarkRange` is the tail and swapping it never moves a sentence.
    static func makeAttributedString(content: DocContent, fontSize: CGFloat,
                                     isChapterBook: Bool = false,
                                     colophon: ReaderColophon? = nil,
                                     columnWidth: CGFloat? = nil,
                                     bold: Bool, ink: ReaderInk)
        -> (string: NSAttributedString, sentenceRanges: [NSRange], endMarkRange: NSRange) {

        let page = ReaderPageStyle(fontSize: fontSize)
        // The indent and hyphenation follow the measure: a narrow column at
        // a large size breaks long words rather than ragging deeply. Layout
        // only; nil keeps the wide setting.
        let setting = page.body(columnWidth: columnWidth)
        // Bold Text: body and headings take the serif's bold face.
        let bodyFont = ReaderPageStyle.serif(size: fontSize, bold: bold)

        func bodyStyle(indent: Bool) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = page.lineHeight
            style.maximumLineHeight = page.lineHeight
            style.paragraphSpacing = page.paragraphGap
            style.firstLineHeadIndent = indent ? setting.firstLineIndent : 0
            style.hyphenationFactor = setting.hyphenationFactor
            return style
        }
        func bodyAttributes(indent: Bool) -> [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: ink.text,
             .paragraphStyle: bodyStyle(indent: indent)]
        }

        // The page numeral sits 8pt under its hairline: no space before
        // (the rule paragraph already carries the gap from the text).
        let numeralStyle = NSMutableParagraphStyle()
        numeralStyle.alignment = .center
        numeralStyle.paragraphSpacingBefore = 0
        numeralStyle.paragraphSpacing = (fontSize * 1.6).rounded()
        var numeralAttributes = markAttributes(fontSize: fontSize, ink: ink)
        numeralAttributes[.paragraphStyle] = numeralStyle

        // Chapter opening: space above, a centered small-caps heading
        // (still a speakable, tappable, highlightable sentence), a short
        // accent rule, space, then an unindented first paragraph whose
        // first words are in small caps.
        func headingAttributes(isFirst: Bool) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacingBefore = isFirst ? 0 : page.openingSpaceAbove
            style.paragraphSpacing = page.headingToRule
            style.hyphenationFactor = 0
            return [.font: ReaderPageStyle.smallCapsSerif(size: page.headingSize, bold: bold),
                    .foregroundColor: ink.text,
                    .kern: ReaderPageStyle.headingKern,
                    .paragraphStyle: style]
        }

        // Which paragraphs open a chapter: text books only, the first
        // paragraph of a chapter group that reads as a heading, and only
        // when the book is genuinely chaptered (see ReaderPageStyle).
        var openings = Set<Int>()
        if isChapterBook {
            var candidates: [Int] = []
            var previousPage: Int?
            for (index, paragraph) in content.paragraphs.enumerated() {
                defer { previousPage = paragraph.page }
                guard paragraph.page != previousPage else { continue }
                let lines = paragraph.sentenceIDs
                    .filter { content.sentences.indices.contains($0) }
                    .map { content.sentences[$0].text }
                // Also as lines: the extractor recognizes two-line headings
                // ("I" over a title line), which a space-joined string
                // hides.
                if TextExtractor.isChapterHeading(lines.joined(separator: " "))
                    || (lines.count > 1 && TextExtractor.isChapterHeading(lines.joined(separator: "\n"))) {
                    candidates.append(index)
                }
            }
            openings = ReaderPageStyle.openingParagraphs(candidates: candidates)
        }

        // Page indices may arrive 0- or 1-based; display starts at 1 either
        // way — the shared rule every page-naming surface uses. Text books
        // group by chapter, so they never get page marks.
        let pageOffset = content.pageOffset
        let showPageMarks = !isChapterBook && content.pageCount > 1

        let result = NSMutableAttributedString()
        var ranges = [NSRange](repeating: NSRange(location: 0, length: 0),
                               count: content.sentences.count)
        var lastPage: Int?
        var afterOpening = false

        for (index, paragraph) in content.paragraphs.enumerated() {
            if showPageMarks, let last = lastPage, paragraph.page != last {
                // PDF page boundary: a short hairline over the page numeral.
                result.append(ruleParagraph(size: ReaderPageStyle.pageRuleSize,
                                            color: ink.lineStrong,
                                            spacingBefore: (fontSize * 1.2).rounded(),
                                            spacingAfter: Theme.Space.xs,
                                            ink: ink))
                result.append(NSAttributedString(
                    string: "\(paragraph.page + pageOffset)\n", attributes: numeralAttributes))
            }
            let isFirstParagraph = lastPage == nil
            lastPage = paragraph.page

            let sentenceIDs = paragraph.sentenceIDs.filter { content.sentences.indices.contains($0) }
            let isOpening = openings.contains(index)
            // Book convention: no indent on a book's first paragraph or
            // the first paragraph after a chapter opening.
            let attributes = isOpening
                ? headingAttributes(isFirst: isFirstParagraph)
                : bodyAttributes(indent: !(isFirstParagraph || afterOpening))
            let paragraphStart = result.length

            var first = true
            for sentenceID in sentenceIDs {
                let sentence = content.sentences[sentenceID]
                if !first {
                    result.append(NSAttributedString(string: " ", attributes: attributes))
                }
                first = false
                let location = result.length
                // Display-only typesetting; UTF-16 length is preserved, so
                // this range (and the word-tint offsets walked from the
                // source text) stay exact.
                result.append(NSAttributedString(
                    string: ReaderTypography.typeset(sentence.text), attributes: attributes))
                ranges[sentence.id] = NSRange(location: location,
                                              length: result.length - location)
            }
            result.append(NSAttributedString(string: "\n", attributes: attributes))

            if isOpening {
                result.append(ruleParagraph(size: ReaderPageStyle.ruleSize,
                                            color: ink.accent,
                                            spacingBefore: 0,
                                            spacingAfter: page.ruleToText,
                                            ink: ink))
            } else if afterOpening, let firstID = sentenceIDs.first {
                // Opening words in small caps: font only, never length.
                let length = ReaderPageStyle.utf16LengthOfFirstWords(
                    content.sentences[firstID].text, count: ReaderPageStyle.openingSmallCapsWords)
                result.addAttribute(.font, value: ReaderPageStyle.smallCapsSerif(size: fontSize, bold: bold),
                                    range: NSRange(location: paragraphStart, length: length))
            }
            afterOpening = isOpening
        }

        let endMark = makeEndMark(colophon: colophon, fontSize: fontSize, bold: bold, ink: ink)
        let endMarkRange = NSRange(location: result.length, length: endMark.length)
        result.append(endMark)
        return (result, ranges, endMarkRange)
    }

    /// The end of the text. nil: the "· · ·" mark. A colophon (R24),
    /// every paragraph centered and unhyphenated, honoring Bold Text: an
    /// accent rule, the heading (`ColophonCopy.theEnd`) in the serif's
    /// italic, the title in small caps, the author and the listening
    /// time, both muted. None of it is a sentence, so it is never
    /// spoken, tapped or highlighted.
    static func makeEndMark(colophon: ReaderColophon?, fontSize: CGFloat,
                            bold: Bool, ink: ReaderInk) -> NSAttributedString {
        guard let colophon else {
            return NSAttributedString(string: "· · ·", attributes: markAttributes(fontSize: fontSize, ink: ink))
        }
        let page = ReaderPageStyle(fontSize: fontSize)
        func centered(spacingAfter: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.paragraphSpacing = spacingAfter
            style.hyphenationFactor = 0
            return style
        }
        let mark = NSMutableAttributedString()
        // The chapter opening's rule and spacing, so the end reads as the
        // book's own typography.
        mark.append(ruleParagraph(size: ReaderPageStyle.ruleSize, color: ink.accent,
                                  spacingBefore: page.openingSpaceAbove,
                                  spacingAfter: page.headingToRule, ink: ink))
        mark.append(NSAttributedString(string: ColophonCopy.theEnd + "\n", attributes: [
            .font: ReaderPageStyle.italicSerif(size: page.headingSize, bold: bold),
            .foregroundColor: ink.text,
            .paragraphStyle: centered(spacingAfter: page.headingToRule),
        ]))
        // Display-only typesetting, like the sentences' (curly quotes).
        mark.append(NSAttributedString(string: ReaderTypography.typeset(colophon.title) + "\n", attributes: [
            .font: ReaderPageStyle.smallCapsSerif(size: fontSize, bold: bold),
            .foregroundColor: ink.text,
            .kern: ReaderPageStyle.headingKern,
            .paragraphStyle: centered(spacingAfter: page.paragraphGap),
        ]))
        if let author = colophon.author {
            mark.append(NSAttributedString(string: author + "\n", attributes: [
                .font: ReaderPageStyle.serif(size: fontSize, bold: bold),
                .foregroundColor: ink.textMuted,
                .paragraphStyle: centered(spacingAfter: page.paragraphGap),
            ]))
        }
        mark.append(NSAttributedString(string: colophon.listeningLine, attributes: [
            .font: ReaderPageStyle.serif(size: page.colophonDetailSize, bold: bold),
            .foregroundColor: ink.textMuted,
            .paragraphStyle: centered(spacingAfter: 0),
        ]))
        mark.addAttribute(.readerFurniture, value: true, range: NSRange(location: 0, length: mark.length))
        return mark
    }

    /// The size of the "· · ·" end mark and the PDF page numerals: they grow
    /// with the text size steps (24pt beside 40pt text), never below 12pt,
    /// as the column's only page landmark.
    static func markFontSize(fontSize: CGFloat) -> CGFloat {
        max(12, (fontSize * 0.6).rounded())
    }

    /// The "· · ·" end mark's and the PDF page numerals' look.
    private static func markAttributes(fontSize: CGFloat, ink: ReaderInk) -> [NSAttributedString.Key: Any] {
        let markStyle = NSMutableParagraphStyle()
        markStyle.alignment = .center
        markStyle.paragraphSpacingBefore = (fontSize * 1.2).rounded()
        markStyle.paragraphSpacing = (fontSize * 1.6).rounded()
        return [
            .font: MarkFont.monospacedDigitSystemFont(ofSize: markFontSize(fontSize: fontSize), weight: .medium),
            .foregroundColor: ink.textMuted,
            .kern: 1.2,
            .paragraphStyle: markStyle,
            .readerFurniture: true,
        ]
    }

    /// A centered rule image on a paragraph of its own: chapter openings
    /// and the colophon (accent), PDF page marks (hairline).
    private static func ruleParagraph(size: CGSize, color: ReaderInk.Tint, spacingBefore: CGFloat,
                                      spacingAfter: CGFloat, ink: ReaderInk) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = ink.ruleImage(size, color)
        attachment.bounds = CGRect(origin: .zero, size: size)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.minimumLineHeight = max(size.height, 4)
        style.maximumLineHeight = max(size.height, 4)
        let rule = NSMutableAttributedString(attachment: attachment)
        rule.append(NSAttributedString(string: "\n"))
        rule.addAttribute(.paragraphStyle, value: style,
                          range: NSRange(location: 0, length: rule.length))
        return rule
    }
}

#if canImport(UIKit)
extension ReaderInk {
    /// The theme's colors as UIKit colors, and rule images resolved for
    /// `traits` (their display scale and appearance). The reader rebuilds
    /// on light/dark flips, so a resolved color is safe.
    init(traits: UITraitCollection) {
        self.init(text: UIColor(Theme.text),
                  textMuted: UIColor(Theme.textMuted),
                  accent: UIColor(Theme.accent),
                  lineStrong: UIColor(Theme.lineStrong),
                  ruleImage: { size, color in
                      PlatformRuleImage.make(size: size, color: color.resolvedColor(with: traits),
                                             scale: traits.displayScale)
                  })
    }
}

extension ReaderColumnText {
    /// The column for an iOS trait collection: Bold Text is
    /// `legibilityWeight == .bold`, and the colors are `ReaderInk(traits:)`.
    static func makeAttributedString(content: DocContent, fontSize: CGFloat,
                                     isChapterBook: Bool = false,
                                     colophon: ReaderColophon? = nil,
                                     columnWidth: CGFloat? = nil,
                                     traits: UITraitCollection = .current)
        -> (string: NSAttributedString, sentenceRanges: [NSRange], endMarkRange: NSRange) {
        makeAttributedString(content: content, fontSize: fontSize, isChapterBook: isChapterBook,
                             colophon: colophon, columnWidth: columnWidth,
                             bold: traits.legibilityWeight == .bold,
                             ink: ReaderInk(traits: traits))
    }

    /// The end mark for an iOS trait collection (see `makeAttributedString`).
    static func makeEndMark(colophon: ReaderColophon?, fontSize: CGFloat,
                            traits: UITraitCollection) -> NSAttributedString {
        makeEndMark(colophon: colophon, fontSize: fontSize, bold: traits.legibilityWeight == .bold,
                    ink: ReaderInk(traits: traits))
    }
}
#endif

// MARK: - Quotes (Copy, Share, VoiceOver lines)

extension ReaderColumnText {

    /// `text`'s characters, less every run of the page's furniture
    /// (`readerFurniture`): a PDF page's numeral, the end mark and the
    /// colophon are never part of a quote (L023).
    static func withoutFurniture(_ text: NSAttributedString) -> String {
        let string = text.string as NSString
        var words = ""
        text.enumerateAttribute(.readerFurniture, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { words += string.substring(with: range) }
        }
        return words
    }

    /// `text` without its attachment characters, and without the line each
    /// rule paragraph (an attachment and its newline) stood on.
    static func quotable(_ text: String) -> String {
        text.replacingOccurrences(of: attachmentMark + "\n", with: "")
            .replacingOccurrences(of: attachmentMark, with: "")
    }

    /// The words of `range` in the column's `text`, as Copy, Share and a
    /// VoiceOver line quote them: no furniture, no rule lines. Empty for a
    /// range past the end of the text.
    static func quote(of range: NSRange, in text: NSAttributedString) -> String {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { return "" }
        return quotable(withoutFurniture(text.attributedSubstring(from: range)))
    }

    /// The longest term Look Up takes (the Mac's selection limit).
    static let lookUpLimit = 256

    /// The word at `offset` for Look Up, by the system's word boundaries
    /// inside its paragraph; nil off a word (a space, punctuation, a rule,
    /// the page's furniture) or past `lookUpLimit` characters.
    static func lookUpRange(at offset: Int, in text: NSAttributedString) -> NSRange? {
        let string = text.string as NSString
        guard offset >= 0, offset < string.length,
              text.attribute(.readerFurniture, at: offset, effectiveRange: nil) == nil else { return nil }
        let paragraph = string.paragraphRange(for: NSRange(location: offset, length: 0))
        var found: NSRange?
        string.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(offset, range) {
                found = range
                stop.pointee = true
            } else if range.location > offset {
                stop.pointee = true
            }
        }
        guard let found, found.length > 0, found.length <= lookUpLimit else { return nil }
        let word = string.substring(with: found)
        return word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) ? found : nil
    }

    /// The longest word of `sentence` (the first of equals), for a Look Up
    /// asked of a whole sentence (VoiceOver's action), where no finger
    /// points at a word: the rare word is usually the long one. nil for a
    /// sentence without a word.
    static func longestWord(in sentence: String) -> String? {
        var best: String?
        sentence.enumerateSubstrings(in: sentence.startIndex..<sentence.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, word.count <= lookUpLimit,
                  word.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return }
            if word.count > (best?.count ?? 0) { best = word }
        }
        return best
    }

    /// `NSTextAttachment.character`, as a string.
    private static let attachmentMark = "\u{FFFC}"
}
