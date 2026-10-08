import SwiftUI

/// The Continue card's words (R11, R12f, R18), spoken and visible, kept
/// apart from the view so each rule is unit-tested.
enum ContinueListeningCopy {
    /// Drawn uppercased: CONTINUE LISTENING.
    static let eyebrow = "Continue listening"

    /// "Continue listening, The Great Gatsby, F. Scott Fitzgerald": the
    /// eyebrow first, so the name starts with the visible text.
    static func label(title: String, author: String?) -> String {
        var parts = [eyebrow, title]
        if let author, !author.isEmpty { parts.append(author) }
        return parts.joined(separator: ", ")
    }

    /// What Voice Control answers to: the title, as on a grid card, or the
    /// eyebrow. The label leads with the eyebrow, so "Tap The Great Gatsby"
    /// matched nothing (J017).
    static func inputLabels(title: String) -> [String] {
        [title, eyebrow]
    }

    /// A stopped reason outranks the natural-voice offer, which outranks the
    /// estimate: the card mirrors the chapter line's precedence. The offer
    /// reads the offer row's line, so after a failed space check the card
    /// says so instead of advertising the download that just failed (R21).
    /// Either replaces the whole line.
    ///
    /// Otherwise the author and the estimate, joined by a middle dot as the
    /// featured classic's line is, with either part left out when it is
    /// missing, so no dot ever dangles.
    static func subtitle(for document: LibraryDocument, rate: Double, stop: StopReason?,
                         offersNaturalVoice: Bool, modelState: ModelManager.ModelState,
                         spaceNeeded: Int64 = ModelManager.requiredFreeBytes) -> String {
        if let stop { return stop.text }
        if offersNaturalVoice { return NaturalVoiceCopy.offerLine(modelState: modelState, need: spaceNeeded) }
        var parts: [String] = []
        if let author = document.author, !author.isEmpty { parts.append(author) }
        let estimate = document.listeningSubtitle(rate: rate)
        if !estimate.isEmpty { parts.append(estimate) }
        return parts.joined(separator: " · ")
    }

    /// The same line as VoiceOver says it, without the author: the label
    /// already ends with it, and VoiceOver would say it twice.
    static func spokenSubtitle(for document: LibraryDocument, rate: Double, stop: StopReason?,
                               offersNaturalVoice: Bool, modelState: ModelManager.ModelState,
                               spaceNeeded: Int64 = ModelManager.requiredFreeBytes) -> String {
        if let stop { return stop.spokenText }
        if offersNaturalVoice {
            return NaturalVoiceCopy.spoken(NaturalVoiceCopy.offerLine(modelState: modelState, need: spaceNeeded))
        }
        return document.spokenListeningSubtitle(rate: rate)
    }

    /// Speaking means heard: the card says "playing" only when its circle
    /// does. A circle load or a buffer shows the Pause glyph too, but the
    /// voice is silent until the first clip lands.
    static func isSpeaking(_ state: PlayButtonState) -> Bool {
        state.glyph == .pause && state.value == playing.value
    }

    private static let playing = PlayButtonState(status: .playing, isPreparingVoice: false, reduceMotion: false)

    static func value(isSpeaking: Bool, spokenSubtitle: String) -> String {
        isSpeaking ? "playing, \(spokenSubtitle)" : spokenSubtitle
    }

    /// The body opens the reader. One already speaking just opens; otherwise
    /// the hint promises playback only when the reader will start it
    /// (`PlaybackController.opensPlaying`): a Finished book opens paused at
    /// its end, so, like its grid card, it promises nothing.
    static func hint(isSpeaking: Bool, opensPlaying: Bool) -> String {
        if isSpeaking { return "Opens the book" }
        return opensPlaying ? "Resumes playing" : ""
    }
}

/// The Continue Listening hero above the shelf grid, the one playback
/// surface outside the reader (R18): the card body opens the reader, and its
/// circle is a real 44pt button that plays and pauses in place. The circle
/// floats over a placeholder in the card's accessory slot, so no button sits
/// inside another and VoiceOver reaches each one on its own. `actions` are
/// its VoiceOver actions and `menu` its context menu: one list on the
/// iPhone, and on the Mac the grid cards' VoiceOver list beside the Mac's
/// menu (J018).
struct ContinueListeningCard<Actions: View, MenuItems: View>: View {
    private let document: LibraryDocument
    private let rate: Double
    private let playState: PlayButtonState
    private let stop: StopReason?
    private let offersNaturalVoice: Bool
    private let modelState: ModelManager.ModelState
    /// `ModelManager.spaceNeeded`, for the offer's too-little-space line.
    private let spaceNeeded: Int64
    private let opensPlaying: Bool
    private let onOpen: () -> Void
    private let onTogglePlayback: () -> Void
    private let actions: Actions
    private let menu: MenuItems

