import SwiftUI

/// R21: the three appearance controls in one view, so each preference has
/// one home: text size (an A−/A+ stepper over the nine steps), System /
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

    /// The sample stops growing here so 35/40pt steps still fit the row.
    private static let sampleMaxPoints: CGFloat = 32

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
                // Sentence case, like every other label (R25).
                sectionLabel(AppearanceCopy.textSize)
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

    /// A− / sample / A+: one step per tap, each end disabled at its limit.
    /// The sample previews the reading serif at the chosen size. VoiceOver
    /// hears the sample and readout as one adjustable size, so a swipe up
    /// or down steps it without hunting for the buttons.
    private var textSizeRow: some View {
        HStack(spacing: 0) {
            stepButton(bigger: false, systemImage: "textformat.size.smaller",
                       label: "Smaller text", identifier: "appearance.textSize.smaller")

            VStack(spacing: Theme.Space.xxs) {
                // In the column's own weight: its bold face under Bold Text
                // (`ReaderPageStyle.serif(size:bold:)`), J027.
                Text("Aa")
                    .font(Theme.readerSerif(min(currentPoints, Self.sampleMaxPoints),
                                            weight: legibilityWeight == .bold ? .bold : .regular))
                    .foregroundStyle(Theme.text)
                    .frame(height: 40)
                    .accessibilityHidden(true)
                Text(AppearanceCopy.points(currentPoints))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.textMuted)
                    .numericReadout(Double(currentPoints))
            }
            .frame(maxWidth: .infinity)
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

            stepButton(bigger: true, systemImage: "textformat.size.larger",
                       label: "Larger text", identifier: "appearance.textSize.larger")
        }
        .padding(Theme.Space.xs)
        .background(Theme.surface2,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
    }

    private func stepButton(bigger: Bool, systemImage: String, label: String,
                            identifier: String) -> some View {
        let enabled = ReaderTextSize.stepped(from: currentStep, bigger: bigger) != nil
        return Button {
            step(bigger: bigger)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The glyph sits in a fixed 44pt button; a long press past the cap
        // shows it large.
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
    /// so "System" never hyphenates across two lines. VoiceOver hears one
    /// segmented control named Appearance, with each choice's place in the
    /// three; the capsules draw exactly as before.
    private var appearanceRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(AppearancePreference.allCases) { preference in
                        appearanceSegment(preference)
                    }
                }
                .padding(Theme.Space.xxs)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            } else {
                HStack(spacing: 0) {
                    ForEach(AppearancePreference.allCases) { preference in
                        appearanceSegment(preference)
                    }
                }
                .padding(Theme.Space.xxs)
                .background(Theme.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            }
        }
        .accessibilityRepresentation {
            Picker(AppearanceCopy.appearance, selection: appearanceSelection) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityIdentifier("appearance.scheme")
    }

    /// One selection style, as on the speed presets: the selected segment is
    /// an accentSoft fill with an accentStrong semibold label; the others
    /// are bare muted labels. Touch only: VoiceOver reads the segmented
    /// control that represents the row.
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
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
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
