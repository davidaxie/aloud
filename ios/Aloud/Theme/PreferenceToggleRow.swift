import SwiftUI

/// The one title(+subtitle) toggle row for a preference (Word highlight in
/// the Text & appearance view, bracketed asides in Voice & speed), so copy
/// and styling can't drift between the surfaces describing the same pref.
struct PreferenceToggleRow: View {

    let title: String
    var subtitle: String?
    /// Title styling varies slightly by surface (sheet rows are a touch
    /// smaller); everything else is fixed by this row.
    var titleFont: Font = Theme.font(.body)
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            // Both lines wrap to their full height and never truncate, in a
            // List row or a scroll view inside a content-sized sheet.
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.accent)
        // The row stays a full touch-height even outside a List (the Aa sheet).
        .frame(minHeight: 44)
    }
}

/// Shared copy for prefs that surface in more than one place.
enum PreferenceCopy {
    static let wordHighlightTitle = "Word highlight"
    /// R13's word marker is an underline, not a tint, so the copy says so.
    static let wordHighlightSubtitle = "Underline each word as it’s spoken"
}
