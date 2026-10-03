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

    var body: some View {
        let layout = MacPlayerBarLayout(barWidth: barWidth, scale: chromeScale)
        VStack(spacing: 0) {
            // The shared line pads itself by the gutter; the rows under it
            // take the same inset, so all three share one left edge.
            ReaderMessageLine(message: message,
                              position: position,
                              onOpenContents: onToggleContents,
                              onRetry: togglePlayback,
                              onBackFiveMinutes: backFiveMinutes)
            MacScrub(document: document, content: content, navigation: navigation)
                .padding(.horizontal, Theme.Space.screenGutter)
            transport(layout)
                .padding(.horizontal, Theme.Space.screenGutter)
        }
        .frame(width: layout.columnWidth + 2 * Theme.Space.screenGutter)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.sm)
        .frame(maxWidth: .infinity)
        // Paper, never a material: the bar stays in the Bronze family.
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .frame(height: Theme.Stroke.hairlineWidth)
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
                              isPreparingVoice: playback.isPreparingVoice)
    }

    private var position: ReaderPositionLine {
        navigation.positionLine(at: playhead,
                                rate: playback.rate,
                                documentTitle: document.title,
                                isFinished: playback.isAtEnd)
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
                .frame(height: MacPlayerBarLayout.transportRowHeight(for: row, scale: chromeScale))
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

    /// Play, pause, and the error line's Try again. Play from `.ended`
    /// restarts the book and from `.error` the failed sentence, both inside
    /// the controller. The Mac plays no transport haptics (M9).
    private func togglePlayback() {
        playback.togglePlayPause()
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
/// the second row and the focus budget are tested without a window (M9:
/// at most 9 focusable controls below the text). The view draws its
/// transport from `transportRows`, so the inventory is what it draws.
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
    /// Mac targets: the HIG's 28 pt minimum hit region; the skips get 32.
    static let chipHeight: CGFloat = 28
    static let glyphHit: CGFloat = 32
    /// Most controls the bar and its chip slot may offer the keyboard.
    static let focusBudget = 9

    let columnWidth: CGFloat
    let chipsOnSecondRow: Bool

    init(barWidth: CGFloat, scale: ChromeScale) {
        columnWidth = Self.columnWidth(forBarWidth: barWidth)
        chipsOnSecondRow = columnWidth < Self.chipRowBreak || scale.chipsOnSecondRow
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
        guard row.contains(.play) else { return chipHeight + 2 * Theme.Space.xs }
        return max(56, scale.playCircleDiameter + Theme.Space.sm)
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

/// The bar's chip on the Mac: a 28 pt capsule on Theme.surface with
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
/// under the pointer, in a 32 pt square hit region.
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
            .frame(width: MacPlayerBarLayout.glyphHit, height: MacPlayerBarLayout.glyphHit)
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
    /// The Mac chip's capsule: 28 high, surface (surface2 when highlighted),
    /// with accentSoft over it when on.
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
            .frame(minWidth: MacPlayerBarLayout.chipHeight, minHeight: MacPlayerBarLayout.chipHeight)
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
