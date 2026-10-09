import AVFoundation
import SwiftUI

/// The Listening view's copy, one place for the sheet and the Settings page.
enum ListeningCopy {
    static let title = "Voice & speed"
    static let naturalVoicesHeader = "Natural voices"
    /// R4-25: the eyebrow over the System row, below the natural voices:
    /// where that voice comes from, the device's own (never a second
    /// name for the row's title).
    static let systemVoiceHeader = "This \(DeviceNoun.device)"
    /// R4-25: the eyebrow over the bracketed-asides switch. Never the Aa
    /// sheet's own section name, which heads a different switch.
    static let readingAloudHeader = "Reading aloud"
    static let readAsidesTitle = "Read bracketed asides"
    static let readAsidesSubtitle = "Text in ( ), [ ] and { } is skipped unless this is on"
    /// The speed track's accessibility label.
    static let speed = "Speed"
    static let preparingVoice = "Preparing voice\u{2026}"
    static let hintSentence = "Reads the current sentence in this voice"
    static let hintSample = "Reads a sample in this voice"

    /// F073: a blend speaking as its stand-in speaker for the session (its
    /// voices file couldn't be built). The row stays, and says so.
    static func blendStandIn(speaker: String) -> String {
        "speaking as \(speaker) for now"
    }

    /// F095: the System voice only standing in for the natural voice picked
    /// (while the device cools, or after the natural voice failed), so a
    /// pick of it, which changes nothing, has its reason in view.
    static func systemStandIn(for voiceName: String) -> String {
        "standing in for \(voiceName)"
    }

    /// A row's subtitle with its stand-in note, if any:
    /// "Low, smooth narrator · speaking as Michael for now".
    static func subtitle(_ described: String, note: String?) -> String {
        [described, note ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// A speed in words (R4-23): ListeningFormat's number, minus its ×,
    /// which is a sign, not a word. The speed track's value, said after its
    /// label, and the Settings row's.
    static func spokenTimes(_ rate: Double) -> String {
        String(ListeningFormat.rate(rate).dropLast()) + " times"
    }

    /// A preset's spoken name, "1.25 times speed". "1.25×" is a numeral and
    /// a sign, not words (the element-description audit flags it), so the
    /// button shows it but says this.
    static func spokenRate(_ rate: Double) -> String {
        spokenTimes(rate) + " speed"
    }

    /// R4-26: a natural voice's region as VoiceOver says it, an accent
    /// where the row draws its two letters. Any other region is its English
    /// name, never the device locale's: the copy is English.
    static func accent(forRegion region: String) -> String {
        switch region.uppercased() {
        case "US": return "American"
        case "GB": return "British"
        default: return Locale(identifier: "en_US").localizedString(forRegionCode: region) ?? region
        }
    }
}

/// R8: speed and voice in one place. Five presets and a 0.5–3× speed track
/// with a 1× detent, its live rate beside it (the numeral above the presets
/// at the accessibility sizes) (`ListeningSpeedControls`); the eleven
/// natural voices (eight stock, three Aloud blends) plus System; Read
/// bracketed asides; and the natural-voice card (or its one unsupported
/// line) (`ListeningVoiceList`). Every pick is app-wide (R7) and heard where
/// it is made: a voice tap re-speaks the current sentence, or a sample line
/// with no book, through the playback graph — there is no second audio
/// path. The System row names the voice it resolves to (M10, P035). Where
/// better System voices come from is a link to System Settings on the Mac
/// and, below a premium voice, a plain line on the iPhone, which has no
/// link to that pane.
///
/// With `pinsSpeed` the speed controls stay put above a hairline and only
/// the voice list scrolls, so the speed is in view whichever voice is
/// picked; at the accessibility sizes everything scrolls as one, because
/// the two-column presets and the scaled numeral would leave the list no
/// room. This view is the one container either way: it resolves the System
/// voice and, as it goes, keeps the speed heard and releases the natural
/// voice, once.
///
/// The reader presents it in `ListeningSheet`; Settings pushes it as
/// `ListeningSettingsPage`.
struct ListeningView: View {

    private let showsInstalledModel: Bool
    /// The speed controls pinned above the scrolling voice list (below the
    /// accessibility sizes).
    private let pinsSpeed: Bool
    /// Every speed preset edged, not only the selected one: on the Settings
    /// page's bgTint an unselected chip's surface2 fill is too close to the
    /// ground to read as a chip, in either appearance.
    private let edgesUnselectedChips: Bool
    /// The scrolling list's natural height, for a content-sized container
    /// (the Mac's popover and Settings tab; the iPhone's sheet opens at a
    /// fixed fraction and passes none). Pinned, the speed block isn't in it.
    private let onContentHeight: ((CGFloat) -> Void)?
    /// The pinned speed block's height, with its hairline: what a
    /// content-sized container sets above the list.
    private let onPinnedHeight: ((CGFloat) -> Void)?

    init(showsInstalledModel: Bool = false, pinsSpeed: Bool = false,
         edgesUnselectedChips: Bool = false,
         onContentHeight: ((CGFloat) -> Void)? = nil, onPinnedHeight: ((CGFloat) -> Void)? = nil) {
        self.showsInstalledModel = showsInstalledModel
        self.pinsSpeed = pinsSpeed
        self.edgesUnselectedChips = edgesUnselectedChips
        self.onContentHeight = onContentHeight
        self.onPinnedHeight = onPinnedHeight
    }

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The System row's resolved voice, its name with its tier: read on
    /// appear and whenever System Settings adds or removes a voice, never
    /// per render (the installed-voice list is slow to read).
    @State private var systemVoiceName: String?
    /// That voice's tier, read with it: below premium, the iPhone says
    /// where better voices come from.
    @State private var systemVoiceQuality: AVSpeechSynthesisVoiceQuality?

    /// Whether the speed stays pinned: asked for, and below the
    /// accessibility sizes.
    nonisolated static func pinsSpeed(_ requested: Bool, dynamicTypeSize: DynamicTypeSize) -> Bool {
        requested && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        layout
            // Before the first frame, so the row never flashes its old subtitle.
            .onAppear { resolveSystemVoiceName() }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechEngine.installedVoicesDidChange)
                .receive(on: RunLoop.main)) { _ in
                resolveSystemVoiceName()
            }
            .onDisappear {
                // A drag the sheet closed under never reached its release;
                // what was heard is what gets kept.
                if playback.rate != model.globalRate { playback.selectRate(playback.rate) }
                playback.releaseNeuralEngineIfUnused()
            }
    }

