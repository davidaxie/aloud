import SwiftUI

/// Search in Book, presented from the reader's overflow menu. A focused
/// search field over a case/diacritic-insensitive linear scan of the
/// document's sentences (debounced 200 ms). Result rows show the matching
/// sentence with the match tinted accent (color only — no weight change in
/// reading contexts) and a chapter/page context line. Tapping a result seeks
/// there preserving the current play/pause mode.
struct SearchSheet: View {

    let content: DocContent
    /// Chapter/page naming, derived once per document by the reader — the same
    /// labels the chapter drawer shows, so a result's context line and its
    /// drawer row can never disagree.
    let labels: PageLabels

    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SentenceMatch] = []
    /// True once a non-empty query has been scanned — gates the empty state
    /// so "No matches" never shows before the user has typed.
    @State private var hasSearched = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var scanTask: Task<[SentenceMatch], Never>?
    @FocusState private var fieldFocused: Bool

    private static let debounceNanoseconds: UInt64 = 200_000_000

    var body: some View {
        VStack(spacing: 16) {
            SheetGrabber()

            searchField

            if hasSearched {
                if results.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .sheetChrome([.large])
        .onAppear {
            // Focus after the sheet's presentation settles; an immediate set
            // is dropped by the transition on some runtimes.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                fieldFocused = true
            }
        }
        .onChange(of: query) { newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
            scanTask?.cancel()
        }
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(14, weight: .medium))
                .foregroundStyle(Theme.textFaint)

            TextField("Search in this book", text: $query)
                .font(Theme.ui(16))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.ui(15))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("search.clear")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 24)
    }

    // MARK: - Results

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(countLabel)
                .font(Theme.ui(13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("search.count")

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { match in
                        resultRow(match)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countLabel: String {
        results.count == 1 ? "1 match" : "\(results.count) matches"
    }

    private func resultRow(_ match: SentenceMatch) -> some View {
        Button {
            playback.seek(to: match.sentenceID, andPlay: playback.isActive)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                emphasized(match)
                    .font(Theme.serif(15))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Text(contextLine(for: match))
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.result.\(match.sentenceID)")
    }

    /// The sentence with the matched range tinted accent — color only, never
    /// a weight change (banned in reading contexts).
    private func emphasized(_ match: SentenceMatch) -> Text {
        let text = match.text
        let prefix = String(text[..<match.range.lowerBound])
        let hit = match.matchedText
        let suffix = String(text[match.range.upperBound...])
        return Text(prefix).foregroundColor(Theme.text)
            + Text(hit).foregroundColor(Theme.accentStrong)
            + Text(suffix).foregroundColor(Theme.text)
    }

    private func contextLine(for match: SentenceMatch) -> String {
        labels.contextTitle(forPage: match.page)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No matches")
                .font(Theme.ui(15, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("search.empty")
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Debounced scan

    /// Debounce, then scan off the main thread. The scan is hundreds of
    /// milliseconds on the largest bundled classics, so it never runs on the
    /// MainActor: the previous scan is cancelled (it polls cancellation per
    /// sentence and abandons the rest of the book), and only the surviving
    /// one publishes — in sentence order, as the scan produces it.
    private func scheduleSearch(for newValue: String) {
        debounceTask?.cancel()
        scanTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            hasSearched = false
            return
        }
        let content = content
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let scan = Task.detached(priority: .userInitiated) {
                content.matches(of: trimmed)
            }
            scanTask = scan
            let found = await scan.value
            guard !scan.isCancelled, !Task.isCancelled else { return }
            results = found
            hasSearched = true
        }
    }
}
