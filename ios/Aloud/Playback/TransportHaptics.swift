import SwiftUI

/// R20's haptic vocabulary: six events, each one `SensoryFeedback`.
///
/// Who emits what (direct taps, plus the end of a book). Emitted just
/// before acting, except for a sentence tap, which emits right after its
/// jump: only the jump tells whether the tap started the book.
/// - play (soft impact, 0.6): the Play button, the Continue circle and magic
///   tap when they start playback (`emitToggle`); a tap on the retry line; a
///   grid card, the Continue body or a Bookshelf row when
///   `playback.opensPlaying(doc)`; the featured classic unless autoplay is
///   suppressed; a sentence tap whose jump the controller counts as a play
///   (`userPlayAction` moves, see `ReaderScreen.playFromSentence`): from
///   paused or ended, and over a voice audition, which reads as active but
///   is a sample over the listener's pause; never while the book reads on;
///   Back 5 min.
/// - pause (light impact): the Play button, the Continue circle and magic
///   tap when they pause (`emitToggle`).
/// - detent (selection): the speed slider arriving at 1.0×, by drag or by
///   VoiceOver adjust (`SpeedScale.landsOnDetent`).
/// - preset (selection): a speed preset tap that changes the speed.
/// - scrubRelease (selection): once per completed scrub seek drag.
/// - finished (success): once, when a book reaches its own end while the
///   app is active and the voice was at full level (R24); emitted by
///   PlaybackController, the one unattended event with a haptic.
///
/// Never: adds and imports, the autoplay of an opened file, interruption
/// recovery, lock-screen and headphone commands, sleep or other unattended
/// stops, a voice audition starting, the skip buttons, Contents picks, Undo
/// jump (Undo back to the end included), VoiceOver scrub steps, a voice
/// sample over the end, and reopening a Finished book. Feedback answers
/// something the hand just did, so a change the user didn't make stays
/// silent; a book heard to its end is the one exception.
enum TransportHaptic: String, CaseIterable, Sendable {
    case play, pause, detent, preset, scrubRelease, finished

    var feedback: SensoryFeedback {
        switch self {
        case .play:   return .impact(flexibility: .soft, intensity: 0.6)
        case .pause:  return .impact(weight: .light)
        case .detent, .preset, .scrubRelease: return .selection
        case .finished: return .success
        }
    }
}

/// The one haptic source. Emitters publish a pulse; the single
/// `.playsTransportHaptics()` at the app root turns each pulse into feedback,
/// so the same tap feels the same everywhere, sheets included. The system
/// gates haptics behind the hardware and accessibility settings, so callers
/// emit unconditionally.
@MainActor
final class TransportHaptics: ObservableObject {

    static let shared = TransportHaptics()

    /// The serial makes two identical haptics in a row distinct values, so
    /// the feedback trigger fires for both.
    struct Pulse: Equatable {
        let haptic: TransportHaptic
        let serial: UInt64
    }

    @Published private(set) var pulse: Pulse?

    private init() {}

    func emit(_ haptic: TransportHaptic) {
        #if DEBUG
        log.append(haptic)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        #endif
        pulse = Pulse(haptic: haptic, serial: (pulse?.serial ?? 0) &+ 1)
    }

    static func emit(_ haptic: TransportHaptic) {
        shared.emit(haptic)
    }

    /// Call BEFORE toggling: pausing feels light, starting feels soft.
    static func emitToggle(isActive: Bool) {
        emit(isActive ? .pause : .play)
    }

    #if DEBUG
    /// The most recent haptics, oldest first, for the debug.haptics probe.
    private(set) var log: [TransportHaptic] = []
    private static let logLimit = 100

    /// Raw values joined by ",": "play,pause,detent".
    var logText: String { log.map(\.rawValue).joined(separator: ",") }

    func resetLog() { log.removeAll() }
    #endif
}

extension View {
    /// The app's one `.sensoryFeedback`, attached once at the root.
    func playsTransportHaptics() -> some View {
        modifier(TransportHapticsPlayer())
    }
}

private struct TransportHapticsPlayer: ViewModifier {
    @ObservedObject private var haptics = TransportHaptics.shared

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: haptics.pulse) { _, new in new?.haptic.feedback }
    }
}
