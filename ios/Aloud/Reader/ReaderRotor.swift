import Foundation

/// The reading column's VoiceOver rotors (R12a), coarse to fine: Chapters
/// (Pages in a PDF), Paragraphs and Sentences. Every step lands on an item's
/// first sentence; "Play from here" and a double-tap play it through the
/// sentence-tap path.
///
/// Nothing is built up front: each step is a binary search over the item
/// starts already in `DocContent` and `ReaderNavigation`, so Pepys' Diary
/// costs nothing at reader open.
enum ReaderRotor: CaseIterable {
    case chapters, paragraphs, sentences

    static let playFromHere = "Play from here"
    /// The column's other custom actions, beside Play from here (P042).
    static let copySentence = "Copy sentence"
    static let lookUp = "Look up"
    static let textHint = "Plays from this sentence"
    /// The most of the book VoiceOver's page content holds: the passage on
    /// screen, never the whole book (R12e; the Mac's value limit).
    static let pageContentLimit = 6_000

    func name(for kind: DocKind) -> String {
        switch self {
        case .chapters: return kind == .pdf ? "Pages" : "Chapters"
        case .paragraphs: return "Paragraphs"
        case .sentences: return "Sentences"
        }
    }

    /// The name for what the book's Contents lists: a PDF with real
    /// chapters steps through Chapters, one without through Pages.
    func name(listing navigation: ReaderNavigation?, isChapterBook: Bool) -> String {
        if let navigation { return name(for: navigation.rowKind == .pages ? .pdf : .text) }
        return name(for: isChapterBook ? .text : .pdf)
    }

    /// The rotors worth offering, coarse to fine. O(1).
    static func available(content: DocContent, navigation: ReaderNavigation?) -> [ReaderRotor] {
        var rotors: [ReaderRotor] = []
        if navigation?.hasChapterList == true { rotors.append(.chapters) }
        if !content.paragraphs.isEmpty { rotors.append(.paragraphs) }
        if !content.sentences.isEmpty { rotors.append(.sentences) }
        return rotors
    }

    /// The sentence one rotor step lands on. With no `from` (the first step
    /// after focusing the text) it is the start of the item holding `anchor`,
    /// the playhead. Forward is the next item start; backward is the item's
    /// own start when `from` is past it, else the previous item's start —
    /// both are "the nearest start beyond `from`". nil at either end.
    static func target(_ rotor: ReaderRotor, from: Int?, anchor: Int, forward: Bool,
                       content: DocContent, navigation: ReaderNavigation?) -> Int? {
        switch rotor {
        case .sentences:
            let sentences = content.sentences
            return step(count: sentences.count, from: from, anchor: anchor, forward: forward,
                        start: { sentences[$0].id }, isEmpty: { _ in false })
        case .paragraphs:
            let paragraphs = content.paragraphs
            return step(count: paragraphs.count, from: from, anchor: anchor, forward: forward,
                        start: { paragraphs[$0].sentenceIDs.lowerBound },
                        isEmpty: { paragraphs[$0].sentenceIDs.isEmpty })
        case .chapters:
            // One page a step in a PDF whose Contents groups its pages.
            guard let chapters = navigation?.rotorSteps else { return nil }
            return step(count: chapters.count, from: from, anchor: anchor, forward: forward,
                        start: { chapters[$0].startSentence }, isEmpty: { chapters[$0].sentenceCount == 0 })
        }
    }

    /// The walk over `count` items whose starts never decrease. An empty
    /// item shares its start with a neighbour, so skipping it never changes
    /// the answer except at the very end, where its start is past the text.
    private static func step(count: Int, from: Int?, anchor: Int, forward: Bool,
                             start: (Int) -> Int, isEmpty: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let from else {
            var index = lastIndex(count: count, start: start) { $0 <= anchor }
            while index >= 0, isEmpty(index) { index -= 1 }
            if index < 0 {
                // The anchor sits before every item: the first one is nearest.
                index = 0
                while index < count, isEmpty(index) { index += 1 }
                return index < count ? start(index) : nil
            }
            return start(index)
        }
        if forward {
            var index = lastIndex(count: count, start: start) { $0 <= from } + 1
            while index < count, isEmpty(index) { index += 1 }
            return index < count ? start(index) : nil
        }
        var index = lastIndex(count: count, start: start) { $0 < from }
        while index >= 0, isEmpty(index) { index -= 1 }
        return index >= 0 ? start(index) : nil
    }

    /// The last index whose start satisfies `isBefore` (a prefix of the
    /// items), or -1.
    private static func lastIndex(count: Int, start: (Int) -> Int, where isBefore: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if isBefore(start(mid)) { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

/// The page's menu: the Mac's context menu (M14) and the iPhone's long-press
/// menu (P042), and the quote they share.
enum ReaderMenuCopy {
    static let playFromHere = "Play from Here"
    static let copy = "Copy"
    /// Look Up, quoting its term as AppKit's own item does.
    static func lookUp(_ term: String?) -> String {
        guard let term else { return "Look Up" }
        return "Look Up \u{201C}\(term)\u{201D}"
    }
    /// The longest term the title quotes.
    static let lookUpTermLimit = 24
    static let share = "Share\u{2026}"

    /// A shared quote and where it is from: the words, then an em dash, the
    /// title and the author (the title alone without one).
    static func sharedQuote(_ quote: String, title: String, author: String?) -> String {
        let source = [title, author].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        guard !source.isEmpty else { return quote }
        return quote + "\n\u{2014} " + source
    }

    /// The text-size step a pinch lands on, spoken (P044).
    static func textSize(points: CGFloat) -> String {
        "\(points.formatted()) point"
    }
}

/// The reader's title bar (P046).
enum ReaderTitleCopy {
    /// The title and author as one header label, or the title alone.
    static func label(title: String, author: String?) -> String {
        guard let author, !author.isEmpty else { return title }
        return "\(title), by \(author)"
    }
}

/// The reader's failure state (P050).
enum ReaderFailureCopy {
    static let title = "Couldn't open this document"
    static let detail = "It may be damaged or a scanned document."
    static let backToLibrary = "Back to Library"
}
