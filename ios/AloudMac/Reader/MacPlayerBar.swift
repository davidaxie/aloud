import AppKit
import SwiftUI

/// The reader's bottom bar on the Mac (M9, mac-ux §3.7): the chapter line
/// (the shared `ReaderMessageLine`, the one message slot), the scrub over
/// the current chapter, and the transport row `[voice · speed]  ↺15  (Play)
/// 15↻  [sleep]`. It spans the window on Theme.surface under a hairline;
/// its content is one centered column, at most 640 wide, so the pointer
/// travels a short way and the controls line up with the reading column.
/// Below a 560 pt column, or in the larger chrome bands, the two chips move
/// to a row of their own under the transport.
///
/// The bar follows the reader's text size in three `ChromeScale` bands
/// (M18), set by `MacReaderScreen`: its type, the Play circle, the chips and
/// the skips' hit regions grow together, and at every band the bar stands
/// within half the 520 × 480 window (`MacPlayerBarLayout.height`).
///
/// Every control goes through the shared functions: `togglePlayPause`,
/// `skip(seconds:)` (R14) and `SleepTimer`; the menus and keys reach the
/// same ones through `MacCommandActions`, and each icon's tooltip names its
/// key from the one `MacShortcuts` table. All state flows through
/// `PlaybackController`.
struct MacPlayerBar: View {

    let document: LibraryDocument
    let content: DocContent
    let navigation: ReaderNavigation
    /// The chapter line's own action: Contents, from phase 2.
    let onToggleContents: () -> Void

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var naturalVoiceOffer: NaturalVoiceOffer
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(MacUIState.self) private var ui
    @Environment(\.chromeScale) private var chromeScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bar's own width, measured; seeded at the default window's.
    @State private var barWidth: CGFloat = 1000
    /// The scrub's press target while it is pressed (`MacScrubPressKey`).
    @State private var pressTarget: Int?