    @ViewBuilder
    private var layout: some View {
        if Self.pinsSpeed(pinsSpeed, dynamicTypeSize: dynamicTypeSize) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ListeningSpeedControls(edgesUnselectedChips: edgesUnselectedChips)
                    ListeningHairline()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onPinnedHeight?(height)
                }
                list(withSpeed: false)
            }
        } else {
            list(withSpeed: true)
        }
    }

    /// The scrolling part, opened at the selected voice.
    private func list(withSpeed: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if withSpeed {
                        ListeningSpeedControls(edgesUnselectedChips: edgesUnselectedChips)
                        ListeningHairline()
                    }
                    ListeningVoiceList(showsInstalledModel: showsInstalledModel,
                                       systemVoiceName: systemVoiceName,
                                       systemVoiceQuality: systemVoiceQuality)
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
                // already on screen leaves what is above it in view.
                await Task.yield()
                proxy.scrollTo(playback.voice.id)
            }
        }
    }

    /// The System row's subtitle names its voice where the platform does,
    /// once resolved; until then, and with no voice to name, it keeps
    /// `DeviceCopy.systemVoiceFallback`.
    private func resolveSystemVoiceName() {
        guard PlatformVoiceSetup.namesResolvedSystemVoice else { return }
        let language = playback.systemVoiceLanguage
        let name = AVSpeechEngine.resolvedVoiceDisplayName(reading: language)
        if name != systemVoiceName { systemVoiceName = name }
        let quality = AVSpeechEngine.resolvedVoiceQuality(reading: language)
        if quality != systemVoiceQuality { systemVoiceQuality = quality }
    }

    // MARK: - Rules

    /// The hint shows where the platform has one and the System voice in
    /// use is below premium, or none is installed to name.
    nonisolated static func showsSystemVoicesHint(_ hint: String?,
                                                  quality: AVSpeechSynthesisVoiceQuality?) -> Bool {
        guard hint != nil else { return false }
        guard let quality else { return true }
        return quality.rawValue < AVSpeechSynthesisVoiceQuality.premium.rawValue
    }

    /// What a row says when its voice isn't what it names: a blend while
    /// the blends couldn't load speaks as its fallback speaker (F073), and
    /// the System voice in use while a natural voice is the stored pick
    /// (`preferred`) only stands in for it (F095). Nil otherwise.
    nonisolated static func standInNote(for voice: TtsVoice, blendsAvailable: Bool?,
                                        standingInFor preferred: TtsVoice?) -> String? {
        if blendsAvailable == false, let blend = KokoroVoiceBlends.blend(forVoiceID: voice.id) {
            let speakerID = KokoroVoiceCatalog.voiceIDPrefix + blend.fallbackSpeaker
            let speaker = KokoroVoiceCatalog.curatedVoices.first { $0.id == speakerID }?.name
                ?? KokoroVoiceCatalog.defaultVoice.name
            return ListeningCopy.blendStandIn(speaker: speaker)
        }
        if voice.engine != .kokoro, let preferred, preferred.engine == .kokoro {
            return ListeningCopy.systemStandIn(for: preferred.name)
        }
        return nil
    }

    /// "en-US" + "male" → "US · male" for the natural voices; the System
    /// voice has no origin to show.
    static func origin(for voice: TtsVoice) -> String {
        guard voice.engine == .kokoro else { return "" }
        let region = Self.region(of: voice)
        return voice.gender.isEmpty ? region : "\(region) · \(voice.gender)"
    }

    /// The origin as VoiceOver says it (R4-26): "en-GB" + "female" says an
    /// accent and the gender, where the row draws "GB · female", which
    /// VoiceOver would spell out letter by letter. Empty for the System
    /// voice.
    nonisolated static func spokenOrigin(for voice: TtsVoice) -> String {
        guard voice.engine == .kokoro else { return "" }
        let accent = ListeningCopy.accent(forRegion: region(of: voice))
        return voice.gender.isEmpty ? accent : "\(accent), \(voice.gender)"
    }

    /// "en-GB" → "GB".
    nonisolated private static func region(of voice: TtsVoice) -> String {
        voice.lang.split(separator: "-").last.map(String.init) ?? voice.lang
    }

    /// Starts with the visible name and subtitle, then the origin in words:
    /// the System row says its resolved voice after its own name. A
    /// subtitle that opens with the drawn origin (a voice with no
    /// description of its own) says the spoken origin there instead, once.
    nonisolated static func accessibilityLabel(name: String, subtitle: String, origin: String,
                                               spokenOrigin: String) -> String {
        let showsOrigin = !origin.isEmpty && subtitle.hasPrefix(origin)
        let said = showsOrigin ? spokenOrigin + String(subtitle.dropFirst(origin.count)) : subtitle
        // A stand-in note's middle dot is read aloud as a word otherwise.
        let spokenSubtitle = said.replacingOccurrences(of: " · ", with: ", ")
        return [name, spokenSubtitle, showsOrigin ? "" : spokenOrigin]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Speed

/// The five presets and the 0.5–3× speed track with its 1× detent (R8):
/// pinned above the voice list, or the list's first section at the
/// accessibility sizes. Below those sizes the live rate reads on the
/// track's own row; at them the large numeral above the presets reads it
/// instead (R3-10, a deliberate change from R8's numeral at every size).
struct ListeningSpeedControls: View {

    /// The unselected presets edged too (`ListeningView(edgesUnselectedChips:)`).
    var edgesUnselectedChips = false

    @EnvironmentObject private var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The speed before the drag in progress moved it; nil with no drag.
    /// Taken at the drag's first frame, cleared by its release or cancel,
    /// which persists the pick (`releaseSpeed`).
    @State private var speedDragStart: Double?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            if Self.showsNumeral(at: dynamicTypeSize) {
                Text(ListeningFormat.rate(playback.rate))
                    .font(Theme.font(.numeral))
                    .foregroundStyle(Theme.text)
                    .numericReadout(playback.rate)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)   // the slider speaks the same value
            }

            presets

            if Self.showsNumeral(at: dynamicTypeSize) {
                speedTrack
            } else {
                // The rate on the track's own row: no numeral repeating the
                // selected preset above, and a voice row more in view.
                HStack(spacing: Theme.Space.sm) {
                    speedTrack
                    SpeedReadout(rate: playback.rate)
                }
            }
        }
        .padding(.horizontal, Theme.Space.sheetGutter)
        .padding(.top, Theme.Space.xs)
        // A small gap to the hairline: pinned, every point here is one the
        // voice list doesn't get.
        .padding(.bottom, Theme.Space.sm)
    }

    /// The large numeral reads the rate only at the accessibility sizes,
    /// where the view scrolls and the presets stand in two columns; below
    /// them the readout beside the track does (R3-10).
    nonisolated static func showsNumeral(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    /// Whether an unselected preset carries the border: where the caller
    /// asks (Settings' bgTint, R2-18), and on every surface under Increase
    /// Contrast (R3-11), where a surface2 chip on surface is otherwise
    /// about 1.1:1 and the line token darkens to 3:1 or better.
    nonisolated static func edgesUnselected(asked: Bool, contrast: ColorSchemeContrast) -> Bool {
        asked || contrast == .increased
    }

    // MARK: Track

    /// The speed track (R3-09): the scrub's warm track and accent thumb in
    /// a 44pt row, never the stock slider's glass thumb. A sideways drag
    /// moves the speed live (the audio follows) and ticks once on arriving
    /// at 1×; the release is the one persisted pick. A drag more downward
    /// than sideways is never the track's: it scrolls the list or moves the
    /// sheet. On the Mac a click sets the speed. To assistive tech and UI
    /// automation it is a slider with the speed as its value. The platform
    /// takes the touches and gives the element (`speedTrackInput`).
    private var speedTrack: some View {
        WarmTrack(fraction: SpeedTrack.fraction(of: playback.rate),
                  isHeld: speedDragStart != nil,
                  reduceMotion: reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A full 44pt touch row around the 4pt line.
            .frame(height: 44)
            .speedTrackInput(SpeedTrackInput(rate: playback.rate,
                                             range: SpeedScale.range,
                                             label: ListeningCopy.speed,
                                             identifier: "listening.speed.slider",
                                             spokenValue: ListeningCopy.spokenTimes,
                                             onDrag: dragSpeed,
                                             onRelease: releaseSpeed,
                                             onStep: stepSpeed,
                                             onSet: setSpeed))
    }

    /// The scrub's drag on the speed scale: snapped to 0.05 with the 1×
    /// detent, ticking once on arriving at 1×, live and not yet persisted.
    /// One that began on the thumb carries it; one elsewhere takes the rate
    /// under the finger (`SpeedTrack.rate(startX:x:startRate:width:)`).
    private func dragSpeed(startX: CGFloat, x: CGFloat, width: CGFloat) {
        let start = speedDragStart ?? playback.rate
        if speedDragStart == nil { speedDragStart = start }
        let target = SpeedTrack.rate(startX: startX, x: x, startRate: start, width: width)
        guard target != playback.rate else { return }
        if SpeedScale.landsOnDetent(from: playback.rate, to: target) {
            TransportHaptics.emit(.detent)
        }
        playback.rate = target
    }

    /// Lifted or cancelled: a drag that moved the speed persists it, as the
    /// stock slider's end of editing did.
    private func releaseSpeed() {
        guard speedDragStart != nil else { return }
        speedDragStart = nil
        playback.selectRate(playback.rate)
    }

    /// An adjustable step (VoiceOver's swipe): one 0.05 step, snapped, its
    /// own pick. Returns the speed it lands on.
    private func stepSpeed(_ increment: Bool) -> Double {
        let delta = increment ? SpeedScale.step : -SpeedScale.step
        let target = SpeedScale.snap(playback.rate + delta)
        if SpeedScale.landsOnDetent(from: playback.rate, to: target) {
            TransportHaptics.emit(.detent)
        }
        playback.selectRate(target)
        return target
    }

    /// An assistive write has no drag to end: it is its own pick.
    private func setSpeed(_ raw: Double) {
        let snapped = SpeedScale.snap(raw)
        if SpeedScale.landsOnDetent(from: playback.rate, to: snapped) {
            TransportHaptics.emit(.detent)
        }
        playback.selectRate(snapped)
    }

    // MARK: Presets

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

    /// Selected reads four ways: accentStrong semibold on accentSoft, its
    /// edge (`Theme.Stroke.selected*`), and the `.isSelected` trait. The
    /// tint is drawn over surface2, the others' fill, on every surface, as
    /// the Appearance segment's is over its track (R4-24): over surface
    /// alone it was a shade from an unselected chip (about 1.03:1 in light).
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
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                // The selected edge, so the selection is never a tint alone;
                // where asked or under Increase Contrast, a border on the
                // others, so each reads as a chip.
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Theme.Stroke.selectedColor
                                           : (Self.edgesUnselected(asked: edgesUnselectedChips, contrast: contrast)
                                                ? Theme.Stroke.borderColor : Color.clear),
                                  lineWidth: selected ? Theme.Stroke.selectedWidth : Theme.Stroke.borderWidth))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ListeningCopy.spokenRate(preset))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("listening.preset.\(ListeningFormat.identifierNumber(preset))")
    }
}

