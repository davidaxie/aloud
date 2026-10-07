import Foundation

/// How the copy names the device, so shared strings read right on each
/// platform. The only place a device or system name is spelled. (C1)
enum DeviceNoun {
    #if os(iOS)
    /// The bare noun.
    static let device = "iPhone"
    /// Mid-sentence subject: "Paused · iPhone is too hot".
    static let subject = "iPhone"
    /// Sentence-initial subject: "iPhone is out of space."
    static let Subject = "iPhone"
    /// With its article: "needs an iPhone with more memory".
    static let withArticle = "an iPhone"
    #elseif os(macOS)
    static let device = "Mac"
    /// "Paused · your Mac is too hot", "… while your Mac cools".
    static let subject = "your Mac"
    /// "Your Mac is out of space."
    static let Subject = "Your Mac"
    /// "needs a Mac with more memory".
    static let withArticle = "a Mac"
    #endif
}

/// Whole lines whose wording, not just the noun, differs by platform.
enum DeviceCopy {
    #if os(iOS)
    /// The stop recorded when the process ended mid-speech
    /// (`StopReason.closedByIOS`).
    static let closedUnexpectedly = "Stopped when iOS closed Aloud"
    /// The stop after the voice failed (`StopReason.playbackError`), with
    /// the gesture that retries it.
    static let playbackFailed = "Playback stopped · tap to try again"
    /// The confirmation before the natural voice downloads on a costly
    /// network, naming what is left to fetch: the whole download, or less
    /// after an attempt that staged a file.
    static var meteredPrompt: String { meteredPrompt(size: ModelManager.downloadSizeText) }
    static func meteredPrompt(size: String) -> String { "Download \(size) on cellular?" }
    /// A line under that prompt naming the costly network. None on the
    /// iPhone, where "cellular" already says it.
    static let meteredDetail: String? = nil
    /// The same question on a costly path that isn't cellular: a Wi-Fi
    /// with Low Data Mode on, or another phone's Personal Hotspot.
    static var meteredNetworkPrompt: String { meteredNetworkPrompt(size: ModelManager.downloadSizeText) }
    static func meteredNetworkPrompt(size: String) -> String { "Download \(size) on a metered connection?" }
    /// Under that prompt, what makes the Wi-Fi costly.
    static let meteredNetworkDetail: String? = "This Wi-Fi is a Personal Hotspot or uses Low Data Mode."
    /// The download waits for a network that costs nothing.
    static let waitingForNetwork = "Download paused · waiting for Wi-Fi"
    /// Where the installed voice lives: "353 MB on device · works offline".
    static let onDevice = "on device"
    /// The card's line with no usable network path. None on the iPhone,
    /// whose Download with no network waits for Wi-Fi.
    static let connectToDownload: String? = nil
    /// The installed card's remove action, which asks first.
    static let removeDownload = "Remove Download"
    /// Where more System voices come from. None on the iPhone.
    static let addSystemVoices: String? = nil
    /// What to do after a file couldn't be opened: add it again from where
    /// it came.
    static let addAgain = "Try adding it again from Files."
    #elseif os(macOS)
    /// A crash, a force quit or a flat battery mid-read: the Mac's system
    /// doesn't close apps on its own.
    static let closedUnexpectedly = "Stopped when Aloud quit unexpectedly"
    /// The Mac's line carries no gesture: its Try again button retries.
    static let playbackFailed = "Playback stopped"
    static var meteredPrompt: String { meteredPrompt(size: ModelManager.downloadSizeText) }
    static func meteredPrompt(size: String) -> String { "Download \(size) on a metered connection?" }
    /// A Mac has no cellular radio: the costly path is a phone's hotspot or
    /// a network the listener marked Low Data.
    static let meteredDetail: String? = "Your Mac is using a Personal Hotspot or Low Data Mode."
    /// Every costly path a Mac has is one of those: the same question.
    static var meteredNetworkPrompt: String { meteredPrompt }
    static func meteredNetworkPrompt(size: String) -> String { meteredPrompt(size: size) }
    static let meteredNetworkDetail: String? = meteredDetail
    static let waitingForNetwork = "Download paused · waiting for Wi-Fi or Ethernet"
    /// "353 MB on this Mac · works offline" (M17).
    static let onDevice = "on this Mac"
    /// No usable network path: Download is disabled until there is one (M17).
    static let connectToDownload: String? = "Connect to the internet to download."
    /// A Mac button that asks before it acts ends in an ellipsis.
    static let removeDownload = "Remove Download\u{2026}"
    /// Opens Spoken Content, where premium voices download before a flight (M10).
    static let addSystemVoices: String? = "Add voices in System Settings\u{2026}"
    /// A Mac file arrives by the open panel, a drop or Open With, so the
    /// step names none of them.
    static let addAgain = "Try adding it again."
    #endif
}