    var body: some View {
        let layout = MacPlayerBarLayout(barWidth: barWidth, scale: chromeScale)
        VStack(spacing: 0) {
            // The shared line pads itself by the gutter; the rows under it
            // take the same inset, so all three share one left edge.
            ReaderMessageLine(message: message,
                              position: position,
                              onOpenContents: onToggleContents,
                              onRetry: retry,
                              onBackFiveMinutes: backFiveMinutes)
            MacScrub(document: document, content: content, navigation: navigation)
                .padding(.horizontal, Theme.Space.screenGutter)
                .onPreferenceChange(MacScrubPressKey.self) { target in
                    if target != pressTarget { pressTarget = target }
                }
            transport(layout)
                .padding(.horizontal, Theme.Space.screenGutter)
        }
        .frame(width: layout.columnWidth + 2 * Theme.Space.screenGutter)
        .padding(.top, MacPlayerBarLayout.topInset)
        .padding(.bottom, MacPlayerBarLayout.bottomInset)
        .frame(maxWidth: .infinity)
        // Paper, never a material: the bar stays in the Bronze family.
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .hairlineHeight()
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            barWidth = width
        }
    }

    // MARK: - Chapter line

    private var message: ReaderMessage? {
        ReaderMessage.resolve(stop: playback.stopReason(for: document.id),
                              notice: playback.notice,
                              offerVisible: naturalVoiceOffer.isVisible,
                              modelState: modelManager.state,
                              waitingLine: modelManager.waitingLine,
                              isPreparingVoice: playback.isPreparingVoice)
    }

    private var position: ReaderPositionLine {
        Self.positionLine(navigation, playhead: playhead, pressTarget: pressTarget,
                          rate: playback.rate, documentTitle: document.title, isAtEnd: playback.isAtEnd)
    }

    /// The chapter line at the playhead, or at a scrub press's target while
    /// pressed: the line previews the target chapter and its time left
    /// before the release, as the iPhone's follows a drag
    /// (`PlayerBarView.position`). A hover leaves it alone.
    static func positionLine(_ navigation: ReaderNavigation, playhead: Int, pressTarget: Int?,
                             rate: Double, documentTitle: String, isAtEnd: Bool) -> ReaderPositionLine {
        navigation.positionLine(at: pressTarget ?? playhead,
                                rate: rate,
                                documentTitle: documentTitle,
                                isFinished: pressTarget == nil && isAtEnd)
    }

    // MARK: - Transport

    /// One row, or the transport over a row of chips. VoiceOver keeps one
    /// order either way: voice · speed, back, play, forward, sleep.
    @ViewBuilder
    private func transport(_ layout: MacPlayerBarLayout) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(layout.transportRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { control in
                        transportControl(control, in: row)
                    }
                }
                .frame(height: MacPlayerBarLayout.transportRowHeight(for: row, scale: layout.scale))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A chip takes an equal flexible side of a full row, so the cluster
    /// sits on the column's center whatever the chips say.
    @ViewBuilder
    private func transportControl(_ control: MacPlayerBarLayout.Control,
                                  in row: [MacPlayerBarLayout.Control]) -> some View {
        let order = MacPlayerBarLayout.voiceOverOrder(of: control)
        switch control {
        case .listening:
            listeningChip
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilitySortPriority(order)
        case .sleep:
            MacSleepMenu()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilitySortPriority(order)
        case .back15:
            skipButton(.back15, systemImage: "gobackward.15", identifier: "player.back15")
                .frame(maxWidth: row.contains(.listening) ? nil : .infinity, alignment: .trailing)
                .padding(.trailing, Theme.Space.xl)
                .accessibilitySortPriority(order)
        case .play:
            playButton
                .accessibilitySortPriority(order)
        case .forward15:
            skipButton(.forward15, systemImage: "goforward.15", identifier: "player.forward15")
                .padding(.leading, Theme.Space.xl)
                .frame(maxWidth: row.contains(.sleep) ? nil : .infinity, alignment: .leading)
                .accessibilitySortPriority(order)
        case .chapterLine, .backFiveMinutes, .offerDownload, .offerNotNow, .scrub, .chip:
            // Not transport controls: the line, the scrub and the chip slot
            // draw themselves.
            EmptyView()
        }
    }

    /// Names lead with the visible text, so Voice Control matches it; the
    /// input labels add the words people say for it.
    private var listeningChip: some View {
        @Bindable var ui = ui
        let voiceName = ListeningFormat.shortName(playback.voice)
        return Button {
            ui.isListeningShown.toggle()
        } label: {
            Text(ListeningFormat.chipTitle(voice: playback.voice, rate: playback.rate))
                .monospacedDigit()
                .numericReadout(playback.rate)
        }
        .buttonStyle(MacChipButtonStyle())
        .fixedSize()
        .help(MacCommand.voiceAndSpeed.help)
        // Upward, off the bar's top edge, as the bar sits at the window's foot.
        .popover(isPresented: $ui.isListeningShown, arrowEdge: .top) {
            MacListeningPopover()
        }
        .accessibilityLabel("\(voiceName), \(ListeningFormat.rate(playback.rate)), voice and speed")
        .accessibilityHint("Opens voice and speed")
        .accessibilityInputLabels([Text(voiceName), Text("Voice"), Text("Speed")])
        .accessibilityIdentifier("player.listening")
    }

    private func skipButton(_ command: MacCommand, systemImage: String, identifier: String) -> some View {
        let seconds = command == .back15 ? -PlaybackController.skipInterval : PlaybackController.skipInterval
        let label = MacMenuCopy.Help.label(for: command)
        return Button {
            skip(seconds)
        } label: {
            Image(systemName: systemImage)
                .imageScale(.large)
        }
        .buttonStyle(MacGlyphButtonStyle())
        .help(command.help)
        .accessibilityLabel(label)
        .accessibilityInputLabels([Text(label), Text(command == .back15 ? "Back 15" : "Forward 15")])
        .accessibilityIdentifier(identifier)
    }

    private var playButton: some View {
        let state = PlayButtonState(status: playback.status,
                                    isPreparingVoice: playback.isPreparingVoice,
                                    reduceMotion: reduceMotion)
        let diameter = chromeScale.playCircleDiameter
        return Button(action: togglePlayback) {
            PlayCircleFace(state: state, diameter: diameter)
        }
        .buttonStyle(MacPlayCircleButtonStyle(diameter: diameter))
        // "Play (Space)", "Pause (Space)": the glyph's own name and the key.
        .help(MacCommand.playPause.shortcut.map { "\(state.label) (\($0.symbol))" } ?? state.label)
        .accessibilityLabel(state.label)
        .accessibilityValue(state.value)
        .accessibilityIdentifier("player.play")
    }

    // MARK: - State helpers

    /// The sentence being read, or the first before anything has loaded.
    private var playhead: Int { max(playback.currentSentence, 0) }

    // MARK: - Actions

    /// Play and pause. Play from `.ended` restarts the book and from
    /// `.error` the failed sentence, both inside the controller. The Mac
    /// plays no transport haptics (M9).
    private func togglePlayback() {
        playback.togglePlayPause()
    }

    /// The error line's Try again: always Play, never the toggle. A voice
    /// sample picked after the failure is active, so the toggle would pause
    /// it and retry nothing; Play turns the sample into the retry.
    private func retry() {
        playback.play()
    }

    /// Keeps play or pause: a skip while paused moves the cue only.
    private func skip(_ seconds: TimeInterval) {
        playback.skip(seconds: seconds)
    }

    private func backFiveMinutes() {
        playback.backFiveMinutes()
    }
}