/// The live rate beside the speed track below the accessibility sizes
/// (R3-10): callout with monospaced digits, trailing, in the widest rate's
/// width, so the track beside it never resizes under a finger as the rate
/// gains digits. Hidden from VoiceOver: the slider speaks the same value.
struct SpeedReadout: View {

    let rate: Double

    /// A three-digit rate: as wide as any the scale holds, the digits being
    /// monospaced.
    static let widestRate = 2.75

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(ListeningFormat.rate(Self.widestRate))
                .font(Theme.font(.callout))
                .monospacedDigit()
                .hidden()
            Text(ListeningFormat.rate(rate))
                .font(Theme.font(.callout))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .numericReadout(rate)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// The speed track's rules (R3-09), pure so tests read them without a
/// view: where a rate sits on the track, which rate a drag lands on, and
/// whether a drag is the track's at all.
enum SpeedTrack {

    /// Half the 44pt target: a touch this near the thumb's centre grabs it.
    static let grabRadius: CGFloat = 22

    private static var span: Double { SpeedScale.range.upperBound - SpeedScale.range.lowerBound }

    /// Where `rate` sits along the track, 0...1.
    static func fraction(of rate: Double) -> Double {
        guard rate.isFinite else { return 0 }
        return min(max((rate - SpeedScale.range.lowerBound) / span, 0), 1)
    }

