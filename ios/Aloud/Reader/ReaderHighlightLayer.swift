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
    /// previous shape; geometry-only refreshes (relayout) pass `false`. A
    /// chapter heading is a pill (`HighlightLayers.SentenceStyle`).
    func showSentence(_ segments: [HighlightLayers.Segment], fill: UIColor, mark: UIColor,
                      gutterX: CGFloat, style: HighlightLayers.SentenceStyle = .body, em: CGFloat = 0,
                      trailingEdge: CGFloat? = nil, animated: Bool) {
        shapes.showSentence(segments, fill: fill.cgColor, mark: mark.cgColor, gutterX: gutterX,
                            style: style, em: em, trailingEdge: trailingEdge,
                            animated: animated, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    /// Fades the sentence and its mark out under the colophon, or brings
    /// them back at once (`HighlightLayers.setSentenceHidden`).
    func setSentenceHidden(_ hidden: Bool, fadeDuration: CFTimeInterval? = nil) {
        shapes.setSentenceHidden(hidden, fadeDuration: fadeDuration)
    }

    var sentenceOpacity: Float { shapes.sentenceOpacity }
    var markOpacity: Float { shapes.markOpacity }

    func clearSentence() {
        shapes.clearSentence()
    }

    // MARK: Word

    func showWord(_ segments: [HighlightLayers.Segment], color: UIColor, fill: UIColor, animated: Bool) {
        shapes.showWord(segments, color: color.cgColor, fill: fill.cgColor, animated: animated,
                        reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func clearWord() {
        shapes.clearWord()
    }
}
