import SwiftUI

/// The document is the screen: full-bleed reading column, player bar below,
/// minimal top chrome. Restores the saved sentence cued (paused) on appear,
/// saves progress as the playhead moves and when leaving.
struct ReaderScreen: View {

    let document: LibraryDocument
    /// Start speaking on arrival — the Continue Listening hero's request,
    /// carried by the push itself. Scoped to this screen: it cannot outlive
    /// the navigation that set it, and every other entry point leaves it
    /// `false` by construction.
    var autoplay = false

    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ReaderTextSize.prefKey) private var textSizeStep = ReaderTextSize.defaultStep

    @StateObject private var sleepTimer = SleepTimer()

    @State private var content: DocContent?
    /// Chapter list + page/chapter labels, derived once when the document
    /// loads. Deriving inside a sheet's initializer would rerun a whole-book
    /// scan on every body evaluation — word-highlight cadence during playback.
    @State private var navigation: ReaderNavigation?
    @State private var loadFailed = false
    @State private var isLoaded = false
    @State private var scrolledAway = false
    @State private var returnTrigger = 0
    @State private var showAppearanceSheet = false
    @State private var showChapterSheet = false
    @State private var showSearchSheet = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if let content {
                ReaderTextView(
                    content: content,
                    fontSize: ReaderTextSize.points(forStep: textSizeStep),
                    activeSentence: playback.currentSentence,
                    // The word-highlight pref is gated once, here at the source.
                    activeWord: model.wordHighlight ? playback.currentWord : -1,
                    autoScroll: model.autoScroll,
                    isPlaying: playback.isActive,
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
        .sheet(isPresented: $showChapterSheet) {
            if let navigation {
                ChapterListSheet(chapters: navigation.chapters,
                                 labels: navigation.labels,
                                 kind: document.kind)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            if let content, let navigation {
                SearchSheet(content: content, labels: navigation.labels)
            }
        }
        .task {
            sleepTimer.attach(to: playback)
            await load()
        }
        // Per-sentence progress persists through `PlaybackController.onProgress`
        // (wired to `DocumentStore.saveProgress` in AppModel) — no duplicate
        // save here; the reader only writes the final position on leave.
        .onChange(of: playback.userPlayAction) { _ in
            // A USER play from idle/paused/ended centers the playhead so
            // following starts from it — honoring the Auto-scroll pref, and
            // never firing on buffering blips or interruption auto-resume
            // (those don't bump `userPlayAction`).
            if model.autoScroll { returnTrigger += 1 }
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
            // The title is the chapter-drawer entry point: a subtle chevron
            // signals it, and the whole 44pt-tall label is the hit area.
            Button { showChapterSheet = true } label: {
                HStack(spacing: 5) {
                    Text(liveDocument.title)
                        .font(Theme.serif(16, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(Theme.ui(9, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(content == nil)
            .accessibilityLabel("Chapters")
            .accessibilityIdentifier("reader.chapters")
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
            Button {
                showSearchSheet = true
            } label: {
                Label("Search in Book", systemImage: "magnifyingglass")
            }
            .disabled(content == nil)
            .accessibilityIdentifier("reader.search")
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
            navigation = ReaderNavigation(content: loaded, kind: document.kind)

            // Reconciliation may have reset progress; load the live record so
            // the controller cues at the saved sentence.
            playback.load(document: liveDocument, content: loaded)
            isLoaded = true
            store.noteOpened(id: document.id)

            // UI-test hook (no-op in Release): `-uitest-seek-text <substring>`
            // cues the playhead at the first sentence containing the
            // substring, so the screenshot rig can land on a known passage
            // deterministically.
            if let needle = UITestHooks.seekText,
               let match = loaded.sentences.first(where: { $0.text.contains(needle) }) {
                playback.seek(to: match.id, andPlay: false)
            }

            // Continue Listening autoplay: content is loaded and the saved
            // position restored (playback.load cued it above) — start through
            // the user-play path so `userPlayAction` bumps and the reader
            // centers the playhead exactly as a tap on Play would. A book
            // still speaking (backed out to the shelf, tapped again) is
            // CONTINUED, never restarted — `startAutoplay` holds that line.
            if autoplay {
                playback.startAutoplay()
            }
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
        playback.seek(to: id, andPlay: playback.isActive)
    }
}
