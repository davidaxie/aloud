import Combine
import Foundation
import MediaPlayer
import UIKit

/// Lock-screen / Control Center integration: mirrors `PlaybackController`
/// state into `MPNowPlayingInfoCenter` and routes `MPRemoteCommandCenter`
/// transport commands back into it.
///
/// Time is reported on a 1× (165 wpm) timeline: duration is the whole-doc
/// estimate at 1×, elapsed is proportional to the sentence index, and
/// `playbackRate` carries the actual speed (0 while not playing) so the
/// system extrapolates between our once-per-sentence updates.
@MainActor
final class NowPlayingManager {

    private weak var playback: PlaybackController?
    private var cancellables: Set<AnyCancellable> = []
    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any] = [:]
    private var configured = false

    private static let skipInterval: TimeInterval = 15

    func configure(playback: PlaybackController, store: DocumentStore) {
        guard !configured else { return }
        configured = true
        self.playback = playback
        _ = store   // reserved: metadata lookups beyond the loaded document

        registerCommands()

        // @Published emits on willSet, so hop to the next main-actor turn and
        // read the controller's settled state instead of the emitted value.
        playback.$document
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.rebuildForCurrentDocument() }
            }
            .store(in: &cancellables)

        playback.$status
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPlaybackState() }
            }
            .store(in: &cancellables)

        // Fires at most once per sentence — our only elapsed-time heartbeat.
        playback.$currentSentence
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPlaybackState() }
            }
            .store(in: &cancellables)

        playback.$rate
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPlaybackState() }
            }
            .store(in: &cancellables)
    }

    deinit {
        for target in commandTargets {
            target.command.removeTarget(target.token)
        }
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        addHandler(center.playCommand) { $0.play() }
        addHandler(center.pauseCommand) { $0.pause() }
        addHandler(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        addHandler(center.nextTrackCommand) { $0.nextSentence() }
        addHandler(center.previousTrackCommand) { $0.previousSentence() }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        addHandler(center.skipForwardCommand) { playback in
            playback.seek(to: playback.currentSentence + Self.sentenceStep(for: playback),
                          andPlay: false)
        }
        addHandler(center.skipBackwardCommand) { playback in
            playback.seek(to: playback.currentSentence - Self.sentenceStep(for: playback),
                          andPlay: false)
        }

        // Sentence-granular playback has no continuous scrubber.
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func addHandler(_ command: MPRemoteCommand,
                            _ action: @escaping @MainActor (PlaybackController) -> Void) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let playback = self?.playback else { return }
                action(playback)
            }
            return .success
        }
        commandTargets.append((command, token))
    }

    /// How many sentences ≈ 15 s of listening at the current rate (min 1).
    private static func sentenceStep(for playback: PlaybackController) -> Int {
        guard let document = playback.document,
              let content = playback.content,
              !content.sentences.isEmpty,
              let total = document.estimatedTotalSeconds(rate: playback.rate),
              total > 0 else { return 1 }
        let perSentence = total / Double(content.sentences.count)
        guard perSentence > 0 else { return 1 }
        return max(1, Int((skipInterval / perSentence).rounded(.up)))
    }

    // MARK: - Now-playing info

    private func rebuildForCurrentDocument() {
        artworkTask?.cancel()
        guard let playback, let document = playback.document else {
            info = [:]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        info = [
            MPMediaItemPropertyTitle: document.title,
            MPMediaItemPropertyArtist: "Aloud",
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        applyTimeAndRate(playback: playback, document: document)
        push()
        loadArtwork(for: document)
    }

    private func refreshPlaybackState() {
        guard let playback, let document = playback.document else { return }
        applyTimeAndRate(playback: playback, document: document)
        push()
    }

    private func applyTimeAndRate(playback: PlaybackController, document: LibraryDocument) {
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            playback.status == .playing ? playback.rate : 0.0

        guard let duration = document.estimatedTotalSeconds(rate: 1.0),
              duration > 0,
              let content = playback.content,
              !content.sentences.isEmpty else {
            info[MPMediaItemPropertyPlaybackDuration] = nil
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nil
            return
        }
        let fraction: Double
        if playback.status == .ended {
            fraction = 1.0
        } else {
            let index = Double(max(playback.currentSentence, 0))
            fraction = min(index / Double(content.sentences.count), 1.0)
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = duration * fraction
    }

    private func push() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info.isEmpty ? nil : info
    }

    // MARK: - Artwork

    private func loadArtwork(for document: LibraryDocument) {
        artworkTask = Task { [weak self] in
            var image: UIImage?
            if document.kind == .pdf {
                image = await ThumbnailProvider.shared.thumbnail(for: document)
            }
            guard let self, !Task.isCancelled,
                  self.playback?.document?.id == document.id else { return }
            let cover = image ?? Self.typographicCover(title: document.title)
            let artwork = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
            self.info[MPMediaItemPropertyArtwork] = artwork
            self.push()
        }
    }

    /// Cover for text documents (and PDFs without a thumbnail): the document
    /// title set in the reading serif on warm paper, with a single accent rule.
    /// Rendered against the light palette so it reads like the app's sepia page.
    private static func typographicCover(title: String) -> UIImage {
        let side: CGFloat = 600
        let inset: CGFloat = 64
        let light = UITraitCollection(userInterfaceStyle: .light)
        let background = UIColor(Theme.bgTint).resolvedColor(with: light)
        let textColor = UIColor(Theme.text).resolvedColor(with: light)
        let mutedColor = UIColor(Theme.textMuted).resolvedColor(with: light)
        let accentColor = UIColor(Theme.accent).resolvedColor(with: light)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            accentColor.setFill()
            context.fill(CGRect(x: inset, y: 108, width: 84, height: 6))

            let titleFont = UIFont(name: Theme.serifFamilyName, size: 54)
                ?? UIFont.systemFont(ofSize: 54, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleRect = CGRect(x: inset, y: 150,
                                   width: side - inset * 2, height: 330)
            (title as NSString).draw(
                with: titleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: titleFont,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph,
                ],
                context: nil)

            let footer = "ALOUD" as NSString
            footer.draw(
                at: CGPoint(x: inset, y: side - inset - 22),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 19, weight: .semibold),
                    .foregroundColor: mutedColor,
                    .kern: 5.5,
                ])
        }
    }
}
