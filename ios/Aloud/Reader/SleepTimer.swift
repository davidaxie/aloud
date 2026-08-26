import Combine
import Foundation

/// Reader sleep timer. Minute options count down only while audio is playing
/// (paused time doesn't burn the timer); "End of chapter" pauses when the
/// playhead moves past the last sentence of the page that was current when
/// armed. Firing pauses playback and surfaces a gentle toast.
@MainActor
final class SleepTimer: ObservableObject {

    enum Option: Hashable {
        case off
        case minutes(Int)
        case endOfChapter

        var label: String {
            switch self {
            case .off: return "Off"
            case .minutes(let minutes): return "\(minutes) minutes"
            case .endOfChapter: return "End of chapter"
            }
        }
    }

    static let minuteChoices = [15, 30, 45, 60]

    @Published private(set) var option: Option = .off
    /// Seconds left on a minute timer; 0 for Off / End of chapter.
    @Published private(set) var remaining: TimeInterval = 0

    var isArmed: Bool { option != .off }

    /// Chip text next to the moon glyph: "14:59" countdown or "Chapter end".
    var chipLabel: String {
        switch option {
        case .off:
            return ""
        case .minutes:
            let seconds = max(Int(remaining.rounded()), 0)
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .endOfChapter:
            return "Chapter end"
        }
    }

    private weak var playback: PlaybackController?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?
    private var toastClearTask: Task<Void, Never>?
    /// Last sentence index of the page current at arm time (End of chapter).
    private var chapterBoundary = Int.max

    /// Wire to the controller once (idempotent). The timer observes status to
    /// suspend while paused, and the sentence stream for the chapter boundary.
    func attach(to playback: PlaybackController) {
        guard self.playback !== playback else { return }
        self.playback = playback
        cancellables = []

        playback.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)

        playback.$currentSentence
            .sink { [weak self] sentence in self?.sentenceChanged(sentence) }
            .store(in: &cancellables)
    }

    func select(_ option: Option) {
        tickTask?.cancel()
        self.option = option
        switch option {
        case .off:
            remaining = 0
        case .minutes(let minutes):
            remaining = TimeInterval(minutes * 60)
            if playback?.status == .playing { startTicking() }
        case .endOfChapter:
            remaining = 0
            captureChapterBoundary()
        }
    }

    // MARK: - Countdown

    private func statusChanged(_ status: PlayerStatus) {
        // The document ran out on its own — nothing left to sleep through.
        if status == .ended, isArmed {
            select(.off)
            return
        }
        guard case .minutes = option else { return }
        if status == .playing {
            startTicking()
        } else {
            tickTask?.cancel()
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.remaining -= 1
                if self.remaining <= 0 {
                    self.fire()
                    return
                }
            }
        }
    }

    // MARK: - End of chapter

    private func captureChapterBoundary() {
        guard let playback, let content = playback.content,
              !content.sentences.isEmpty else {
            chapterBoundary = Int.max
            return
        }
        let index = min(max(playback.currentSentence, 0), content.sentences.count - 1)
        let page = content.sentences[index].page
        chapterBoundary = content.sentences.lastIndex { $0.page == page } ?? Int.max
    }

    private func sentenceChanged(_ sentence: Int) {
        guard option == .endOfChapter else { return }
        let live = playback?.isActive == true
        if live {
            if sentence > chapterBoundary { fire() }
        } else {
            // A manual seek while paused relocates the reader; the "current
            // chapter" follows the new position.
            captureChapterBoundary()
        }
    }

    // MARK: - Firing

    private func fire() {
        tickTask?.cancel()
        option = .off
        remaining = 0
        guard let playback else { return }
        playback.pause()
        showToast("Sleep timer paused playback")
    }

    /// Rides the controller's published `toast` (rendered by the reader);
    /// clears itself unless something else replaced the message meanwhile.
    private func showToast(_ message: String) {
        guard let playback else { return }
        playback.toast = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak playback] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, playback?.toast == message else { return }
            playback?.toast = nil
        }
    }
}
