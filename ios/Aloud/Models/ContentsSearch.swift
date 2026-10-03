import SwiftUI

/// Contents' row labels and search-result text, apart from the views, so
/// every Contents surface reads and cuts its results the same way.
enum ContentsSearch {

    // MARK: - Chapters

    /// "CHAPTER I, 1 hour 12 minutes, current": the row's visible title
    /// first, then its time spelled out, because VoiceOver reads "min" and
    /// "hr" poorly (R25). ", current" only on the playhead's chapter.
    static func chapterAccessibilityLabel(title: String, minutes: Int, isCurrent: Bool) -> String {
        "\(title), \(ListeningEstimate.spokenPhrase(minutes: minutes))" + (isCurrent ? ", current" : "")
    }

    // MARK: - Results

    /// Characters kept before the hit: under half of a 375pt phone's body
    /// line, which holds 30–40 below the accessibility sizes. At those sizes
    /// it holds 13–25, so the hit starts the snippet after at most an
    /// opening quote or a one-letter word.
    static func leadLimit(for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? 2 : 16
    }

    /// A result's three runs: the text before the hit, the hit, the rest.
    struct Snippet: Equatable {
        let lead: String
        let hit: String
        let tail: String
    }

    /// The sentence typeset like the reading column (curly quotes, em
    /// dashes) and split around its hit. The whole sentence is typeset first
    /// so quote direction keeps its context, then split at the match's
    /// UTF-16 offsets, which typesetting preserves; only then is the lead cut.
    static func snippet(for match: SentenceMatch, leadLimit: Int) -> Snippet {
        let source = match.text
        let lower = match.range.lowerBound.utf16Offset(in: source)
        let upper = match.range.upperBound.utf16Offset(in: source)
        let typeset = ReaderTypography.typeset(source) as NSString
        return Snippet(lead: trimmedLead(typeset.substring(to: lower), limit: leadLimit),
                       hit: typeset.substring(with: NSRange(location: lower, length: upper - lower)),
                       tail: typeset.substring(from: upper))
    }

    /// `lead` whole when it is at most `limit` characters; otherwise "…" and
    /// its last `limit` characters, from the start of a word. Counted in
    /// characters, so an accent or an emoji is never split. Text with no
    /// spaces in the window (Chinese, Japanese) keeps the plain cut.
    static func trimmedLead(_ lead: String, limit: Int) -> String {
        guard lead.count > limit else { return lead }
        var kept = lead.suffix(max(limit, 0))
        let cutMidWord = lead.dropLast(kept.count).last.map { !$0.isWhitespace } ?? false
        if cutMidWord, let space = kept.firstIndex(where: \.isWhitespace) {
            kept = kept[kept.index(after: space)...]
        }
        return "\u{2026}" + kept.drop(while: \.isWhitespace)
    }
}
