import SwiftUI

/// The one warm track (R3-09): the reader's scrub on both apps and the
/// Voice & speed control draw it, so a value track reads the same
/// everywhere. The pale `scrubTrack` capsule, edged by `trackEdge` (clear
/// unless Increase Contrast is on), under an accent fill, with the 12pt
/// accent thumb at the fill's end (`ScrubThumb`). Held, the track thickens
/// and the thumb grows to 20pt; under Reduce Motion nothing grows and a
/// soft accentSoft ring fades in instead.
///
/// It fills the width it is offered and stands in a box as tall as the
/// held line, centred in it, so a press thickens the line evenly and the
/// thumb never moves under the finger. The thumb and the ring overhang that
/// box; callers seat it in a touch row tall enough for both. Drawing only:
/// each caller keeps its own gesture and its own accessibility element.
struct WarmTrack: View {

    /// How far the fill reaches along the track, 0...1.
    let fraction: Double
    /// A finger (or a press) is on the track.
    let isHeld: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = Self.fillWidth(fraction: fraction, width: width)
            let grows = isHeld && !reduceMotion
            let thumb = grows ? ScrubThumb.pressedDiameter : ScrubThumb.diameter
            ZStack(alignment: .leading) {
                // The edge strokes the unfilled track alone (clear unless
                // Increase Contrast is on); the fill draws over it.
                Capsule()
                    .fill(Theme.scrubTrack)
                    .overlay(Capsule().strokeBorder(Theme.trackEdge, lineWidth: 1))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: fill)
            }
            .frame(height: grows ? ScrubThumb.pressedTrackHeight : ScrubThumb.trackHeight)
            .overlay(alignment: .leading) {
                thumbView(diameter: thumb)
                    .offset(x: ScrubThumb.offset(fill: fill, diameter: thumb, width: width))
            }
            // Centred in the box, whichever height the line has.
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: ScrubThumb.pressedTrackHeight)
        .animation(.easeOut(duration: Theme.Motion.press), value: isHeld)
        .accessibilityHidden(true)
    }

    /// The fill's width: `fraction` of the track, never shorter than the
    /// resting line is tall, so an empty track still shows its round start.
    static func fillWidth(fraction: Double, width: CGFloat) -> CGFloat {
        guard width > 0, fraction.isFinite else { return ScrubThumb.trackHeight }
        return max(ScrubThumb.trackHeight, width * CGFloat(min(max(fraction, 0), 1)))
    }

    /// Where the thumb's centre sits on a track `width` wide: the fill's
    /// end, kept inside the track at either end.
    static func thumbCentre(fraction: Double, width: CGFloat, diameter: CGFloat = ScrubThumb.diameter) -> CGFloat {
        ScrubThumb.offset(fill: fillWidth(fraction: fraction, width: width), diameter: diameter, width: width)
            + diameter / 2
    }

    /// The accent thumb at the end of the fill. Decoration: each track is
    /// one adjustable element to assistive tech.
    private func thumbView(diameter: CGFloat) -> some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: ScrubThumb.ringDiameter, height: ScrubThumb.ringDiameter)
                    .opacity(isHeld && reduceMotion ? 1 : 0)
            }
    }
}
