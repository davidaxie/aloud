import Foundation

/// The Mac target's exclusion list (contracts §2 and §3.3) as the lints read
/// it: what `AloudMac` leaves out of ios/Aloud, spelled as project.yml's
/// `excludes` spells it, relative to ios/Aloud (a file, or a folder as
/// "Folder/**"). Everything else in ios/Aloud is the shared core.
///
/// The one Swift copy of the list. From phase 1, MacProjectLintTests pins it
/// to project.yml, and the two change together. The rule for a shared file
/// that names a symbol from one of these files: move the symbol into a
/// shared file. Never un-exclude.
///
/// A helper, not a lint, so the Mac test bundle compiles it too, beside
/// SourceTree.
enum MacExclusions {

    /// The 14 iOS-only Swift files: the app shell, the audio session, and the
    /// UIKit and iPhone-sheet views the Mac draws its own way.
    static let swiftFiles = [
        "App/AloudApp.swift",
        "App/RootView.swift",
        "Bookshelf/BookshelfView.swift",
        "Library/LibraryView.swift",
        "Playback/AudioSessionManager.swift",
        "Reader/AppearanceSheet.swift",
        "Reader/ContentsSheet.swift",
        "Reader/PlayerBarView.swift",
        "Reader/ReaderHighlightLayer.swift",
        "Reader/ReaderScreen.swift",
        "Reader/ReaderTextView.swift",
        "Settings/ListeningSheet.swift",
        "Settings/SettingsView.swift",
        "Theme/SheetGrabber.swift",
    ]

    /// The iOS target's own Info.plist and asset catalog. No Swift: the Mac
    /// re-adds the data folders under Resources as resources.
    static let nonSwift = ["Info.plist", "Resources/**"]

    /// The whole `excludes` list under `path: Aloud`, in project.yml's order.
    static let projectExcludes = nonSwift + swiftFiles

    /// Whether the Mac leaves `path` (relative to ios/Aloud) out.
    static func excludes(_ path: String) -> Bool {
        SourceTree.isExcluded(path, by: projectExcludes)
    }
}
