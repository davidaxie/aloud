import SwiftUI

/// Settings: default voice + speed, neural model management, reading behavior,
/// and the privacy promise with version and licenses.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController

    @State private var showSpeedSheet = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    VoicePickerView()
                } label: {
                    HStack {
                        Text("Voice")
                            .font(Theme.ui(16))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text(playback.voice.name)
                            .font(Theme.ui(15))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .accessibilityIdentifier("settings.voice")
                speedRow
            } header: {
                sectionHeader("Voice")
            }
            .listRowBackground(Theme.surface)

            Section {
                ModelDownloadView(showsInstalledState: true, showsCard: false)
            } header: {
                sectionHeader("Neural voice model")
            }
            .listRowBackground(Theme.surface)

            Section {
                PreferenceToggleRow(title: "Skip text in [brackets]",
                                    subtitle: "Citations and asides aren't read aloud.",
                                    isOn: $playback.skipBrackets)
                PreferenceToggleRow(title: "Auto-scroll",
                                    isOn: $model.autoScroll)
                PreferenceToggleRow(title: PreferenceCopy.wordHighlightTitle,
                                    subtitle: PreferenceCopy.wordHighlightSubtitle,
                                    isOn: $model.wordHighlight)
                    .accessibilityIdentifier("settings.wordHighlight")
            } header: {
                sectionHeader("Reading")
            }
            .listRowBackground(Theme.surface)

            Section {
                Text("Everything stays on your device. Aloud works entirely offline.")
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.textMuted)
                HStack {
                    Text("Version")
                        .font(Theme.ui(16))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(Self.versionLabel)
                        .font(Theme.ui(15))
                        .foregroundStyle(Theme.textFaint)
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Text("Licenses")
                        .font(Theme.ui(16))
                        .foregroundStyle(Theme.text)
                }
                .accessibilityIdentifier("settings.licenses")
            } header: {
                sectionHeader("About")
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bgTint.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .sheet(isPresented: $showSpeedSheet) { SpeedSheet() }
    }

    // MARK: Speed

    private var speedRow: some View {
        Button {
            showSpeedSheet = true
        } label: {
            HStack {
                Text("Speed")
                    .font(Theme.ui(16))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Self.rateLabel(playback.rate))
                    .font(Theme.ui(15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.accentStrong)
                Image(systemName: "chevron.right")
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.speed")
    }

    private static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    // MARK: Bits

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
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
