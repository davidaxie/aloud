import Foundation

/// R24: what the end of a book says, in place of the "· · ·" end mark once
/// the listener is at the end (`PlaybackController.isAtEnd`): an accent
/// rule, "The End", the title, the author and how long the book is to
/// listen to. Pure values, so the reader, its VoiceOver label and the tests
/// read one source.
struct ReaderColophon: Equatable {

    let title: String
    let author: String?
    let minutes: Int

    /// `words` at the app-wide `rate`, the way the cards count them, so the
    /// colophon and the card can't disagree about a book's length. Never
    /// under a minute: a finished book took some time.
    init(title: String, author: String?, words: Int, rate: Double) {
        // A title is one centered line; a newline from a file name or a PDF
        // title would break it into two.
        self.title = title
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.author = trimmed.isEmpty ? nil : trimmed
        self.minutes = max(1, ListeningEstimate.minutes(
            words: words, wordsPerMinute: LibraryDocument.spokenWordsPerMinute * rate))
    }

    /// The record's word count when it has one (the card's figure), else
    /// the words of the loaded text.
    static func forBook(_ document: LibraryDocument, textWords: Int, rate: Double) -> ReaderColophon {
        ReaderColophon(title: document.title, author: document.author,
                       words: document.wordCount > 0 ? document.wordCount : textWords,
                       rate: rate)
    }

    /// "About 1 hr 12 min of listening".
    var listeningLine: String { ColophonCopy.listening(minutes: minutes) }

    /// The whole colophon as one VoiceOver label, units spelled out:
    /// "The End, Pride and Prejudice, Jane Austen, About 11 hours 2 minutes
    /// of listening".
    var spokenText: String {
        ([ColophonCopy.theEnd, title] + (author.map { [$0] } ?? [])
            + [ColophonCopy.spokenListening(minutes: minutes)])
            .joined(separator: ", ")
    }
}

/// R24's copy, spelled once. "The End" is also what VoiceOver hears at a
/// natural end (`PlaybackController`).
enum ColophonCopy {

    static let theEnd = "The End"

    static func listening(minutes: Int) -> String {
        "About \(ListeningEstimate.phrase(minutes: minutes)) of listening"
    }

    static func spokenListening(minutes: Int) -> String {
        "About \(ListeningEstimate.spokenPhrase(minutes: minutes)) of listening"
    }
}
