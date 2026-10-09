import SwiftUI

/// The chapter line, which is the reader's one message slot (R11).
///
/// With no message it shows where the listener is ("Chapter IV · 4 of 61 ·
/// 8 min left") and opens Contents. A message replaces it by the fixed
/// precedence in `ReaderMessage.resolve`. A stop stays until the next Play:
/// the error line retries on a tap, every other stop opens Contents, and a
/// sleep stop adds Back 5 min. Only a change of slot crossfades, so
/// time-left and download ticks never animate the line. Every arm is
/// reader.chapterLine (the offer row carries its own identifiers), and each
/// label starts with the visible text. On the Mac its type follows the
/// reader's chrome band (M18), and in the Largest band the title may wrap.
/// On the iPhone the player bar stops its type at the chips' cap, so every
/// button here shows its visible text in the Large Content Viewer.
struct ReaderMessageLine: View {

    let message: ReaderMessage?
    let position: ReaderPositionLine
    let onOpenContents: () -> Void
    let onRetry: () -> Void
    let onBackFiveMinutes: () -> Void
    /// Where each arm's ink sits in its 44pt row: centred, or (`.bottom`,
    /// the iPhone bar) on the row's foot, by the scrub it describes. Only
    /// the ink moves; the rows and their hit areas stay as they are.
    var rowAlignment: VerticalAlignment = .center
    /// Undo jump as a named action on the position line, while a jump can
    /// be undone: focus lands here after a Contents pick. Nil on the Mac,
    /// where ⌘Z covers it.
    var onUndoJump: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Set by the Mac's reader; `.standard` on the iPhone, where the band
    /// changes nothing.
    @Environment(\.chromeScale) private var chromeScale

    private static let contentsHint = "Opens contents and search"
    /// What the error line's button does. The Mac's label names no action
    /// ("Playback stopped", `DeviceCopy.playbackFailed`), so the hint says it.
    static let retryHint = "Plays from the sentence that failed"

    private var slotKey: String { message?.slotKey ?? "position" }

    /// Every arm's frame, and the slot's: leading, on `rowAlignment`, so a
    /// crossfade between slots never moves the ink.
    private var rowFrameAlignment: Alignment { Alignment(horizontal: .leading, vertical: rowAlignment) }

