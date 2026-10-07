import Foundation

enum DocKind: String, Codable {
    case pdf
    case text
}

/// Library metadata for one imported document.
/// The backing file lives at Documents/Library/<id>.<ext>.
struct LibraryDocument: Codable, Identifiable {
    let id: UUID
    var title: String
    let fileName: String
    let addedAt: Date
    var lastOpenedAt: Date?
    var pageCount: Int
    var sentenceCount: Int
    var progressSentence: Int
    var progressFraction: Double
    var contentHash: String   // invalidates progress if extractor changes output
    /// SHA-256 of the picked file's bytes, lowercase hex: the first dedupe
    /// key. Unlike contentHash it survives extractor changes, so opening the
    /// same file again finds this record. nil on records from before it
    /// existed until the launch backfill hashes their library copy.
    var sourceHash: String?
    let kind: DocKind
    var author: String?
    var wordCount: Int
    /// Legacy per-book playback memory, retired by R7: decoded and re-encoded
    /// unchanged and never applied, so the values survive on disk for one
    /// release. Delete them, with AppModel.migratedListeningGlobals, in the
    /// release after.
    var preferredRate: Double?
    var preferredVoiceID: String?
    /// The bundled classic this record was added from (Project Gutenberg
    /// ebook number); nil for Files and Open-in. Survives Rename. The
    /// Bookshelf matches on it, never on the title.
    var gutenbergID: Int?
    /// When the book was first heard: playback ran for it. A book stopped
    /// inside its first sentence has progress 0 but still counts as started
    /// for Continue listening (`DocumentStore.continueListeningCandidate`).
    /// nil until then, and on records from before it existed.
    var firstPlayedAt: Date?

    init(id: UUID,
         title: String,
         fileName: String,
         addedAt: Date,
         lastOpenedAt: Date? = nil,
         pageCount: Int,
         sentenceCount: Int,
         progressSentence: Int = 0,
         progressFraction: Double = 0,
         contentHash: String,
         kind: DocKind = .pdf,
         author: String? = nil,
         wordCount: Int = 0,
         preferredRate: Double? = nil,
         preferredVoiceID: String? = nil,
         gutenbergID: Int? = nil,
         sourceHash: String? = nil,
         firstPlayedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.pageCount = pageCount
        self.sentenceCount = sentenceCount
        self.progressSentence = progressSentence
        self.progressFraction = progressFraction
        self.contentHash = contentHash
        self.kind = kind
        self.author = author
        self.wordCount = wordCount
        self.preferredRate = preferredRate
        self.preferredVoiceID = preferredVoiceID
        self.gutenbergID = gutenbergID
        self.sourceHash = sourceHash
        self.firstPlayedAt = firstPlayedAt
    }

    // Forward-compatible decoding: kind/author/wordCount, the legacy per-book
    // playback preferences, gutenbergID (library.json v2), sourceHash and
    // firstPlayedAt are late additions. The synthesized encoder skips nil
    // optionals, so a record with none of them writes no key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        fileName = try c.decode(String.self, forKey: .fileName)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        sentenceCount = try c.decode(Int.self, forKey: .sentenceCount)
        progressSentence = try c.decode(Int.self, forKey: .progressSentence)
        progressFraction = try c.decode(Double.self, forKey: .progressFraction)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        kind = try c.decodeIfPresent(DocKind.self, forKey: .kind) ?? .pdf
        author = try c.decodeIfPresent(String.self, forKey: .author)
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        preferredRate = try c.decodeIfPresent(Double.self, forKey: .preferredRate)
        preferredVoiceID = try c.decodeIfPresent(String.self, forKey: .preferredVoiceID)
        gutenbergID = try c.decodeIfPresent(Int.self, forKey: .gutenbergID)
        sourceHash = try c.decodeIfPresent(String.self, forKey: .sourceHash)
        firstPlayedAt = try c.decodeIfPresent(Date.self, forKey: .firstPlayedAt)
    }
}

// MARK: - Time estimates

extension LibraryDocument {
    /// Spoken-word rate underlying all time estimates, at 1.0× playback.
    static let spokenWordsPerMinute: Double = 165

    /// Progress below which a book is never Finished (short of a stored 1.0,
    /// it also needs `finishedSlackSeconds`).
    static let finishedThreshold: Double = 0.99

