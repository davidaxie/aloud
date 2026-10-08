import SwiftUI

/// The chapter line's other ways into Contents, where the platform offers
/// them (`PlatformContentsEntry`, P033).
///
/// On the iPhone the position line also goes straight to search: a
/// VoiceOver action, a Voice Control name (`ReaderMessageLine
/// .positionInputLabels`) and a long-press menu with Contents and the
/// search. The error line, whose tap retries, keeps Contents in its
/// long-press menu. The search asks the sheet to open with its field
/// focused (`ContentsSearchMemory.requestSearchFocus`).
///
/// The menu stays off at the accessibility sizes. There the player bar caps
/// the line's type, so a long press is the only way to read it whole, and
/// that press belongs to the Large Content Viewer. The VoiceOver action and
/// the Voice Control name stay at every size.
///
/// Shared so the Mac compiles it; the seam's flag keeps it inert there.
struct ChapterLineContentsEntry: ViewModifier {

    let onOpenContents: () -> Void
    let offersSearchAction: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if PlatformContentsEntry.chapterLineOffersSearch {
            let entered = content
                .accessibilityActions {
                    if offersSearchAction {
                        Button(ContentsSearch.searchPrompt, action: searchThisBook)
                    }
                }
            if Self.offersMenu(dynamicTypeSize: dynamicTypeSize) {
                entered
                    .contextMenu {
                        Button(ContentsSearch.title, systemImage: "list.bullet", action: onOpenContents)
                        Button(ContentsSearch.searchPrompt, systemImage: "magnifyingglass", action: searchThisBook)
                    }
            } else {
                entered
            }
        } else {
            content
        }
    }

    /// Whether a long press opens the menu: only below the accessibility
    /// sizes, where it can't shadow the Large Content Viewer.
    nonisolated static func offersMenu(dynamicTypeSize: DynamicTypeSize) -> Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    private func searchThisBook() {
        ContentsSearchMemory.shared.requestSearchFocus()
        onOpenContents()
    }
}
