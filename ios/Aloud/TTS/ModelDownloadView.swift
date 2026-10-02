import SwiftUI

/// The neural-voice model card: promo → downloading (or waiting for Wi-Fi)
/// → failed → installed.
/// The foot of the Listening view, in the reader's sheet (promo + progress,
/// card chrome) and on Settings' Voice & speed page (`showsInstalledState`
/// adds size-on-disk and a remove action). `showsCard` off drops the card
/// chrome; the Listening view does so for the bare unsupported-device line.
struct ModelDownloadView: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @EnvironmentObject private var manager: ModelManager

    var showsInstalledState = false
    var showsCard = true

    @State private var isConfirmingRemove = false
    @State private var isConfirmingCellular = false

    /// Icon tiles grow with their glyphs under Dynamic Type.
    @ScaledMetric(relativeTo: .title3) private var tileSize: CGFloat = 40

    /// The drawn tile, capped: past AX1 a bigger decorative tile only costs
    /// the card height (its glyph is capped at AX1 to match).
    private var cappedTileSize: CGFloat { min(tileSize, 56) }

    var body: some View {
        card
            .naturalVoiceCellularPrompt(isPresented: $isConfirmingCellular)
    }

    @ViewBuilder
    private var card: some View {
        if showsCard {
            content
                .padding(Theme.Space.md)
                .background(Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(Theme.Stroke.borderColor, lineWidth: Theme.Stroke.borderWidth))
        } else {
            content
                .padding(.vertical, Theme.Space.xs)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if !ModelManager.deviceSupportsNeuralVoice {
            unsupported
        } else {
            switch manager.state {
            case .notInstalled:
                promo
            case .downloading(let progress):
                inFlight(progress, waiting: false)
            case .waitingForWiFi(let progress):
                inFlight(progress, waiting: true)
            case .failed(let failure):
                failed(failure)
            case .installed:
                if showsInstalledState { installed }
            }
        }
    }

    private var promo: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            tileRow {
                icon
            } label: {
                Text(NaturalVoiceCopy.offer)
                    .font(Theme.font(.body).weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                requestDownload()
            } label: {
                // The capsule carries a text label, so it is `accentStrong`.
                // The label wraps inside it rather than truncating; the
                // capsule grows from its 44pt minimum.
                Text(NaturalVoiceCopy.download)
                    .font(Theme.font(.callout).weight(.semibold))
                    .foregroundStyle(Theme.bg)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accentStrong, in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("model.download")
            Text(NaturalVoiceCopy.privacyLine)
                .font(Theme.font(.footnote))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inFlight(_ progress: Double, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked: side by side, the tile and the cancel squeezed the
                // title to ~65 pt. The cancel gets a line of its own.
                icon
                inFlightLabel(progress, waiting: waiting)
                progressBar(progress, waiting: waiting)
                CancelDownloadButton { manager.cancelDownload() }
            } else {
                HStack(spacing: Theme.Space.sm) {
                    icon
                    inFlightLabel(progress, waiting: waiting)
                    Spacer(minLength: 0)
                    CancelDownloadButton { manager.cancelDownload() }
                }
                progressBar(progress, waiting: waiting)
            }
        }
    }

    @ViewBuilder
    private func inFlightLabel(_ progress: Double, waiting: Bool) -> some View {
        if waiting {
            // Nothing is moving, so it reads quieter than the live percent.
            Text(NaturalVoiceCopy.waitingForWiFi)
                .font(Theme.font(.body).weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityLabel(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi))
                .accessibilityIdentifier("model.waiting")
        } else {
            Text(NaturalVoiceCopy.downloading(progress))
                .font(Theme.font(.body).weight(.semibold))
                .monospacedDigit()
                .numericReadout(progress)
                .foregroundStyle(Theme.text)
        }
    }

    /// The whole line is the retry: "Download failed · Try again". Too little
    /// space checks again, and on cellular the prompt asks first.
    private func failed(_ failure: ModelManager.DownloadFailure) -> some View {
        let copy = NaturalVoiceCopy.failure(failure)
        return Button {
            requestDownload()
        } label: {
            tileRow {
                icon
            } label: {
                (Text(copy.status).foregroundColor(Theme.text)
                    + Text(" · ").foregroundColor(Theme.textMuted)
                    + Text(copy.detail).foregroundColor(copy.detailIsAction ? Theme.accentStrong : Theme.textMuted))
                    .font(Theme.font(.body).weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(failure)))
        .accessibilityIdentifier("model.failure")
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                // The decorative tile and checkmark give their width back to
                // the text at accessibility sizes (it wrapped a word a line).
                if !dynamicTypeSize.isAccessibilitySize { icon }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(NaturalVoiceCopy.installed)
                        .font(Theme.font(.body).weight(.semibold))
                        .foregroundStyle(Theme.text)
                    // Measured on disk, not the expected download size.
                    Text(NaturalVoiceCopy.onDevice(ModelManager.formattedSize(manager.sizeOnDisk)))
                        .font(Theme.font(.footnote))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            // Deleting ~350 MB is never one tap: confirm first (PRD R1d).
            Button {
                isConfirmingRemove = true
            } label: {
                Text("Remove Download")
                    .font(Theme.font(.callout).weight(.medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("model.remove")
            .confirmationDialog("Remove the natural voice?",
                                isPresented: $isConfirmingRemove,
                                titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { manager.deleteModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Books will read in the System voice until you download it again.")
            }
        }
    }

    /// Exactly one line (R8); Listening reuses this view for it.
    private var unsupported: some View {
        Text(NaturalVoiceCopy.unsupported)
            .font(Theme.font(.footnote))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("model.unsupported")
    }

    // MARK: - Bits

    /// A state's icon tile beside its text — or above it at accessibility
    /// sizes, where a tile beside the text squeezed the title column to
    /// ~65 pt (AX3/AX5) and wrapped it a few letters per line.
    @ViewBuilder
    private func tileRow<TileContent: View, LabelContent: View>(
        @ViewBuilder tile: () -> TileContent,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                tile()
                label()
            }
        } else {
            HStack(spacing: Theme.Space.sm) {
                tile()
                label()
                Spacer(minLength: 0)
            }
        }
    }

    /// Decorative, like the installed checkmark: unhidden, VoiceOver stopped
    /// on "Waveform, image" before the card's text.
    private var icon: some View {
        Image(systemName: "waveform")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.accentStrong)
            // Scales with the text, capped where it fits the capped tile.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(width: cappedTileSize, height: cappedTileSize)
            .background(Theme.accentSoft,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .accessibilityHidden(true)
    }

    private func progressBar(_ progress: Double, waiting: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(5, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.crossfade), value: progress)
        .accessibilityElement()
        .accessibilityLabel(waiting ? "Download paused" : "Downloading natural voice")
        // Truncated like the visible "· 42%", so VoiceOver never reads ahead of it.
        .accessibilityValue("\(min(max(Int(progress * 100), 0), 100)) percent")
        // Only a moving download is worth re-reading.
        .accessibilityAddTraits(waiting ? [] : .updatesFrequently)
        .accessibilityIdentifier("model.progress")
    }

    /// On cellular or Low Data Mode nothing is sent until the user confirms.
    private func requestDownload() {
        if manager.requestDownload() == .needsCellularConfirmation {
            isConfirmingCellular = true
        }
    }
}

/// The in-flight card's cancel: a 34 pt disc inside a 44 pt target, or a
/// labeled button at accessibility sizes, where a lone glyph on its own
/// line reads poorly.
struct CancelDownloadButton: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .footnote) private var discSize: CGFloat = 34

    let onCancel: () -> Void

    /// Capped at the 44 pt target around it: at xxxLarge the scaled disc
    /// (~50 pt) outgrew its own tap target and took width from the title.
    private var cappedDiscSize: CGFloat { min(discSize, 44) }

    var body: some View {
        Button(action: onCancel) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Cancel Download")
                        .font(Theme.font(.callout).weight(.medium))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    Image(systemName: "xmark")
                        .font(Theme.font(.subhead))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: cappedDiscSize, height: cappedDiscSize)
                        .background(Theme.surface2, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.Stroke.borderColor,
                                                       lineWidth: Theme.Stroke.borderWidth))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Cancel download")
        .accessibilityIdentifier("model.cancel")
    }
}
