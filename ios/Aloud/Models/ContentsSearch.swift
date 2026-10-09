import SwiftUI

/// Contents' row labels and search-result text, apart from the views, so
/// every Contents surface reads and cuts its results the same way.
enum ContentsSearch {

    // MARK: - Copy

    /// The sheet's and the panel's title, and the chapter line's menu item.
    static let title = "Contents"
    /// The field's placeholder, and the chapter line's VoiceOver action
    /// straight to it.
    static let searchPrompt = "Search this book"
    /// The chapter line's context-menu item to the field: title case, as
    /// iOS menu items are (the field's placeholder stays sentence case).
    static let searchMenuItem = "Search This Book"
    /// The Voice Control name that opens Contents for a search.
    static let searchInputLabel = "Search"
    /// Backs out of a search: clears it and drops the keyboard (iPhone).
    static let cancelSearch = "Cancel"
    /// What a chapter, place or result row does when picked.
    static let playsFromHereHint = "Plays from here"

    // MARK: - Picks

    /// A pick in Contents (R15, M16): the shared jump, which offers Undo
    /// jump with the listener's status, then play from there if the book
    /// was not already playing. Undo jump restores the sentence and the
    /// pause. True when this call started playback: the iPhone answers it
    /// with the soft play impact, and any other pick with the place tick
    /// (R20).
    @MainActor @discardableResult
    static func jumpAndPlay(_ playback: PlaybackController, to sentence: Int, origin: JumpOrigin) -> Bool {
        playback.jump(to: sentence, origin: origin)
        guard playback.document != nil, !playback.isListenerPlaying else { return false }
        playback.seek(to: max(playback.currentSentence, 0), andPlay: true)
        return true
    }

    // MARK: - Chapters

    /// "CHAPTER I, 1 hour 12 minutes, current": the row's visible title
    /// first, then its time spelled out, because VoiceOver reads "min" and
    /// "hr" poorly (R25). ", current" only on the playhead's chapter: the
    /// form the Mac's plain announcements speak (`MacContents.cursorLabel`),
    /// which carry no trait.
    static func chapterAccessibilityLabel(title: String, minutes: Int, isCurrent: Bool) -> String {
        chapterRowLabel(title: title, minutes: minutes) + (isCurrent ? ", current" : "")
    }

    /// "CHAPTER I, 1 hour 12 minutes": the iPhone row's label. Its
    /// `.isSelected` trait says which chapter is current, so VoiceOver says
    /// it once (R4-32).
    static func chapterRowLabel(title: String, minutes: Int) -> String {
        "\(title), \(ListeningEstimate.spokenPhrase(minutes: minutes))"
    }

    // MARK: - The book's time left

    /// What follows the time in Contents' line under its title (R4-29).
    static let bookLeftSuffix = "in the book"

    /// The line: the visible time left, then `bookLeftSuffix`.
    static func bookLeftCaption(minutes: Int) -> String {
        "\(ListeningEstimate.leftPhrase(minutes: minutes)) \(bookLeftSuffix)"
    }

    /// The line as VoiceOver says it, the time spelled out.
    static func bookLeftSpoken(minutes: Int) -> String {
        "\(ListeningEstimate.spokenPhrase(minutes: minutes)) left \(bookLeftSuffix)"
    }

    /// The line shows over the list, never over a search's results.
    static func showsBookLeft(query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
