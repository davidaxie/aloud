import Foundation

/// The one place listening time is computed and phrased. Every surface that
/// quotes a duration — shelf cards, Continue Listening, the bookshelf rows,
/// the chapter drawer, the speed sheet — goes through here, so the words→
/// minutes rule and the "4 hr 52 min" wording can never drift apart.
enum ListeningEstimate {

    /// Whole-minute estimate for a span of words at a spoken-word rate.
    /// `LibraryDocument.spokenWordsPerMinute` is the 1.0× rate — multiply it
    /// by the active playback rate for a rate-aware estimate. Never less than
    /// a minute for a non-empty span; no words is no time.
    static func minutes(words: Int,
                        wordsPerMinute: Double = LibraryDocument.spokenWordsPerMinute) -> Int {
        guard words > 0, wordsPerMinute > 0 else { return 0 }
        return max(1, Int((Double(words) / wordsPerMinute).rounded()))
    }

    static func phrase(seconds: TimeInterval) -> String {
        phrase(minutes: max(1, Int((seconds / 60).rounded())))
    }

    static func phrase(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours) hr \(rest) min" : "\(hours) hr"
    }
}
