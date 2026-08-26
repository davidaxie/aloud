import SwiftUI

/// The one voice picker, curated: the eight neural voices under a single
/// "Neural" header with a subtle "System voice" footer row — or, before the
/// model is installed, the system voice plus the neural-download promo card.
/// Every full row carries an inline preview button that speaks a sample in
/// that voice via `VoicePreviewer` — never through the playback graph.
/// Selecting a voice mid-playback keeps position (PlaybackController
/// re-synthesizes from the current sentence).
///
/// Pushed from Settings as-is (`.global` — the default voice every unpinned
/// book follows); presented from the player bar via `VoicePickerSheet` below
/// (`.book` — the voice of the book being read). The roster and the previews
/// are identical either way; only where the checkmark reads from and where the
/// pick is written differ.
struct VoicePickerView: View {

    var scope: PreferenceScope = .book

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
                        voiceRow(voice, footer: true)
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
        .onAppear {
            // A preview may warm the ~800 MB neural engine just for its
            // sample — give it back whenever previews go idle and the active
            // voice doesn't need it.
            previewer.onIdle = { [weak playback] in
                playback?.releaseNeuralEngineIfUnused()
            }
        }
        .onDisappear {
            previewer.stop()
            playback.releaseNeuralEngineIfUnused()
        }
    }

    // MARK: - Rows

    /// One row for both presentations. `footer: true` renders the subtle
    /// "System voice" row under the neural roster — the fallback exists,
    /// quietly, without competing with the curated eight (no subtitle,
    /// origin, or preview button).
    private func voiceRow(_ voice: TtsVoice, footer: Bool = false) -> some View {
        Button {
            select(voice)
        } label: {
            HStack(spacing: 12) {
                if footer {
                    Text(voice.name)
                        .font(Theme.ui(14))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name)
                            .font(Theme.ui(16, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(subtitle(for: voice))
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer()
                if !footer {
                    Text(origin(for: voice))
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.textFaint)
                }
                if voice.id == selectedVoiceID {
                    Image(systemName: "checkmark")
                        .font(Theme.ui(footer ? 13 : 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                if !footer {
                    previewButton(voice)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voice.\(voice.id)")
    }

    /// Which row wears the checkmark: the loaded book's active voice, or the
    /// global default. In Settings these differ whenever the last book read
    /// carries a pin of its own, or while a neural pick is standing in as the
    /// system voice because the model isn't installed.
    private var selectedVoiceID: String {
        scope == .book ? playback.voice.id : model.globalVoice.id
    }

    /// Selecting is identical for every row apart from where the pick lands:
    /// on the book being read, or on the default every unpinned book follows.
    /// A sheet dismisses on selection.
    private func select(_ voice: TtsVoice) {
        switch scope {
        case .book: playback.selectVoice(voice)
        case .global: model.selectGlobalVoice(voice)
        }
        if dismissesOnSelect {
            previewer.stop()
            dismiss()
        }
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
            VoicePickerView(scope: .book, dismissesOnSelect: true)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
