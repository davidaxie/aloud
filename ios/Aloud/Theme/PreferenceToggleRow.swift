import SwiftUI

/// The one title(+subtitle) toggle row used everywhere a preference appears
/// (AppearanceSheet's Reading section, Settings' Reading section), so copy
/// and styling can't drift between the surfaces describing the same pref.
struct PreferenceToggleRow: View {

    let title: String
    var subtitle: String?
    /// Title styling varies slightly by surface (sheet rows are a touch
    /// smaller); everything else is fixed by this row.
    var titleFont: Font = Theme.ui(16)
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .tint(Theme.accent)
    }
}

/// Shared copy for prefs that surface in more than one place.
enum PreferenceCopy {
    static let wordHighlightTitle = "Word highlight"
    static let wordHighlightSubtitle = "Tint each word as it's spoken."
}
