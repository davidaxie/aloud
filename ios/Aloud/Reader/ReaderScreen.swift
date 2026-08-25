import SwiftUI

/// The document is the screen: full-bleed reading column, player bar below,
/// minimal top chrome. Restores the saved sentence cued (paused) on appear,
/// saves progress as the playhead moves and when leaving.
struct ReaderScreen: View {

    let document: LibraryDocument

    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ReaderTextSize.prefKey) private var textSizeStep = ReaderTextSize.defaultStep

    @StateObject private var sleepTimer = SleepTimer()

    @State private var content: DocContent?
    @State private var loadFailed = false
    @State private var isLoaded = false
    @State private var scrolledAway = false
    @State private var returnTrigger = 0
    @State private var showAppearanceSheet = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let content {
                ReaderTextView(
                    content: content,
                    fontSize: ReaderTextSize.points(forStep: textSizeStep),
                    activeSentence: playback.currentSentence,
                    activeWord: playback.currentWord,
                    autoScroll: model.autoScroll,
                    returnToPlayheadTrigger: returnTrigger,
                    scrolledAway: $scrolledAway,
                    onTapSentence: tapSentence)
                .ignoresSafeArea(edges: .bottom)

                chipLayer
                toastLayer
            } else if loadFailed {
                failureState
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let content {
                PlayerBarView(document: liveDocument, content: content)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAppearanceSheet) { AppearanceSheet() }
        .task {
            sleepTimer.attach(to: playback)
            await load()
        }
        .onChange(of: playback.currentSentence) { sentence in
            guard isLoaded else { return }
            store.saveProgress(id: document.id, sentence: sentence, fraction: fraction(at: sentence))
        }
        .onDisappear {
            guard isLoaded else { return }
            store.saveProgress(id: document.id,
                               sentence: playback.currentSentence,
                               fraction: fraction(at: playback.currentSentence))
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(Theme.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Back to Library")
        }
        ToolbarItem(placement: .principal) {
            Text(liveDocument.title)
                .font(Theme.serif(16, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showAppearanceSheet = true } label: {
                Text("Aa")
                    .font(Theme.serif(17, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Appearance")
            .accessibilityIdentifier("reader.appearance")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            Menu {
                sleepOption(.off)
                ForEach(SleepTimer.minuteChoices, id: \.self) { minutes in
                    sleepOption(.minutes(minutes))
                }
                sleepOption(.endOfChapter)
            } label: {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("reader.more")
    }

    private func sleepOption(_ option: SleepTimer.Option) -> some View {
        Button {
            sleepTimer.select(option)
        } label: {
            if sleepTimer.option == option {
                Label(option.label, systemImage: "checkmark")
            } else {
                Text(option.label)
            }
        }
    }

    /// Bottom chips: sleep countdown (while armed) and return-to-playhead
    /// (while scrolled away) share one row above the player bar.
    private var chipLayer: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                if sleepTimer.isArmed {
                    sleepChip
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if scrolledAway {
                    returnChip
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.bottom, 14)
        }
        .animation(.easeOut(duration: 0.2), value: scrolledAway)
        .animation(.easeOut(duration: 0.2), value: sleepTimer.isArmed)
    }

    private var sleepChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.fill")
                .font(Theme.ui(11, weight: .semibold))
            Text(sleepTimer.chipLabel)
                .font(Theme.ui(13, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep timer, \(sleepTimer.chipLabel)")
        .accessibilityIdentifier("reader.sleepChip")
    }

    private var returnChip: some View {
        Button {
            returnTrigger += 1
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                    .font(Theme.ui(12, weight: .semibold))
                Text("Return to playhead")
                    .font(Theme.ui(13, weight: .semibold))
            }
            .foregroundStyle(Theme.accentStrong)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
        }
    }

    /// Gentle toast riding `PlaybackController.toast` (sleep timer, skipped
    /// sentences). Sits above the chip row; never intercepts touches.
    private var toastLayer: some View {
        VStack {
            Spacer()
            if let toast = playback.toast {
                Text(toast)
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: playback.toast)
        .allowsHitTesting(false)
    }

    private var failureState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(Theme.ui(30))
                .foregroundStyle(Theme.textFaint)
            Text("Couldn't open this document")
                .font(Theme.serif(18, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("It may be damaged or a scanned document.")
                .font(Theme.ui(14))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(32)
    }

    // MARK: - Loading & progress

    private func load() async {
        guard content == nil else { return }
        do {
            let loaded = try await store.content(for: document)
            content = loaded

            // Reconciliation may have reset progress; load the live record so
            // the controller cues at the saved sentence.
            playback.load(document: liveDocument, content: loaded)
            isLoaded = true
            store.noteOpened(id: document.id)
        } catch {
            loadFailed = true
        }
    }

    /// The store's current record for this document (progress moves while reading).
    private var liveDocument: LibraryDocument {
        store.documents.first(where: { $0.id == document.id }) ?? document
    }

    private func fraction(at sentence: Int) -> Double {
        guard let count = content?.sentences.count, count > 1 else { return 0 }
        return Double(min(max(sentence, 0), count - 1)) / Double(count - 1)
    }

    private func tapSentence(_ id: Int) {
        let playing: Bool
        switch playback.status {
        case .playing, .buffering: playing = true
        default: playing = false
        }
        playback.seek(to: id, andPlay: playing)
    }
}
