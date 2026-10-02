import Foundation

/// How a deliberate move was asked for (R15). The PRD rule: a tap must move
/// more than 3 sentences to offer "Undo jump"; chapter, search and scrub
/// picks offer Undo whenever they move.
enum JumpOrigin: Equatable, Sendable {
    /// A tap on the text, or VoiceOver "Play from here"/double-tap: plays in
    /// any state.
    case sentence
    /// A Contents row, a search result, a scrub release or a VoiceOver scrub
    /// step: keeps play or pause.
    case chapter, searchResult, scrub

    var startsPlayback: Bool { self == .sentence }
}

/// The "Undo jump" offer: where the listener was, and in what state, before
/// a jump that moved far enough to lose their place (R15).
struct UndoableJump: Equatable, Sendable {
    let documentID: UUID
    let fromSentence: Int
    let fromStatus: PlayerStatus
    let toSentence: Int
    /// The controller's `jumpSerial` when the offer was made or extended.
    let serial: Int

    static let displaySeconds: TimeInterval = 10
    /// A sentence tap offers Undo only past this many sentences.
    static let tapThreshold = 3
}