    /// The rate under `x` on a track `width` wide, as the scrub maps x to
    /// a sentence: clamped to the scale, snapped to 0.05, the 1× detent
    /// magnetic.
    static func rate(atX x: CGFloat, width: CGFloat) -> Double {
        SpeedScale.snap(SpeedScale.range.lowerBound + ScrubGesture.fraction(atX: x, width: width) * span)
    }

    /// The rate a drag lands on. One that began on the thumb carries it by
    /// the finger's travel, so the thumb keeps its place under the finger
    /// and never jumps at the first frame; one that began elsewhere on the
    /// track takes the rate under the finger, as the scrub does.
    static func rate(startX: CGFloat, x: CGFloat, startRate: Double, width: CGFloat) -> Double {
        guard width > 0 else { return SpeedScale.snap(startRate) }
        let thumb = WarmTrack.thumbCentre(fraction: fraction(of: startRate), width: width)
        guard abs(startX - thumb) <= grabRadius else { return rate(atX: x, width: width) }
        return SpeedScale.snap(startRate + Double((x - startX) / width) * span)
    }

    /// Whether a drag is the track's, decided once, at the travel where it
    /// becomes a drag: more sideways than down. A drag straight down or on
    /// the diagonal is the sheet's or the list's, so one that crosses the
    /// row, or drifts sideways later, never moves the speed. (The Mac's
    /// pointer needs no such rule: a click there sets the speed.)
    static func beginsSideways(_ travel: CGSize) -> Bool {
        abs(travel.width) > abs(travel.height)
    }
}

// MARK: - Voices

/// The voices (the natural ones under their eyebrow, then System with its
/// hint or link), Read bracketed asides, and the natural-voice card: the
/// part of the view that scrolls.
struct ListeningVoiceList: View {

