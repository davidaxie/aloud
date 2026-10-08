import Foundation

/// The ways into Contents beyond a tap on the chapter line (P033).
///
/// The iPhone's chapter line is its only way in, so it also offers search
/// directly: a VoiceOver action, a Voice Control name and a long-press
/// menu, on the chapter line and on the error line that otherwise only
/// retries. The Mac reaches Contents from its toolbar, menu bar and Find,
/// and its player bar shares `ReaderMessageLine`, so the line stays as it
/// is there.
enum PlatformContentsEntry {
    #if os(iOS)
    static let chapterLineOffersSearch = true
    #elseif os(macOS)
    static let chapterLineOffersSearch = false
    #endif
}
