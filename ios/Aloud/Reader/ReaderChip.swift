import SwiftUI

/// The one chip above the player bar (R11, R15, R16, R24). "Undo jump" for
/// 10 s after a jump beats "More classics" at the end of a book, which beats
/// "Follow the voice" while the voice is off-screen; the slot never shows
/// two.
enum ReaderChip: Equatable {
    case undoJump
    /// R24: the end of a book offers the next one.
    case moreClassics
    case followVoice(ReaderFollowDirection)

    /// nil = no chip. Undo outranks More classics, so a jump away from the
    /// end can still be taken back.
    static func resolve(canUndoJump: Bool, voiceOffscreen: ReaderFollowDirection?,
                        isAtEnd: Bool = false) -> ReaderChip? {
        if canUndoJump { return .undoJump }
        if isAtEnd { return .moreClassics }
        return voiceOffscreen.map { .followVoice($0) }
    }

    var title: String {
        switch self {
        case .undoJump: return "Undo jump"
        case .moreClassics: return "More classics"
        case .followVoice: return "Follow the voice"
        }
    }

    /// The arrow points toward the voice.
    var systemImage: String {
        switch self {
        case .undoJump: return "arrow.uturn.backward"
        case .moreClassics: return "books.vertical"
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
        case .followVoice(.up): return "reader.followVoice.up"
        case .followVoice(.down): return "reader.followVoice.down"
        }
    }

    var hint: String {
        switch self {
        case .undoJump: return "Returns to where you were"
        // The screen it opens is titled Classics.
        case .moreClassics: return "Opens Classics"
        case .followVoice: return "Scrolls to the sentence being read"
        }
    }

    /// Voice Control names: the full title and a one-word short form.
    var inputLabels: [String] {
        switch self {
        case .undoJump: return ["Undo jump", "Undo"]
        case .moreClassics: return ["More classics", "Classics"]
        case .followVoice: return ["Follow the voice", "Follow"]
        }
    }

    /// The slot's animation key: the follow arrow flipping direction is the
    /// same chip, so it doesn't re-animate.
    var slotKey: String {
        switch self {
        case .undoJump: return "undo"
        case .moreClassics: return "moreClassics"
        case .followVoice: return "follow"
        }
    }
}

/// The chip's capsule. No transition inside: the caller applies
/// `.messageTransition()` keyed by `slotKey`.
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
            .font(Theme.font(.subhead))
            .foregroundStyle(Theme.accentStrong)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            // The capsule is ~32pt tall; the hit area is the full 44.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(chip.title)
        .accessibilityHint(chip.hint)
        .accessibilityInputLabels(chip.inputLabels)
        .accessibilityIdentifier(chip.identifier)
    }
}
