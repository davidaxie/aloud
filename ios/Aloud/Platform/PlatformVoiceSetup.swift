import Foundation

/// What the voice surfaces do to get a listener ready before a flight, per
/// platform. (M10, M17)
enum PlatformVoiceSetup {
    #if os(iOS)
    /// The iPhone's card makes its promise (`DeviceCopy.naturalVoicePromise`)
    /// but has no flight line and no offline state: the path is watched
    /// only from a Download (M4), which with no network waits for Wi-Fi.
    static let preparesForFlight = false
    /// The System row names the voice it resolves to, as the Mac's does, so
    /// a listener on it knows which voice they hear (P035).
    static let namesResolvedSystemVoice = true
    /// No Settings pane is opened from the Listening view.
    static let addVoicesURL: URL? = nil
    #elseif os(macOS)
    /// The Mac card says to download before the flight and, with no usable
    /// network path, that it can't yet; R5's offer hides meanwhile. Only
    /// then is the path watched: from a not-installed card or an offer
    /// that would show.
    static let preparesForFlight = true
    /// The System row names the voice it resolves to, "Ava (Premium)", so
    /// the listener knows which voice the plane will hear.
    static let namesResolvedSystemVoice = true
    /// System Settings › Accessibility › Spoken Content, where premium
    /// voices download. An anchor System Settings doesn't know opens the
    /// Accessibility pane, the fallback offline-voices.md §6 allows.
    static let addVoicesURL: URL? =
        URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    #endif
}
