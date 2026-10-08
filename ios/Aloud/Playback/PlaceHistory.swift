import Foundation

// "Where you stopped": a short per-book list of the places listening ended,
// newest first, at the top of Contents. The controller reports every end of
// a listening session (`PlaceStop`); the pure rules below decide what the
// list keeps; `PlaceHistoryStore` keeps it on disk; `PlaceHistoryRows`
// names each entry for the row.
//
// "Place history" in code, to keep it apart from R11's unattended stops
// (`PlaybackStop`, `StopReason`), which say WHY audio stopped.

/// One end of listening, as the controller saw it: pause, an unattended stop
/// (sleep timer, headphones, a call, Mac sleep), switching books, closing
/// the book, quitting while it played, or iOS ending the app mid-speech
/// (recovered at the next launch). Emitted for every session, however
/// short: the 20 s floor is the rules' to apply, so tests never wait.
struct PlaceStop: Equatable, Sendable {
    let documentID: UUID
    /// The content the sentence index belongs to; nil when recovered from
    /// the live marker, which doesn't carry it (the library record's hash
    /// stands in).
    let contentHash: String?
    /// Where listening ended: the sentence progress was saved at.
    let sentence: Int
    /// The sentence's first `PlaceHistory.excerptLength` characters, kept
    /// so a later re-anchoring by text can carry an entry across a
    /// re-extraction instead of dropping it.
    let excerpt: String?
    /// Where this session's audio first played (after any resume rewind).
    let startSentence: Int
    let startedAt: Date
    let stoppedAt: Date
    /// Seconds from the first audio to the stop.
    let listenedSeconds: TimeInterval
    /// The listener jumped away (far enough to be offered Undo) while
    /// playing: the place they started from was their own, not this sitting's.
    let movedAway: Bool

    /// The same stop, moved to `sentence`: a boundary inside the pause ramp
    /// moved the playhead after the stop was reported.
    func moved(to sentence: Int, excerpt: String?) -> PlaceStop {
        PlaceStop(documentID: documentID, contentHash: contentHash, sentence: sentence,
                  excerpt: excerpt, startSentence: startSentence, startedAt: startedAt,
                  stoppedAt: stoppedAt, listenedSeconds: listenedSeconds, movedAway: movedAway)
    }

    /// iOS ended the app while it spoke: the live marker says where and
    /// when. A marker written before sessions were recorded has no start,
    /// and counts as a long enough listen.
    static func recovered(from live: LiveSession) -> PlaceStop {
        let startedAt = live.startedAt ?? live.wallClock
        let listened = live.startedAt.map { live.wallClock.timeIntervalSince($0) } ?? PlaceHistory.minimumListen
        return PlaceStop(documentID: live.documentID, contentHash: nil,
                         sentence: live.sentenceIndex, excerpt: nil,
                         startSentence: live.startSentence ?? live.sentenceIndex,
                         startedAt: startedAt, stoppedAt: live.wallClock,
                         listenedSeconds: max(listened, 0), movedAway: live.movedAway ?? false)
    }
}

/// The session the controller is timing: opened at the first audio that is
/// the listener's own (never a voice sample), closed by `PlaceStop`.
struct PlaceSession: Equatable, Sendable {
    let documentID: UUID
    let startSentence: Int
    let startedAt: Date
    /// `MonotonicClock.now` at the start, so a clock change can't stretch or
    /// erase the listened time.
    let startUptime: TimeInterval
    var movedAway = false
}

/// One kept place.
struct PlaceHistoryEntry: Equatable, Codable, Sendable {
    var sentence: Int
    var stoppedAt: Date
    var excerpt: String?
}

/// A book's kept places, newest first, for the content they index.
struct BookPlaces: Equatable, Codable, Sendable {
    let documentID: UUID
    var contentHash: String
    var places: [PlaceHistoryEntry]
}

/// The rules: what one stop does to a book's list. Pure, so every case is a
/// unit test (PlaceHistoryRulesTests).
enum PlaceHistory {

    /// Under this much listening a session leaves no place: a Play pressed
    /// by mistake, a quick check of the voice.
    static let minimumListen: TimeInterval = 20
    /// Two places this close are one place.
    static let samePlaceSentences = 3
    /// A rest shorter than this, resumed where it paused, is one sitting:
    /// the resume rewind's "real break" tier.
    static let sittingGap: TimeInterval = 300
    /// Places kept per book.
    static let limit = 8
    /// Rows shown before "Show N earlier stops" in a book with a chapter list.
    static let collapsedCount = 3
    /// The iPhone's half-height Contents: the newest stop alone, so the
    /// chapter list starts above the fold (`collapsedCount(atHalfHeight:)`).
    static let halfHeightCollapsedCount = 1
    static let excerptLength = 80

    /// `places` (newest first) after `stop`:
    /// 1. Under `minimumListen`, nothing changes.
    /// 2. One sitting keeps only its last stop: a session that resumed where
    ///    the newest place is (within `samePlaceSentences`), less than
    ///    `sittingGap` after it, without jumping away, replaces it.
    /// 3. One entry per place: any entry within `samePlaceSentences` of the
    ///    stop goes.
    /// 4. The stop goes on top, and the newest `limit` stay.
    static func recording(_ stop: PlaceStop, into places: [PlaceHistoryEntry]) -> [PlaceHistoryEntry] {
        guard stop.listenedSeconds >= minimumListen else { return places }
        var kept = places
        if let newest = kept.first,
           !stop.movedAway,
           abs(stop.startSentence - newest.sentence) <= samePlaceSentences,
           stop.startedAt.timeIntervalSince(newest.stoppedAt) < sittingGap {
            kept.removeFirst()
        }
        kept.removeAll { abs($0.sentence - stop.sentence) <= samePlaceSentences }
        let entry = PlaceHistoryEntry(sentence: stop.sentence, stoppedAt: stop.stoppedAt, excerpt: stop.excerpt)
        return Array(([entry] + kept).prefix(limit))
    }

    /// How many of `total` rows show: all of them in a book without a
    /// chapter list (nothing else is in the list) or once expanded, else
    /// the newest `collapsedCount` (three unless a caller passes fewer).
    static func visibleCount(total: Int, hasChapterList: Bool, expanded: Bool,
                             collapsedCount: Int = PlaceHistory.collapsedCount) -> Int {
        hasChapterList && !expanded ? min(total, collapsedCount) : total
    }

    /// Whether "Show N earlier stops" (then "Show fewer") follows the rows:
    /// only where `visibleCount` holds some back.
    static func offersEarlier(total: Int, hasChapterList: Bool,
                              collapsedCount: Int = PlaceHistory.collapsedCount) -> Bool {
        hasChapterList && total > collapsedCount
    }

    /// The rows the iPhone's Contents keeps above its earlier-stops toggle:
    /// one at half height above a chapter list, so its first chapters show
    /// without a scroll; three at full height, and at the accessibility
    /// sizes, where even one stop fills half a screen. The Mac's panel is
    /// full height and keeps `collapsedCount`.
    static func collapsedCount(atHalfHeight: Bool, hasChapterList: Bool, accessibilitySize: Bool) -> Int {
        atHalfHeight && hasChapterList && !accessibilitySize ? halfHeightCollapsedCount : collapsedCount
    }

    /// The first `excerptLength` characters of a sentence.
    static func excerpt(of text: String) -> String {
        String(text.prefix(excerptLength))
    }
}
