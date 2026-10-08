import CoreGraphics
// DynamicTypeSize only: this type builds no views.
import SwiftUI

/// The iPhone player bar's transport geometry as plain numbers, so the
/// layout rules are testable without a screen (the Mac's twin is
/// MacPlayerBarLayout).
///
/// Play sits on the bar's center line whatever the chips say: each chip
/// takes an equal flexible side of the row, so the cluster between them
/// never shifts with the voice name, the speed or the timer. From .xxLarge
/// the chips share a row of their own above the centred cluster. Play and
/// the skips grow with Dynamic Type inside their caps; the chips stop at
/// `chipTypeCap` and say the rest through the Large Content Viewer.
struct PlayerBarLayout: Equatable {

    /// The five transport controls, in VoiceOver's reading order.
    enum Control: CaseIterable {
        case listening, back15, play, forward15, sleep
    }

    /// Play's diameter: never under the 54 pt minimum target, never past
    /// 66 pt, so a large-type bar keeps room for the page.
    static let playDiameterRange: ClosedRange<CGFloat> = Theme.PlayCircle.diameter...66
    /// The skip targets: a full 44 pt hit area, grown to at most 52 pt.
    static let skipTargetRange: ClosedRange<CGFloat> = 44...52
    /// The transport takes two rows from this size up.
    static let stackingSize: DynamicTypeSize = .xxLarge
    /// The chips' type stops growing here (the Large Content Viewer shows
    /// them larger); the chapter line's does too, inside the bar's height
    /// budget.
    static let chipTypeCap: DynamicTypeSize = .accessibility2
    /// A bar narrower than this (a 340 pt screen less its gutters) always
    /// takes the tight gap beside Play.
    static let narrowBarWidth: CGFloat = 300
    /// The breathing room between the skips and Play, and its tight form.
    static let roomyClusterGap: CGFloat = Theme.Space.xs
    static let tightClusterGap: CGFloat = Theme.Space.xxs
    /// Between the two chips when they share a row.
    static let chipRowSpacing: CGFloat = Theme.Space.xs

    /// The transport row's width, inside the screen gutters; 0 before it
    /// has been measured.
    let barWidth: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let playDiameter: CGFloat
    let skipTarget: CGFloat
    let clusterGap: CGFloat

    init(barWidth: CGFloat, dynamicTypeSize: DynamicTypeSize, playDiameter: CGFloat,
         skipTarget: CGFloat, clusterGap: CGFloat) {
        self.barWidth = barWidth
        self.dynamicTypeSize = dynamicTypeSize
        self.playDiameter = playDiameter
        self.skipTarget = skipTarget
        self.clusterGap = clusterGap
    }

    /// The bar with the gap `clusterGap(...)` picks for `widestFullChip`,
    /// the wider chip's width with its full label.
    init(barWidth: CGFloat, dynamicTypeSize: DynamicTypeSize, playDiameter: CGFloat,
         skipTarget: CGFloat, widestFullChip: CGFloat) {
        self.init(barWidth: barWidth, dynamicTypeSize: dynamicTypeSize, playDiameter: playDiameter,
                  skipTarget: skipTarget,
                  clusterGap: Self.clusterGap(barWidth: barWidth, dynamicTypeSize: dynamicTypeSize,
                                              playDiameter: playDiameter, skipTarget: skipTarget,
                                              widestFullChip: widestFullChip))
    }

    /// Five controls in one row fit through .xLarge; past that the chips'
    /// text would squeeze the transport, so they share a row above it.
    var stacksTransport: Bool { dynamicTypeSize >= Self.stackingSize }

    /// Back 15, Play and Forward 15 with the gaps between them.
    var clusterWidth: CGFloat { 2 * skipTarget + 2 * clusterGap + playDiameter }

    /// Each chip's side of a one-row bar: an equal share of what the cluster
    /// leaves, so the cluster sits on the center line.
    var chipSideWidth: CGFloat {
        Self.side(barWidth: barWidth, clusterWidth: clusterWidth)
    }

    /// The most a chip may take: its side of the one-row bar, or half the
    /// chip row once stacked. Unbounded until the bar has been measured.
    var chipWidthLimit: CGFloat {
        guard barWidth > 0 else { return .infinity }
        guard stacksTransport else { return chipSideWidth }
        return max(((barWidth - Self.chipRowSpacing) / 2).rounded(.down), 0)
    }

    // MARK: - Rules

    /// Play's diameter from its Dynamic Type scaled value.
    static func playDiameter(scaled: CGFloat) -> CGFloat {
        min(max(scaled, playDiameterRange.lowerBound), playDiameterRange.upperBound)
    }

    /// A skip target's side from its Dynamic Type scaled value.
    static func skipTarget(scaled: CGFloat) -> CGFloat {
        min(max(scaled, skipTargetRange.lowerBound), skipTargetRange.upperBound)
    }

    /// The roomy gap beside Play, tightened only on a narrow bar or where
    /// the tight gap is what lets the chips keep their full labels (where
    /// even that is too little, the chips shorten and the room stays).
    static func clusterGap(barWidth: CGFloat, dynamicTypeSize: DynamicTypeSize, playDiameter: CGFloat,
                           skipTarget: CGFloat, widestFullChip: CGFloat) -> CGFloat {
        guard barWidth > 0 else { return roomyClusterGap }
        if barWidth < narrowBarWidth { return tightClusterGap }
        // Stacked, the chips aren't beside the cluster.
        guard dynamicTypeSize < stackingSize else { return roomyClusterGap }
        func side(gap: CGFloat) -> CGFloat {
            Self.side(barWidth: barWidth, clusterWidth: 2 * skipTarget + 2 * gap + playDiameter)
        }
        let rescued = widestFullChip > side(gap: roomyClusterGap) && widestFullChip <= side(gap: tightClusterGap)
        return rescued ? tightClusterGap : roomyClusterGap
    }

    /// VoiceOver reads voice · speed, back, play, forward, sleep in every
    /// layout: higher sorts first, as in MacPlayerBarLayout.
    static func voiceOverOrder(of control: Control) -> Double {
        switch control {
        case .listening: return 5
        case .back15: return 4
        case .play: return 3
        case .forward15: return 2
        case .sleep: return 1
        }
    }

    private static func side(barWidth: CGFloat, clusterWidth: CGFloat) -> CGFloat {
        max(((barWidth - clusterWidth) / 2).rounded(.down), 0)
    }
}
