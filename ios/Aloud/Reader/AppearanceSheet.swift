import SwiftUI

/// R21: the three appearance controls in one view, so each preference has
/// one home: text size (a two-button stepper, a small and a large serif A,
/// over the nine steps, its size in points beside its eyebrow), System /
/// Light / Dark, and Word highlight. The reader's Aa sheet presents it and
/// Settings pushes it (`AppearanceSettingsPage`). Everything persists at
/// once; `ReaderTextView` rebuilds its attributed string when the size
/// changes. At AX4/AX5 and on small phones the sections outgrow the space:
/// they scroll rather than clip, and at sizes that fit nothing bounces.
///
/// Each section's eyebrow sits on the gutter its control starts at, and the
/// toggle row's title is body text, as on the Voice & speed sheet (P038).
/// For VoiceOver the scheme capsules are one segmented control and the size
/// readout one adjustable element (P039).
struct AppearanceView: View {

    /// The content's natural height, for the sheet's content-sized detent.
    private let onContentHeight: ((CGFloat) -> Void)?

    init(onContentHeight: ((CGFloat) -> Void)? = nil) {
        self.onContentHeight = onContentHeight
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    @EnvironmentObject private var model: AppModel

    @AppStorage(ReaderTextSize.prefKey)
    private var textSizeStep = ReaderTextSize.defaultStep

    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    /// The stepper's glyphs, about 15 and 24 pt, growing with Dynamic Type
    /// up to the caps that keep them inside their 44 pt halves.
    @ScaledMetric(relativeTo: .body) private var smallerGlyph: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var largerGlyph: CGFloat = 24
    private static let smallerGlyphMax: CGFloat = 20
    private static let largerGlyphMax: CGFloat = 32
    /// The readout's caption line, scaled with it (its hit region's overhang).
    @ScaledMetric(relativeTo: .caption) private var readoutLine: CGFloat = 16

    var body: some View {
        ScrollView {
            sections
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onContentHeight?(height)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // Sentence case in source, like every other label (R25).
                textSizeHeader
                textSizeRow
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel(AppearanceCopy.appearance)
                appearanceRow
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                sectionLabel("Reading")
                wordHighlightRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.md)
        .padding(.horizontal, Theme.Space.sheetGutter)
        .padding(.bottom, Theme.Space.xl)
    }

    // MARK: - Text size

    /// The stored step, clamped (an out-of-range value reads as the nearest end).
    private var currentStep: Int {
        min(max(textSizeStep, 0), ReaderTextSize.steps.count - 1)
    }

    private var currentPoints: CGFloat {
        ReaderTextSize.points(forStep: currentStep)
    }

    /// One step through the shared rule (`ReaderTextSize.stepped`); nothing
    /// past either end.
    private func step(bigger: Bool) {
        guard let target = ReaderTextSize.stepped(from: currentStep, bigger: bigger) else { return }
        textSizeStep = target
    }

    /// The size in points on the eyebrow's baseline, trailing. VoiceOver
    /// hears it as the one adjustable size, so a swipe up or down steps it
    /// without hunting for the buttons. Its 44 pt hit region overhangs the
    /// row by the difference from its caption line, so the row stays the
    /// eyebrow's height.
    private var textSizeReadout: some View {
        Text(AppearanceCopy.points(currentPoints))
            .font(Theme.font(.caption))
            .foregroundStyle(Theme.textMuted)
            .numericReadout(Double(currentPoints))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .padding(.vertical, -max(0, (44 - readoutLine) / 2))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppearanceCopy.textSize)
            .accessibilityValue(AppearanceCopy.spokenPoints(currentPoints))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(bigger: true)
                case .decrement: step(bigger: false)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("appearance.textSize.value")
    }

