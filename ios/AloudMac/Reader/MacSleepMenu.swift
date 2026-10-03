import SwiftUI

/// The player bar's sleep chip on the Mac (R19, mac-ux §3.10): a pull-down
/// menu bound to the app's one `SleepTimer`, which outlives the reader and
/// the window. The chip shows a moon while off and the countdown ("28:14"),
/// "Chapter end" or "Book end" while armed. The menu lists the most recent
/// choice first, then 15 min, 30 min, 45 min, 1 hr and End of chapter (End
/// of book without chapters), with a check on the armed one; Off sits apart
/// below a separator, only while armed. Arming 30 minutes takes two clicks.
/// While the voice fades toward the stop the chip is a plain "+15 min"
/// button. Playback ▸ Sleep Timer lists the same choices in title case.
struct MacSleepMenu: View {

    /// Owned by AppModel, so leaving the reader never disarms it.
    @EnvironmentObject private var sleepTimer: SleepTimer
    @State private var isHovered = false

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

    private var menu: some View {
        let items = Self.items(options: sleepTimer.menuOptions, isArmed: sleepTimer.isArmed)
        return Menu {
            ForEach(items.choices, id: \.self) { option in
                Toggle(isOn: selection(option)) {
                    Text(Self.title(for: option, endsAtChapter: sleepTimer.endsAtChapter))
                }
            }
            if items.showsOff {
                Divider()
                Button(Self.title(for: .off, endsAtChapter: sleepTimer.endsAtChapter)) {
                    sleepTimer.select(.off)
                }
            }
        } label: {
            // The capsule is the label, so the whole chip is the hit region
            // and it matches the voice · speed chip; the pull-down itself
            // stays system chrome.
            chipLabel
                .macChipFace(isOn: sleepTimer.isArmed, isHighlighted: isHovered)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: Theme.Motion.press), value: isHovered)
        .help(MacCommand.sleepTimer.help)
        .accessibilityLabel(sleepTimer.isArmed ? "\(sleepTimer.chipText), sleep timer" : SleepTimer.Copy.section)
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
        } else {
            Image(systemName: "moon")
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// A checkmark item: on while it is the armed choice; picking it again
    /// re-arms it from the top, as on the iPhone.
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
        .buttonStyle(MacChipButtonStyle(isOn: true))
        .fixedSize()
        .accessibilityLabel(SleepTimer.Copy.extendSpoken)
        .accessibilityHint(SleepTimer.Copy.extendHint)
        .accessibilityInputLabels([Text(SleepTimer.Copy.extendChip),
                                   Text(SleepTimer.Copy.extendSpoken),
                                   Text(SleepTimer.Copy.section)])
        .accessibilityIdentifier("player.sleep")
    }

    // MARK: - Rules

    /// The menu's choices, most recent first (the shared order), and whether
    /// Off shows: only while a timer is armed, kept apart from the choices.
    static func items(options: [SleepTimer.Option], isArmed: Bool) -> (choices: [SleepTimer.Option], showsOff: Bool) {
        (options.filter { $0 != .off }, isArmed)
    }

    /// The chip menu's sentence-case titles: "15 min", "1 hr", "End of
    /// chapter" ("End of book" without chapters) and "Off".
    static func title(for option: SleepTimer.Option, endsAtChapter: Bool) -> String {
        switch option {
        case .minutes(let minutes): return ListeningEstimate.phrase(minutes: minutes)
        case .off, .endOfChapter: return option.title(endsAtChapter: endsAtChapter)
        }
    }
}
