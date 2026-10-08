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

    /// The navigation bar's system content (back chevron, title rendering)
    /// in `scheme`, the app's own, not the phone's.
    func toolbarColorSchemeOnPhone(_ scheme: ColorScheme?) -> some View {
        toolbarColorScheme(scheme, for: .navigationBar)
    }

    /// An opaque navigation bar in the screen's own `ground` (see
    /// `ShelfScrollEdge`); `rule` adds its hairline once content scrolls
    /// under it.
    func shelfScrollEdge(ground: Color = Theme.bg, rule: Bool = false) -> some View {
        modifier(ShelfScrollEdge(ground: ground, showsScrollRule: rule))
    }

    /// A menu lists its first item nearest the control that opens it.
    func menuOrderNearestFirst() -> some View {
        menuOrder(.priority)
    }

    /// Return on a focused control acts on it. iOS sends no Return to a
    /// focused button this way, so this is the Mac's alone.
    func returnKeyActsOnMac(_ action: @escaping () -> Void) -> some View {
        self
    }

    /// A shelf card's press: the paper plate under a finger
    /// (`ShelfPlateButtonStyle`), its corners `radius`; with `scales` off,
    /// the plate without the shrink.
    func shelfCardPressStyle(radius: CGFloat = Theme.Radius.md, scales: Bool = true) -> some View {
        buttonStyle(ShelfPlateButtonStyle(radius: radius, scales: scales))
    }

    /// A long press lifts the card as a rounded paper card, not the square
    /// cell its hit area is.
    func contextMenuPreviewCorners(_ radius: CGFloat) -> some View {
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
#elseif os(macOS)
extension View {
    /// A Mac window has no large-title bar to opt out of.
    func inlineTitleOnPhone() -> some View {
        self
    }

    /// The Mac has no Large Content Viewer (Zoom and Hover Text serve
    /// there). SwiftUI accepts the modifier but shows nothing, so the
    /// accessibility tree stays as the view built it.
    func largeContentViewerIfAvailable() -> some View {
        self
    }

    /// The same, for the form that names `largeContent`.
    func largeContentViewerIfAvailable<V: View>(@ViewBuilder _ largeContent: () -> V) -> some View {
        self
    }

    /// There is no navigation bar. The window's toolbar follows
    /// `NSApp.appearance`, which the appearance setting sets.
    func toolbarColorSchemeOnPhone(_ scheme: ColorScheme?) -> some View {
        self
    }

    /// The window paints its own toolbar ground (paper, no separator), so a
    /// screen has no bar edge or rule to set.
    func shelfScrollEdge(ground: Color = Theme.bg, rule: Bool = false) -> some View {
        self
    }

    /// A Mac menu always lists top-down, whichever way it opens.
    func menuOrderNearestFirst() -> some View {
        self
    }

    /// Return on the focused control runs `action` instead of bubbling to
    /// its ancestors: a Mac button leaves Return to them (L015).
    func returnKeyActsOnMac(_ action: @escaping () -> Void) -> some View {
        onKeyPress(.return) {
            action()
            return .handled
        }
    }

    /// A plain button, whatever `radius` and `scales` ask: the Mac card
    /// draws its own hover and press plate around it (`MacHoverPlate`).
    func shelfCardPressStyle(radius: CGFloat = Theme.Radius.md, scales: Bool = true) -> some View {
        buttonStyle(.plain)
    }

    /// A Mac context menu lifts no preview.
    func contextMenuPreviewCorners(_ radius: CGFloat) -> some View {
        self
    }
}
#endif
