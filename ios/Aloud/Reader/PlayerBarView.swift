import SwiftUI

/// Bottom player chrome, every frequent control in the thumb's reach (R6):
/// the chapter line (the one message slot, which opens Contents), the scrub
/// and one row of five controls — the voice · speed chip, back 15, Play,
/// forward 15 and the sleep chip. Play sits on the screen's center line
/// whatever the chips say (PlayerBarLayout); from .xxLarge the two chips
/// share a row above the centred transport. All state flows through
/// PlaybackController.
///
/// The scrub spans the current chapter (the whole document for PDFs and
/// chapterless books) so a long book still scrubs at sentence precision
/// (R17). Only a horizontal drag of at least 8pt seeks: a touch only shows
/// it is held (a thicker track, a larger thumb) and a plain tap does
/// nothing. The release is a `.scrub` jump, which offers Undo jump (R15).
/// VoiceOver adjusts it by chapter or page row, else by a minute (R12c).
struct PlayerBarView: View {

    let document: LibraryDocument
    let content: DocContent
    let navigation: ReaderNavigation
    /// How tall the Voice & speed sheet stands while it rests open, for the
    /// reader's calm follow (`ListeningSheet.coveredHeight`).
    var listeningSheetHeight: Binding<CGFloat?> = .constant(nil)

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var naturalVoiceOffer: NaturalVoiceOffer
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The seek drag in progress, which the chapter line, the track fill and
    /// the preview follow. Gesture state, so it lives exactly as long as the
    /// touch: SwiftUI clears it when the drag ends and also when the system
    /// cancels it (an alert, Siri, the app going inactive), which never
    /// calls onEnded and left plain @State frozen on the drag target.
    @GestureState private var drag: ScrubDrag?
    /// The same frozen span for the release: `drag` is already reset when
    /// onEnded runs, and the voice may have changed chapter mid-drag. One
    /// instance for the view's life, written by drag frames, never drawn.
    @State private var releaseSpan = ScrubReleaseSpan()
    /// The scrub preview's measured width, so its centering and edge clamp
    /// use the capsule's real size (it varies with the words and text size).
    /// Seeded near a default-size preview so the first drag frame sits right.
    @State private var previewWidth: CGFloat = 180
    /// A finger resting on the scrub: touch feedback only, never a seek.
    /// Gesture state, so a system cancel lets the track settle back too.
    @GestureState private var isTouchingScrub = false
    @State private var showListening = false
    @State private var showContents = false
    /// The transport row's measured width, inside the gutters (0 until the
    /// first layout), and the wider chip's width with its full label.
    @State private var barWidth: CGFloat = 0
    @State private var widestFullChip: CGFloat = 0
    /// Play and the skip targets grow with Dynamic Type, inside
    /// PlayerBarLayout's caps.
    @ScaledMetric(relativeTo: .title2) private var scaledPlayDiameter: CGFloat = Theme.PlayCircle.diameter
    @ScaledMetric(relativeTo: .title2) private var scaledSkipTarget: CGFloat = 44

    /// The skip glyphs read a step lighter than Play.
    private static let skipGlyphFont = Font.title3.weight(.medium)
    /// The scrub line's centre, down from the top of its 44pt touch row:
    /// resting and held alike (`ScrubLineSeat`).
    nonisolated static let trackCentre: CGFloat = 16

