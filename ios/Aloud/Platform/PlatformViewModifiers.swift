import SwiftUI

// SwiftUI modifiers that exist only on some platforms, as one call each the
// shared views can make everywhere. (U1, U2)

#if os(iOS)
extension View {
    /// A pushed screen's title sits inline in the navigation bar.
    func inlineTitleOnPhone() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }

    /// Long-press shows the control enlarged at accessibility text sizes.
    func largeContentViewerIfAvailable() -> some View {
        accessibilityShowsLargeContentViewer()
    }

    /// The same, showing `largeContent` (an icon-only control's label).
    func largeContentViewerIfAvailable<V: View>(@ViewBuilder _ largeContent: () -> V) -> some View {
        accessibilityShowsLargeContentViewer(largeContent)
    }
}
#endif