    /// The most listening, at 1×, a book past `finishedThreshold` may have
    /// left and still count as Finished. A fraction alone is no measure of
    /// what is left: the last 1% of an article is seconds, of a long classic
    /// half an hour. Finished reopens a book at its colophon (R24), so a
    /// classic stopped that far short (a sleep timer) must stay in progress
    /// at its saved sentence. A minute still covers a stop a sentence or two
    /// short of the end.
    static let finishedSlackSeconds: TimeInterval = 60

    /// The one "Finished" rule: the card subtitle, the Continue candidate,
    /// autoplay (a Finished book opens paused), the card hint and the reopen
    /// at the colophon (R24, which the sleep timer reads as a bare end, not
    /// one heard) all ask here, so none can disagree. A stored 1.0 (a
    /// natural end, Mark as finished), or `finishedThreshold` with at most
    /// `finishedSlackSeconds` left. Measured at 1× so the speed slider never
    /// flips it; with no word count there is no time to weigh, and the
    /// threshold alone decides.
    var isFinished: Bool {
        if progressFraction >= 1 { return true }
        guard progressFraction >= Self.finishedThreshold else { return false }
        guard let left = estimatedSecondsRemaining(rate: 1) else { return true }
        return left <= Self.finishedSlackSeconds
    }

    /// Estimated total listening time at the given playback rate, or nil when unknown.
    func estimatedTotalSeconds(rate: Double = 1.0) -> TimeInterval? {
        guard wordCount > 0, rate > 0 else { return nil }
        return Double(wordCount) / (Self.spokenWordsPerMinute * rate) * 60
    }

    /// Estimated remaining listening time at the given playback rate, or nil when unknown.
    func estimatedSecondsRemaining(rate: Double = 1.0) -> TimeInterval? {
        estimatedTotalSeconds(rate: rate).map { $0 * (1 - progressFraction.clamped01) }
    }

    /// Which of the shelf's three forms a card reads (R25), or none.
    enum ShelfStatus: Equatable {
        /// Not started: the whole length, "4 hr 52 min".
        case length(minutes: Int)
        /// In progress: the time left, "1 hr 12 min left".
        case left(minutes: Int)
        /// `isFinished`: "Finished".
        case finished
        /// No word count, so no length to quote: no line at all.
        case unknown
    }

    /// The one decision behind both subtitles, so the visible and spoken
    /// lines always pick the same form and round to the same minute.
    /// Finished outranks an unknown length: a book marked finished says so
    /// even when it was never measured.
    func shelfStatus(rate: Double) -> ShelfStatus {
        if isFinished { return .finished }
        guard let total = estimatedTotalSeconds(rate: rate) else { return .unknown }
        if progressFraction <= 0 { return .length(minutes: ListeningEstimate.wholeMinutes(seconds: total)) }
        return .left(minutes: ListeningEstimate.wholeMinutes(seconds: estimatedSecondsRemaining(rate: rate) ?? 0))
    }

    /// The shelf's status line, rendered by the Continue Listening hero and
    /// the grid card from this ONE implementation: "4 hr 52 min" before the
    /// first listen, "1 hr 12 min left" in progress, "Finished", or "" when
    /// the length is unknown (the card then draws no line). A PDF reads like
    /// a book: no "12 pages" lead, and never a percent, which said nothing
    /// a listener could act on ("0% · …") (R25).
    ///
    /// `rate` is the app-wide speed, so the estimate follows the listener's
    /// own pace.
    func listeningSubtitle(rate: Double) -> String {
        switch shelfStatus(rate: rate) {
        case .length(let minutes): return ListeningEstimate.phrase(minutes: minutes)
        case .left(let minutes): return ListeningEstimate.leftPhrase(minutes: minutes)
        case .finished: return "Finished"
        case .unknown: return ""
        }
    }

    /// The same line as VoiceOver reads it — "4 hours 52 minutes",
    /// "1 hour 12 minutes left", "finished", or "" — so a card's label never
    /// says "min", "hr" or a middle dot.
    func spokenListeningSubtitle(rate: Double) -> String {
        switch shelfStatus(rate: rate) {
        case .length(let minutes): return ListeningEstimate.spokenPhrase(minutes: minutes)
        case .left(let minutes): return "\(ListeningEstimate.spokenPhrase(minutes: minutes)) left"
        case .finished: return "finished"
        case .unknown: return ""
        }
    }
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
