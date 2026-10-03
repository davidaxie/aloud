import UIKit

/// The iOS host of the follow-along highlight (`HighlightLayers`): a clear,
/// non-interactive view beneath the text whose own layer holds the three
/// shapes. It resolves nothing itself: colors arrive resolved, and Reduce
/// Motion is read for each change, as the highlight always did.
final class ReaderHighlightLayer: UIView {

    /// The shapes, in this view's layer. `lazy` because the layer exists
    /// only after `super.init`; `init` creates them at once.
    private lazy var shapes = HighlightLayers(host: layer)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        _ = shapes
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Sentence

    /// Shows `segments` as the active sentence. `animated` crossfades from the
    /// previous shape; geometry-only refreshes (relayout) pass `false`.
    func showSentence(_ segments: [HighlightLayers.Segment], fill: UIColor, mark: UIColor,
                      gutterX: CGFloat, animated: Bool) {
        shapes.showSentence(segments, fill: fill.cgColor, mark: mark.cgColor, gutterX: gutterX,
                            animated: animated, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func clearSentence() {
        shapes.clearSentence()
    }

    // MARK: Word

    func showWord(_ segments: [HighlightLayers.Segment], color: UIColor, animated: Bool) {
        shapes.showWord(segments, color: color.cgColor, animated: animated,
                        reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func clearWord() {
        shapes.clearWord()
    }
}