    var body: some View {
        // The ZStack overlaps the outgoing and incoming slots during the
        // crossfade; in the bar's VStack they would stack for a frame.
        // Opacity only, so Reduce Motion needs no gate.
        ZStack(alignment: rowFrameAlignment) {
            slot
                .padding(.horizontal, Theme.Space.screenGutter)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: rowFrameAlignment)
                .id(slotKey)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: Theme.Motion.message), value: slotKey)
    }

    @ViewBuilder
    private var slot: some View {
        switch message {
        case .none:
            positionLine
        case .some(.stopped(.playbackError)):
            retryLine
        case .some(.stopped(let reason)):
            stoppedLine(reason)
        case .some(.naturalVoiceOffer):
            // Carries its own identifiers; its text still opens Contents,
            // and its ink sits on `rowAlignment` like every other arm's.
            NaturalVoiceOfferRow(onOpenContents: onOpenContents, rowAlignment: rowAlignment)
        case .some(let message):
            statusLine(message)
        }
    }

    // MARK: - Position

    /// On the iPhone it also goes straight to search
    /// (`ChapterLineContentsEntry`, P033).
    private var positionLine: some View {
        Button(action: onOpenContents) {
            Group {
                if Self.stacksPosition(dynamicTypeSize: dynamicTypeSize, scale: chromeScale) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            positionTitle
                                .lineLimit(2)
                            positionDetail(position.detail)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 0)
                        contentsGlyph
                    }
                } else {
                    HStack(spacing: Theme.Space.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            positionTitle
                                .lineLimit(1)
                            // The time never truncates; a long chapter title
                            // does. The first dot takes the detail's own
                            // space-dot-space, so the gaps either side of
                            // every dot match.
                            positionDetail("\u{00A0}\u{00B7} " + position.detail)
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                        contentsGlyph
                    }
                }
            }
            .rowInk(rowAlignment)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: rowFrameAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The whole visible line, title first, as the HUD may cut its end.
        .largeContentViewerIfAvailable { Text(position.text) }
        .accessibilityLabel(position.accessibilityLabel)
        .accessibilityHint(Self.contentsHint)
        // The visible title first, so Voice Control matches what it shows.
        .accessibilityInputLabels(Self.positionInputLabels(title: position.title))
        .accessibilityIdentifier("reader.chapterLine")
        .modifier(ChapterLineContentsEntry(onOpenContents: onOpenContents, offersSearchAction: true))
        .accessibilityActions {
            if let onUndoJump {
                Button(ReaderChip.undoJump.title, action: onUndoJump)
            }
        }
    }

    /// Contents' own icon (the line's long-press menu uses it too): the
    /// line opens Contents, a sheet on the iPhone and a side panel on the
    /// Mac. Beside the title at every text size.
    private var contentsGlyph: some View {
        Image(systemName: "list.bullet")
            .font(Theme.font(.caption, scale: chromeScale))
            .foregroundStyle(Theme.textFaint)
            .accessibilityHidden(true)
    }

    private var positionTitle: some View {
        Text(position.title)
            .font(Self.titleFont(chromeScale))
            .foregroundStyle(Theme.text)
            .truncationMode(.tail)
    }

    private func positionDetail(_ text: String) -> some View {
        Text(text)
            .font(Self.detailFont(chromeScale))
            .monospacedDigit()
            .foregroundStyle(Theme.textMuted)
            .numericReadout(Double(position.minutesLeft ?? 0))
    }

    // MARK: - Stops

    /// The error stop: one tap resumes at the failed sentence.
    private var retryLine: some View {
        Button(action: onRetry) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Theme.accentStrong)
                    .accessibilityHidden(true)
                Text(StopReason.playbackError.text)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .font(Self.detailFont(chromeScale))
            .rowInk(rowAlignment)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: rowFrameAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .largeContentViewerIfAvailable {
            Label(StopReason.playbackError.text, systemImage: "arrow.clockwise")
        }
        .accessibilityLabel(StopReason.playbackError.spokenText)
        .accessibilityHint(Self.retryHint)
        .accessibilityIdentifier("reader.chapterLine")
        // Its tap retries, so Contents stays a long press away (below the
        // accessibility sizes, where that press shows the whole line).
        .modifier(ChapterLineContentsEntry(onOpenContents: onOpenContents, offersSearchAction: false))
    }

    /// Every other stop says why; Play resumes. A sleep stop offers Back
    /// 5 min beside it, or under it at accessibility sizes, where the reason
    /// needs the full width.
    @ViewBuilder
    private func stoppedLine(_ reason: StopReason) -> some View {
        if reason == .sleepTimer {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    stopReasonButton(reason)
                    backFiveMinutesButton
                }
            } else {
                HStack(spacing: Theme.Space.xs) {
                    stopReasonButton(reason)
                    backFiveMinutesButton
                }
            }
        } else {
            stopReasonButton(reason)
        }
    }

    private func stopReasonButton(_ reason: StopReason) -> some View {
        Button(action: onOpenContents) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
                Text(reason.text)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Self.detailFont(chromeScale))
            .rowInk(rowAlignment)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: rowFrameAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .largeContentViewerIfAvailable { Label(reason.text, systemImage: "pause.circle") }
        .accessibilityLabel(reason.spokenText)
        .accessibilityHint(Self.contentsHint)
        .accessibilityIdentifier("reader.chapterLine")
    }

    /// Text only, never filled: Play keeps the one accent fill.
    private var backFiveMinutesButton: some View {
        Button(action: onBackFiveMinutes) {
            Text(StopCopy.backFiveMinutes)
                .font(Self.titleFont(chromeScale))
                .foregroundStyle(Theme.accentStrong)
                // On the reason's line, wherever the row sets its ink.
                .rowInk(rowAlignment)
                .frame(minWidth: 44, minHeight: 44, alignment: Alignment(horizontal: .center, vertical: rowAlignment))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .largeContentViewerIfAvailable { Text(StopCopy.backFiveMinutes) }
        .accessibilityLabel(StopCopy.backFiveMinutesSpoken)
        .accessibilityHint(StopCopy.backFiveMinutesHint)
        .accessibilityInputLabels([Text(StopCopy.backFiveMinutes), Text(StopCopy.backFiveMinutesSpoken)])
        .accessibilityIdentifier("reader.back5min")
    }

    // MARK: - Notices and status

    /// Notices, download progress and waiting, voice preparation:
    /// informational, so the line keeps its job of opening Contents.
    private func statusLine(_ message: ReaderMessage) -> some View {
        let progress: Double?
        if case .downloadProgress(let value) = message { progress = value } else { progress = nil }
        return Button(action: onOpenContents) {
            Text(message.text)
                .font(Self.detailFont(chromeScale))
                .foregroundStyle(message == .preparingVoice ? Theme.textMuted : Theme.text)
                .numericReadout(progress ?? 0)
                .rowInk(rowAlignment)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: rowFrameAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .largeContentViewerIfAvailable { Text(message.text) }
        .accessibilityLabel(message.spokenText)
        .accessibilityHint(Self.contentsHint)
        .accessibilityAddTraits(progress != nil ? .updatesFrequently : [])
        .accessibilityIdentifier("reader.chapterLine")
    }
}

extension ReaderMessageLine {
    /// What Voice Control answers to on the position line: the visible title
    /// first, so it matches what it shows, then Contents, and on the iPhone
    /// Search too.
    nonisolated static func positionInputLabels(title: String) -> [Text] {
        [Text(title), Text("Contents")]
            + (PlatformContentsEntry.chapterLineOffersSearch ? [Text(ContentsSearch.searchInputLabel)] : [])
    }

    /// The title, and Back 5 min, in `scale`'s band: the Mac's ramp steps it
    /// up per band; the iPhone's follows Dynamic Type whatever the band.
    nonisolated static func titleFont(_ scale: ChromeScale) -> Font {
        Theme.font(.subhead, scale: scale)
    }

    /// The detail, and every stop and notice, in `scale`'s band.
    nonisolated static func detailFont(_ scale: ChromeScale) -> Font {
        Theme.font(.footnote, scale: scale)
    }

    /// Whether the position line sets its title, on up to two lines, over its
    /// detail, with the Contents glyph beside the title's first line: at the
    /// accessibility sizes, and in the Mac's Largest band.
    nonisolated static func stacksPosition(dynamicTypeSize: DynamicTypeSize, scale: ChromeScale) -> Bool {
        dynamicTypeSize.isAccessibilitySize || PlatformTypeRamp.wrapsChapterLine(in: scale)
    }

    /// Each arm's least height: one full touch row.
    nonisolated static let rowHeight: CGFloat = 44
    /// How far a `.bottom` row lifts its ink off the row's foot.
    nonisolated static let footInset: CGFloat = Theme.Space.xxs
    /// The air a `.bottom` row keeps above its ink at the accessibility
    /// sizes (R2-26), where a stacked or wrapped line outgrows its 44pt row
    /// and would otherwise sit right under the bar's hairline, which has no
    /// top inset on the iPhone. Below them, and on a centred row (the Mac),
    /// it is zero, so nothing moves by a point.
    nonisolated static let overflowHeadroom: CGFloat = Theme.Space.sm

    /// The lift for ink `inkHeight` tall in a `.bottom` row: `footInset`,
    /// less where the ink nearly fills the row, so the row never grows and
    /// the ink never rises past its top. Zero once the ink is a row tall.
    nonisolated static func footLift(inkHeight: CGFloat) -> CGFloat {
        min(footInset, max(rowHeight - inkHeight, 0))
    }
}

extension View {
    /// On a `.bottom` row, sets the ink `ReaderMessageLine.footLift` above
    /// the row's foot (an alignment guide, so no frame or hit area changes)
    /// and, at the accessibility sizes, keeps `overflowHeadroom` above it.
    /// Nothing on a centred row. The natural-voice offer's row takes it too,
    /// so its ink sits where the line it replaces put it.
    func rowInk(_ alignment: VerticalAlignment) -> some View {
        modifier(RowInk(alignment: alignment))
    }
}

/// `rowInk`'s work, a modifier so it can read the text size.
struct RowInk: ViewModifier {
    let alignment: VerticalAlignment

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `overflowHeadroom` on a `.bottom` row at an accessibility size,
    /// otherwise zero.
    nonisolated static func headroom(alignment: VerticalAlignment, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        alignment == .bottom && dynamicTypeSize.isAccessibilitySize ? ReaderMessageLine.overflowHeadroom : 0
    }

    func body(content: Content) -> some View {
        let alignment = alignment
        let headroom = Self.headroom(alignment: alignment, dynamicTypeSize: dynamicTypeSize)
        // The headroom is padding, so a tall line's row grows by it; the
        // lift is still measured on the ink alone.
        return content
            .padding(.top, headroom)
            .alignmentGuide(.bottom) { dimensions in
                guard alignment == .bottom else { return dimensions[.bottom] }
                return dimensions[.bottom] + ReaderMessageLine.footLift(inkHeight: dimensions.height - headroom)
            }
    }
}
