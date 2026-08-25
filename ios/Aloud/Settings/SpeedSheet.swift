import SwiftUI

/// Speed bottom sheet: large 0.5–3.0× slider (0.05 steps, magnetic 1.0 detent),
/// big tabular readout, preset chips, and — when a document is loaded — a live
/// "≈ … left in this book" line recomputed at the slider's value from the
/// document's remaining words (the shared 165 wpm estimate).
struct SpeedSheet: View {

    @EnvironmentObject private var playback: PlaybackController

    private static let presets: [Double] = [0.8, 1.0, 1.2, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 22) {
            Capsule()
                .fill(Theme.lineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            Text(rateLabel)
                .font(Theme.ui(40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("speed.readout")

            Slider(value: rateBinding, in: 0.5...3.0)
                .tint(Theme.accent)
                .padding(.horizontal, 24)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(rateLabel)

            HStack(spacing: 10) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        playback.rate = preset
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

            if let remaining = timeLeftLine {
                Text(remaining)
                    .font(Theme.ui(13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("speed.timeLeft")
            }

            Spacer(minLength: 0)
        }
        .background(Theme.surface)
        .presentationDetents([.height(316)])
    }

    // MARK: - Rate

    /// 0.05 steps with a magnetic detent at 1.0×.
    private var rateBinding: Binding<Double> {
        Binding(
            get: { playback.rate },
            set: { value in
                let stepped = (value * 20).rounded() / 20
                playback.rate = abs(stepped - 1.0) < 0.05 ? 1.0 : stepped
            }
        )
    }

    private var rateLabel: String {
        playback.rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func isActive(_ preset: Double) -> Bool {
        abs(playback.rate - preset) < 0.001
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
