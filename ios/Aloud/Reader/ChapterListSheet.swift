import SwiftUI

/// Chapter drawer, presented by tapping the title in the reader top bar.
/// Text books list their derived chapters — serif title, estimated listening
/// time trailing; PDFs (whose pages carry no headings) degrade to a page
/// jumper, whose rows name a page or a run of them ("Pages 12–14") because
/// prose flowing across a page break leaves that break with no block of its
/// own. The current chapter carries a subtle accent dot, completed chapters
/// mute, and a tap seeks there preserving play/pause mode.
///
/// Chapters and labels are derived once per loaded document by the reader and
/// handed in — deriving them here would rerun a whole-book scan on every
/// parent body evaluation (word-highlight cadence during playback).
struct ChapterListSheet: View {

    let chapters: [DerivedChapter]
    let labels: PageLabels
    let kind: DocKind

    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()

            Text(kind == .pdf ? "Pages" : "Chapters")
                .font(Theme.ui(13, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chapters) { chapter in
                            row(chapter)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToCurrent(proxy) }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .sheetChrome([.medium, .large])
    }

    // MARK: - Rows

    private var currentChapter: DerivedChapter? {
        chapters.first { $0.contains(sentence: playback.currentSentence) }
    }

    /// Land on the current chapter without animation (nothing to soften;
    /// Reduce Motion needs no gate). A LazyVStack has not laid out its rows
    /// when `onAppear` fires during sheet presentation, so the scroll happens
    /// after the first layout pass and repeats once when the presentation has
    /// settled — a hundreds-of-rows page list otherwise opens at the top.
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = currentChapter else { return }
        Task { @MainActor in
            proxy.scrollTo(current.id, anchor: .center)
            try? await Task.sleep(nanoseconds: 150_000_000)
            proxy.scrollTo(current.id, anchor: .center)
        }
    }

    private func row(_ chapter: DerivedChapter) -> some View {
        let isCurrent = chapter.contains(sentence: playback.currentSentence)
        let isCompleted = !isCurrent && playback.currentSentence > chapter.lastSentence
        // Rate-aware, like the shelf cards and the player bar's time left: at
        // 2× a chapter takes half as long, and the drawer says so.
        let estimate = ListeningEstimate.phrase(
            minutes: chapter.estimatedMinutes(
                wordsPerMinute: LibraryDocument.spokenWordsPerMinute * playback.rate))

        return Button {
            playback.seek(to: chapter.startSentence, andPlay: playback.isActive)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                // Fixed-width indicator column keeps titles aligned.
                Circle()
                    .fill(isCurrent ? Theme.accent : Color.clear)
                    .frame(width: 6, height: 6)

                Text(labels.contextTitle(forPage: chapter.page))
                    .font(Theme.serif(16))
                    .foregroundStyle(isCompleted ? Theme.textMuted : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Text(estimate)
                    .font(Theme.ui(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(chapter.id)
        .accessibilityLabel(accessibilityLabel(for: chapter,
                                               estimate: estimate,
                                               isCurrent: isCurrent))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("chapters.row.\(labels.displayPage(chapter.page))")
    }

    private func accessibilityLabel(for chapter: DerivedChapter,
                                    estimate: String,
                                    isCurrent: Bool) -> String {
        var label = "\(labels.contextTitle(forPage: chapter.page)), \(estimate)"
        if isCurrent { label += ", current" }
        return label
    }
}
