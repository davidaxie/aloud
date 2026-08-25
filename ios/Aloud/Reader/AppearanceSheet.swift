import SwiftUI

/// Appearance preference: System follows the device; Light/Dark pin the scheme.
/// Persisted as a raw string; `AloudApp` resolves it beneath the UI-test
/// launch-argument override (`-uitest-force-dark` / `-uitest-force-light`),
/// so launch arguments always win.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let prefKey = "aloud.prefs.v1.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "no override" — the device setting governs.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Five reader text sizes, S…XL, in serif points. Line spacing stays 1.75×
/// (applied in `ReaderTextView`), so only the point size varies.
enum ReaderTextSize {
    static let prefKey = "aloud.prefs.v1.textSize"
    static let steps: [CGFloat] = [16, 17.5, 19, 21, 23]
    static let labels = ["S", "M", "L", "XL", "XXL"]
    static let defaultStep = 2

    static func points(forStep step: Int) -> CGFloat {
        steps[min(max(step, 0), steps.count - 1)]
    }
}

/// The `Aa` sheet: text size (5 discrete steps) and appearance
/// (System / Light / Dark). Both persist immediately via `@AppStorage`;
/// `ReaderTextView` rebuilds its attributed string when the size changes.
struct AppearanceSheet: View {

    @AppStorage(ReaderTextSize.prefKey)
    private var textSizeStep = ReaderTextSize.defaultStep

    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        VStack(spacing: 26) {
            Capsule()
                .fill(Theme.lineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            VStack(spacing: 14) {
                sectionLabel("Text Size")
                textSizeRow
            }

            VStack(spacing: 14) {
                sectionLabel("Appearance")
                appearanceRow
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Text size

    /// Five "A" swatches at increasing sizes — a discrete slider the eye can
    /// preview before committing.
    private var textSizeRow: some View {
        HStack(spacing: 8) {
            ForEach(ReaderTextSize.steps.indices, id: \.self) { step in
                sizeSwatch(step: step)
            }
        }
    }

    private func sizeSwatch(step: Int) -> some View {
        let selected = step == textSizeStep
        // Preview glyphs scaled down so XXL still fits the swatch.
        let previewSize = 12 + CGFloat(step) * 3
        return Button {
            textSizeStep = step
        } label: {
            Text("A")
                .font(Theme.serif(previewSize, weight: .medium))
                .foregroundStyle(selected ? Theme.accentStrong : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    selected ? Theme.accentSoft : Theme.surface2,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .accessibilityLabel("Text size \(ReaderTextSize.labels[step])")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.size.\(step)")
    }

    // MARK: - Appearance

    private var appearanceRow: some View {
        HStack(spacing: 0) {
            ForEach(AppearancePreference.allCases) { preference in
                appearanceSegment(preference)
            }
        }
        .padding(3)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }

    private func appearanceSegment(_ preference: AppearancePreference) -> some View {
        let selected = preference.rawValue == appearanceRaw
        return Button {
            appearanceRaw = preference.rawValue
        } label: {
            Text(preference.label)
                .font(Theme.ui(14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.accentStrong : Theme.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    selected ? Theme.accentSoft : Color.clear,
                    in: Capsule())
        }
        .accessibilityLabel("\(preference.label) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.scheme.\(preference.rawValue)")
    }

    // MARK: - Shared

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
    }
}
