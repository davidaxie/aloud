import SwiftUI

/// R10's progress overlay, over the whole window, for the shared importer.
/// An add that extracts within 0.8 s never shows it (M8): most text files
/// and small PDFs are done before an overlay could be read. Past that, a
/// shadow-ink scrim takes the clicks and a raised surface card shows the
/// file, its progress and Cancel, which Esc presses too. Cancel drops the
/// queue with it, and the book never opens. A file still being copied in
/// (a cloud file downloading, a large one copying) shows the same card at
/// no progress yet, and Cancel drops its batch too (`MacFileIntake`).
///
/// `isRevealed` is the root's, so the stack under the overlay leaves the
/// VoiceOver tree only while the overlay is actually up.
struct MacImportOverlay: View {
    @Binding var isRevealed: Bool

    @EnvironmentObject private var importer: DocumentImporter
    /// The window's intake: its copies come before the importer has them.
    @ObservedObject private var intake = MacFileIntake.shared

    /// Quicker extraction than this shows nothing: the iPhone's delay too
    /// (`ImportOverlayReveal`).
    static let revealDelay: Duration = ImportOverlayReveal.delay

    var body: some View {
        ZStack {
            if isRevealed, let shown = Self.shown(phase: importer.phase, copyingName: intake.copyingName) {
                MacImportCard(fileName: shown.name, progress: shown.progress, onCancel: intake.cancel)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.crossfade), value: isRevealed)
        // Keyed on the add as a whole: a queued file starts in the same turn
        // the last one ends, and a copied batch is handed over in the turn
        // its copying ends, so a batch keeps the overlay up.
        .task(id: isBusy) { await revealOnceSlow() }
    }

    /// What the card shows: the importer's add, or else the file being
    /// copied in, at no progress yet. nil: nothing is under way.
    static func shown(phase: DocumentImporter.Phase, copyingName: String?) -> (name: String, progress: Double)? {
        if case .importing(let name, let progress) = phase { return (name, progress) }
        return copyingName.map { (name: $0, progress: 0.0) }
    }

    private var isBusy: Bool { importer.isImporting || intake.copyingName != nil }

    /// A display delay only: the add itself never waits on it.
    private func revealOnceSlow() async {
        guard isBusy else {
            isRevealed = false
            return
        }
        try? await Task.sleep(for: Self.revealDelay)
        if !Task.isCancelled, isBusy { isRevealed = true }
    }
}

/// The overlay's card: "Adding", the file name, a progress bar and Cancel.
private struct MacImportCard: View {
    let fileName: String
    let progress: Double
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// VoiceOver lands on the progress as the card appears, as on the iPhone.
    @AccessibilityFocusState private var focused: Bool

    /// The card's width; the Mac's type doesn't scale, so neither does it.
    private static let width: CGFloat = 320

    var body: some View {
        ZStack {
            Theme.Elevation.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            card
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCancel)
        .accessibilityIdentifier("import.overlay")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            progressGroup
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(MacTextLinkStyle())
                    // Esc, while the overlay is up (the shortcut table's
                    // "cancel import").
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel (Esc)")
                    .accessibilityIdentifier("import.cancel")
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.surface)
                .raisedElevation()
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth)
        )
        .padding(Theme.Space.xxl)
    }

    private var progressGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // R25: one word for an add in progress, as on a Classics row.
            Text("Adding")
                .font(Theme.font(.eyebrow))
                .eyebrowTracking()
                .textCase(.uppercase)
                .accessibilityLabel(Text("Adding"))
                .foregroundStyle(Theme.textFaint)
            Text(fileName)
                .font(Theme.font(.callout))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: Theme.Space.sm) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * clampedProgress)
                    }
                }
                .frame(height: 4)
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.crossfade),
                           value: clampedProgress)
                // Sized by its widest reading, so the bar holds still as
                // the count gains a digit.
                ZStack(alignment: .trailing) {
                    Text("100%").hidden()
                    Text("\(percent)%")
                }
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            }
        }
        // One element, so VoiceOver reads the file once and then only the
        // percent as it changes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adding \(fileName)")
        .accessibilityValue("\(percent) percent")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($focused)
        .accessibilityIdentifier("import.progress")
        .onAppear { focused = true }
    }

    private var clampedProgress: Double { min(max(progress, 0), 1) }
    private var percent: Int { Int((clampedProgress * 100).rounded()) }
}
