import SwiftUI

/// Settings (R21): three rows and a footer. "Voice & speed" pushes the
/// Listening view the reader's chip presents, with the installed-model card;
/// "Text & appearance" pushes the view the reader's Aa presents; then
/// Licenses. Each preference has one home in those views, so this screen
/// holds no toggle. The privacy line and the version close the list.
///
/// Each row shows its current value (P040): the voice and speed, then the
/// text size and scheme. While the natural voice could run here and isn't
/// installed, the Voice & speed row says so under its value.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Read for the row's value only; Text & appearance binds them.
    @AppStorage(ReaderTextSize.prefKey)
    private var textSizeStep = ReaderTextSize.defaultStep
    @AppStorage(AppearancePreference.prefKey)
    private var appearanceRaw = AppearancePreference.system.rawValue

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ListeningSettingsPage()
                } label: {
                    listeningRowLabel
                }
                .accessibilityLabel(Self.listeningRowSpokenLabel(voice: playback.voice, rate: model.globalRate,
                                                                 naturalVoice: naturalVoiceLine))
                .accessibilityInputLabels([Text(ListeningCopy.title), Text("Voice"), Text("Speed")])
                .accessibilityIdentifier("settings.listening")

                NavigationLink {
                    AppearanceSettingsPage()
                } label: {
                    appearanceRowLabel
                }
                .accessibilityLabel(Self.appearanceRowSpokenLabel(points: textPoints, appearance: appearance))
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
            // The system draws these a full point wide: at the border's
            // weight they're as quiet as the Licenses cards' edges.
            .listRowSeparatorTint(Theme.Stroke.borderColor)
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
        // Voice & speed names the System voice on its first frame (P035):
        // rank the pick off the main thread before that push asks for it.
        .task { AVSpeechEngine.warmSystemVoice(reading: playback.systemVoiceLanguage) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
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

    /// The row as VoiceOver says it: the title first, so Voice Control still
    /// matches it, then the value as the player chip says it, without the
    /// middle dot VoiceOver would read aloud as a word, then the natural
    /// voice's line when the row shows one.
    nonisolated static func listeningRowSpokenLabel(voice: TtsVoice, rate: Double,
                                                    naturalVoice: String? = nil) -> String {
        let value = "\(ListeningCopy.title), \(ListeningFormat.shortName(voice)), \(ListeningFormat.rate(rate))"
        guard let naturalVoice else { return value }
        return "\(value), \(NaturalVoiceCopy.spoken(naturalVoice))"
    }

    /// The Text & appearance row as VoiceOver says it: the title first, as
    /// the Voice & speed row's, then the size and scheme in words.
    nonisolated static func appearanceRowSpokenLabel(points: CGFloat, appearance: AppearancePreference) -> String {
        "\(AppearanceCopy.title), \(AppearanceCopy.spokenSummary(points: points, appearance: appearance))"
    }

    /// The Voice & speed row's second line: while the device could run the
    /// natural voice and nothing is fetching it (never downloaded, or a
    /// download that failed and can be tried again), that it exists and its
    /// size. Nil once installed, and while it downloads or waits for Wi-Fi,
    /// where the pushed card says so: the row never offers what's on its way.
    nonisolated static func naturalVoiceLine(supported: Bool, state: ModelManager.ModelState) -> String? {
        guard supported else { return nil }
        switch state {
        case .notInstalled, .failed: return NaturalVoiceCopy.available
        case .downloading, .waitingForWiFi, .installed: return nil
        }
    }

    private var naturalVoiceLine: String? {
        Self.naturalVoiceLine(supported: model.neuralVoiceOffered, state: modelManager.state)
    }

    private var textPoints: CGFloat { ReaderTextSize.points(forStep: textSizeStep) }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    /// Voice & speed with the app-wide voice and speed after it, and the
    /// natural voice's line under both when there is one.
    private var listeningRowLabel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            valueRow(title: ListeningCopy.title,
                     value: Text(ListeningFormat.chipTitle(voice: playback.voice, rate: model.globalRate))
                        .font(Theme.font(.callout))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                        .numericReadout(model.globalRate))
            if let naturalVoiceLine {
                Text(naturalVoiceLine)
                    .font(Theme.font(.footnote))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Text & appearance with the size and scheme after it.
    private var appearanceRowLabel: some View {
        valueRow(title: AppearanceCopy.title,
                 value: Text(AppearanceCopy.summary(points: textPoints, appearance: appearance))
                    .font(Theme.font(.callout))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .numericReadout(Double(textPoints)))
    }

    /// A title with its value after it; at accessibility sizes the value
    /// moves under the title instead of squeezing it.
    @ViewBuilder
    private func valueRow(title: String, value: some View) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                rowTitle(title)
                value
            }
        } else {
            HStack {
                rowTitle(title)
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
