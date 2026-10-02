import Foundation

/// The one place listening time is computed and phrased. Every surface that
/// quotes a duration — shelf cards, Continue Listening, the Bookshelf rows
/// (and their spoken "about 5 hours" label), the reader's chapter line (and
/// its spoken "8 minutes left in chapter"), Contents, the sleep chip
/// ("28:14", "+15 min") and the sleep stop's "Back 5 min" — goes through
/// here, so the words→minutes rule and the "4 hr 52 min" wording can never
/// drift apart (R25).
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

    /// The one seconds→minutes rounding: to the nearest minute, never less
    /// than one for any time at all, and 0 for none (or a non-finite value).
    /// The cards round with it, so a visible "1 hr 12 min left" and the
    /// spoken "1 hour 12 minutes left" can't land on different minutes.
    static func wholeMinutes(seconds: TimeInterval) -> Int {
        (seconds.isFinite && seconds > 0) ? max(1, Int((seconds / 60).rounded())) : 0
    }

    static func phrase(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours) hr \(rest) min" : "\(hours) hr"
    }

    /// "8 min left", "1 hr 12 min left" — the visible time-left wording.
    static func leftPhrase(minutes: Int) -> String {
        "\(phrase(minutes: minutes)) left"
    }

    /// The same span spelled out for VoiceOver, which reads "min" and "hr"
    /// poorly: "1 minute", "8 minutes", "1 hour 12 minutes", "2 hours".
    static func spokenPhrase(minutes: Int) -> String {
        let total = max(minutes, 1)
        guard total >= 60 else { return count(total, "minute") }
        let hours = total / 60
        let rest = total % 60
        return rest > 0
            ? "\(count(hours, "hour")) \(count(rest, "minute"))"
            : count(hours, "hour")
    }

    /// The spoken span with "more" after its leading number, for a hint that
    /// adds time ("Keeps playing for 15 more minutes"): "1 more minute",
    /// "15 more minutes", "1 more hour", "1 more hour 30 minutes".
    static func spokenMorePhrase(minutes: Int) -> String {
        let phrase = spokenPhrase(minutes: minutes)
        guard let space = phrase.firstIndex(of: " ") else { return phrase }
        return phrase[..<space] + " more" + phrase[space...]
    }

    /// A deliberately rough length for the Bookshelf row's spoken label:
    /// "about 14 minutes" under an hour, else whole hours ("about 13 hours").
    static func aboutPhrase(minutes: Int) -> String {
        guard minutes >= 60 else { return "about \(count(max(minutes, 1), "minute"))" }
        return "about \(count(Int((Double(minutes) / 60).rounded()), "hour"))"
    }

    /// A position as a clock — "0:00", "4:05", "1:02:05" — for the scrub
    /// preview. Floors, so it never reads ahead of the voice; negatives read
    /// "0:00".
    static func clock(seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? Int(max(seconds, 0).rounded(.down)) : 0
        let duration = Duration.seconds(whole)
        return whole < 3600
            ? duration.formatted(.time(pattern: .minuteSecond))
            : duration.formatted(.time(pattern: .hourMinuteSecond))
    }

    /// The sleep chip's countdown — "28:14", "60:00", "0:01" — as minutes
    /// and seconds, with the minutes never rolled into hours, so a fresh
    /// 1-hour timer reads "60:00" and every armed value has one shape.
    /// Rounds UP, so the chip never reads "0:00" while time is left. Below
    /// zero (inside the landing window) or non-finite reads "0:00".
    static func countdown(seconds: TimeInterval) -> String {
        let whole = (seconds.isFinite && seconds > 0) ? Int(seconds.rounded(.up)) : 0
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }
}
