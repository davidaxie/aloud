import CoreGraphics
import Foundation

/// The scroll view as calm follow's decisions see it at one moment. Every
/// value is in the text view's CONTENT coordinates. The host checks for a
/// finger or a coasting flick itself, before it asks.
struct ReaderScrollState: Equatable {
    /// The scroll offset now.
    var contentOffsetY: CGFloat
    /// The visible content rect the band is measured in (see `FollowBand`).
    var viewport: CGRect
    /// Every offset the text can rest at: from its top under the top inset
    /// to its end above the bottom inset.
    var restingRange: ClosedRange<CGFloat>
    var reduceMotion: Bool
}

/// One follow scroll, as the host performs it.
enum FollowAction: Equatable {
    /// Already there (pinned at an end of the text, or within a point).
    case none
    /// One `FollowBand.glideDuration` glide on `FollowBand.glideCurve`,
    /// which a touch stops where it is.
    case glide(toY: CGFloat)
    /// A placement without motion. With `reaim`, the landing is measured
    /// again once the offset has moved and corrected as part of the same
    /// scroll (a deep jump lands on real geometry, not estimates).
    case jump(toY: CGFloat, reaim: Bool)
}

/// Calm follow (R16) as state and pure decisions, shared by the iPhone and
/// Mac columns. The host measures through `ReaderColumnLayout` and moves
/// its own scroll view; the rules of when to scroll, how, and when a
/// placement without motion has settled live here.
///
/// While following, the text scrolls only when the spoken sentence leaves
/// the `FollowBand`, then glides once so it lands on the landing line. A
/// user scroll stops following, and nothing re-engages it on a timer: only
/// Play, a jump or Undo, the Follow chip, or a scroll that ends with the
/// voice in view.
struct ReaderFollowEngine {

    /// Off from the moment the user scrolls; never back on by itself.
    var isFollowing = true
    /// The host's last `followRequest`; any change resumes following.
    var lastFollowRequest = 0
    /// Cached bounding rect of the follow target, so the per-frame chip
    /// update never forces TextKit layout. The host clears it on sentence
    /// change, rebuild, and content-size change.
    var cachedActiveRect: CGRect? {
        didSet { cachedWordRect = nil }
    }
    /// Cached rect of the spoken word, measured only inside a sentence
    /// taller than the band (`FollowBand.followed`). Re-measured whenever
    /// the sentence rect is, and dropped by the host when the word moves.
    var cachedWordRect: CGRect?
    /// After a placement without motion, keep re-placing on every layout
    /// pass until the geometry resolves: insets and bounds settle a few
    /// passes after the text is set, and a deep target's estimated line
    /// heights shift once it is really laid out. Cleared when the user
    /// scrolls.
    var pendingPlacement = false
    /// A rotor stop placed without motion, checked on each layout pass
    /// like `pendingPlacement` until it holds in the band. Cleared by a
    /// user scroll, following, or a rebuild.
    var pendingReveal: Int?
    /// Layout passes the current placement check may still take, and the
    /// text's laid-out height at its last pass (see `placementPass`).
    private(set) var placementPassesLeft = 0
    private(set) var placementHeight: CGFloat?
    static let placementPassLimit = 12
    /// Every follow scroll, for the R16 budget.
    private(set) var programmaticScrollCount = 0
    /// The last direction published to the Follow chip. Kept here, not read
    /// back from the host's binding, whose writes land a turn later.
    private(set) var voiceOffscreen: ReaderFollowDirection?

    // MARK: Following

    /// A drag, a scroll-to-top or a VoiceOver scroll: stop following, and
    /// don't fight the user with a pending placement or reveal.
    mutating func takeOver() {
        isFollowing = false
        pendingPlacement = false
        pendingReveal = nil
    }

    /// Play, a jump, Undo or the Follow chip: follow again; the voice owns
    /// the scroll, so a rotor stop's check ends.
    mutating func resume() {
        isFollowing = true
        pendingReveal = nil
    }