    /// The eyebrow on the gutter and the readout trailing, on one baseline;
    /// stacked where the two can't share a line (AX5).
    private var textSizeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                sectionLabel(AppearanceCopy.textSize)
                textSizeReadout
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                sectionLabel(AppearanceCopy.textSize)
                textSizeReadout
            }
        }
    }

    /// A two-button stepper, one step per tap, each end disabled at its
    /// limit: a capsule on surface2 with a border and xxs padding, as the
    /// Appearance row below it, split by a hairline into two equal halves.
    /// Each half is a serif A, small and large, in the column's own weight
    /// (its bold face under Bold Text, J027).
    private var textSizeRow: some View {
        HStack(spacing: 0) {
            stepButton(bigger: false, glyphSize: min(smallerGlyph, Self.smallerGlyphMax),
                       systemImage: "textformat.size.smaller",
                       label: "Smaller text", identifier: "appearance.textSize.smaller")
            stepButton(bigger: true, glyphSize: min(largerGlyph, Self.largerGlyphMax),
                       systemImage: "textformat.size.larger",
                       label: "Larger text", identifier: "appearance.textSize.larger")
        }
        // The halves are equal, so the split sits in the middle.
        .overlay {
            Rectangle()
                .fill(Theme.Stroke.borderColor)
                .frame(width: Theme.Stroke.borderWidth)
                .padding(.vertical, Theme.Space.sm)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.xxs)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
    }

    private func stepButton(bigger: Bool, glyphSize: CGFloat, systemImage: String, label: String,
                            identifier: String) -> some View {
        let enabled = ReaderTextSize.stepped(from: currentStep, bigger: bigger) != nil
        return Button {
            step(bigger: bigger)
        } label: {
            Text(verbatim: "A")
                .font(Theme.readerSerif(glyphSize, weight: legibilityWeight == .bold ? .bold : .regular))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(StepperHalfButtonStyle())
        // The glyphs stop growing at their caps; a long press past them
        // shows the half large.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .largeContentViewerIfAvailable {
            Label(label, systemImage: systemImage)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(AppearanceCopy.spokenPoints(currentPoints))
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Appearance

    /// The stored scheme, for the segmented control VoiceOver hears.
    private var appearanceSelection: Binding<AppearancePreference> {
        Binding(get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
                set: { select($0) })
    }

    private func select(_ preference: AppearancePreference) {
        appearanceRaw = preference.rawValue
    }

    /// One row of three segments; at accessibility sizes the segments stack
    /// so "System" never hyphenates across two lines. In the row VoiceOver
    /// hears one segmented control named Appearance, with each choice's
    /// place in the three; the capsules draw exactly as before. Stacked, the
    /// three keep their own elements, so each focus rectangle and Voice
    /// Control number sits on the capsule it names (a segmented control
    /// would lay its segments side by side across the stack).
    @ViewBuilder
    private var appearanceRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                ForEach(Array(AppearancePreference.allCases.enumerated()), id: \.element) { index, preference in
                    appearanceSegment(preference)
                        .accessibilityValue(AppearanceCopy.position(index + 1,
                                                                    of: AppearancePreference.allCases.count))
                }
            }
            .padding(Theme.Space.xxs)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppearanceCopy.appearance)
            .accessibilityIdentifier("appearance.scheme")
        } else {
            HStack(spacing: 0) {
                ForEach(AppearancePreference.allCases) { preference in
                    appearanceSegment(preference)
                }
            }
            .padding(Theme.Space.xxs)
            .background(Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            .accessibilityRepresentation {
                Picker(AppearanceCopy.appearance, selection: appearanceSelection) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }
            // A segmented picker drops its title: without this VoiceOver
            // reads the three choices with no name for the control.
            .accessibilityLabel(AppearanceCopy.appearance)
            .accessibilityIdentifier("appearance.scheme")
        }
    }

    /// One selection style, as on the speed presets: the selected segment is
    /// an accentSoft fill with an accentStrong semibold label; the others
    /// are bare muted labels. In the row VoiceOver reads the segmented
    /// control that represents it; stacked, each segment speaks for itself,
    /// its name and selection never color alone.
    private func appearanceSegment(_ preference: AppearancePreference) -> some View {
        let selected = preference.rawValue == appearanceRaw
        return Button {
            select(preference)
        } label: {
            Text(preference.label)
                .font(Theme.font(.callout).weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.accentStrong : Theme.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    selected ? Theme.accentSoft : Color.clear,
                    in: Capsule())
                // Edged under Increase Contrast, so the selection isn't a faint tint alone.
                .overlay(Capsule().strokeBorder(selected ? Theme.Stroke.selectedColor : Color.clear,
                                                lineWidth: Theme.Stroke.selectedWidth))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preference.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Reading

    /// R13's underline under the spoken word. Off by default — the calm
    /// sentence pill is the default experience. The pref's only binding.
    /// Its title is body text, as the Voice & speed sheet's toggle is.
    private var wordHighlightRow: some View {
        PreferenceToggleRow(title: PreferenceCopy.wordHighlightTitle,
                            subtitle: PreferenceCopy.wordHighlightSubtitle,
                            isOn: $model.wordHighlight)
            .accessibilityIdentifier("appearance.wordHighlight")
    }

    // MARK: - Shared

    /// On the section's leading gutter, over its control.
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A text-size half pressed: Theme.surface in a capsule, at the press
/// beat, never a scale.
private struct StepperHalfButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface : Color.clear, in: Capsule())
            .animation(.easeOut(duration: Theme.Motion.press), value: configuration.isPressed)
    }
}