    init(document: LibraryDocument, rate: Double, playState: PlayButtonState, stop: StopReason?,
         offersNaturalVoice: Bool, modelState: ModelManager.ModelState,
         spaceNeeded: Int64 = ModelManager.requiredFreeBytes, opensPlaying: Bool,
         onOpen: @escaping () -> Void,
         onTogglePlayback: @escaping () -> Void, @ViewBuilder actions: () -> Actions,
         @ViewBuilder menu: () -> MenuItems) {
        self.document = document
        self.rate = rate
        self.playState = playState
        self.stop = stop
        self.offersNaturalVoice = offersNaturalVoice
        self.modelState = modelState
        self.spaceNeeded = spaceNeeded
        self.opensPlaying = opensPlaying
        self.onOpen = onOpen
        self.onTogglePlayback = onTogglePlayback
        self.actions = actions()
        self.menu = menu()
    }

    /// Where the shelf moves VoiceOver to after a Delete or a Mark as
    /// finished (`voiceOverFocus(_:)`); nil on the Mac, whose keyboard
    /// focus is its own.
    private var focus: AccessibilityFocusState<UUID?>.Binding?

    private var isSpeaking: Bool { ContinueListeningCopy.isSpeaking(playState) }

    /// The card's body takes VoiceOver focus when `binding` names this book.
    func voiceOverFocus(_ binding: AccessibilityFocusState<UUID?>.Binding) -> Self {
        var card = self
        card.focus = binding
        return card
    }

    var body: some View {
        Button(action: onOpen) {
            ShelfHeroCard(eyebrow: ContinueListeningCopy.eyebrow, title: document.title,
                          subtitle: ContinueListeningCopy.subtitle(for: document, rate: rate, stop: stop,
                                                                   offersNaturalVoice: offersNaturalVoice,
                                                                   modelState: modelState,
                                                                   spaceNeeded: spaceNeeded)) {
                DocumentCoverView(document: document)
            } accessory: {
                Color.clear
                    .frame(width: Theme.PlayCircle.compactDiameter, height: Theme.PlayCircle.compactDiameter)
                    .anchorPreference(key: CircleSlotKey.self, value: .bounds) { $0 }
            }
        }
        // The iPhone's paper plate under a finger, round the card's corners,
        // without the shrink: the circle is placed from outside the button
        // and would stay full size over a shrinking body. The Mac's own
        // hover plate.
        .shelfCardPressStyle(radius: Theme.Radius.lg, scales: false)
        // On the body alone: modifiers after the overlay would reach the circle too.
        .accessibilityLabel(ContinueListeningCopy.label(title: document.title, author: document.author))
        .accessibilityValue(ContinueListeningCopy.value(
            isSpeaking: isSpeaking,
            spokenSubtitle: ContinueListeningCopy.spokenSubtitle(for: document, rate: rate, stop: stop,
                                                                 offersNaturalVoice: offersNaturalVoice,
                                                                 modelState: modelState,
                                                                 spaceNeeded: spaceNeeded)))
        .accessibilityHint(ContinueListeningCopy.hint(isSpeaking: isSpeaking, opensPlaying: opensPlaying))
        .accessibilityInputLabels(ContinueListeningCopy.inputLabels(title: document.title))
        .accessibilityActions { actions }
        .accessibilityIdentifier("library.continue")
        .modifier(BodyFocus(focus: focus, id: document.id))
        .overlayPreferenceValue(CircleSlotKey.self) { slot in
            GeometryReader { proxy in
                if let slot {
                    let frame = proxy[slot]
                    circle.position(x: frame.midX, y: frame.midY)
                }
            }
        }
        // The hero is lifted out of the grid, so it carries the management
        // affordances its grid card would have given it. A long press lifts
        // the card by its own rounded corners.
        .contextMenuPreviewCorners(Theme.Radius.lg)
        .contextMenu { menu }
    }