    let showsInstalledModel: Bool
    let systemVoiceName: String?
    let systemVoiceQuality: AVSpeechSynthesisVoiceQuality?

    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var modelManager: ModelManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    /// A fixed-width, trailing-aligned origin column: subtitles wrap at one
    /// width row to row, and the origin sits on the gutter, as the Classics
    /// lengths do.
    @ScaledMetric(relativeTo: .caption) private var originColumnWidth: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            voiceSection
            eyebrow(ListeningCopy.readingAloudHeader)
            PreferenceToggleRow(title: ListeningCopy.readAsidesTitle,
                                subtitle: ListeningCopy.readAsidesSubtitle,
                                isOn: readAsides)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.vertical, Theme.Space.sm)
                .accessibilityIdentifier("listening.readAsides")
            footer
        }
    }

    /// The natural voices under their eyebrow, then the System row: under
    /// an eyebrow of its own where the natural voices show (R4-25), so the
    /// headings rotor reaches both groups; alone, it needs none.
    @ViewBuilder
    private var voiceSection: some View {
        if model.neuralVoiceOffered, modelManager.isInstalled {
            eyebrow(ListeningCopy.naturalVoicesHeader)
            ForEach(model.kokoroEngine.voices) { voiceRow($0) }
            eyebrow(ListeningCopy.systemVoiceHeader)
        }
        // The single System row, always offered as the fallback.
        ForEach(model.engine.voices) { voiceRow($0) }
        systemVoicesHint
        addSystemVoices
    }

    /// A section's eyebrow (R4-25): capitals drawn, its words spoken as
    /// written, and a heading for the rotor.
    private func eyebrow(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(.eyebrow))
            .eyebrowTracking()
            .textCase(.uppercase)
            .accessibilityLabel(Text(title))
            .foregroundStyle(Theme.textMuted)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xs)
    }

    /// iPhone only: a muted line under the System row naming where better
    /// System voices download, while the one it speaks in isn't premium.
    /// Plain text, never a link (iOS has no public link to that pane); it
    /// wraps at every size.
    @ViewBuilder
    private var systemVoicesHint: some View {
        if let hint = DeviceCopy.systemVoicesHint,
           ListeningView.showsSystemVoicesHint(hint, quality: systemVoiceQuality) {
            Text(hint)
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.sheetGutter)
                .padding(.bottom, Theme.Space.sm)
                .accessibilityIdentifier("listening.systemVoicesHint")
        }
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

    /// One whole-row button: a tap selects and speaks, and the sheet stays
    /// open so voices can be compared. Selection is a 3pt accentStrong bar,
    /// flush and full height as on Contents' rows, a semibold name and
    /// `.isSelected`, never color alone.
    private func voiceRow(_ voice: TtsVoice) -> some View {
        let selected = voice.id == playback.voice.id
        let origin = ListeningView.origin(for: voice)
        let spokenOrigin = ListeningView.spokenOrigin(for: voice)
        let resolvedName = voice.id == AVSpeechEngine.systemVoiceID ? systemVoiceName : nil
        // Read only for the System row in use: the stored pick it may be
        // standing in for (AppModel's engaged preference).
        let preferred = selected && voice.engine != .kokoro ? model.thermalGuard.preferredVoice() : nil
        let note = ListeningView.standInNote(for: voice,
                                             blendsAvailable: model.kokoroEngine.blendsAvailable,
                                             standingInFor: preferred)
        let subtitle = selected && playback.isPreparingVoice
            ? ListeningCopy.preparingVoice
            : ListeningCopy.subtitle(resolvedName ?? (voice.subtitle.isEmpty ? origin : voice.subtitle),
                                     note: note)
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
                        .frame(width: originColumnWidth, alignment: .trailing)
                }
            }
            .padding(.horizontal, Theme.Space.sheetGutter)
            .padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.accentStrong)
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(voice.id)
        .accessibilityLabel(ListeningView.accessibilityLabel(name: voice.name, subtitle: subtitle, origin: origin,
                                                             spokenOrigin: spokenOrigin))
        .accessibilityHint(playback.content == nil ? ListeningCopy.hintSample : ListeningCopy.hintSentence)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("voice.\(voice.id)")
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
}

/// One pixel of the screen it is drawn on (`hairlineHeight()`): the Mac
/// draws this view in Settings and the Voice & Speed popover, on whichever
/// display holds the window, not the main one.
private struct ListeningHairline: View {

    var body: some View {
        Rectangle()
            .fill(Theme.Stroke.hairlineColor)
            .hairlineHeight()
    }
}

/// R7/R21: Settings' Voice & speed row pushes the same Listening view the
/// reader's chip presents, with the installed-model card, and with the
/// speed pinned above the voices as in the sheet. On the Settings root's
/// own ground, bgTint, so the paper doesn't change colour at the push
/// (P041); the reader's sheet stays on surface. A selected preset's tint
/// is drawn over surface2, the unselected chips' fill, here as on every
/// surface (R4-24), so its label clears AA on bgTint too.
struct ListeningSettingsPage: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ListeningView(showsInstalledModel: true, pinsSpeed: true, edgesUnselectedChips: true)
            .background(Theme.bgTint.ignoresSafeArea())
            // An opaque bar on the page's own ground, never a hard scroll
            // edge on a pushed screen (see `ShelfScrollEdge`).
            .shelfScrollEdge(ground: Theme.bgTint)
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
