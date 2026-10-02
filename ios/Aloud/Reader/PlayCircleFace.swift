import SwiftUI

/// What the Play circle shows and says for a playback state (R1, R20). The
/// player bar and the Continue card both read it, so the glyph, the spoken
/// name and the busy ring always agree.
struct PlayButtonState: Equatable {

    enum Glyph: String {
        case play = "play.fill", pause = "pause.fill", retry = "arrow.clockwise"
        /// R24: at the end of a book, Play starts it over.
        case listenAgain = "arrow.counterclockwise"
    }

    /// The ring around the circle: an orbiting arc, or a still ring that
    /// pulses under Reduce Motion.
    enum Busy: Equatable { case none, arc, pulse }

    let glyph: Glyph
    let label: String
    let value: String
    let busy: Busy

    var glyphOpacity: Double { busy == .none ? 1 : Theme.PlayCircle.busyGlyphOpacity }

    init(status: PlayerStatus, isPreparingVoice: Bool, reduceMotion: Bool) {
        switch status {
        case .playing, .buffering:
            glyph = .pause
            label = "Pause"
            value = status == .playing ? "playing" : "buffering"
        case .error:
            // A stop the user didn't ask for must never look like a pause.
            glyph = .retry
            label = "Try again"
            value = "stopped, playback error"
        case .ended:
            // R24: the book is over, and Play starts it from the top. The
            // value stays "paused": nothing is playing.
            glyph = .listenAgain
            label = "Listen again"
            value = "paused"
        case .idle, .paused:
            glyph = .play
            label = "Play"
            value = "paused"
        }
        busy = status == .buffering || isPreparingVoice ? (reduceMotion ? .pulse : .arc) : .none
    }
}

/// The Play circle's face: the glyph in paper on the accent circle (drawn by
/// `AccentCircleButtonStyle`) and, while busy, a 2pt accent ring just outside
/// it. The ring is driven by a TimelineView, so it runs only while it is on
/// screen and stops the moment the state settles. No system spinner: one
/// inside the circle hid the glyph and spun under Reduce Motion.
struct PlayCircleFace: View {

    let state: PlayButtonState
    var diameter: CGFloat = Theme.PlayCircle.diameter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: state.glyph.rawValue)
                .font(diameter >= Theme.PlayCircle.diameter ? .title2.weight(.bold) : .title3.weight(.semibold))
                .foregroundStyle(Theme.bg)
                .opacity(state.glyphOpacity)
                // Optical centering: the triangle's mass sits left of its box.
                .offset(x: state.glyph == .play ? 1.5 : 0)
                .id(state.glyph)
                .transition(MotionStyle.glyph(reduceMotion: reduceMotion).transition)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if state.busy != .none {
                BusyRing(busy: state.busy)
                    .frame(width: ringDiameter, height: ringDiameter)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.glyph), value: state)
    }

    private var ringDiameter: CGFloat {
        diameter + 2 * (Theme.PlayCircle.arcGap + Theme.PlayCircle.arcWidth)
    }
}

/// The busy ring, redrawn every frame from the clock rather than by an
/// implicit animation, so it can't outlive its state or drift.
private struct BusyRing: View {

    let busy: PlayButtonState.Busy

    var body: some View {
        TimelineView(.animation) { context in
            ring(at: context.date.timeIntervalSinceReferenceDate)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func ring(at seconds: TimeInterval) -> some View {
        let circle = Circle().inset(by: Theme.PlayCircle.arcWidth / 2)
        if busy == .pulse {
            // Under Reduce Motion: a full ring that breathes, never turns.
            circle
                .stroke(Theme.accent, lineWidth: Theme.PlayCircle.arcWidth)
                .opacity(PlayCircleFace.pulseOpacity(at: seconds))
        } else {
            circle
                .trim(from: 0, to: Theme.PlayCircle.arcSweep)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: Theme.PlayCircle.arcWidth, lineCap: .round))
                .rotationEffect(.degrees(PlayCircleFace.arcDegrees(at: seconds)))
        }
    }
}

extension PlayCircleFace {
    /// The arc's angle: one turn per `Motion.arcTurn`, starting at 12 o'clock.
    nonisolated static func arcDegrees(at seconds: TimeInterval) -> Double {
        let turn = Theme.Motion.arcTurn
        return seconds.truncatingRemainder(dividingBy: turn) / turn * 360 - 90
    }

    /// The pulse's opacity: from 1 down to `pulseFloor` and back once per
    /// `Motion.pulse`.
    nonisolated static func pulseOpacity(at seconds: TimeInterval) -> Double {
        let phase = seconds.truncatingRemainder(dividingBy: Theme.Motion.pulse) / Theme.Motion.pulse
        let wave = (1 + cos(2 * .pi * phase)) / 2   // 1 → 0 → 1
        return Theme.PlayCircle.pulseFloor + (1 - Theme.PlayCircle.pulseFloor) * wave
    }
}
