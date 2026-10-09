import SwiftUI

/// A navigation-bar button's 44 pt hit area, sized the way the system sizes
/// its own bar items (R4-07).
///
/// From iOS 26 the bar sets each item on a glass platter that is the hit
/// region, at least 44 pt, so the label stays its own size: a label framed
/// to 44 pt got the glass padding around the frame, a 56 pt pill for a lone
/// glyph and 68 pt for Aa, next to the system back button's 44 pt circle.
/// Before iOS 26 the bar draws no platter, and the frame is the only thing
/// that gives the glyph a 44 pt target. The Mac's toolbar is AppKit's and
/// sizes its own items, so there it changes nothing.
struct BarItemTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            content
        } else {
            content
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        #else
        content
        #endif
    }
}
