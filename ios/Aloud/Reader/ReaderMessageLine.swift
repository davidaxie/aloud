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
struct ReaderMessageLine: View {

    let message: ReaderMessage?
    let position: ReaderPositionLine
    let onOpenContents: () -> Void
    let onRetry: () -> Void
    let onBackFiveMinutes: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Set by the Mac's reader; `.standard` on the iPhone, where the band
    /// changes nothing.
    @Environment(\.chromeScale) private var chromeScale

    private static let contentsHint = "Opens contents and search"

    private var slotKey: String { message?.slotKey ?? "position" }

    var body: some View {
        // The ZStack overlaps the outgoing and incoming slots during the
        // crossfade; in the bar's VStack they would stack for a frame.
        // Opacity only, so Reduce Motion needs no gate.
        ZStack(alignment: .leading) {
            slot
                .padding(.horizontal, Theme.Space.screenGutter)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
            // Carries its own identifiers; its text still opens Contents.
            NaturalVoiceOfferRow(onOpenContents: onOpenContents)
        case .some(let message):
            statusLine(message)
        }
    }

    // MARK: - Position

    private var positionLine: some View {
        Button(action: onOpenContents) {
            Group {
                if Self.stacksPosition(dynamicTypeSize: dynamicTypeSize, scale: chromeScale) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        positionTitle
                            .lineLimit(2)
                        positionDetail(position.detail)
                    }
                } else {
                    HStack(spacing: Theme.Space.xs) {
                        positionTitle
                            .lineLimit(1)
                        // The time never truncates; a long chapter title does.
                        positionDetail("\u{00B7} " + position.detail)
                            .fixedSize()
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                            .font(Theme.font(.caption, scale: chromeScale))
                            .foregroundStyle(Theme.textFaint)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(position.accessibilityLabel)
        .accessibilityHint(Self.contentsHint)
        // The visible title first, so Voice Control matches what it shows.
        .accessibilityInputLabels([Text(position.title), Text("Contents")])
        .accessibilityIdentifier("reader.chapterLine")
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StopReason.playbackError.spokenText)
        .accessibilityIdentifier("reader.chapterLine")
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
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
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.spokenText)
        .accessibilityHint(Self.contentsHint)
        .accessibilityAddTraits(progress != nil ? .updatesFrequently : [])
        .accessibilityIdentifier("reader.chapterLine")
    }
}

extension ReaderMessageLine {
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
    /// detail: at the accessibility sizes, and in the Mac's Largest band.
    nonisolated static func stacksPosition(dynamicTypeSize: DynamicTypeSize, scale: ChromeScale) -> Bool {
        dynamicTypeSize.isAccessibilitySize || PlatformTypeRamp.wrapsChapterLine(in: scale)
    }
}
