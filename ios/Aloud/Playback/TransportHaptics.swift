import SwiftUI

/// R20's haptic vocabulary: eight events, each one `SensoryFeedback`,
/// every one answering the hand. Subtle by design: a button press is a
/// softer impact than Play's, and a place move is the lightest tick there
/// is (selection), as the scrub's and the presets' are.
///
/// Who emits what (direct taps, plus the end of a book). Emitted just
/// before acting, except for a sentence tap and a Contents pick, which
/// emit right after their jump: only the jump tells whether the tap
/// started the book. A control emits exactly one event per tap, never two.
/// - play (soft impact, 0.6): the Play button, the Continue circle and magic
///   tap when they start playback (`emitToggle`); a tap on the retry line; a
///   grid card, the Continue body or a Bookshelf row when
///   `playback.opensPlaying(doc)`; the featured classic unless autoplay is
///   suppressed; a sentence tap (or Play from Here) whose jump the
///   controller counts as a play (`userPlayAction` moves, see
///   `ReaderScreen.playFromSentence`): from paused or ended, and over a
///   voice audition, which reads as active but is a sample over the
///   listener's pause; a Contents chapter, place or search pick that starts
///   playback (`ContentsSearch.jumpAndPlay`); Back 5 min.
/// - pause (light impact): the Play button, the Continue circle and magic
///   tap when they pause (`emitToggle`).
/// - press (soft impact, 0.4): a button the hand just pressed that neither
///   plays, pauses nor moves the place: Back 15 and Forward 15, the voice
///   chip, the chapter line that opens Contents, the reader's Aa, every
///   sheet's close button (`SheetHeader`), the reader chips that aren't
///   place moves (Follow the voice, The End, More classics), the sleep
///   chip's +15 min, a voice row, a sleep timer choice, and the Library's
///   gear, its + menu's items and its More classics and Add a file links.
/// - place (selection): the reading place moved by the hand without
///   starting the book: a sentence tap (or Play from Here) while the book
///   reads on, a Contents pick while it plays, and Undo jump (the chip, the
///   chapter line's and the scrub's named action).
/// - detent (selection): the speed slider arriving at 1.0×, by drag or by
///   VoiceOver adjust (`SpeedScale.landsOnDetent`).
/// - preset (selection): a speed preset tap that changes the speed, a text
///   size stepper half or an Appearance segment that changes its setting,
///   and a pinch on the reader's page that steps the text size (P044).
/// - scrubRelease (selection): once per completed scrub seek drag.
/// - finished (success): once, when a book reaches its own end while the
///   app is active and the voice was at full level (R24); emitted by
///   PlaybackController, the one unattended event with a haptic.
///
/// Never: adds and imports finishing (the paste control's tap is the
/// system's own control), the autoplay of an opened file, interruption
/// recovery, lock-screen, headphone and remote commands, sleep or other
/// unattended stops, a voice audition's sample (its row's tap is a press,
/// never a play), VoiceOver scrub and text size adjust steps, the shelf
/// map's jumps, a voice sample over the end, a second `finished` for Undo
/// back to the end (its tap is a place), and reopening a Finished book.
/// Controls the system draws stay as the system makes them: the navigation
/// back button, Toggle switches, NavigationLink pushes and a Menu opening.
/// Feedback answers something the hand just did, so a change the user
/// didn't make stays silent; a book heard to its end is the one exception.
///
/// The Mac plays none of these. Its root attaches no
/// `.playsTransportHaptics()`, and SwiftUI's impact and selection feedback
/// play only on iOS and watchOS (the SDK's own note on `SensoryFeedback`);
/// a click already clicks physically. A shared view that emits on the Mac
/// (a voice row, a speed preset) only feeds the DEBUG log.
enum TransportHaptic: String, CaseIterable, Sendable {
    case play, pause, press, place, detent, preset, scrubRelease, finished

    var feedback: SensoryFeedback {
        switch self {
        case .play:   return .impact(flexibility: .soft, intensity: 0.6)
        case .pause:  return .impact(weight: .light)
        case .press:  return .impact(flexibility: .soft, intensity: Self.pressIntensity)
        case .place, .detent, .preset, .scrubRelease: return .selection
        case .finished: return .success
        }
    }

    /// A button press: softer than Play's 0.6, so a tap that starts the
    /// voice still reads as the bigger event.
    static let pressIntensity = 0.4
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
