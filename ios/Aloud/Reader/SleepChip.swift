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

    /// The most recent choice sits nearest the chip (`.priority` on the
    /// iPhone), each a native checkmark item that VoiceOver reads as
    /// selected; Off sits apart, and only while a timer is armed.
    private var menu: some View {
        let items = SleepTimer.menuItems(options: sleepTimer.menuOptions, isArmed: sleepTimer.isArmed)
        return Menu {
            Section(SleepTimer.Copy.section) {
                ForEach(items.choices, id: \.self) { option in
                    Toggle(isOn: selection(option)) {
                        Text(option.title(endsAtChapter: sleepTimer.endsAtChapter))
                    }
                }
            }
            if items.showsOff {
                Section {
                    Button(SleepTimer.Option.off.title(endsAtChapter: sleepTimer.endsAtChapter)) {
                        sleepTimer.select(.off)
                    }
                }
            }
        } label: {
            // The label draws the chip; the press reaches it wherever the
            // system styles the menu's button.
            chipLabel
                .readerChip(isOn: sleepTimer.isArmed)
        }
        .menuStyle(.button)
        .buttonStyle(ReaderChipPressStyle())
        .menuOrderNearestFirst()
        .menuIndicator(.hidden)
        .readerChipFullWidth(isOn: sleepTimer.isArmed) { fullLabel }
        .largeContentViewerIfAvailable { largeContent }
        .accessibilityLabel(sleepTimer.chipSpokenLabel)
        .accessibilityValue(sleepTimer.isArmed ? "" : "Off")
        .accessibilityInputLabels([Text(SleepTimer.Copy.section)])
        .accessibilityIdentifier("player.sleep")
    }

    /// The moon while off; the countdown, which never shortens; or the
    /// chapter or book end, which falls back to a filled moon on the armed
    /// fill where its words can't fit. Never smaller type.
    @ViewBuilder
    private var chipLabel: some View {
        switch sleepTimer.option {
        case .off:
            Image(systemName: "moon")
                .foregroundStyle(Theme.textMuted)
        case .minutes:
            Text(sleepTimer.chipText)
                .monospacedDigit()
                .numericReadout(sleepTimer.remaining)
        case .endOfChapter:
            ViewThatFits(in: .horizontal) {
                Text(sleepTimer.chipText)
                Image(systemName: "moon.fill")
            }
        }
    }

    /// The label with all its words, which the bar measures.
    @ViewBuilder
    private var fullLabel: some View {
        if sleepTimer.isFading {
            Text(SleepTimer.Copy.extendChip)
                .monospacedDigit()
        } else if sleepTimer.isArmed {
            Text(sleepTimer.chipText)
                .monospacedDigit()
        } else {
            Image(systemName: "moon")
        }
    }

    /// What a long press shows at accessibility sizes, past the chip's cap.
    @ViewBuilder
    private var largeContent: some View {
        if sleepTimer.isArmed {
            Text(sleepTimer.chipText)
        } else {
            Label(SleepTimer.Copy.section, systemImage: "moon")
        }
    }

    /// A checkmark item: on while it is the armed choice; picking it again
    /// re-arms it from the top, as on the Mac.
    private func selection(_ option: SleepTimer.Option) -> Binding<Bool> {
        Binding(get: { sleepTimer.option == option },
                set: { _ in sleepTimer.select(option) })
    }

    // MARK: - Fading

    private var extendButton: some View {
        Button {
            sleepTimer.addFifteenMinutes()
        } label: {
            Text(SleepTimer.Copy.extendChip)
                .monospacedDigit()
        }
        .buttonStyle(ReaderChipButtonStyle(isOn: true))
        .readerChipFullWidth(isOn: true) { fullLabel }
        .largeContentViewerIfAvailable { Text(SleepTimer.Copy.extendChip) }
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
    /// timer" while off. At "0:00" (the landing window, below zero) it says
    /// there is no time left, never the "1 minute" `spokenPhrase` rounds up
    /// to. One label for the iPhone chip and the Mac's sleep menu, so the
    /// two can't drift apart.
    var chipSpokenLabel: String {
        switch option {
        case .off:
            return Copy.section
        case .minutes:
            guard remaining > 0 else { return Copy.noTimeLeftSpoken + ", sleep timer" }
            let minutes = Int((remaining / 60).rounded(.up))
            return ListeningEstimate.spokenPhrase(minutes: minutes) + " left, sleep timer"
        case .endOfChapter:
            return "\(chipText), sleep timer"
        }
    }
}