    /// A user scroll came to rest: following resumes only when the voice
    /// (`voice`, the follow target's rect) is in view.
    mutating func scrollEnded(voice: CGRect, in viewport: CGRect) {
        if FollowBand.direction(of: voice, in: viewport) == nil {
            isFollowing = true
        }
    }

    /// One follow, placement or reveal scroll.
    mutating func noteScroll() {
        programmaticScrollCount += 1
    }

    /// Which way the Follow chip points: nil while following, or while any
    /// part of the voice is visible.
    func chipDirection(voice: CGRect, in viewport: CGRect) -> ReaderFollowDirection? {
        isFollowing ? nil : FollowBand.direction(of: voice, in: viewport)
    }

    /// Records `direction` for the chip; false when it is already shown.
    mutating func publish(_ direction: ReaderFollowDirection?) -> Bool {
        guard direction != voiceOffscreen else { return false }
        voiceOffscreen = direction
        return true
    }

    /// The offset that puts `rect` on the landing line under `state`,
    /// clamped to where the text can rest.
    static func landingOffset(for rect: CGRect, in state: ReaderScrollState) -> CGFloat {
        FollowBand.landingContentOffsetY(sentenceMinY: rect.minY, viewport: state.viewport,
                                         contentOffsetY: state.contentOffsetY,
                                         range: state.restingRange)
    }

    /// How a follow scroll reaches `target`: nothing within a point (pinned
    /// at an end of the text), a glide within one viewport when `animated`,
    /// else a jump (a longer move, or any move under Reduce Motion).
    static func move(to target: CGFloat, in state: ReaderScrollState,
                     animated: Bool, reaim: Bool) -> FollowAction {
        let distance = target - state.contentOffsetY
        guard abs(distance) > 1 else { return .none }
        if animated, FollowBand.glides(distance: distance, viewportHeight: state.viewport.height,
                                       reduceMotion: state.reduceMotion) {
            return .glide(toY: target)
        }
        return .jump(toY: target, reaim: reaim)
    }

    // MARK: Placement check

    /// Arms the layout-pass check of a placement without motion.
    mutating func startPlacementCheck() {
        pendingPlacement = true
        placementPassesLeft = Self.placementPassLimit
        placementHeight = nil
    }

    /// Arms the same check for a rotor stop placed without motion.
    mutating func startRevealCheck(_ id: Int) {
        pendingReveal = id
        placementPassesLeft = Self.placementPassLimit
        placementHeight = nil
    }

    mutating func endPlacementCheck() {
        pendingPlacement = false
        pendingReveal = nil
    }

    var isCheckingPlacement: Bool { pendingPlacement || pendingReveal != nil }

    /// What one layout pass measured of a placement or rotor stop.
    enum PlacementCheck: Equatable {
        case holds, unresolved, moveTo(CGFloat)
    }

    /// What the host does after a measured pass.
    enum PlacementStep: Equatable {
        /// Set the offset (a correction of a placement already counted, so
        /// not a new scroll) and ask for the pass that confirms it.
        case correct(toY: CGFloat)
        /// In place, but the laid-out height moved since the last pass:
        /// ask for another pass.
        case confirm
        /// In place on a steady height: the check is over.
        case end
    }

    /// One measured layout pass (never `.unresolved`, which measures
    /// nothing). A pass that finds the placement off re-places it. A pass
    /// that finds it in place ends the check only once the text's laid-out
    /// height has held since the pass before, since a host can still be
    /// laying out lines newly on screen. After `.correct` or `.confirm`,
    /// the host ends the check once `placementPassesSpent`.
    mutating func placementPass(_ check: PlacementCheck, laidOutHeight height: CGFloat) -> PlacementStep {
        let steady = placementHeight.map { abs($0 - height) < 0.5 } ?? false
        placementHeight = height
        placementPassesLeft -= 1
        switch check {
        case .moveTo(let settled):
            return .correct(toY: settled)
        case .holds where steady:
            return .end
        case .holds, .unresolved:
            return .confirm
        }
    }

    /// The check has taken `placementPassLimit` passes: it ends in any case.
    var placementPassesSpent: Bool { placementPassesLeft <= 0 }
}