    private var circle: some View {
        Button(action: onTogglePlayback) {
            PlayCircleFace(state: playState, diameter: Theme.PlayCircle.compactDiameter)
                // The glyph scales with the text, capped where it fits the circle.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .buttonStyle(AccentCircleButtonStyle(diameter: Theme.PlayCircle.compactDiameter))
        // Return on the focused circle plays or pauses in place, as Space
        // does; the Mac card's own Return opens the book (L015).
        .returnKeyActsOnMac(onTogglePlayback)
        .accessibilityLabel(playState.label)
        .accessibilityValue(playState.value)
        .accessibilityIdentifier("library.continue.play")
        .largeContentViewerIfAvailable {
            Label(playState.label, systemImage: playState.glyph.rawValue)
        }
    }
}

extension ContinueListeningCard where MenuItems == Actions {
    /// One list as both the VoiceOver actions and the context menu, as the
    /// iPhone's grid cards have.
    init(document: LibraryDocument, rate: Double, playState: PlayButtonState, stop: StopReason?,
         offersNaturalVoice: Bool, modelState: ModelManager.ModelState,
         spaceNeeded: Int64 = ModelManager.requiredFreeBytes, opensPlaying: Bool,
         onOpen: @escaping () -> Void,
         onTogglePlayback: @escaping () -> Void, @ViewBuilder actions: () -> Actions) {
        self.init(document: document, rate: rate, playState: playState, stop: stop,
                  offersNaturalVoice: offersNaturalVoice, modelState: modelState,
                  spaceNeeded: spaceNeeded, opensPlaying: opensPlaying, onOpen: onOpen,
                  onTogglePlayback: onTogglePlayback, actions: actions, menu: actions)
    }
}

/// VoiceOver focus on the card's body alone, never its circle, when the
/// shelf hands it one.
private struct BodyFocus: ViewModifier {
    let focus: AccessibilityFocusState<UUID?>.Binding?
    let id: UUID

    func body(content: Content) -> some View {
        if let focus {
            content.accessibilityFocused(focus, equals: id)
        } else {
            content
        }
    }
}

/// Where the card's accessory slot sits, so the circle can be laid over it.
private struct CircleSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Hero card shape

/// The shelf's one hero shape (cover, an eyebrow, serif title over a
/// subtitle, and a trailing accessory on a bordered surface), shared by the
/// Continue Listening card and the empty Library's featured classic, so the
/// first book a new listener taps looks like the card it becomes. Each
/// names what it is in its eyebrow (`ContinueListeningCopy.eyebrow`,
/// `FeaturedClassic.eyebrow`), drawn uppercased.
struct ShelfHeroCard<Cover: View, Accessory: View>: View {
    private let eyebrow: String?
    private let title: String
    private let subtitle: String
    private let cover: Cover
    private let accessory: Accessory

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(eyebrow: String? = nil, title: String, subtitle: String,
         @ViewBuilder cover: () -> Cover,
         @ViewBuilder accessory: () -> Accessory) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.cover = cover()
        self.accessory = accessory()
    }

    var body: some View {
        content
            .multilineTextAlignment(.leading)
            .padding(Theme.Space.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth)
            )
    }

    /// At the accessibility sizes the text gets the card's full width under
    /// the cover row: beside a 64pt cover and the circle it had a word or
    /// two per line.
    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .top) {
                    framedCover
                    Spacer(minLength: Theme.Space.md)
                    accessory
                }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    eyebrowText
                    titleText
                }
                subtitleText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: Theme.Space.md) {
                framedCover
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    eyebrowText
                    // fixedSize: inside a button label in a scroll view the
                    // stack was offered one line's height, so "The Cask of
                    // Amontillado" truncated despite its two-line limit.
                    // From xxLarge it wraps in full, as the grid card's does.
                    titleText.lineLimit(DocumentCardView.wrapsInFull(at: dynamicTypeSize) ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    // Wraps instead of truncating, at any length: the natural
                    // voice's space line ends on the space it needs, and
                    // beside the cover and circle on a narrow screen
                    // (Display Zoom) it runs to four or five lines.
                    subtitleText
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
        }
    }

    private var framedCover: some View {
        cover
            .frame(width: CoverGeometry.heroSize.width, height: CoverGeometry.heroSize.height)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var eyebrowText: some View {
        if let eyebrow {
            Text(eyebrow)
                .font(Theme.font(.eyebrow))
                .eyebrowTracking()
                .textCase(.uppercase)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleText: Text {
        Text(title)
            .font(Theme.font(.headline))
            .foregroundStyle(Theme.text)
    }

    private var subtitleText: Text {
        Text(subtitle)
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
    }
}

// MARK: - Play glyph

/// Decorative echo of AccentCircleButtonStyle for the featured classic: the
/// card around it is the button, so this stays a plain 44pt accent circle.
struct PlayCircleGlyph: View {
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "play.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.bg)
                    // Scales with the text, capped where it fits the circle.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            )
            .accessibilityHidden(true)
    }
}
