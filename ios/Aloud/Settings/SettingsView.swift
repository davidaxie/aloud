import SwiftUI

/// Settings (R21): three rows and a footer. "Voice & speed" pushes the
/// Listening view the reader's chip presents, with the installed-model card;
/// "Text & appearance" pushes the view the reader's Aa presents; then
/// Licenses. Each preference has one home in those views, so this screen
/// holds no toggle. The privacy line and the version close the list.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ListeningSettingsPage()
                } label: {
                    listeningRowLabel
                }
                .accessibilityInputLabels([Text(ListeningCopy.title), Text("Voice"), Text("Speed")])
                .accessibilityIdentifier("settings.listening")

                NavigationLink {
                    AppearanceSettingsPage()
                } label: {
                    rowTitle(AppearanceCopy.title)
                }
                .accessibilityInputLabels([Text(AppearanceCopy.title), Text("Appearance"),
                                           Text("Text size"), Text("Dark mode")])
                .accessibilityIdentifier("settings.appearance")

                NavigationLink {
                    LicensesView()
                } label: {
                    rowTitle("Licenses")
                }
                .accessibilityInputLabels([Text("Licenses")])
                .accessibilityIdentifier("settings.licenses")
            } footer: {
                footer
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.Stroke.hairlineColor)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .modifier(ShelfScrollEdge(ground: Theme.bgTint))
        .background(Theme.bgTint.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // The bar's system content (back chevron, title rendering) follows
        // the app's scheme, not the phone's: under an in-app Dark override
        // on a Light phone the title otherwise drew dark-on-dark.
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    // The bar caps text scaling; at accessibility sizes a
                    // long press shows the title large instead.
                    .accessibilityShowsLargeContentViewer()
            }
        }
    }

    // MARK: Rows

    private func rowTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(.body))
            .foregroundStyle(Theme.text)
    }

    /// "Voice & speed" with the app-wide "Michael · 1.25×" after it; at
    /// accessibility sizes the value moves under the title instead of
    /// squeezing it.
    @ViewBuilder
    private var listeningRowLabel: some View {
        let title = rowTitle(ListeningCopy.title)
        let value = Text(ListeningFormat.chipTitle(voice: playback.voice, rate: model.globalRate))
            .font(Theme.font(.callout))
            .monospacedDigit()
            .foregroundStyle(Theme.textMuted)
            .numericReadout(model.globalRate)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                title
                value
            }
        } else {
            HStack {
                title
                Spacer()
                value
            }
        }
    }

    // MARK: Footer

    /// The one privacy line, in the serif aside, over the version: words,
    /// not settings. `textCase(nil)` keeps the List from upper-casing them.
    private var footer: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(PrivacyCopy.line)
                .font(Theme.font(.aside))
                .foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("settings.privacy")
            Text("Version \(Self.versionLabel)")
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("settings.version")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
        .textCase(nil)
    }

    private static var versionLabel: String {
        let info = Bundle.main
        let short = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        if let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
