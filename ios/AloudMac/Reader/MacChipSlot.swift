import SwiftUI

/// The one chip above the player bar (R11, mac-ux §3.8), centered on the
/// column 12 above the bar's top edge. The shared `ReaderChip` picks it:
/// "Undo jump" for 10 s after a jump beats "More classics" at the end of a
/// book, which beats "Follow the voice" while the voice is off the page.
/// The slot never shows two. Keys: ⌘Z (Undo Jump) and ⌘J (Follow the
/// Voice) reach the same actions from the menus; each tooltip names its key.
struct MacChipSlot: View {

    /// Where the voice is while the page isn't following it, as the page
    /// reports it.
    let voiceOffscreen: ReaderFollowDirection?
    let onFollowVoice: () -> Void

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var router: LibraryRouter

    var body: some View {
        // Keyed by slot, so the Follow arrow flipping direction doesn't
        // re-animate; the shared transition is a plain fade under Reduce Motion.
        ZStack {
            if let chip {
                MacChipView(chip: chip) { handle(chip) }
                    .id(chip.slotKey)
                    .messageTransition()
            }
        }
        .animation(.easeOut(duration: Theme.Motion.message), value: chip?.slotKey)
    }

    var chip: ReaderChip? {
        ReaderChip.resolve(canUndoJump: playback.undoableJump != nil,
                           voiceOffscreen: voiceOffscreen,
                           isAtEnd: playback.isAtEnd)
    }

    private func handle(_ chip: ReaderChip) {
        switch chip {
        case .undoJump: playback.undoJump()
        case .moreClassics: router.showBookshelfFromReader()
        case .followVoice: onFollowVoice()
        }
    }
}

/// The slot's capsule: the shared chip's glyph, title and names, drawn as a
/// Mac chip (accentStrong on Theme.surface, surface2 under the pointer)
/// with a tooltip that names its menu key.
struct MacChipView: View {
    let chip: ReaderChip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: chip.systemImage)
                    .accessibilityHidden(true)
                Text(chip.title)
            }
        }
        .buttonStyle(MacChipButtonStyle(tint: Theme.accentStrong))
        .fixedSize()
        .help(Self.help(for: chip))
        .accessibilityLabel(chip.title)
        .accessibilityHint(chip.hint)
        .accessibilityInputLabels(chip.inputLabels.map { Text($0) })
        .accessibilityIdentifier(chip.identifier)
    }

    /// "Undo jump (⌘Z)", "Follow the voice (⌘J)"; More classics has no key.
    static func help(for chip: ReaderChip) -> String {
        switch chip {
        case .undoJump: return MacCommand.undoJump.help
        case .followVoice: return MacCommand.followVoice.help
        case .moreClassics: return chip.hint
        }
    }
}