    var body: some View {
        // Line, track and transport are each at least a 44pt-tall hit row,
        // so the rows sit flush and only the bottom takes padding.
        VStack(spacing: 0) {
            // The line's ink sits on its row's foot, with the scrub it
            // describes; Undo jump is one of its actions while it is offered.
            ReaderMessageLine(message: message,
                              position: position,
                              onOpenContents: openContents,
                              onRetry: retry,
                              onBackFiveMinutes: backFiveMinutes,
                              rowAlignment: .bottom,
                              onUndoJump: playback.undoableJump != nil ? undoJump : nil)
                // The bar's height budget: past the chips' cap a wrapping
                // line would leave only a few lines of the page.
                .dynamicTypeSize(...PlayerBarLayout.chipTypeCap)
            // Inside the gutter, so a back swipe from the screen edge never
            // lands on the drag gesture.
            scrubTrack
                .padding(.horizontal, Theme.Space.screenGutter)
            transport
                .padding(.horizontal, Theme.Space.screenGutter)
                .padding(.bottom, Theme.Space.xs)
        }
        // Always its ideal height. The reader's safeAreaInset places the bar
        // with a finite height, which a VStack shares out least-flexible row
        // first: with a wrapping chapter line (a book title at AX sizes) the
        // transport was squeezed and the bar fell ~20pt short of its inset,
        // so the paper stopped above the screen bottom.
        .fixedSize(horizontal: false, vertical: true)
        // Paper, not system material: the bar stays in the Bronze family in
        // both modes (a material renders neutral gray over the warm page).
        .background(Theme.surface, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Stroke.hairlineColor)
                .frame(height: Theme.Stroke.hairlineWidth)
        }
        .sheet(isPresented: $showListening) { ListeningSheet(coveredHeight: listeningSheetHeight) }
        .sheet(isPresented: $showContents) {
            ContentsSheet(content: content, navigation: navigation)
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

    /// Follows a scrub drag, so the line previews the target chapter and its
    /// time left before the finger lifts.
    private var position: ReaderPositionLine {
        navigation.positionLine(at: drag?.target ?? playhead,
                                rate: playback.rate,
                                documentTitle: document.title,
                                isFinished: drag == nil && playback.isAtEnd)
    }

    // MARK: - Scrub track

    private var scrubTrack: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = drag?.span ?? navigation.scrubSpan(at: playhead)
            // The shared warm track (R3-09): a held track thickens and its
            // thumb grows; under Reduce Motion nothing grows and a soft ring
            // fades in instead.
            WarmTrack(fraction: navigation.scrubFill(of: drag?.target ?? playhead, in: span,
                                                     isFinished: drag == nil && playback.isAtEnd),
                      isHeld: isTouchingScrub,
                      reduceMotion: reduceMotion)
            // The line sits high in its 44pt row, near the chapter line it
            // describes, seated by its centre: a press thickens it evenly
            // and the thumb stays under the finger. The pressed thumb and
            // the Reduce Motion ring still fit inside the row.
            .modifier(ScrubLineSeat())
            .overlay(alignment: .topLeading) {
                if let drag {
                    dragPreview(for: drag, width: width)
                        // Bottom edge on the row's top, ~14pt above the line:
                        // a taller label grows upward, never over the track.
                        .alignmentGuide(.top) { $0[.bottom] }
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
            .simultaneousGesture(touchDownGesture)
        }
        // A full 44pt touch row around the 4pt line.
        .frame(height: 44)
        // A slider to assistive tech (R12c): shapes with only an adjustable
        // action read as a plain element (.other to XCUITest, not .slider).
        // This swaps the accessibility alone; the drag stays on the track.
        .accessibilityRepresentation {
            // Constant: every assistive step arrives as the adjustable action
            // below, never as a write to the value.
            Slider(value: .constant(navigation.scrubFill(of: playhead,
                                                         in: navigation.scrubSpan(at: playhead),
                                                         isFinished: playback.isAtEnd)),
                   in: 0...1)
                // The whole touch row, so the element's frame is the one the
                // drag uses: a Slider's own ideal height is a thin track, and
                // the representation is sized from it.
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .accessibilityLabel("Position")
                // The playhead's spoken position, never a sentence index (R12e).
                .accessibilityValue(navigation.positionLine(at: playhead,
                                                            rate: playback.rate,
                                                            documentTitle: document.title,
                                                            isFinished: playback.isAtEnd)
                                        .accessibilityLabel)
                // The scrub's own step (R12c), by chapter in place of the
                // slider's default: VoiceOver reads the new value.
                .accessibilityAdjustableAction { direction in
                    if let target = navigation.adjustmentTarget(from: playhead,
                                                                forward: direction == .increment,
                                                                rate: playback.rate) {
                        playback.jump(to: target, origin: .scrub)
                    }
                }
                // Undo jump beside the step while it is offered, so VoiceOver
                // and Switch Control reach it from the scrub that made it.
                .accessibilityActions {
                    if playback.undoableJump != nil {
                        Button(ReaderChip.undoJump.title, action: undoJump)
                    }
                }
                .accessibilityIdentifier("player.scrub")
        }
    }

    /// The span freezes on the first seek frame, so the track never rescales
    /// under the finger. A drag that is not (or no longer) 8pt sideways shows
    /// no preview and seeks nothing, so the preview always tells the truth.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: ScrubGesture.minimumDistance)
            .updating($drag) { value, state, _ in
                state = ScrubDrag.next(after: state, translation: value.translation,
                                       current: { navigation.scrubSpan(at: playhead) },
                                       target: { scrubTarget(atX: value.location.x, width: width, in: $0) })
                // The release's copy, from this same frame: gesture state
                // restarts at nil on every drag (a cancelled one too), so a
                // stale span can't outlive the drag that froze it.
                releaseSpan.track(state)
            }
            // Only a lifted finger seeks; a cancelled drag just lets the line
            // and the track fall back to the playhead.
            .onEnded { value in
                // The span the preview showed: reading the gesture state here
                // fell back to wherever the playhead had moved.
                guard let span = releaseSpan.release(translation: value.translation,
                                                     current: { navigation.scrubSpan(at: playhead) }) else { return }
                let target = scrubTarget(atX: value.location.x, width: width, in: span)
                // One tick per seek, not one per sentence crossed.
                TransportHaptics.emit(.scrubRelease)
                playback.jump(to: target, origin: .scrub)
            }
    }

