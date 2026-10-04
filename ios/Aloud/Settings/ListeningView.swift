import SwiftUI

/// The Listening view's copy, one place for the sheet and the Settings page.
enum ListeningCopy {
    static let title = "Voice & speed"
    static let naturalVoicesHeader = "Natural voices"
    static let readAsidesTitle = "Read bracketed asides"
    static let readAsidesSubtitle = "Text in ( ), [ ] and { } is skipped unless this is on"
    static let preparingVoice = "Preparing voice\u{2026}"
    static let hintSentence = "Reads the current sentence in this voice"
    static let hintSample = "Reads a sample in this voice"

    /// A preset's spoken name, "1.25 times speed". "1.25×" is a numeral and
    /// a sign, not words (the element-description audit flags it), so the
    /// button shows it but says this. ListeningFormat's number, minus its ×.
    static func spokenRate(_ rate: Double) -> String {
        String(ListeningFormat.rate(rate).dropLast()) + " times speed"
    }
}

/// R8: speed and voice in one place. The speed numeral, five presets and a
/// 0.5–3× slider with a 1× detent; the eleven natural voices (eight stock,
/// three Aloud blends) plus System; Read
/// bracketed asides; and the natural-voice card (or its one unsupported
/// line). Every pick is app-wide (R7) and heard where it is made: a voice tap
/// re-speaks the current sentence, or a sample line with no book, through the
/// playback graph — there is no second audio path. On the Mac (M10) the
/// System row names the voice it resolves to, and a link opens System
/// Settings, where premium voices download before a flight.
///
/// The reader presents it in `ListeningSheet`; Settings pushes it as
/// `ListeningSettingsPage`.
struct ListeningView: View {

    private let showsInstalledModel: Bool
    /// The content's natural height, for the sheet's content-sized detent.
    private let onContentHeight: ((CGFloat) -> Void)?

    init(showsInstalledModel: Bool = false, onContentHeight: ((CGFloat) -> Void)? = nil) {
        self.showsInstalledModel = showsInstalledModel
        self.onContentHeight = onContentHeight
    }

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    /// The System row's resolved voice, "Ava (Premium)" (Mac only): read on
    /// appear and whenever System Settings adds or removes a voice, never
    /// per render (the installed-voice list is slow to read).
    @State private var systemVoiceName: String?

