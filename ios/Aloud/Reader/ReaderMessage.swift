import Foundation

/// The chapter line's one message slot (R11). Precedence, highest first:
/// stop > notice > natural-voice offer > download progress > download
/// waiting for Wi-Fi > preparing voice > position. The state-matrix test
/// iterates `resolve`.
///
/// Nil from `resolve` means no message: the line shows the reader's
/// position (chapter and time left) instead. Every string comes from the
/// fixed copy tables (StopReason, PlaybackNotice, NaturalVoiceCopy).
enum ReaderMessage: Equatable {
    /// Stopped tier: playback stopped without the listener asking, until
    /// the next Play.
    case stopped(StopReason)
    /// Changed tier: something the listener didn't do, shown while audio continues.
    case notice(PlaybackNotice)
    case naturalVoiceOffer
    case downloadProgress(Double)
    /// R21: the download is paused until Wi-Fi returns.
    case downloadWaiting
    case preparingVoice

    /// A failed download resolves to nil here: the out-of-space line shows
    /// through the offer (`NaturalVoiceOffer.isVisible`), the other failures
    /// on the download card.
    static func resolve(stop: StopReason?,
                        notice: PlaybackNotice?,
                        offerVisible: Bool,
                        modelState: ModelManager.ModelState,
                        isPreparingVoice: Bool) -> ReaderMessage? {
        if let stop { return .stopped(stop) }
        if let notice { return .notice(notice) }
        if offerVisible { return .naturalVoiceOffer }
        switch modelState {
        case .downloading(let progress): return .downloadProgress(progress)
        case .waitingForWiFi: return .downloadWaiting
        case .notInstalled, .installed, .failed: break
        }
        if isPreparingVoice { return .preparingVoice }
        return nil
    }

    /// Identity for the slot's crossfade. Progress ticks and a pause for
    /// Wi-Fi keep one key, so only a change of message animates; each stop
    /// reason has its own. The view uses "position" for nil.
    var slotKey: String {
        switch self {
        case .stopped(let reason): return "stopped.\(reason.rawValue)"
        case .notice: return "notice"
        case .naturalVoiceOffer: return "offer"
        case .downloadProgress, .downloadWaiting: return "download"
        case .preparingVoice: return "preparing"
        }
    }

    var text: String {
        switch self {
        case .stopped(let reason): return reason.text
        case .notice(let notice): return notice.text
        case .naturalVoiceOffer: return NaturalVoiceCopy.offer
        case .downloadProgress(let progress): return NaturalVoiceCopy.downloading(progress)
        case .downloadWaiting: return NaturalVoiceCopy.waitingForWiFi
        case .preparingVoice: return ListeningCopy.preparingVoice
        }
    }

    /// The text as VoiceOver says it, without the middle dot or a trailing
    /// ellipsis: "Download paused, waiting for Wi-Fi", "Preparing voice".
    var spokenText: String { PlaybackCopy.spoken(text) }
}
