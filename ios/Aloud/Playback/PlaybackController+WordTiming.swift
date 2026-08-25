import AVFoundation
import Foundation
import QuartzCore

/// M3 word karaoke state, owned by `PlaybackController` (see the small hooks
/// in PlaybackController.swift). Holds per-sentence word windows laid out in
/// the player node's media timeline and drives a 30 fps `CADisplayLink` that
/// maps the playhead to a word index while audio is playing.
///
/// Timeline model: clips are scheduled gaplessly on one `AVAudioPlayerNode`,
/// so each clip's start is the running sum of previously scheduled clip
/// durations since the last `player.stop()`. `playerTime(forNodeTime:)`
/// counts SOURCE frames consumed by the node — the time-pitch unit pulls
/// frames faster at higher rates — so the position read each frame is already
/// in 1× media seconds and windows never need re-deriving on speed changes.
@MainActor
final class WordKaraokeState: NSObject {

    struct Clip {
        let start: TimeInterval      // media-timeline offset of the clip's first frame
        let duration: TimeInterval   // 1× seconds
        let windows: [WordWindow]    // empty for silence / skipped sentences
    }

    /// Fires ~30×/s while the link runs; the controller maps time → word.
    var onTick: (() -> Void)?

    /// Last (sentence, word) pair pushed to `currentWord`; publishing only on
    /// change keeps per-frame SwiftUI/TextKit work at zero.
    var lastPublished: (sentence: Int, word: Int) = (-1, -1)

    private(set) var clips: [Int: Clip] = [:]
    private var scheduledSeconds: TimeInterval = 0
    private var displayLink: CADisplayLink?

    func clip(for sentence: Int) -> Clip? { clips[sentence] }

    /// Record a clip at the current end of the gapless schedule. Must be
    /// called in scheduling order (it is: `scheduleClip` is the only caller).
    func appendScheduled(sentence: Int, duration: TimeInterval, windows: [WordWindow]) {
        clips[sentence] = Clip(start: scheduledSeconds, duration: duration, windows: windows)
        scheduledSeconds += duration
    }

    /// Drop entries the playhead has moved past (look-behind of 1 sentence).
    func prune(before sentence: Int) {
        guard clips.count > 8 else { return }
        for key in clips.keys where key < sentence - 1 {
            clips.removeValue(forKey: key)
        }
    }

    /// Full reset — pairs with `player.stop()`, which rewinds the node's
    /// sample time to zero (called from `invalidateSchedule`).
    func reset() {
        clips.removeAll()
        scheduledSeconds = 0
        lastPublished = (-1, -1)
        stopLink()
    }

    // MARK: Display link

    func startLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // 30 fps is plenty for word-boundary resolution and halves the wakeups.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let onTick else {
            stopLink()   // owner gone: break the link's retain on self
            return
        }
        onTick()
    }
}

// MARK: - PlaybackController integration

extension PlaybackController {

    /// Called once from `init` — wires the display link back into the controller.
    func configureWordTiming() {
        wordTiming.onTick = { [weak self] in self?.wordTimingTick() }
    }

    /// Hook from `status.didSet`: the link runs only while audio actually plays.
    /// Pausing freezes the highlight on the last word (web behavior); seeks and
    /// stops clear it via the `currentSentence`/`reset` paths.
    func wordTimingStatusChanged(_ status: PlayerStatus) {
        if status == .playing {
            wordTiming.startLink()
        } else {
            wordTiming.stopLink()
        }
    }

    /// Hook from `scheduleClip`, right after a buffer is handed to the player:
    /// records the clip's slot in the gapless timeline and lays its word
    /// windows out over the clip's exact duration. Silence / skipped sentences
    /// get an empty window list so no word ever lights up for them.
    func wordTimingRecordScheduled(sentence: Int,
                                   frameLength: AVAudioFrameCount,
                                   sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let duration = Double(frameLength) / sampleRate
        var windows: [WordWindow] = []
        if !skippedSentences.contains(sentence),
           let content, content.sentences.indices.contains(sentence) {
            windows = WordTimingEstimator.windows(
                sentenceText: content.sentences[sentence].text,
                duration: duration,
                skipBrackets: skipBrackets)
        }
        wordTiming.appendScheduled(sentence: sentence, duration: duration, windows: windows)
    }

    /// Display-link body: playhead media time − clip start → word index,
    /// published ONLY on change. O(log words) per frame, zero allocation.
    private func wordTimingTick() {
        guard status == .playing else { return }
        let sentence = currentSentence
        guard sentence >= 0,
              let clip = wordTiming.clip(for: sentence),
              !clip.windows.isEmpty,
              let now = playerMediaSeconds else { return }

        let index = WordTimingEstimator.wordIndex(at: now - clip.start, in: clip.windows)
        if wordTiming.lastPublished != (sentence, index) {
            wordTiming.lastPublished = (sentence, index)
            updateCurrentWord(index)
        }
        wordTiming.prune(before: sentence)
    }
}
