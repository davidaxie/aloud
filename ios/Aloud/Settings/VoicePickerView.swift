import SwiftUI

/// The one voice picker, curated: the eight neural voices under a single
/// "Neural" header with a subtle "System voice" footer row — or, before the
/// model is installed, the system voice plus the neural-download promo card.
/// Every full row carries an inline preview button that speaks a sample in
/// that voice via `VoicePreviewer` — never through the playback graph.
/// Selecting a voice mid-playback keeps position (PlaybackController
/// re-synthesizes from the current sentence).
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
            if model.neuralVoiceOffered, modelManager.isInstalled {
                Section {
                    ForEach(model.kokoroEngine.voices) { voice in
                        voiceRow(voice)
                    }
                } header: {
                    sectionHeader("Neural")
                }
                .listRowBackground(Theme.surface)
                Section {
                    ForEach(model.engine.voices) { voice in
                        systemFooterRow(voice)
                    }
                }
                .listRowBackground(Theme.surface)
            } else {
                Section {
                    ForEach(model.engine.voices) { voice in
                        voiceRow(voice)
                    }
                }
                .listRowBackground(Theme.surface)
                if model.neuralVoiceOffered {
                    Section {
                        ModelDownloadView()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
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
                Text(origin(for: voice))
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textFaint)
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

    /// The subtle "System voice" footer under the neural roster — the
    /// fallback exists, quietly, without competing with the curated eight.
    private func systemFooterRow(_ voice: TtsVoice) -> some View {
        Button {
            playback.voice = voice
            if dismissesOnSelect {
                previewer.stop()
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text(voice.name)
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if voice.id == playback.voice.id {
                    Image(systemName: "checkmark")
                        .font(Theme.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
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

    /// The voice's character note, falling back to origin when it has none.
    private func subtitle(for voice: TtsVoice) -> String {
        voice.subtitle.isEmpty ? origin(for: voice) : voice.subtitle
    }

    /// "en-US" + "female" → "US · female".
    private func origin(for voice: TtsVoice) -> String {
        let region = voice.lang.split(separator: "-").last.map(String.init) ?? voice.lang
        return voice.gender.isEmpty ? region : "\(region) · \(voice.gender)"
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
