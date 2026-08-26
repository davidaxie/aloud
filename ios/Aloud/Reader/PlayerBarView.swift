import SwiftUI

/// Bottom player chrome: sentence-granular scrub track with drag preview,
/// percent + time-left readout, and the transport row (voice chip,
/// back / play / forward, speed chip). All state flows through PlaybackController.
struct PlayerBarView: View {

    let document: LibraryDocument
    let content: DocContent

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel

    @State private var dragSentence: Int?
    @State private var showVoiceSheet = false
    @State private var showSpeedSheet = false
    @State private var showPageReadout = false

    var body: some View {
        VStack(spacing: 0) {
            scrubTrack
            readoutRow
                .padding(.horizontal, 20)
                .padding(.top, 6)
            transportRow
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
        .sheet(isPresented: $showVoiceSheet) { VoicePickerSheet() }
        .sheet(isPresented: $showSpeedSheet) { SpeedSheet() }
    }

    // MARK: - Scrub track

    private var scrubTrack: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(4, width * displayedFraction))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topLeading) {
                if let sentence = dragSentence {
                    dragPreview(for: sentence, width: width)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let target = sentenceIndex(atX: value.location.x, width: width)
                        if dragSentence == nil {
                            TransportHaptics.prepare()   // drag start: warm the engine
                        } else if dragSentence != target {
                            TransportHaptics.selectionChanged()   // preview moved a sentence
                        }
                        dragSentence = target
                    }
                    .onEnded { value in
                        let target = sentenceIndex(atX: value.location.x, width: width)
                        dragSentence = nil
                        playback.seek(to: target, andPlay: playback.isActive)
                    }
            )
        }
        .frame(height: 30)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(document.progressPercent) percent")
    }

    private func dragPreview(for sentence: Int, width: CGFloat) -> some View {
        let page = content.sentences.indices.contains(sentence)
            ? content.sentences[sentence].page + pageOffset : 1
        var label = "Sentence \(sentence + 1) of \(sentenceCount)"
        if content.pageCount > 1 { label += " · Page \(page)" }
        return Text(label)
            .font(Theme.ui(12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 0.5))
            .fixedSize()
            .offset(x: previewOffsetX(for: sentence, width: width), y: -36)
            .transition(.opacity)
    }

    private func previewOffsetX(for sentence: Int, width: CGFloat) -> CGFloat {
        let fraction = sentenceCount > 1
            ? CGFloat(sentence) / CGFloat(sentenceCount - 1) : 0
        return min(max(fraction * width - 90, 4), max(width - 184, 4))
    }

    // MARK: - Readout

    private var readoutRow: some View {
        HStack {
            if playback.isPreparingVoice {
                Text("Preparing voice…")
                    .foregroundStyle(Theme.textMuted)
            } else {
                // Tap toggles percent ↔ "page 12 of 218" (multi-page docs).
                Button { showPageReadout.toggle() } label: {
                    Text(progressReadout)
                        .font(Theme.ui(11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Progress readout")
            }
            Spacer()
            if let remaining = timeRemaining {
                Text(remaining)
            }
        }
        .font(Theme.ui(11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.textFaint)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reader.sentence")
        .accessibilityValue("\(max(playback.currentSentence, 0))")
    }

    // MARK: - Transport

    private var transportRow: some View {
        HStack(spacing: 0) {
            chip(icon: "waveform", label: voiceShortName) { showVoiceSheet = true }
                .accessibilityLabel("Voice, \(playback.voice.name)")
                .accessibilityIdentifier("player.voice")
            Spacer()

            Button { step(-1) } label: {
                Image(systemName: "backward.fill")
                    .font(Theme.ui(19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous sentence")
            .accessibilityIdentifier("player.previous")

            playButton
                .padding(.horizontal, 14)

            Button { step(1) } label: {
                Image(systemName: "forward.fill")
                    .font(Theme.ui(19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next sentence")
            .accessibilityIdentifier("player.next")

            Spacer()
            chip(label: rateLabel) { showSpeedSheet = true }
                .accessibilityLabel("Speed, \(rateLabel)")
                .accessibilityIdentifier("player.speed")
        }
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                if isBuffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.bg)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(Theme.ui(22, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .offset(x: isPlaying ? 0 : 1.5)
                }
            }
        }
        .buttonStyle(AccentCircleButtonStyle(diameter: 54))
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("player.play")
        .accessibilityValue(isPlaying ? "playing" : (isBuffering ? "buffering" : "paused"))
    }

    private func chip(icon: String? = nil, label: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(Theme.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(label)
                    .font(Theme.ui(13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    // MARK: - State helpers

    private var sentenceCount: Int { max(content.sentences.count, 1) }

    /// Page display normalizes through the shared rule (0-based legacy caches
    /// display from 1) so this readout, the reader's page marks, the chapter
    /// drawer and search results all name the same page identically.
    private var pageOffset: Int { content.pageOffset }

    private var isPlaying: Bool {
        if case .playing = playback.status { return true }
        return false
    }

    private var isBuffering: Bool {
        if case .buffering = playback.status { return true }
        return false
    }

    private var liveFraction: Double {
        sentenceCount > 1
            ? Double(min(max(playback.currentSentence, 0), sentenceCount - 1))
                / Double(sentenceCount - 1)
            : 1
    }

    private var displayedFraction: Double {
        guard let sentence = dragSentence, sentenceCount > 1 else { return liveFraction }
        return Double(sentence) / Double(sentenceCount - 1)
    }

    private var displayedPercent: Int {
        Int((displayedFraction * 100).rounded())
    }

    /// Percent by default; page-of-pages after a tap (multi-page docs only).
    private var progressReadout: String {
        if showPageReadout, content.pageCount > 1 {
            let sentence = dragSentence ?? max(playback.currentSentence, 0)
            let page = content.sentences.indices.contains(sentence)
                ? content.sentences[sentence].page + pageOffset : 1
            return "page \(page) of \(content.pageCount)"
        }
        return "\(displayedPercent)%"
    }

    private var timeRemaining: String? {
        guard document.wordCount > 0, playback.rate > 0 else { return nil }
        let total = Double(document.wordCount)
            / (LibraryDocument.spokenWordsPerMinute * playback.rate) * 60
        return Self.timeLeftLabel(seconds: total * (1 - displayedFraction))
    }

    private var voiceShortName: String {
        playback.voice.name.components(separatedBy: " ").first ?? playback.voice.name
    }

    private var rateLabel: String {
        let value = (playback.rate * 100).rounded() / 100
        return value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func timeLeftLabel(seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "Under a min left" }
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60) h \(minutes % 60) min left"
    }

    // MARK: - Actions

    private func togglePlayback() {
        TransportHaptics.tap()
        switch playback.status {
        case .playing, .buffering:
            playback.pause()
        case .ended:
            playback.seek(to: 0, andPlay: true)
        default:
            playback.play()
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(playback.currentSentence + delta, 0), sentenceCount - 1)
        guard target != playback.currentSentence else { return }
        TransportHaptics.tap()
        // Buffering counts as intent to play: stepping mid-buffer keeps going.
        playback.seek(to: target, andPlay: playback.isActive)
    }

    private func sentenceIndex(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        let fraction = min(max(x / width, 0), 1)
        return Int((fraction * Double(sentenceCount - 1)).rounded())
    }
}

// The voice picker sheet lives in Settings/VoicePickerView.swift
// (`VoicePickerSheet`); the speed sheet in Settings/SpeedSheet.swift.