    /// Fixed-width origin column, so names and subtitles line up row to row.
    @ScaledMetric(relativeTo: .caption) private var originColumnWidth: CGFloat = 80

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    speedSection
                    hairline()
                    voiceSection
                    hairline()
                    PreferenceToggleRow(title: ListeningCopy.readAsidesTitle,
                                        subtitle: ListeningCopy.readAsidesSubtitle,
                                        isOn: readAsides)
                        .padding(.horizontal, Theme.Space.sheetGutter)
                        .padding(.vertical, Theme.Space.sm)
                        .accessibilityIdentifier("listening.readAsides")
                    footer
                }
                .padding(.bottom, Theme.Space.xl)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onContentHeight?(height)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .task {
                // After the first layout, or there is nothing to scroll to.
                // A nil anchor scrolls only as far as needed, so a voice
                // already on screen leaves the speed controls in view.
                await Task.yield()
                proxy.scrollTo(playback.voice.id)
            }
        }
        // Before the first frame, so the row never flashes its old subtitle.
        .onAppear { resolveSystemVoiceName() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechEngine.installedVoicesDidChange)
            .receive(on: RunLoop.main)) { _ in
            resolveSystemVoiceName()
        }
        .onDisappear {
            // A drag the sheet closed under never reached onEditingChanged;
            // what was heard is what gets kept.
            if playback.rate != model.globalRate { playback.selectRate(playback.rate) }
            playback.releaseNeuralEngineIfUnused()
        }
    }

    // MARK: - Speed

    private var speedSection: some View {
        VStack(spacing: Theme.Space.md) {
            Text(ListeningFormat.rate(playback.rate))
                .font(Theme.font(.numeral))
                .foregroundStyle(Theme.text)
                .numericReadout(playback.rate)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)   // the slider speaks the same value

            presets

            Slider(value: Binding(get: { playback.rate },
                                  set: { raw in
                                      let snapped = SpeedScale.snap(raw)
                                      if SpeedScale.landsOnDetent(from: playback.rate, to: snapped) {
                                          TransportHaptics.emit(.detent)
                                      }
                                      playback.rate = snapped
                                  }),
                   in: SpeedScale.range,
                   onEditingChanged: { editing in
                       // The drag moves the audio live; the release is the
                       // one persisted pick.
                       if !editing { playback.selectRate(playback.rate) }
                   })
                // No step: a stepped slider can't hold the 1× detent.
                .tint(Theme.accent)
                .frame(minHeight: 44)
                .accessibilityLabel("Speed")
                .accessibilityValue(ListeningFormat.rate(playback.rate))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? SpeedScale.step : -SpeedScale.step
                    let target = SpeedScale.snap(playback.rate + delta)
                    if SpeedScale.landsOnDetent(from: playback.rate, to: target) {
                        TransportHaptics.emit(.detent)
                    }
                    playback.selectRate(target)
                }
                .accessibilityIdentifier("listening.speed.slider")
        }
        .padding(.horizontal, Theme.Space.sheetGutter)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.lg)
    }

    /// One row of five, or two columns at accessibility sizes so "1.25×"
    /// never wraps inside its button.
    @ViewBuilder
    private var presets: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.xs), count: 2),
                      spacing: Theme.Space.xs) {
                ForEach(SpeedScale.presets, id: \.self) { presetButton($0) }
            }
        } else {
            HStack(spacing: Theme.Space.xs) {
                ForEach(SpeedScale.presets, id: \.self) { presetButton($0) }
            }
        }
    }

    /// Selected reads three ways: accentStrong semibold on accentSoft, and
    /// the `.isSelected` trait.
    private func presetButton(_ preset: Double) -> some View {
        let selected = SpeedScale.isSelected(preset, at: playback.rate)
        return Button {
            // A re-tap of the selected preset changes nothing, so it is silent.
            if !SpeedScale.isSelected(preset, at: playback.rate) { TransportHaptics.emit(.preset) }
            playback.selectRate(preset)
        } label: {
            Text(ListeningFormat.rate(preset))
                .font(Theme.font(.callout).weight(selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.accentStrong : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ListeningCopy.spokenRate(preset))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("listening.preset.\(ListeningFormat.identifierNumber(preset))")
    }

    // MARK: - Voices

    @ViewBuilder
    private var voiceSection: some View {
        if model.neuralVoiceOffered, modelManager.isInstalled {
            Text(ListeningCopy.naturalVoicesHeader)
                .font(Theme.font(.eyebrow))
                .eyebrowTracking()
                .foregroundStyle(Theme.textFaint)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.top, Theme.Space.lg)
                .padding(.bottom, Theme.Space.xs)
            ForEach(model.kokoroEngine.voices) { voiceRow($0) }
            hairline(inset: Theme.Space.sheetGutter)
        }
        // The single System row, always offered as the fallback.
        ForEach(model.engine.voices) { voiceRow($0) }
        addSystemVoices
    }

    /// Mac only: opens Spoken Content, where premium System voices download
    /// before a flight. The pane opens in System Settings; nothing here
    /// speaks. A pointer's link, so the Mac's 28 pt floor with room rather
    /// than a touch row's 44: the card's Download stays above the fold.
    @ViewBuilder
    private var addSystemVoices: some View {
        if let title = DeviceCopy.addSystemVoices, let url = PlatformVoiceSetup.addVoicesURL {
            Button {
                openURL(url)
            } label: {
                Text(title)
                    .font(Theme.font(.callout).weight(.medium))
                    .foregroundStyle(Theme.accentStrong)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityIdentifier("listening.addVoices")
        }
    }

    /// The System row's subtitle names its voice where the platform does,
    /// once resolved; the iPhone keeps "Built-in fallback".
    private func resolveSystemVoiceName() {
        guard PlatformVoiceSetup.namesResolvedSystemVoice else { return }
        let name = AVSpeechEngine.resolvedVoiceDisplayName()
        if name != systemVoiceName { systemVoiceName = name }
    }

    /// One whole-row button: a tap selects and speaks, and the sheet stays
    /// open so voices can be compared. Selection is a 3pt bar, a semibold
    /// name and `.isSelected`, never color alone.
    private func voiceRow(_ voice: TtsVoice) -> some View {
        let selected = voice.id == playback.voice.id
        let origin = Self.origin(for: voice)
        let resolvedName = voice.id == AVSpeechEngine.systemVoiceID ? systemVoiceName : nil
        let subtitle = selected && playback.isPreparingVoice
            ? ListeningCopy.preparingVoice
            : (resolvedName ?? (voice.subtitle.isEmpty ? origin : voice.subtitle))
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        return Button {
            playback.selectVoice(voice)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                // Each line wraps to its full height, never truncates, however
                // the sheet's height moves under it.
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(voice.name)
                        .font(Theme.font(.body).weight(selected ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    // At accessibility sizes the origin joins the text column
                    // rather than squeezing it from a trailing one.
                    if isAccessibilitySize, !origin.isEmpty {
                        Text(origin)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.xs)
                if !isAccessibilitySize {
                    Text(origin)
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .frame(width: originColumnWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, Theme.Space.xs)
                        .padding(.leading, Theme.Space.xs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(voice.id)
        .accessibilityLabel(Self.accessibilityLabel(name: voice.name, subtitle: subtitle, origin: origin))
        .accessibilityHint(playback.content == nil ? ListeningCopy.hintSample : ListeningCopy.hintSentence)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("voice.\(voice.id)")
    }

    /// "en-US" + "male" → "US · male" for the natural voices; the System
    /// voice has no origin to show.
    private static func origin(for voice: TtsVoice) -> String {
        guard voice.engine == .kokoro else { return "" }
        let region = voice.lang.split(separator: "-").last.map(String.init) ?? voice.lang
        return voice.gender.isEmpty ? region : "\(region) · \(voice.gender)"
    }

    /// Starts with the visible name and subtitle: "Michael, Deep, warm
    /// narrator, US, male"; "System voice, Built-in fallback".
    private static func accessibilityLabel(name: String, subtitle: String, origin: String) -> String {
        // When the subtitle already is the origin, don't say it twice.
        let spokenOrigin = subtitle == origin ? "" : origin.replacingOccurrences(of: " · ", with: ", ")
        return [name, subtitle, spokenOrigin].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Read asides and footer

    /// Shown inverted: the stored `skipBrackets` value is never rewritten,
    /// and AppModel's sink persists the flip.
    private var readAsides: Binding<Bool> {
        Binding(get: { !playback.skipBrackets }, set: { playback.skipBrackets = !$0 })
    }

    /// The natural-voice card until the model is installed (Settings also
    /// shows it installed). On a device that can't run the natural voice it
    /// is a single bare line, so it carries no card.
    @ViewBuilder
    private var footer: some View {
        if !modelManager.isInstalled || showsInstalledModel {
            ModelDownloadView(showsInstalledState: showsInstalledModel,
                              showsCard: model.neuralVoiceOffered)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.top, Theme.Space.sm)
        }
    }

    // MARK: - Bits

    private func hairline(inset: CGFloat = 0) -> some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .frame(height: Theme.Stroke.hairlineWidth)
            .padding(.horizontal, inset)
    }
}

/// R7/R21: Settings' "Voice & speed" row pushes the same Listening view the
/// reader's chip presents, with the installed-model card.
struct ListeningSettingsPage: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ListeningView(showsInstalledModel: true)
            .background(Theme.surface.ignoresSafeArea())
            // An opaque bar on the page's own ground, never a hard scroll
            // edge on a pushed screen (see `ShelfScrollEdge`).
            .shelfScrollEdge(ground: Theme.surface)
            .inlineTitleOnPhone()
            // The bar's system content follows the app's scheme, not the
            // phone's (an in-app Dark override on a Light phone).
            .toolbarColorSchemeOnPhone(colorScheme)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(ListeningCopy.title)
                        .font(Theme.font(.headline))
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("listening.title")
                        // The bar caps its text size; long-press shows it large.
                        .largeContentViewerIfAvailable()
                }
            }
    }
}
