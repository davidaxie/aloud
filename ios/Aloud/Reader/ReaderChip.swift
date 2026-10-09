import SwiftUI

/// The one chip above the player bar (R11, R15, R16, R24, R4-06). Undo jump
/// for 10 s after a jump beats the end of a book, which beats Follow the
/// voice while the voice is off-screen; the slot never shows two. At the
/// end, the chip offers the next book while the colophon is on screen, and
/// leads back to the colophon once the page is scrolled away from it.
enum ReaderChip: Equatable {
    case undoJump
    /// R24: the end of a book offers the next one.
    case moreClassics
    /// R4-06: at the end, scrolled away from the colophon. While it shows,
    /// the follow target is the colophon, so the arrow points to it.
    case theEnd(ReaderFollowDirection)
    case followVoice(ReaderFollowDirection)

    /// nil = no chip. Undo outranks the end, so a jump away from the end
    /// can still be taken back. At the end, `voiceOffscreen` says where the
    /// colophon is: off screen, the chip leads back to it; on screen, it
    /// offers the next book.
    static func resolve(canUndoJump: Bool, voiceOffscreen: ReaderFollowDirection?,
                        isAtEnd: Bool = false) -> ReaderChip? {
        if canUndoJump { return .undoJump }
        if isAtEnd { return voiceOffscreen.map { .theEnd($0) } ?? .moreClassics }
        return voiceOffscreen.map { .followVoice($0) }
    }

    var title: String {
        switch self {
        case .undoJump: return "Undo jump"
        case .moreClassics: return "More classics"
        case .theEnd: return "Back to The End"
        case .followVoice: return "Follow the voice"
        }
    }

    /// The arrow points toward the voice, or toward the colophon.
    var systemImage: String {
        switch self {
        case .undoJump: return "arrow.uturn.backward"
        case .moreClassics: return "books.vertical"
        case .theEnd(.up): return "arrow.up"
        case .theEnd(.down): return "arrow.down"
        case .followVoice(.up): return "arrow.up"
        case .followVoice(.down): return "arrow.down"
        }
    }

    /// Carries the direction, so UI tests can check the arrow without
    /// VoiceOver having to say it.
    var identifier: String {
        switch self {
        case .undoJump: return "reader.undoJump"
        case .moreClassics: return "reader.moreClassics"
        case .theEnd(.up): return "reader.theEnd.up"
        case .theEnd(.down): return "reader.theEnd.down"
        case .followVoice(.up): return "reader.followVoice.up"
        case .followVoice(.down): return "reader.followVoice.down"
        }
    }

    var hint: String {
        switch self {
        case .undoJump: return "Returns to where you were"
        // The screen it opens is titled Classics.
        case .moreClassics: return "Opens Classics"
        case .theEnd: return "Scrolls to the end of the book"
        case .followVoice: return "Scrolls to the sentence being read"
        }
    }

    /// Voice Control names: the full title and a one-word short form.
    var inputLabels: [String] {
        switch self {
        case .undoJump: return ["Undo jump", "Undo"]
        case .moreClassics: return ["More classics", "Classics"]
        case .theEnd: return ["Back to The End", "The End"]
        case .followVoice: return ["Follow the voice", "Follow"]
        }
    }

    /// The slot's animation key: the follow arrow flipping direction is the
    /// same chip, so it doesn't re-animate, and neither does a swap between
    /// Follow and the way back to the colophon, which share the follow role.
    var slotKey: String {
        switch self {
        case .undoJump: return "undo"
        case .moreClassics: return "moreClassics"
        case .theEnd, .followVoice: return "follow"
        }
    }
}

/// The chip's capsule: the reader's chip look in accentStrong, pressed like
/// the bar's chips (surface2 and a slight settle), never an opacity dim. No
/// transition inside: the caller applies `.messageTransition()` keyed by
/// `slotKey`.
struct ReaderChipView: View {
    let chip: ReaderChip
    let action: () -> Void

    init(chip: ReaderChip, action: @escaping () -> Void) {
        self.chip = chip
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: chip.systemImage)
                    .accessibilityHidden(true)
                Text(chip.title)
            }
            // With the style's own inset, the capsule's roomier sides.
            .padding(.horizontal, Theme.Space.xs)
        }
        .buttonStyle(ReaderChipButtonStyle(tint: Theme.accentStrong))
        .accessibilityLabel(chip.title)
        .accessibilityHint(chip.hint)
        .accessibilityInputLabels(chip.inputLabels)
        .accessibilityIdentifier(chip.identifier)
    }
}