/// The reader's `Aa` sheet: the pinned title over `AppearanceView`, sized to
/// its content. At accessibility sizes the content can outgrow the fitted
/// height the system allows, so `.large` is offered too and the sheet can
/// grow; whatever still doesn't fit scrolls.
///
/// The page stays live behind it, with no scrim, up through the fitted
/// detent, so size and theme changes are judged on the real page as it
/// reflows (P037). A tap outside no longer closes it, so its header carries
/// Done; a drag down still does.
struct AppearanceSheet: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    /// Seeded near the default-size layout so the first frame barely moves.
    @State private var headerHeight: CGFloat = 72
    @State private var contentHeight: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the scroll view: the title never scrolls away.
            VStack(spacing: Theme.Space.xs) {
                SheetGrabber()
                header
            }
            .padding(.bottom, Theme.Space.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerHeight = height
            }

            AppearanceView(onContentHeight: { contentHeight = $0 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheetChrome(detents, backgroundInteraction: fittedDetent)
    }

    private var fittedDetent: PresentationDetent {
        .height(headerHeight + contentHeight)
    }

    private var detents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [fittedDetent, .large] : [fittedDetent]
    }

    /// The title stays centred: beside Done, a hidden twin of it on the
    /// other side balances the row. At accessibility sizes Done takes its
    /// own line above the title, so neither squeezes the other.
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                doneButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Theme.Space.md)
                // VoiceOver still meets the sheet's heading before Done.
                title
                    .accessibilitySortPriority(1)
            }
            .accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 0) {
                doneLabel
                    .hidden()
                    .accessibilityHidden(true)
                title
                    .frame(maxWidth: .infinity)
                doneButton
            }
            .padding(.horizontal, Theme.Space.md)
        }
    }

    // Wraps, centered inside the gutters, rather than running to the
    // sheet's edges at the largest sizes (J029), as the Voice & speed
    // sheet's title does.
    private var title: some View {
        Text(AppearanceCopy.title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("appearance.title")
    }

    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            doneLabel
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance.done")
    }

    /// Accent text on the sheet's surface, a full 44pt target.
    private var doneLabel: some View {
        Text(AppearanceCopy.done)
            .font(Theme.font(.callout).weight(.semibold))
            .foregroundStyle(Theme.accentStrong)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// R21: Settings' Text & appearance row pushes the same view the reader's
/// Aa sheet presents, on the Settings root's own ground, bgTint, so the
/// paper doesn't change colour at the push (P041). The Aa sheet stays on
/// surface.
struct AppearanceSettingsPage: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AppearanceView()
            .background(Theme.bgTint.ignoresSafeArea())
            // An opaque bar on the page's own ground, never a hard scroll
            // edge on a pushed screen (see `ShelfScrollEdge`).
            .modifier(ShelfScrollEdge(ground: Theme.bgTint))
            .navigationBarTitleDisplayMode(.inline)
            // The bar's system content follows the app's scheme, not the
            // phone's (an in-app Dark override on a Light phone).
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(AppearanceCopy.title)
                        .font(Theme.font(.headline))
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("appearance.title")
                        // The bar caps its text size; long-press shows it large.
                        .accessibilityShowsLargeContentViewer()
                }
            }
    }
}
