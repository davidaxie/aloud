import SwiftUI

/// The neural-voice model card: promo → downloading → failed → installed.
/// Reused in the voice picker (promo + progress, card chrome) and in Settings
/// (`showsInstalledState` adds size-on-disk and a remove action; `showsCard`
/// off lets the list row provide the surface).
struct ModelDownloadView: View {

    @EnvironmentObject private var manager: ModelManager

    var showsInstalledState = false
    var showsCard = true

    var body: some View {
        if showsCard {
            content
                .padding(16)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.line, lineWidth: 0.5))
        } else {
            content
                .padding(.vertical, 6)
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
                downloading(progress)
            case .failed(let message):
                failed(message)
            case .installed:
                if showsInstalledState { installed }
            }
        }
    }

    private var promo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Natural neural voice")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(ModelManager.downloadSizeLabel) one-time download")
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            Button {
                manager.startDownload()
            } label: {
                Text("Download")
                    .font(Theme.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("model.download")
            Text("Wi-Fi recommended. Speech is synthesized entirely on this device.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func downloading(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloading neural voice")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(Int((progress * 100).rounded()))% of \(ModelManager.downloadSizeLabel)")
                        .font(Theme.ui(13))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                Button {
                    manager.cancelDownload()
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.ui(13, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface2, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.5))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
            }
            progressBar(progress)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Download didn't finish")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            Button {
                manager.startDownload()
            } label: {
                Text("Try Again")
                    .font(Theme.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.accentStrong)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.accentSoft, in: Capsule())
            }
            .buttonStyle(.borderless)
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Neural voice installed")
                        .font(Theme.ui(16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\(sizeLabel) on device · works offline")
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.ui(18))
                    .foregroundStyle(Theme.accent)
            }
            Button {
                manager.deleteModel()
            } label: {
                Text("Remove Download")
                    .font(Theme.ui(14, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.borderless)
        }
    }

    private var unsupported: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.slash")
                .font(Theme.ui(17, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 40, height: 40)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            Text("This device can't run the neural voice — Aloud uses the best system voice instead.")
                .font(Theme.ui(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bits

    private var icon: some View {
        Image(systemName: "waveform")
            .font(Theme.ui(17, weight: .semibold))
            .foregroundStyle(Theme.accentStrong)
            .frame(width: 40, height: 40)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(5, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.2), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: manager.sizeOnDisk, countStyle: .file)
    }
}
