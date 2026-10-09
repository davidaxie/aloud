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

extension Theme {
    enum SheetTarget {
        /// iOS 26 draws a partly raised sheet scaled by about 0.98-0.99 at rest,
        /// so a target inside one needs headroom to stay 44 pt on screen.
        static let minimum: CGFloat = 46
    }
}

/// The reader sheets' header copy.
enum SheetCopy {
    static let close = "Close"
    /// What Voice Control also answers to, the Aa sheet's old label among them.
    static let closeInputLabels = ["Close", "Done"]
}

/// One header for the reader's three sheets (Contents, Voice & speed and
/// Aa): the grabber, the centred title and a close button, so every sheet
/// closes the same way at any height, the keyboard up included.
///
/// The button rides an overlay on the title's row, its circle's trailing
/// edge on the sheet gutter, so the header is no taller than its title:
/// Voice & speed's opening detent and Aa's fitted one keep their room. The
/// title pads past the button on both sides, so it stays centred and a
/// wrapped line never runs under it. At the accessibility sizes the button
/// takes its own row above the title, and VoiceOver still meets the
/// heading first.
///
/// The button's frame reaches past the title's row, a few points into the
/// content below where the gap under the header is small (Voice & speed,
/// Aa). The header sits above its siblings, so the content drawn after it
/// never takes those touches and the whole frame stays the button's.
///
/// The circle is solid surface2 with a border, never glass: the sheets
/// stand on a solid surface.
///
/// One gap, `Theme.Space.xs`, from the grabber to the title on every
/// sheet, so the three titles sit at one height (R4-30); a sheet spaces
/// what follows its header with its own padding.
struct SheetHeader: View {
    let title: String
    let titleIdentifier: String
    let closeIdentifier: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The drawn circle; its hit frame is `Theme.SheetTarget.minimum`.
    static let circle: CGFloat = 30
    /// The hit frame's trailing inset that puts the circle's edge on the gutter.
    static let closeTrailing = Theme.Space.sheetGutter - (Theme.SheetTarget.minimum - circle) / 2

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            SheetGrabber()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    closeButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, Self.closeTrailing)
                    titleText
                        .padding(.horizontal, Theme.Space.sheetGutter)
                        // VoiceOver meets the sheet's heading before the button.
                        .accessibilitySortPriority(1)
                }
                .accessibilityElement(children: .contain)
            } else {
                titleText
                    .padding(.horizontal, Theme.Space.sheetGutter + Theme.SheetTarget.minimum)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        closeButton
                            .padding(.trailing, Self.closeTrailing)
                    }
            }
        }
        .zIndex(1)
    }

    // Wraps, centred inside the gutters, rather than truncating at the
    // largest sizes or while the detent is still moving (J029).
    private var titleText: some View {
        Text(title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(titleIdentifier)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(Theme.font(.footnote).weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: Self.circle, height: Self.circle)
                .background(Theme.surface2, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
                .frame(width: Theme.SheetTarget.minimum, height: Theme.SheetTarget.minimum)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The glyph stops growing inside its circle; a long press past
        // that shows it large.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .largeContentViewerIfAvailable {
            Label(SheetCopy.close, systemImage: "xmark")
        }
        .accessibilityLabel(SheetCopy.close)
        .accessibilityInputLabels(SheetCopy.closeInputLabels.map { Text($0) })
        .accessibilityIdentifier(closeIdentifier)
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
    /// on a tap outside it; its `SheetHeader` close button does, as on every
    /// reader sheet. Nil keeps the system's default: a scrim that dismisses
    /// on a tap.
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
