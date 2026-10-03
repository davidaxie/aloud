import Foundation

/// Every stopped reason and changed notice the chapter line, the Continue
/// card and VoiceOver say (R11's fixed table). Nothing else spells these
/// strings: a lint holds every other file to that, so the visible line and
/// what VoiceOver hears can never drift apart.
///
/// A stopped reason is why playback stopped without the listener asking. It
/// persists (one app-wide slot, `PlaybackStopStore`) until the next Play.
/// The raw values are persisted: `closedByIOS` keeps its name on every
/// platform, where it means the process ended mid-speech.
enum StopReason: String, Codable, CaseIterable, Sendable {
    case headphonesDisconnected, interrupted, sleepTimer, playbackError, tooHot, closedByIOS
    /// The Mac went to sleep mid-speech. Never raised on an iPhone, whose
    /// lock screen keeps the audio playing.
    case macSlept

    /// The device is named through `DeviceNoun`, and a line worded
    /// differently per platform comes whole from `DeviceCopy`.
    var text: String {
        switch self {
        case .headphonesDisconnected: return "Paused · headphones disconnected"
        case .interrupted: return "Paused by a call or another app"
        case .sleepTimer: return "Paused by sleep timer"
        case .playbackError: return DeviceCopy.playbackFailed
        case .tooHot: return "Paused · \(DeviceNoun.subject) is too hot"
        case .closedByIOS: return DeviceCopy.closedUnexpectedly
        case .macSlept: return "Paused · \(DeviceNoun.subject) went to sleep"
        }
    }

    var spokenText: String { PlaybackCopy.spoken(text) }
}

/// A change the listener didn't directly make: shown in the chapter line for
/// `displaySeconds` while audio continues, announced once.
enum PlaybackNotice: Equatable, Sendable {
    case fellBackToSystem
    case nowReadingIn(voiceName: String)
    case backedUp(sentences: Int)
    case skippedSentence
    case coolingDown

    var text: String {
        switch self {
        case .fellBackToSystem: return "Natural voice unavailable · using System"
        case .nowReadingIn(let name): return "Now reading in \(name)"
        case .backedUp(let sentences):
            return sentences == 1 ? "Backed up 1 sentence" : "Backed up \(sentences) sentences"
        case .skippedSentence: return "Skipped a sentence the voice couldn't read"
        case .coolingDown: return "Using the System voice while \(DeviceNoun.subject) cools"
        }
    }

    var spokenText: String { PlaybackCopy.spoken(text) }

    static let displaySeconds: TimeInterval = 8
}

/// The sleep stop's one action (R19). The minutes come from the rewind
/// itself and are worded by ListeningEstimate (R25), so the label can't
/// promise a different distance than the button rewinds.
enum StopCopy {
    static let rewindMinutes = Int(PlaybackController.sleepRewindSeconds / 60)
    static let backFiveMinutes = "Back " + ListeningEstimate.phrase(minutes: rewindMinutes)
    static let backFiveMinutesSpoken = "Back " + ListeningEstimate.spokenPhrase(minutes: rewindMinutes)
    static let backFiveMinutesHint = "Plays from \(ListeningEstimate.spokenPhrase(minutes: rewindMinutes)) earlier"
}

enum PlaybackCopy {
    /// The visible text as VoiceOver says it: " · " → ", ", a trailing "…"
    /// trimmed. VoiceOver reads the middle dot aloud as a word.
    static func spoken(_ text: String) -> String {
        var spoken = text.replacingOccurrences(of: " · ", with: ", ")
        if spoken.hasSuffix("…") { spoken.removeLast() }
        return spoken
    }
}