// MARK: - Layout

/// The bar's geometry and its control inventory, pure, so the column math,
/// the second row, each band's sizes and the focus budget are tested
/// without a window (M9: at most 9 focusable controls below the text at
/// rest, 10 while the natural-voice offer shows; M18: the bands). The view
/// draws its transport from `transportRows` and its sizes from here, so
/// the inventory and the measures are what it draws.
struct MacPlayerBarLayout: Equatable {

    /// Everything in the bar, the chip slot above it included, that takes
    /// keyboard focus.
    enum Control: Hashable, CaseIterable {
        /// The chapter line: position, a stop, a notice, or the offer's text.
        case chapterLine
        /// A sleep stop's "Back 5 min".
        case backFiveMinutes
        /// The natural-voice offer's two buttons.
        case offerDownload, offerNotNow
        case scrub
        case listening, back15, play, forward15, sleep
        /// The one chip above the bar.
        case chip
    }

    /// The reading column's widest measure (33 em at the default size, about
    /// 627 pt), which the bar's column never passes.
    static let maxColumnWidth: CGFloat = 640
    /// The narrowest reading column; the window's 520 pt minimum less its
    /// gutters.
    static let minColumnWidth: CGFloat = 480
    /// Below this the five controls crowd, and the chips take a second row.
    static let chipRowBreak: CGFloat = 560
    /// Mac targets in the standard band: the HIG's 28 pt minimum hit
    /// region; the skips get 32. Both grow with the band's type.
    static let chipHeight: CGFloat = 28
    static let glyphHit: CGFloat = 32
    /// The bar's insets above the chapter line and below the transport.
    static let topInset = Theme.Space.xs
    static let bottomInset = Theme.Space.sm
    /// The shared `ReaderMessageLine`'s row: its least height, one line.
    static let chapterLineMinHeight: CGFloat = 44
    /// Most controls the bar and its chip slot may offer the keyboard at
    /// rest. While the natural-voice offer shows, its Download and Not now
    /// are one more than a line's one inline action, so under a chip the
    /// bar holds 10 then; the offer shows once, after 60 s of listening.
    static let focusBudget = 9

    let columnWidth: CGFloat
    let chipsOnSecondRow: Bool
    /// The reader's chrome band, from its text size.
    let scale: ChromeScale

    init(barWidth: CGFloat, scale: ChromeScale) {
        columnWidth = Self.columnWidth(forBarWidth: barWidth)
        chipsOnSecondRow = columnWidth < Self.chipRowBreak || scale.chipsOnSecondRow
        self.scale = scale
    }

    /// The bar less its gutters, capped at the reading column's measure.
    static func columnWidth(forBarWidth width: CGFloat) -> CGFloat {
        guard width.isFinite else { return maxColumnWidth }
        return min(max(width - 2 * Theme.Space.screenGutter, 0), maxColumnWidth)
    }

