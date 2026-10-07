import SwiftUI

/// The player bar's sleep chip (R6, R19): a moon while off; the countdown
/// ("28:14"), "Chapter end" or "Book end" while armed; and "+15 min" while
/// the voice fades toward the stop, where one tap keeps it playing. Its own
/// view, so the timer's tick re-renders only the chip, never the player bar.
struct SleepChip: View {

    /// Owned by AppModel, so leaving the reader never disarms it.
    @EnvironmentObject private var sleepTimer: SleepTimer

    var body: some View {
        ZStack {
            if sleepTimer.isFading {
                extendButton
                    .transition(MotionStyle.opacity.transition)
            } else {
                menu
                    .transition(MotionStyle.opacity.transition)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.crossfade), value: sleepTimer.isFading)
    }

    // MARK: - Armed or off

    /// The most recent option sits nearest the chip (`.priority` on the
    /// iPhone), Off last.
    private var menu: some View {
        Menu {
            Section(SleepTimer.Copy.section) {
                ForEach(sleepTimer.menuOptions, id: \.self) { option in
                    Button {
                        sleepTimer.select(option)
                    } label: {
                        optionLabel(option)
                    }
                }
            }
        } label: {
            chipLabel
        }
        .menuOrderNearestFirst()
        .menuIndicator(.hidden)
        .accessibilityLabel(sleepTimer.chipSpokenLabel)
        .accessibilityValue(sleepTimer.isArmed ? "" : "Off")
        .accessibilityInputLabels([Text(SleepTimer.Copy.section)])
        .accessibilityIdentifier("player.sleep")
    }

    @ViewBuilder
    private var chipLabel: some View {
        if sleepTimer.isArmed {
            Text(sleepTimer.chipText)
                .monospacedDigit()
                .numericReadout(sleepTimer.remaining)
                .readerChip(isOn: true)
        } else {
            Image(systemName: "moon")
                .foregroundStyle(Theme.textMuted)
                .readerChip()
        }
    }

    @ViewBuilder
    private func optionLabel(_ option: SleepTimer.Option) -> some View {
        let title = option.title(endsAtChapter: sleepTimer.endsAtChapter)
        if sleepTimer.option == option {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Fading

    private var extendButton: some View {
        Button {
            sleepTimer.addFifteenMinutes()
        } label: {
            Text(SleepTimer.Copy.extendChip)
                .monospacedDigit()
                .readerChip(isOn: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SleepTimer.Copy.extendSpoken)
        .accessibilityHint(SleepTimer.Copy.extendHint)
        .accessibilityInputLabels([Text(SleepTimer.Copy.extendChip),
                                   Text(SleepTimer.Copy.extendSpoken),
                                   Text(SleepTimer.Copy.section)])
        .accessibilityIdentifier("player.sleep")
    }
}

extension SleepTimer {
    /// The armed chip's VoiceOver label, with the time left spelled out
    /// ("29 minutes left, sleep timer", "1 hour left, sleep timer") like
    /// every other time in the bar, never the visible m:ss countdown, which
    /// VoiceOver reads as a pair of numbers or a clock time. Rounded up, as
    /// the countdown is. "Chapter end" and "Book end" read as shown; "Sleep
    /// timer" while off. One label for the iPhone chip and the Mac's sleep
    /// menu, so the two can't drift apart.
    var chipSpokenLabel: String {
        switch option {
        case .off:
            return Copy.section
        case .minutes:
            let minutes = Int((max(remaining, 0) / 60).rounded(.up))
            return ListeningEstimate.spokenPhrase(minutes: minutes) + " left, sleep timer"
        case .endOfChapter:
            return "\(chipText), sleep timer"
        }
    }
}
