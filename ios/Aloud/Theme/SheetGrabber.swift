import SwiftUI

/// The app's bottom-sheet grabber: one capsule, drawn the same way in every
/// fixed-height sheet. `.sheetChrome(_:)` decides which indicator a sheet
/// gets, and the grabber follows that decision, so a sheet can't end up
/// showing both (the speed sheet once did) or neither.
///
/// On a resizable (multi-detent) sheet the system indicator stays, because
/// it is the control VoiceOver exposes for resizing (adjustable: swipe up or
/// down to change the detent); this purely decorative, VoiceOver-hidden
/// capsule would take that away. There the grabber keeps its footprint —
/// so the sheet's layout doesn't shift — but draws nothing.
struct SheetGrabber: View {
    @Environment(\.sheetShowsSystemDragIndicator) private var systemIndicatorShown

    var body: some View {
        Capsule()
            .fill(Theme.lineStrong)
            .frame(width: 36, height: 4)
            .opacity(systemIndicatorShown ? 0 : 1)
            .padding(.top, Theme.Space.xs)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Standard sheet presentation on a solid `surface` ground (never the
    /// system's glass/material sheet). A sheet with more than one detent
    /// keeps the system drag indicator — the accessible resize control — and
    /// any `SheetGrabber` inside it steps aside; a single-detent sheet has
    /// nothing to resize, so it hides the system indicator and shows the
    /// app's own grabber.
    ///
    /// `backgroundInteraction` leaves the presenting screen live, with no
    /// scrim, up through that detent (the Aa sheet, so size and theme
    /// changes are judged on the real page). Such a sheet no longer closes
    /// on a tap outside it, so it carries its own Done. Nil keeps the
    /// system's default: a scrim that dismisses on a tap.
    func sheetChrome(_ detents: Set<PresentationDetent>,
                     backgroundInteraction: PresentationDetent? = nil) -> some View {
        let resizable = detents.count > 1
        return environment(\.sheetShowsSystemDragIndicator, resizable)
            .presentationDetents(detents)
            .presentationDragIndicator(resizable ? .visible : .hidden)
            .presentationBackground(Theme.surface)
            .presentationBackgroundInteraction(SheetBackground.interaction(upThrough: backgroundInteraction))
    }

    /// `sheetChrome(_:)` for a sheet that moves its own detent (Contents
    /// grows to `.large` when its search field takes focus; Voice & speed
    /// opens at its lower detent).
    func sheetChrome(_ detents: Set<PresentationDetent>,
                     selection: Binding<PresentationDetent>,
                     backgroundInteraction: PresentationDetent? = nil) -> some View {
        let resizable = detents.count > 1
        return environment(\.sheetShowsSystemDragIndicator, resizable)
            .presentationDetents(detents, selection: selection)
            .presentationDragIndicator(resizable ? .visible : .hidden)
            .presentationBackground(Theme.surface)
            .presentationBackgroundInteraction(SheetBackground.interaction(upThrough: backgroundInteraction))
    }
}

/// What a sheet leaves of the screen behind it.
enum SheetBackground {
    /// Live up through `detent`; nil is the system's default (dimmed, and a
    /// tap there dismisses).
    static func interaction(upThrough detent: PresentationDetent?) -> PresentationBackgroundInteraction {
        guard let detent else { return .automatic }
        return .enabled(upThrough: detent)
    }
}

// MARK: - Indicator hand-off

private struct SheetShowsSystemDragIndicatorKey: EnvironmentKey {
    static let defaultValue = false
}

fileprivate extension EnvironmentValues {
    /// Set by `sheetChrome(_:)`: true when the sheet shows the system drag
    /// indicator, telling any `SheetGrabber` inside it not to draw.
    var sheetShowsSystemDragIndicator: Bool {
        get { self[SheetShowsSystemDragIndicatorKey.self] }
        set { self[SheetShowsSystemDragIndicatorKey.self] = newValue }
    }
}
