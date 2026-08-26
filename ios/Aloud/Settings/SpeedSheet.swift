import SwiftUI

/// Speed bottom sheet: large 0.5–3.0× slider (0.05 steps, magnetic 1.0 detent),
/// big tabular readout, preset chips, and — in the reader — a live
/// "≈ … left in this book" line recomputed at the slider's value from the
/// document's remaining words (the shared 165 wpm estimate).
///
/// Two presentations, one sheet. From the player bar (`.book`) it drives and
/// pins the loaded book. From Settings (`.global`) it edits the default every
/// unpinned book follows: no book's live audio is dragged along, and the
/// "in this book" line — which would be about a book the user isn't looking
/// at — stays away.
struct SpeedSheet: View {

    var scope: PreferenceScope = .book

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel

    /// Global scope only: the value under the slider while it is being dragged.
    /// The default is a preference, not live audio, so there is nothing to
    /// write it through until the drag ends.
    @State private var globalDraft: Double = 1.0

    private static let presets: [Double] = [0.8, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 22) {
            SheetGrabber()

            Text(rateLabel)
                .font(Theme.ui(40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("speed.readout")

            Slider(value: rateBinding, in: 0.5...3.0, onEditingChanged: { editing in
                // One write per drag: every 0.05 step moves the readout (and,
                // in the reader, the audio), but the pick is only committed
                // when the user lets go — a 0.5→3.0 sweep costs one store
                // write instead of fifty.
                if !editing { commit(rate) }
            })
                .tint(Theme.accent)
                .padding(.horizontal, 24)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(rateLabel)

            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        TransportHaptics.selectionChanged()
                        // Deliberate pick: re-tapping the active preset is
                        // how a book gets pinned to the speed it inherited,
                        // so this must not be conditioned on a value change.
                        setLive(preset)
                        commit(preset)
                    } label: {
                        Text(preset.formatted(.number.precision(.fractionLength(0...1))) + "×")
                            .font(Theme.ui(14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(isActive(preset) ? Theme.accentStrong : Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                isActive(preset) ? Theme.accentSoft : Theme.surface2,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                }
            }
            .padding(.horizontal, 24)

            if scope == .book, let remaining = timeLeftLine {
                Text(remaining)
                    .font(Theme.ui(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("speed.timeLeft")
            }

            Spacer(minLength: 0)
        }
        .background(Theme.surface)
        // Was the one sheet showing the system indicator on top of its own
        // grabber; the shared chrome hides it like every other sheet.
        .sheetChrome([.height(316)])
        .onAppear { globalDraft = model.globalRate }
    }

    // MARK: - Rate

    /// What the sheet is showing: the loaded book's live rate, or the global
    /// default being edited.
    private var rate: Double {
        scope == .book ? playback.rate : globalDraft
    }

    /// 0.05 steps with a magnetic detent at 1.0×. Live only — the drag moves
    /// the readout (and the audio, in the reader); the release is the pick.
    private var rateBinding: Binding<Double> {
        Binding(
            get: { rate },
            set: { value in
                let stepped = (value * 20).rounded() / 20
                setLive(abs(stepped - 1.0) < 0.05 ? 1.0 : stepped)
            }
        )
    }

    /// Moves the value without persisting anything.
    private func setLive(_ value: Double) {
        switch scope {
        case .book: playback.rate = value
        case .global: globalDraft = PlaybackController.clampedRate(value)
        }
    }

    /// Writes the pick where this presentation means it to go.
    private func commit(_ value: Double) {
        switch scope {
        case .book: playback.selectRate(value)
        case .global:
            model.selectGlobalRate(value)
            globalDraft = model.globalRate   // adopt the clamped value
        }
    }

    private var rateLabel: String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func isActive(_ preset: Double) -> Bool {
        abs(rate - preset) < 0.001
    }

    // MARK: - Time left

    /// Live estimate from the loaded document's remaining words at the current
    /// slider value. Uses the shared 165 wpm helper; the remaining fraction
    /// comes from the live playhead, not the debounced stored progress.
    private var timeLeftLine: String? {
        guard let document = playback.document,
              let total = document.estimatedTotalSeconds(rate: playback.rate)
        else { return nil }

        let sentenceCount = playback.content?.sentences.count ?? document.sentenceCount
        let fraction: Double
        if sentenceCount > 0, playback.currentSentence >= 0 {
            fraction = min(Double(playback.currentSentence) / Double(sentenceCount), 1)
        } else {
            fraction = document.progressFraction
        }
        let seconds = total * (1 - min(max(fraction, 0), 1))
        return "≈ " + PlayerBarView.timeLeftLabel(seconds: seconds) + " in this book"
    }
}
