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
    let kind: DocKind
    var author: String?
    var wordCount: Int
    /// Per-book playback memory (nil = follow the global default).
    var preferredRate: Double?
    var preferredVoiceID: String?

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
         preferredVoiceID: String? = nil) {
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
    }

    // Forward-compatible decoding: kind/author/wordCount and the per-book
    // playback preferences are late additions.
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
    }
}

// MARK: - Time estimates

extension LibraryDocument {
    /// Spoken-word rate underlying all time estimates, at 1.0× playback.
    static let spokenWordsPerMinute: Double = 165

    var progressPercent: Int {
        Int((progressFraction.clamped01 * 100).rounded())
    }

    /// The speed this book actually plays at: its own per-book pin, else the
    /// current global default. The single per-book rate rule — the apply on
    /// load and the shelf's time-left estimates both resolve through here, so
    /// a card and the reader can never disagree.
    func effectiveRate(globalDefault: Double) -> Double {
        preferredRate ?? globalDefault
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

    /// The shelf's status line — "43% · 1 hr 12 min left" — rendered by the
    /// Continue Listening hero and the grid card from this ONE implementation,
    /// so separator, suffix and rounding can never drift between the two cards
    /// sitting on the same screen.
    ///
    /// `rate` is the rate the book will actually be spoken at (its per-book
    /// preference, else the global default) — never a rate borrowed from
    /// whatever was last loaded. `lead` overrides the default progress
    /// percentage; the grid card passes a page count for PDFs.
    func listeningSubtitle(rate: Double, lead: String? = nil) -> String {
        let lead = lead ?? "\(progressPercent)%"
        guard let remaining = estimatedSecondsRemaining(rate: rate) else { return lead }
        if progressFraction >= 0.99 { return "\(lead) · Finished" }
        return "\(lead) · \(ListeningEstimate.phrase(seconds: remaining)) left"
    }
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
