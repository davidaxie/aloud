import SwiftUI

/// The scrub on the Mac (M9, mac-ux §3.7): a 4 pt track in a 24 pt row
/// that spans the current chapter (the whole document for PDFs and
/// chapterless books), so a long book still scrubs at sentence precision.
///
/// A pointer shows its target before it clicks: hovering previews the
/// target sentence's first six words and its time into the span. A click
/// seeks to the nearest sentence start and offers "Undo jump" (⌘Z), a
/// deliberate divergence from R17, where a touch without travel does
/// nothing. A drag previews live and seeks on release, in the span it
/// started in. Focused, ← and → skip 15 s (the one `skip(seconds:)`),
/// PageUp and PageDown step by chapter start, and Home and End go to the
/// chapter's first and last sentence.
/// VoiceOver adjusts it by chapter start, or by a minute without chapters
/// (R12c), and never hears a sentence index (R12e).
struct MacScrub: View {

    let document: LibraryDocument
    let content: DocContent
    let navigation: ReaderNavigation

    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.chromeScale) private var chromeScale

    /// The press in progress, which the fill and the preview follow. Gesture
    /// state, so it lives exactly as long as the press, a cancelled one too.
    @GestureState private var press: ScrubDrag?
    /// The span the press froze, for the release: gesture state is already
    /// reset when onEnded runs. Written by press frames, never drawn.
    @State private var pressSpan = MacScrubPressSpan()
    /// Where the pointer rests over the row, while it does.
    @State private var hoverX: CGFloat?
    /// The preview's measured width, for its centering and edge clamp.
    @State private var previewWidth: CGFloat = 180

    static let rowHeight: CGFloat = 24
    static let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let model = self.model
            let span = press?.span ?? model.span
            let shown = press?.target ?? model.playhead
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(Self.trackHeight,
                                      width * navigation.scrubFraction(of: shown, in: span)))
            }
            .frame(height: Self.trackHeight)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topLeading) {
                if let target = previewTarget(model: model, width: width) {
                    preview(target, in: press?.span ?? model.span, model: model, width: width)
                        // Its bottom edge on the row's top: the label grows
                        // upward over the chapter line, never over the track.
                        .alignmentGuide(.top) { $0[.bottom] }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            .gesture(pressGesture(width: width))
        }
        .frame(height: Self.rowHeight)
        .focusable()
        .onKeyPress(keys: MacScrubModel.keys) { keyPress in
            MacScrubModel.Key(keyPress.key).map { perform($0) } ?? .ignored
        }
        .accessibilityRepresentation {
            // Constant: every assistive step arrives as the adjustable
            // action below, never as a write to the value.
            Slider(value: .constant(model.fraction), in: 0...1)
                .accessibilityLabel("Position")
                // The playhead's spoken position, never a sentence index.
                .accessibilityValue(navigation.positionLine(at: model.playhead,
                                                            rate: playback.rate,
                                                            documentTitle: document.title,
                                                            isFinished: playback.isAtEnd)
                                        .accessibilityLabel)
                .accessibilityAdjustableAction { direction in
                    MacScrubModel.adjust(playback, navigation: navigation,
                                         forward: direction == .increment)
                }
                .accessibilityIdentifier("player.scrub")
        }
    }

    private var model: MacScrubModel {
        MacScrubModel(navigation: navigation, sentences: content.sentences,
                      playhead: max(playback.currentSentence, 0), rate: playback.rate)
    }

    // MARK: - Pointer

    /// A press is a click (no travel) or a drag; either previews its target
    /// and seeks only on release, in the span it froze at its first frame.
    private func pressGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($press) { value, state, _ in
                let model = self.model
                let span = state?.span ?? model.span
                state = ScrubDrag(span: span, target: model.target(atX: value.location.x, width: width, in: span))
                pressSpan.span = span
            }
            .onEnded { value in
                let span = pressSpan.span ?? model.span
                pressSpan.span = nil
                MacScrubModel.seek(playback, to: model.target(atX: value.location.x, width: width, in: span))
            }
    }

    /// The press's target while pressed, else the hovered one.
    private func previewTarget(model: MacScrubModel, width: CGFloat) -> Int? {
        if let press { return press.target }
        guard let hoverX else { return nil }
        return model.target(atX: hoverX, width: width)
    }

    /// "“Well, Prince, so Genoa and Lucca… · 4:05": never a sentence number.
    private func preview(_ target: Int, in span: ClosedRange<Int>, model: MacScrubModel,
                         width: CGFloat) -> some View {
        HStack(spacing: Theme.Space.xxs) {
            Text(model.previewWords(of: target))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\u{00B7} " + model.previewTime(of: target, in: span))
                .monospacedDigit()
                .fixedSize()
        }
        .font(Theme.font(.caption, scale: chromeScale))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xxs)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.hairlineColor, lineWidth: Theme.Stroke.hairlineWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
            previewWidth = measured
        }
        .frame(maxWidth: max(width - 2 * Theme.Space.xxs, 0), alignment: .leading)
        .offset(x: previewOffsetX(fraction: navigation.scrubFraction(of: target, in: span), width: width))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    /// Centers the preview on its target's place, clamped inside the row.
    private func previewOffsetX(fraction: Double, width: CGFloat) -> CGFloat {
        let inset = Theme.Space.xxs
        let maxX = max(width - previewWidth - inset, inset)
        return min(max(CGFloat(fraction) * width - previewWidth / 2, inset), maxX)
    }

    // MARK: - Keys

    /// The focused scrub owns its six keys, as a slider does: one with
    /// nowhere to go (PageUp in the first chapter) is still taken here, so it
    /// never travels up a chain that may end in a beep (M11): PageUp,
    /// PageDown, Home and End aren't plain keys, so `MacKeyRouter` never
    /// hands them to its silent tail.
    private func perform(_ key: MacScrubModel.Key) -> KeyPress.Result {
        MacScrubModel.perform(key, on: playback, navigation: navigation)
        return .handled
    }
}

