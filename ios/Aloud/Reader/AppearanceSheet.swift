import SwiftUI

/// R21: the three appearance controls in one view, so each preference has
/// one home: text size (an A−/A+ stepper over the nine steps), System /
/// Light / Dark, and Word highlight. The reader's Aa sheet presents it and
/// Settings pushes it (`AppearanceSettingsPage`). Everything persists at
/// once; `ReaderTextView` rebuilds its attributed string when the size
/// changes. At AX4/AX5 and on small phones the sections outgrow the space:
/// they scroll rather than clip, and at sizes that fit nothing bounces.
struct AppearanceView: View {

    /// The content's natural height, for the sheet's content-sized detent.
    private let onContentHeight: ((CGFloat) -> Void)?

    init(onContentHeight: ((CGFloat) -> Void)? = nil) {
        self.onContentHeight = onContentHeight
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.sm) {
                // Sentence case, like every other label (R25).
                sectionLabel("Text size")
                textSizeRow
            }

            VStack(spacing: Theme.Space.sm) {
                sectionLabel("Appearance")
                appearanceRow
            }

            VStack(spacing: Theme.Space.sm) {
                sectionLabel("Reading")
                wordHighlightRow
            }
        }
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

    private var currentPointsLabel: String {
        currentPoints.formatted()
    }

    /// A− / sample / A+: one step per tap, each end disabled at its limit.
    /// The sample previews the reading serif at the chosen size.
    private var textSizeRow: some View {
        HStack(spacing: 0) {
            stepButton(delta: -1, systemImage: "textformat.size.smaller",
                       label: "Smaller text", identifier: "appearance.textSize.smaller")

            VStack(spacing: Theme.Space.xxs) {
                Text("Aa")
                    .font(Theme.readerSerif(min(currentPoints, Self.sampleMaxPoints)))
                    .foregroundStyle(Theme.text)
                    .frame(height: 40)
                    .accessibilityHidden(true)
                Text("\(currentPointsLabel) pt")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.textMuted)
                    .numericReadout(Double(currentPoints))
                    .accessibilityLabel("\(currentPointsLabel) point")
            }
            .frame(maxWidth: .infinity)

            stepButton(delta: 1, systemImage: "textformat.size.larger",
                       label: "Larger text", identifier: "appearance.textSize.larger")
        }
        .padding(Theme.Space.xs)
        .background(Theme.surface2,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
    }

    private func stepButton(delta: Int, systemImage: String, label: String,
                            identifier: String) -> some View {
        let target = currentStep + delta
        let enabled = ReaderTextSize.steps.indices.contains(target)
        return Button {
            textSizeStep = target
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.textFaint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The glyph sits in a fixed 44pt button.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue("\(currentPointsLabel) point")
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Appearance

    /// One row of three segments; at accessibility sizes the segments stack
    /// so "System" never hyphenates across two lines. One named group, so
    /// VoiceOver says "Appearance" before the three choices.
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    /// One selection style, as on the speed presets: the selected segment is
    /// an accentSoft fill with an accentStrong semibold label (plus the
    /// `.isSelected` trait); the others are bare muted labels.
    private func appearanceSegment(_ preference: AppearancePreference) -> some View {
        let selected = preference.rawValue == appearanceRaw
        return Button {
            appearanceRaw = preference.rawValue
        } label: {
            Text(preference.label)
                .font(Theme.font(.callout).weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.accentStrong : Theme.textMuted)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    selected ? Theme.accentSoft : Color.clear,
                    in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preference.label) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.scheme.\(preference.rawValue)")
    }

    // MARK: - Reading

    /// R13's underline under the spoken word. Off by default — the calm
    /// sentence pill is the default experience. The pref's only binding.
    private var wordHighlightRow: some View {
        PreferenceToggleRow(title: PreferenceCopy.wordHighlightTitle,
                            subtitle: PreferenceCopy.wordHighlightSubtitle,
                            titleFont: Theme.font(.callout),
                            isOn: $model.wordHighlight)
            .accessibilityIdentifier("appearance.wordHighlight")
    }

    // MARK: - Shared

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .foregroundStyle(Theme.textMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The reader's `Aa` sheet: the pinned title over `AppearanceView`, sized to
/// its content. At accessibility sizes the content can outgrow the fitted
/// height the system allows, so `.large` is offered too and the sheet can
/// grow; whatever still doesn't fit scrolls.
struct AppearanceSheet: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Seeded near the default-size layout so the first frame barely moves.
    @State private var headerHeight: CGFloat = 56
    @State private var contentHeight: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the scroll view: the title never scrolls away.
            VStack(spacing: Theme.Space.xs) {
                SheetGrabber()
                Text(AppearanceCopy.title)
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appearance.title")
            }
            .padding(.bottom, Theme.Space.xs)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerHeight = height
            }

            AppearanceView(onContentHeight: { contentHeight = $0 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheetChrome(detents)
    }

    private var detents: Set<PresentationDetent> {
        let fitted = PresentationDetent.height(headerHeight + contentHeight)
        return dynamicTypeSize.isAccessibilitySize ? [fitted, .large] : [fitted]
    }
}

/// R21: Settings' "Text & appearance" row pushes the same view the reader's
/// Aa sheet presents.
struct AppearanceSettingsPage: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AppearanceView()
            .background(Theme.surface.ignoresSafeArea())
            // An opaque bar on the page's own ground, never a hard scroll
            // edge on a pushed screen (see `ShelfScrollEdge`).
            .modifier(ShelfScrollEdge(ground: Theme.surface))
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
