import SwiftUI

/// Text & appearance on the Mac (R2, R21, mac-ux §3.11): three controls in
/// one view, so each preference has one home. The reader's Aa popover holds
/// it (`MacAppearancePopover`) and so does Settings' "Text & appearance"
/// tab. Text size is an A− / "19 pt" / A+ stepper over the nine steps
/// (16-40 pt), the one rule ⌘+ and ⌘− also step by; Appearance is a
/// System / Light / Dark segmented control, which `MacAppearance` turns
/// into `NSApp.appearance`; Word highlight is a switch. No sample
/// paragraph: the popover leaves the page in view, and it changes live.
/// Everything persists at once. Callers pad it.
struct MacTextAppearanceView: View {

    @EnvironmentObject private var model: AppModel

    @AppStorage(ReaderTextSize.prefKey)
    private var textSizeStep = ReaderTextSize.defaultStep

    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            section("Text size") { textSizeRow }
            section("Appearance") { appearancePicker }
            section("Reading") {
                PreferenceToggleRow(title: PreferenceCopy.wordHighlightTitle,
                                    subtitle: PreferenceCopy.wordHighlightSubtitle,
                                    titleFont: Theme.font(.body),
                                    isOn: $model.wordHighlight)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("appearance.wordHighlight")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.font(.eyebrow))
                .eyebrowTracking()
                .foregroundStyle(Theme.textMuted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: - Text size

    private var currentStep: Int {
        min(max(textSizeStep, 0), ReaderTextSize.steps.count - 1)
    }

    /// A− / "19 pt" / A+: one step a click, each end disabled at its limit.
    private var textSizeRow: some View {
        HStack(spacing: 0) {
            stepButton(bigger: false)
            Text(Self.pointsLabel(step: currentStep))
                .font(Theme.font(.callout))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .numericReadout(Double(ReaderTextSize.points(forStep: currentStep)))
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Self.spokenPoints(step: currentStep))
                .accessibilityIdentifier("appearance.textSize.value")
            stepButton(bigger: true)
        }
        .padding(Theme.Space.xxs)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
    }

    private func stepButton(bigger: Bool) -> some View {
        let target = MacCommandActions.steppedTextSize(from: currentStep, bigger: bigger)
        let command: MacCommand = bigger ? .biggerText : .smallerText
        return Button {
            if let target { textSizeStep = target }
        } label: {
            Image(systemName: bigger ? "textformat.size.larger" : "textformat.size.smaller")
                .imageScale(.large)
        }
        .buttonStyle(MacTextStepButtonStyle())
        .disabled(target == nil)
        .help(command.help)
        .accessibilityLabel(bigger ? "Larger text" : "Smaller text")
        .accessibilityValue(Self.spokenPoints(step: currentStep))
        .accessibilityIdentifier(bigger ? "appearance.textSize.larger" : "appearance.textSize.smaller")
    }

    /// "19 pt", "17.5 pt".
    static func pointsLabel(step: Int) -> String {
        "\(ReaderTextSize.points(forStep: step).formatted()) pt"
    }

    /// "19 point", as VoiceOver says it.
    static func spokenPoints(step: Int) -> String {
        "\(ReaderTextSize.points(forStep: step).formatted()) point"
    }

    // MARK: - Appearance

    /// The system's segmented control: it is focusable, takes the arrows
    /// when focused, and reads as one named group with three choices.
    private var appearancePicker: some View {
        Picker("Appearance", selection: appearance) {
            ForEach(AppearancePreference.allCases) { preference in
                Text(preference.label).tag(preference)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Appearance")
        .accessibilityIdentifier("appearance.scheme")
    }

    private var appearance: Binding<AppearancePreference> {
        Binding(get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }
}

/// A− and A+ as the iPhone's stepper draws them: text while a step is left,
/// textFaint at 16 or 40 pt, about 3:1 apart (J028). The transport's glyph
/// style rests at textMuted, a tint step from textFaint, so a dead end
/// there looked live. Pressed, the glyph dims to textMuted.
struct MacTextStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacTextStepFace(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct MacTextStepFace<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @Environment(\.chromeScale) private var scale
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(Theme.font(.body, scale: scale))
            .foregroundStyle(!isEnabled ? Theme.textFaint : (isPressed ? Theme.textMuted : Theme.text))
            .frame(width: MacPlayerBarLayout.glyphHit(for: scale), height: MacPlayerBarLayout.glyphHit(for: scale))
            .contentShape(Rectangle())
    }
}
