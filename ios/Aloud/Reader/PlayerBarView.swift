import SwiftUI

/// Bottom player chrome, every frequent control in the thumb's reach (R6):
/// the chapter line (the one message slot, which opens Contents), the scrub
/// and one row of five controls — the voice · speed chip, back 15, Play,
/// forward 15 and the sleep chip. From .xxLarge the chip takes a row of its
/// own. All state flows through PlaybackController.
///
/// The scrub spans the current chapter (the whole document for PDFs and
/// chapterless books) so a long book still scrubs at sentence precision
/// (R17). Only a horizontal drag of at least 8pt seeks: a plain tap does
/// nothing. The release is a `.scrub` jump, which offers Undo jump (R15).
/// VoiceOver adjusts it by chapter or page row, else by a minute (R12c).
struct PlayerBarView: View {

    let document: LibraryDocument
    let content: DocContent
    let navigation: ReaderNavigation

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
    @State private var showListening = false
    @State private var showContents = false

    var body: some View {
        // Line, track and transport are each at least a 44pt-tall hit row,
        // so the rows sit flush and only the bottom takes padding.
        VStack(spacing: 0) {
            ReaderMessageLine(message: message,
                              position: position,
                              onOpenContents: { showContents = true },
                              onRetry: retry,
                              onBackFiveMinutes: backFiveMinutes)
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
        .sheet(isPresented: $showListening) { ListeningSheet() }
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
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, width * navigation.scrubFill(of: drag?.target ?? playhead, in: span,
                                                                     isFinished: drag == nil && playback.isAtEnd)))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topLeading) {
                if let drag {
                    dragPreview(for: drag, width: width)
                        // Bottom edge on the row's top, ~20pt above the line:
                        // a taller label grows upward, never over the track.
                        .alignmentGuide(.top) { $0[.bottom] }
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
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

    /// Five controls in one row fit through .xLarge; past that the chip's
    /// text would squeeze the transport, so it moves to a row of its own.
    private var stacksTransport: Bool { dynamicTypeSize >= .xxLarge }

    /// VoiceOver order in both layouts: chip, back, play, forward, sleep.
    @ViewBuilder
    private var transport: some View {
        if stacksTransport {
            VStack(spacing: Theme.Space.xs) {
                HStack {
                    listeningChip
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    transportCluster
                    Spacer(minLength: Theme.Space.xs)
                    SleepChip()
                }
            }
        } else {
            HStack(spacing: 0) {
                listeningChip
                Spacer(minLength: Theme.Space.xs)
                transportCluster
                Spacer(minLength: Theme.Space.xs)
                SleepChip()
            }
        }
    }

    private var transportCluster: some View {
        HStack(spacing: 0) {
            back15
            playButton
            forward15
        }
        .fixedSize()
    }

    /// Names lead with the visible text, so Voice Control matches it; the
    /// input labels add the words people say for it.
    private var listeningChip: some View {
        let voiceName = ListeningFormat.shortName(playback.voice)
        return Button { showListening = true } label: {
            Text(ListeningFormat.chipTitle(voice: playback.voice, rate: playback.rate))
                .monospacedDigit()
                .numericReadout(playback.rate)
                .readerChip()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(voiceName), \(ListeningFormat.rate(playback.rate)), voice and speed")
        .accessibilityHint("Opens voice and speed")
        .accessibilityInputLabels([Text(voiceName), Text("Voice"), Text("Speed")])
        .accessibilityIdentifier("player.listening")
    }

    private var back15: some View {
        skipButton(seconds: -PlaybackController.skipInterval, systemImage: "gobackward.15",
                   label: "Back 15 seconds", inputLabel: "Back 15",
                   identifier: "player.back15")
    }

    private var forward15: some View {
        skipButton(seconds: PlaybackController.skipInterval, systemImage: "goforward.15",
                   label: "Forward 15 seconds", inputLabel: "Forward 15",
                   identifier: "player.forward15")
    }

    private func skipButton(seconds: TimeInterval, systemImage: String, label: String,
                            inputLabel: String, identifier: String) -> some View {
        Button { skip(seconds) } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // The glyph scales inside a fixed 44pt target, so growth stops at
        // xxxLarge; a long press past the cap shows it large.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .largeContentViewerIfAvailable {
            Label(label, systemImage: systemImage)
        }
        .accessibilityLabel(label)
        .accessibilityInputLabels([Text(inputLabel)])
        .accessibilityIdentifier(identifier)
    }

    private var playButton: some View {
        // A playback error's stop keeps the retry face beside "tap to try
        // again" (`PlayButtonState.circleStatus`).
        let state = PlayButtonState(status: PlayButtonState.circleStatus(playback.status,
                                                                         stop: playback.stopReason(for: document.id)),
                                    isPreparingVoice: playback.isPreparingVoice,
                                    reduceMotion: reduceMotion)
        return Button(action: togglePlayback) {
            PlayCircleFace(state: state)
                // The glyph scales inside the fixed 54pt circle; a long
                // press past the cap shows it large.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(AccentCircleButtonStyle(diameter: Theme.PlayCircle.diameter))
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
    /// audio. No haptic: skips aren't in R20's vocabulary (TransportHaptics).
    private func skip(_ seconds: TimeInterval) {
        playback.skip(seconds: seconds)
    }

    /// A sleep stop's Back 5 min: a user-started play, so it ticks like one.
    private func backFiveMinutes() {
        TransportHaptics.emit(.play)
        playback.backFiveMinutes()
    }
}