    /// Touch feedback alone: holds `isTouchingScrub` while a finger rests on
    /// the track. It never seeks, ticks or offers Undo; lifting without 8pt
    /// of travel just lets the track settle.
    private var touchDownGesture: some Gesture {
        DragGesture(minimumDistance: ScrubGesture.touchDownDistance)
            .updating($isTouchingScrub) { _, touching, _ in touching = true }
    }

    private func scrubTarget(atX x: CGFloat, width: CGFloat, in span: ClosedRange<Int>) -> Int {
        navigation.sentence(atFraction: ScrubGesture.fraction(atX: x, width: width), in: span)
    }

    /// The target's first words and its time into the span: never a
    /// sentence number.
    private func dragPreview(for drag: ScrubDrag, width: CGFloat) -> some View {
        let sentence = content.sentences.indices.contains(drag.target)
            ? content.sentences[drag.target].text : ""
        let seconds = navigation.secondsIntoSpan(of: drag.target, in: drag.span, rate: playback.rate)
        return HStack(spacing: Theme.Space.xxs) {
            Text(ScrubPreview.words(of: sentence))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\u{00B7} " + ListeningEstimate.clock(seconds: seconds))
                .monospacedDigit()
                .fixedSize()
        }
        .font(Theme.font(.caption))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Stroke.hairlineColor,
                                        lineWidth: Theme.Stroke.hairlineWidth))
        // A one-line floating label: past xxxLarge it would only truncate
        // further, so its growth stops there.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
            previewWidth = measured
        }
        // Never wider than the track less an inset at either end: the words
        // truncate first. Leading, so the capsule's edge is the frame's.
        .frame(maxWidth: max(width - 2 * Theme.Space.xxs, 0), alignment: .leading)
        .offset(x: previewOffsetX(fraction: navigation.scrubFraction(of: drag.target, in: drag.span),
                                  width: width))
        .transition(.opacity)
    }

    /// Centers the preview on the target's place along the track, clamped
    /// so its real width stays inside the bar with a small inset at either
    /// end.
    private func previewOffsetX(fraction: Double, width: CGFloat) -> CGFloat {
        let inset = Theme.Space.xxs
        let maxX = max(width - previewWidth - inset, inset)
        return min(max(CGFloat(fraction) * width - previewWidth / 2, inset), maxX)
    }

    // MARK: - Transport

    /// The bar's geometry for this width, text size and pair of chips.
    private var layout: PlayerBarLayout {
        PlayerBarLayout(barWidth: barWidth,
                        dynamicTypeSize: dynamicTypeSize,
                        playDiameter: PlayerBarLayout.playDiameter(scaled: scaledPlayDiameter),
                        skipTarget: PlayerBarLayout.skipTarget(scaled: scaledSkipTarget),
                        widestFullChip: widestFullChip)
    }

    /// One row of five through .xLarge, each chip on an equal flexible side
    /// so Play sits on the center line; from .xxLarge the chips share a row
    /// above the centred cluster. VoiceOver reads chip, back, play, forward,
    /// sleep in both.
    private var transport: some View {
        let layout = self.layout
        return Group {
            if layout.stacksTransport {
                VStack(spacing: Theme.Space.xs) {
                    HStack(spacing: PlayerBarLayout.chipRowSpacing) {
                        listeningChipSlot(layout)
                        sleepChipSlot(layout)
                    }
                    transportCluster(layout)
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    listeningChipSlot(layout)
                    transportCluster(layout)
                    sleepChipSlot(layout)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            barWidth = width
        }
        .onPreferenceChange(ReaderChipFullWidth.self) { width in
            widestFullChip = width
        }
        // The sort priorities order the five among themselves, never ahead
        // of the chapter line and the scrub.
        .accessibilityElement(children: .contain)
    }

    /// The outer chips' faces sit on the bar's gutter, where the scrub
    /// starts, their 44pt hit boxes growing inward (R2-25), in both rows.
    private func listeningChipSlot(_ layout: PlayerBarLayout) -> some View {
        listeningChip
            .environment(\.readerChipEdge, .leading)
            .frame(maxWidth: layout.chipWidthLimit, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .listening))
    }

    /// Its own view, so the countdown's tick never redraws the bar.
    private func sleepChipSlot(_ layout: PlayerBarLayout) -> some View {
        SleepChip()
            .environment(\.readerChipEdge, .trailing)
            .dynamicTypeSize(...PlayerBarLayout.chipTypeCap)
            .frame(maxWidth: layout.chipWidthLimit, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .sleep))
    }

    private func transportCluster(_ layout: PlayerBarLayout) -> some View {
        HStack(spacing: layout.clusterGap) {
            skipButton(seconds: -PlaybackController.skipInterval, systemImage: "gobackward.15",
                       label: "Back 15 seconds", inputLabel: "Back 15",
                       identifier: "player.back15", target: layout.skipTarget)
                .accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .back15))
            playButton(diameter: layout.playDiameter)
                .accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .play))
            skipButton(seconds: PlaybackController.skipInterval, systemImage: "goforward.15",
                       label: "Forward 15 seconds", inputLabel: "Forward 15",
                       identifier: "player.forward15", target: layout.skipTarget)
                // Dimmed where it can't move (the last sentence, the end);
                // Back 15 stays, as at the end it restarts the last sentence.
                .disabled(!playback.canSkipForward)
                .accessibilitySortPriority(PlayerBarLayout.voiceOverOrder(of: .forward15))
        }
        .fixedSize()
    }

    /// Names lead with the visible text, so Voice Control matches it; the
    /// input labels add the words people say for it. Where its full title
    /// can't fit its side, the chip shows the speed alone at the same size;
    /// the spoken label and a long press past the type cap still name the
    /// voice.
    private var listeningChip: some View {
        let voiceName = ListeningFormat.shortName(playback.voice)
        let title = ListeningFormat.chipTitle(voice: playback.voice, rate: playback.rate)
        return Button {
            TransportHaptics.emit(.press)
            showListening = true
        } label: {
            ViewThatFits(in: .horizontal) {
                Text(title)
                Text(ListeningFormat.chipShortTitle(rate: playback.rate))
            }
            .monospacedDigit()
            .numericReadout(playback.rate)
        }
        .buttonStyle(ReaderChipButtonStyle())
        .readerChipFullWidth { Text(title).monospacedDigit() }
        .dynamicTypeSize(...PlayerBarLayout.chipTypeCap)
        .largeContentViewerIfAvailable { Text(title) }
        .accessibilityLabel("\(voiceName), \(ListeningFormat.rate(playback.rate)), voice and speed")
        .accessibilityHint("Opens voice and speed")
        .accessibilityInputLabels([Text(voiceName), Text("Voice"), Text("Speed")])
        .accessibilityIdentifier("player.listening")
    }

    private func skipButton(seconds: TimeInterval, systemImage: String, label: String,
                            inputLabel: String, identifier: String, target: CGFloat) -> some View {
        Button { skip(seconds) } label: {
            Image(systemName: systemImage)
                .font(Self.skipGlyphFont)
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        // textMuted at rest, Theme.text while pressed; the press haptic
        // comes from `skip(_:)`, so a disabled Forward 15 stays silent.
        .buttonStyle(ReaderGlyphButtonStyle())
        // The glyph scales inside the target, so growth stops at xxxLarge;
        // a long press past the cap shows it large.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .largeContentViewerIfAvailable {
            Label(label, systemImage: systemImage)
        }
        .accessibilityLabel(label)
        .accessibilityInputLabels([Text(inputLabel)])
        .accessibilityIdentifier(identifier)
    }

    private func playButton(diameter: CGFloat) -> some View {
        // A playback error's stop keeps the retry face beside "tap to try
        // again" (`PlayButtonState.circleStatus`).
        let state = PlayButtonState(status: PlayButtonState.circleStatus(playback.status,
                                                                         stop: playback.stopReason(for: document.id)),
                                    isPreparingVoice: playback.isPreparingVoice,
                                    reduceMotion: reduceMotion)
        return Button(action: togglePlayback) {
            PlayCircleFace(state: state, diameter: diameter)
                // The glyph scales inside the circle, which grows to its own
                // cap; a long press past the glyph's cap shows it large.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(AccentCircleButtonStyle(diameter: diameter))
        .largeContentViewerIfAvailable {
            Label(state.label, systemImage: state.glyph.rawValue)
        }
        .accessibilityLabel(state.label)
        .accessibilityValue(state.value)
        .accessibilityIdentifier("player.play")
    }

    // MARK: - State helpers

    /// The sentence being read, or the first before anything has loaded.
    private var playhead: Int { max(playback.currentSentence, 0) }

    // MARK: - Actions

    /// Play and pause. Play from `.ended` restarts the book and from
    /// `.error` the failed sentence, both inside `play()`.
    private func togglePlayback() {
        TransportHaptics.emitToggle(isActive: playback.isActive)
        playback.togglePlayPause()
    }

    /// The retry line's tap: always Play, never the toggle. A voice sample
    /// picked after the failure is active, so the toggle would pause it
    /// and retry nothing; Play turns the sample into the retry.
    private func retry() {
        TransportHaptics.emit(.play)
        playback.play()
    }

    /// Keeps play/pause: a skip while paused moves the cue, never starts
    /// audio. A button press, so the press haptic (TransportHaptics), never
    /// a play: the place it moves is the skip's own, not a pick.
    private func skip(_ seconds: TimeInterval) {
        TransportHaptics.emit(.press)
        playback.skip(seconds: seconds)
    }

    /// The chapter line's tap (and its named actions): Contents opens, a
    /// press.
    private func openContents() {
        TransportHaptics.emit(.press)
        showContents = true
    }

    /// Undo jump from the scrub's or the chapter line's named action: the
    /// same restore, and the same place tick, as the chip's tap.
    private func undoJump() {
        TransportHaptics.emit(.place)
        playback.undoJump()
    }

    /// A sleep stop's Back 5 min: a user-started play, so it ticks like one.
    private func backFiveMinutes() {
        TransportHaptics.emit(.play)
        playback.backFiveMinutes()
    }
}

/// Seats the scrub line in its 44pt touch row by its centre,
/// `PlayerBarView.trackCentre` down from the row's top. The line and the
/// thumb centred on it sit in a fixed box as tall as the held line, so the
/// resting and the held line share that centre: a press thickens the line
/// evenly (the resting line spans 14 to 18pt, the held one 12 to 20pt) and
/// the thumb never moves under the finger. Pinned by its top edge, the held
/// line grew downward only and its thumb dropped 2pt.
struct ScrubLineSeat: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: ScrubThumb.pressedTrackHeight)
            .padding(.top, PlayerBarView.trackCentre - ScrubThumb.pressedTrackHeight / 2)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
