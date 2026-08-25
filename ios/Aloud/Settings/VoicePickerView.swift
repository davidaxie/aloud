import SwiftUI

/// The one voice picker: neural voices on top (or the model promo card when
/// not yet installed), then system voices ranked premium > enhanced > default.
/// Every row carries an inline preview button that speaks a sample in that
/// voice via `VoicePreviewer` — never through the playback graph. Selecting a
/// voice mid-playback keeps position (PlaybackController re-synthesizes from
/// the current sentence).
///
/// Pushed from Settings as-is; presented from the player bar via
/// `VoicePickerSheet` below.
struct VoicePickerView: View {

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var previewer = VoicePreviewer()

    /// Sheets dismiss on selection; a pushed picker stays put for comparing.
    var dismissesOnSelect = false

    var body: some View {
        List {
            if model.neuralVoiceOffered {
                if modelManager.isInstalled {
                    Section {
                        ForEach(model.kokoroEngine.voices) { voice in
                            voiceRow(voice)
                        }
                    } header: {
                        sectionHeader("On this device — Neural")
                    }
                    .listRowBackground(Theme.surface)
                } else {
                    Section {
                        ModelDownloadView()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            Section {
                ForEach(model.engine.voices) { voice in
                    voiceRow(voice)
                }
            } header: {
                sectionHeader("System voices")
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bgTint.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Voice")
                    .font(Theme.serif(17, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .onDisappear { previewer.stop() }
    }

    // MARK: - Rows

    private func voiceRow(_ voice: TtsVoice) -> some View {
        Button {
            playback.voice = voice
            if dismissesOnSelect {
                previewer.stop()
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(Theme.ui(16, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(subtitle(for: voice))
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if let badge = qualityBadge(for: voice) {
                    Text(badge)
                        .font(Theme.ui(11, weight: .semibold))
                        .foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule())
                }
                if voice.id == playback.voice.id {
                    Image(systemName: "checkmark")
                        .font(Theme.ui(14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                previewButton(voice)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice.\(voice.id)")
    }

    private func previewButton(_ voice: TtsVoice) -> some View {
        Button {
            previewer.toggle(voice, engine: engine(for: voice))
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 25, height: 25)
                if previewer.isSynthesizing(voice) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .tint(Theme.bg)
                } else if previewer.isActive(voice) {
                    Image(systemName: "stop.fill")
                        .font(Theme.ui(10, weight: .bold))
                        .foregroundStyle(Theme.bg)
                } else {
                    Image(systemName: "play.fill")
                        .font(Theme.ui(10, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .offset(x: 0.5)
                }
            }
            .frame(width: 44, height: 44)   // tap target around the 25 pt circle
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)   // keeps the row's own tap separate in a List
        .accessibilityLabel(previewer.isActive(voice)
                            ? "Stop preview" : "Preview \(voice.name)")
        .accessibilityIdentifier("voice.preview.\(voice.id)")
    }

    // MARK: - Bits

    /// The engine that will actually speak this voice during playback.
    private func engine(for voice: TtsVoice) -> any TtsEngine {
        voice.engine == .kokoro ? model.kokoroEngine : model.engine
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
    }

    /// "en-US" + "female" → "US · female".
    private func subtitle(for voice: TtsVoice) -> String {
        let region = voice.lang.split(separator: "-").last.map(String.init) ?? voice.lang
        return voice.gender.isEmpty ? region : "\(region) · \(voice.gender)"
    }

    private func qualityBadge(for voice: TtsVoice) -> String? {
        switch voice.quality {
        case 4...: return "Neural"
        case 3: return "Premium"
        case 2: return "Enhanced"
        default: return nil
        }
    }
}

// MARK: - Sheet wrapper (player bar)

/// The picker in the bottom sheet the player bar presents.
struct VoicePickerSheet: View {
    var body: some View {
        NavigationStack {
            VoicePickerView(dismissesOnSelect: true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