    /// One row of five, or the transport cluster over the two chips.
    var transportRows: [[Control]] {
        chipsOnSecondRow
            ? [[.back15, .play, .forward15], [.listening, .sleep]]
            : [[.listening, .back15, .play, .forward15, .sleep]]
    }

    /// The transport row is 56 high (mac-ux §3.7), and grows with the Play
    /// circle in the larger bands; a chips-only row needs only the chips.
    static func transportRowHeight(for row: [Control], scale: ChromeScale) -> CGFloat {
        guard row.contains(.play) else { return chipHeight(for: scale) + 2 * Theme.Space.xs }
        return max(56, scale.playCircleDiameter + Theme.Space.sm)
    }

    // MARK: Bands (M18)

    /// A chip's height: 28, 32 and 36 by band, so the larger label keeps
    /// the standard chip's margins above and below it.
    static func chipHeight(for scale: ChromeScale) -> CGFloat {
        chipHeight + 2 * scale.step
    }

    /// The skips' square hit region: 32, 36 and 40 by band, around a glyph
    /// set in the band's body size.
    static func glyphHit(for scale: ChromeScale) -> CGFloat {
        glyphHit + 2 * scale.step
    }

    /// Back 15, Play and Forward 15 with the 24 pt between them: the part
    /// of the transport that never wraps.
    static func transportClusterWidth(for scale: ChromeScale) -> CGFloat {
        2 * glyphHit(for: scale) + 2 * Theme.Space.xl + scale.playCircleDiameter
    }

    /// The chapter line's row: the shared line's 44, or in the Largest
    /// band, where the line may wrap (mac-ux §10.4), room for its title on
    /// two lines over its detail, at the band's sizes as SwiftUI sets them.
    static func chapterLineHeight(for scale: ChromeScale) -> CGFloat {
        guard scale == .largest else { return chapterLineMinHeight }
        let wrapped = 2 * lineHeight(.subhead, scale: scale) + Theme.Space.xxs + lineHeight(.footnote, scale: scale)
        return max(chapterLineMinHeight, wrapped.rounded(.up))
    }

    /// One line of the system face at `style`'s size in `scale`'s band.
    static func lineHeight(_ style: Theme.TypeStyle, scale: ChromeScale) -> CGFloat {
        let font = NSFont.systemFont(ofSize: PlatformTypeRamp.points(style, scale: scale))
        // As SwiftUI sets a line: ascender and descender each rounded out
        // to a whole point (19 pt at 15, where AppKit's sum gives 18).
        return (font.ascender.rounded(.up) - font.descender.rounded(.down) + font.leading).rounded(.up)
    }

    /// The room either chip has beside the cluster on one row, or in its
    /// half of the chips' own row.
    var chipSideWidth: CGFloat {
        chipsOnSecondRow
            ? columnWidth / 2
            : max(columnWidth - Self.transportClusterWidth(for: scale), 0) / 2
    }

    /// The most the bar stands, as `MacPlayerBar` stacks it: the insets,
    /// the chapter line (with its room to wrap in the Largest band), the
    /// scrub's row and the transport's one or two rows.
    var height: CGFloat {
        Self.topInset + Self.chapterLineHeight(for: scale) + MacScrub.rowHeight
            + transportRows.reduce(0) { $0 + Self.transportRowHeight(for: $1, scale: scale) }
            + Self.bottomInset
    }

    /// VoiceOver's order in either layout (higher reads first).
    static func voiceOverOrder(of control: Control) -> Double {
        switch control {
        case .listening: return 5
        case .back15: return 4
        case .play: return 3
        case .forward15: return 2
        case .sleep: return 1
        default: return 0
        }
    }

    /// What the chapter line offers the keyboard for `message`: the line
    /// itself, plus a sleep stop's Back 5 min or the offer's two buttons.
    static func messageControls(_ message: ReaderMessage?) -> [Control] {
        switch message {
        case .stopped(.sleepTimer)?: return [.chapterLine, .backFiveMinutes]
        case .naturalVoiceOffer?: return [.chapterLine, .offerDownload, .offerNotNow]
        default: return [.chapterLine]
        }
    }