/// The span a press froze, handed from its frames to its release. A class,
/// so a gesture frame writes it with no state change or redraw.
final class MacScrubPressSpan {
    var span: ClosedRange<Int>?
}

/// The scrub's rules over the shared `ReaderNavigation` and
/// `PlaybackController`, pure enough to test without a window: where an x
/// lands, what the preview says, and what a click, a key or a VoiceOver
/// adjust does.
struct MacScrubModel {

    let navigation: ReaderNavigation
    let sentences: [Sentence]
    /// The sentence being read (0 before anything loads).
    let playhead: Int
    let rate: Double

    /// The chapter holding the playhead, or the whole document.
    var span: ClosedRange<Int> { navigation.scrubSpan(at: playhead) }

    /// The playhead's place along the track, 0...1, by words.
    var fraction: Double { navigation.scrubFraction(of: playhead, in: span) }

    /// The sentence whose start is nearest `x` along a track `width` wide,
    /// in `span` (the playhead's chapter unless a press froze another).
    func target(atX x: CGFloat, width: CGFloat, in span: ClosedRange<Int>? = nil) -> Int {
        navigation.sentence(atFraction: ScrubGesture.fraction(atX: x, width: width), in: span ?? self.span)
    }

    /// The target's first six words, as the reader typesets them.
    func previewWords(of target: Int) -> String {
        sentences.indices.contains(target) ? ScrubPreview.words(of: sentences[target].text) : ""
    }

    /// How far into `span` the target starts, at the current speed.
    func previewTime(of target: Int, in span: ClosedRange<Int>? = nil) -> String {
        ListeningEstimate.clock(seconds: navigation.secondsIntoSpan(of: target, in: span ?? self.span, rate: rate))
    }

    /// The whole preview, "words… · 0:42".
    func preview(of target: Int) -> String {
        "\(previewWords(of: target)) \u{00B7} \(previewTime(of: target))"
    }

    // MARK: Actions

    /// A click or a drag's release: a `.scrub` jump, which keeps play or
    /// pause and offers Undo jump whenever it moves (R15).
    @MainActor
    static func seek(_ playback: PlaybackController, to target: Int) {
        playback.jump(to: target, origin: .scrub)
    }

    /// A click at `x` along a track `width` wide, in the playhead's chapter.
    @MainActor
    static func click(_ playback: PlaybackController, navigation: ReaderNavigation,
                      atX x: CGFloat, width: CGFloat) {
        guard let content = playback.content else { return }
        let model = MacScrubModel(navigation: navigation, sentences: content.sentences,
                                  playhead: max(playback.currentSentence, 0), rate: playback.rate)
        seek(playback, to: model.target(atX: x, width: width))
    }

    /// One VoiceOver adjust (R12c): the next or previous chapter start (a
    /// PDF's page row), or a minute either way without chapters.
    @MainActor
    @discardableResult
    static func adjust(_ playback: PlaybackController, navigation: ReaderNavigation, forward: Bool) -> Bool {
        guard let target = navigation.adjustmentTarget(from: max(playback.currentSentence, 0),
                                                       forward: forward, rate: playback.rate) else { return false }
        seek(playback, to: target)
        return true
    }

    // MARK: Keys

    /// The keys a focused scrub answers.
    enum Key: CaseIterable {
        case left, right, pageUp, pageDown, home, end

        init?(_ key: KeyEquivalent) {
            switch key {
            case .leftArrow: self = .left
            case .rightArrow: self = .right
            case .pageUp: self = .pageUp
            case .pageDown: self = .pageDown
            case .home: self = .home
            case .end: self = .end
            default: return nil
            }
        }

        var equivalent: KeyEquivalent {
            switch self {
            case .left: return .leftArrow
            case .right: return .rightArrow
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .home: return .home
            case .end: return .end
            }
        }
    }

    static let keys: Set<KeyEquivalent> = Set(Key.allCases.map(\.equivalent))

    /// ← and → are the one skip (R14, the same function as the keys and
    /// buttons everywhere); PageUp and PageDown step chapter starts; Home
    /// and End go to the chapter's first and last sentence. False when there
    /// was nowhere to go; the focused view takes the key either way.
    @MainActor
    @discardableResult
    static func perform(_ key: Key, on playback: PlaybackController, navigation: ReaderNavigation) -> Bool {
        guard playback.content != nil else { return false }
        let span = navigation.scrubSpan(at: max(playback.currentSentence, 0))
        switch key {
        case .left: return playback.skip(seconds: -PlaybackController.skipInterval) != nil
        case .right: return playback.skip(seconds: PlaybackController.skipInterval) != nil
        case .pageUp: return adjust(playback, navigation: navigation, forward: false)
        case .pageDown: return adjust(playback, navigation: navigation, forward: true)
        case .home:
            seek(playback, to: span.lowerBound)
            return true
        case .end:
            seek(playback, to: span.upperBound)
            return true
        }
    }
}
