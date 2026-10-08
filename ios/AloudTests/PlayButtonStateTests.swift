import XCTest
@testable import Aloud

/// What the Play circle shows and says for every playback state (R1, R20),
/// and the one motion vocabulary that collapses to opacity under Reduce
/// Motion.
final class PlayButtonStateTests: XCTestCase {

    private static let statuses: [PlayerStatus] = [.idle, .buffering, .playing, .paused, .ended, .error]

    /// Exhaustive, so a new PlayerStatus case can't skip this table.
    private static func expected(_ status: PlayerStatus)
        -> (glyph: PlayButtonState.Glyph, label: String, value: String) {
        switch status {
        case .playing:   return (.pause, "Pause", "playing")
        case .buffering: return (.pause, "Pause", "buffering")
        case .error:     return (.retry, "Try again", "stopped, playback error")
        case .ended:     return (.listenAgain, "Listen again", "paused")
        case .idle, .paused: return (.play, "Play", "paused")
        }
    }

    func testFullMatrix() {
        for status in Self.statuses {
            for preparing in [false, true] {
                for reduceMotion in [false, true] {
                    let state = PlayButtonState(status: status, isPreparingVoice: preparing,
                                                reduceMotion: reduceMotion)
                    let want = Self.expected(status)
                    let context = "\(status), preparing \(preparing), reduceMotion \(reduceMotion)"
                    XCTAssertEqual(state.glyph, want.glyph, context)
                    XCTAssertEqual(state.label, want.label, context)
                    XCTAssertEqual(state.value, want.value, context)

                    let busy = status == .buffering || preparing
                    XCTAssertEqual(state.busy, busy ? (reduceMotion ? .pulse : .arc) : .none, context)
                    XCTAssertEqual(state.glyphOpacity, busy ? 0.4 : 1, accuracy: 1e-9, context)
                    if reduceMotion {
                        XCTAssertNotEqual(state.busy, .arc, "no rotation under Reduce Motion: \(context)")
                    }
                }
            }
        }
    }

    func testBufferingShowsPauseWithTheArc() {
        let state = PlayButtonState(status: .buffering, isPreparingVoice: false, reduceMotion: false)
        XCTAssertEqual(state.glyph, .pause)
        XCTAssertEqual(state.glyph.rawValue, "pause.fill")
        XCTAssertEqual(state.label, "Pause")
        XCTAssertEqual(state.value, "buffering")
        XCTAssertEqual(state.busy, .arc)
        XCTAssertEqual(state.glyphOpacity, 0.4, accuracy: 1e-9)
    }

    func testPreparingVoiceWhilePausedIsBusyButStillPlay() {
        let state = PlayButtonState(status: .paused, isPreparingVoice: true, reduceMotion: true)
        XCTAssertEqual(state.glyph, .play)
        XCTAssertEqual(state.label, "Play")
        XCTAssertEqual(state.value, "paused")
        XCTAssertEqual(state.busy, .pulse)
        XCTAssertEqual(state.glyphOpacity, 0.4, accuracy: 1e-9)
    }

    /// R24: at the end, Play starts the book over, and says so. Nothing is
    /// playing, so the value stays "paused".
    func testEndedIsListenAgain() {
        let state = PlayButtonState(status: .ended, isPreparingVoice: false, reduceMotion: false)
        XCTAssertEqual(state.glyph, .listenAgain)
        XCTAssertEqual(state.glyph.rawValue, "arrow.counterclockwise")
        XCTAssertEqual(state.label, "Listen again")
        XCTAssertEqual(state.value, "paused")
        XCTAssertEqual(state.busy, .none)
        XCTAssertEqual(state.glyphOpacity, 1, accuracy: 1e-9)
    }

    func testErrorIsRetry() {
        let state = PlayButtonState(status: .error, isPreparingVoice: false, reduceMotion: false)
        XCTAssertEqual(state.glyph.rawValue, "arrow.clockwise")
        XCTAssertEqual(state.label, "Try again")
        XCTAssertEqual(state.value, "stopped, playback error")
        XCTAssertEqual(state.busy, .none)
    }

    // MARK: - The busy ring's clock

    func testArcTurnsOncePerArcTurn() {
        let turn = Theme.Motion.arcTurn
        XCTAssertEqual(PlayCircleFace.arcDegrees(at: 0), -90, accuracy: 1e-9, "starts at 12 o'clock")
        XCTAssertEqual(PlayCircleFace.arcDegrees(at: turn / 4), 0, accuracy: 1e-6)
        XCTAssertEqual(PlayCircleFace.arcDegrees(at: 10 * turn + turn / 2),
                       PlayCircleFace.arcDegrees(at: turn / 2), accuracy: 1e-6)
    }

    func testPulseStaysBetweenItsFloorAndFull() {
        let period = Theme.Motion.pulse
        XCTAssertEqual(PlayCircleFace.pulseOpacity(at: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(PlayCircleFace.pulseOpacity(at: period / 2), Theme.PlayCircle.pulseFloor, accuracy: 1e-9)
        for step in 0...120 {
            let opacity = PlayCircleFace.pulseOpacity(at: Double(step) * period / 37)
            XCTAssertGreaterThanOrEqual(opacity, Theme.PlayCircle.pulseFloor - 1e-9)
            XCTAssertLessThanOrEqual(opacity, 1 + 1e-9)
        }
    }

    // MARK: - Motion styles

    func testMotionStylesCollapseToOpacityUnderReduceMotion() {
        XCTAssertEqual(MotionStyle.message(reduceMotion: true), .opacity)
        XCTAssertEqual(MotionStyle.glyph(reduceMotion: true), .opacity)
        XCTAssertEqual(MotionStyle.message(reduceMotion: false), .rise)
        XCTAssertEqual(MotionStyle.glyph(reduceMotion: false), .pop)
    }

    /// R1-47: the Play circles (the bar's, the Continue card's and the
    /// Mac's, which draws through the same style) settle on a press only
    /// with motion on; under Reduce Motion they darken alone.
    @MainActor
    func testThePlayCirclePressScalesOnlyWithMotion() {
        XCTAssertEqual(AccentCircleButtonStyle.pressedScale, 0.94)
        XCTAssertEqual(AccentCircleButtonStyle.scale(isPressed: true, reduceMotion: false), 0.94)
        XCTAssertEqual(AccentCircleButtonStyle.scale(isPressed: true, reduceMotion: true), 1,
                       "Reduce Motion: the colour alone")
        XCTAssertEqual(AccentCircleButtonStyle.scale(isPressed: false, reduceMotion: false), 1)
        XCTAssertEqual(AccentCircleButtonStyle.scale(isPressed: false, reduceMotion: true), 1)
    }

    func testPlayCircleTokens() {
        XCTAssertEqual(Theme.PlayCircle.diameter, 54)
        XCTAssertGreaterThanOrEqual(Theme.PlayCircle.compactDiameter, 44, "still a full hit target")
        XCTAssertEqual(AccentCircleButtonStyle().diameter, Theme.PlayCircle.diameter)
        XCTAssertEqual(Theme.Motion.glyph, 0.18)
        XCTAssertEqual(Theme.Motion.glyphFromScale, 0.6)
        XCTAssertEqual(Theme.Motion.pulse, 1.2)
    }
}