    /// Every focusable control under the text, in Tab order: the chip slot,
    /// the chapter line and its actions, the scrub, then the transport.
    func focusableControls(message: ReaderMessage?, chip: ReaderChip?) -> [Control] {
        (chip == nil ? [] : [.chip])
            + Self.messageControls(message)
            + [.scrub]
            + transportRows.flatMap { $0 }.sorted { Self.voiceOverOrder(of: $0) > Self.voiceOverOrder(of: $1) }
    }
}

// MARK: - Mac control styles

/// The bar's chip on the Mac: a 28 pt capsule (by band) on Theme.surface with
/// Stroke.border that fills surface2 under the pointer (mac-ux §11);
/// `isOn` (an armed timer) is accentStrong on accentSoft. Shared by the
/// voice · speed chip, the sleep chip and the chip slot.
struct MacChipButtonStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        MacHoverFace { isHovered in
            configuration.label
                .macChipFace(isOn: isOn, isHighlighted: isHovered || configuration.isPressed, tint: tint)
        }
    }
}

/// A transport glyph (back and forward 15): textMuted that turns Theme.text
/// under the pointer, in a 32 pt square hit region (36 and 40 in the larger
/// bands).
struct MacGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacGlyphFace(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct MacGlyphFace<Label: View>: View {
    let label: Label
    let isPressed: Bool

    @Environment(\.chromeScale) private var scale
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .font(Theme.font(.body, scale: scale))
            .foregroundStyle(!isEnabled ? Theme.textFaint
                             : (isHovered || isPressed ? Theme.text : Theme.textMuted))
            .frame(width: MacPlayerBarLayout.glyphHit(for: scale), height: MacPlayerBarLayout.glyphHit(for: scale))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: Theme.Motion.press), value: isHovered)
    }
}

/// Play: the shared accent circle, a touch lighter under the pointer (the
/// Continue card's 92%), and accentStrong while pressed.
struct MacPlayCircleButtonStyle: ButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        MacHoverFace { isHovered in
            AccentCircleButtonStyle(diameter: diameter)
                .makeBody(configuration: configuration)
                .opacity(isHovered && !configuration.isPressed ? 0.92 : 1)
                .contentShape([.interaction, .focusEffect], Circle())
        }
    }
}

/// Tracks the pointer over its content and hands the state to `content`,
/// so a `ButtonStyle` (which can't hold state) can draw a hover.
struct MacHoverFace<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: Theme.Motion.press), value: isHovered)
    }
}

extension View {
    /// The Mac chip's capsule: 28 high (32 and 36 in the larger bands),
    /// surface (surface2 when highlighted), with accentSoft over it when on.
    func macChipFace(isOn: Bool = false, isHighlighted: Bool, tint: Color = Theme.text) -> some View {
        modifier(MacChipFace(isOn: isOn, isHighlighted: isHighlighted, tint: tint))
    }
}

private struct MacChipFace: ViewModifier {
    let isOn: Bool
    let isHighlighted: Bool
    let tint: Color

    @Environment(\.chromeScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(Theme.font(.subhead, scale: scale))
            .lineLimit(1)
            .foregroundStyle(isOn ? Theme.accentStrong : tint)
            .padding(.horizontal, Theme.Space.sm)
            .frame(minWidth: MacPlayerBarLayout.chipHeight(for: scale),
                   minHeight: MacPlayerBarLayout.chipHeight(for: scale))
            .background {
                // On (an armed timer) lays the translucent accentSoft over
                // the same ground, so the pointer still deepens it.
                ZStack {
                    Capsule().fill(isHighlighted ? Theme.surface2 : Theme.surface)
                    if isOn { Capsule().fill(Theme.accentSoft) }
                }
            }
            .overlay(Capsule().strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
            // The keyboard focus ring follows the capsule, not its frame.
            .contentShape([.interaction, .focusEffect], Capsule())
    }
}

/// The Mac scrub's press target while pressed, nil otherwise: the press is
/// the scrub's gesture state, and the bar's chapter line follows it.
struct MacScrubPressKey: PreferenceKey {
    static let defaultValue: Int? = nil

    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = nextValue() ?? value
    }
}
