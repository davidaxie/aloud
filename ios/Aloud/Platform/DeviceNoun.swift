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
    #endif
}

/// Whole lines whose wording, not just the noun, differs by platform.
enum DeviceCopy {
    // `closedUnexpectedly` arrives with the PlaybackNotice change that reads
    // it: until then AppLintTests holds that line to PlaybackNotice.swift.
    #if os(iOS)
    /// The confirmation before the natural voice downloads on a costly
    /// network.
    static var meteredPrompt: String { "Download \(ModelManager.downloadSizeText) on cellular?" }
    /// A line under that prompt naming the costly network. None on the
    /// iPhone, where "cellular" already says it.
    static let meteredDetail: String? = nil
    /// The download waits for a network that costs nothing.
    static let waitingForNetwork = "Download paused · waiting for Wi-Fi"
    #endif
}
