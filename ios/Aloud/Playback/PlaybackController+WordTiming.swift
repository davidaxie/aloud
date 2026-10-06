import AVFoundation
import Foundation

/// M3 word karaoke state, owned by `PlaybackController` (see the small hooks
/// in PlaybackController.swift). Holds per-sentence word windows laid out in
/// the player node's media timeline and drives a 30 fps `FrameTicker` that
/// maps the playhead to a word index while audio is playing.
///
/// Timeline model: clips are scheduled gaplessly on one `AVAudioPlayerNode`,
/// so each clip's start is the running sum of previously scheduled clip
/// durations since the last `player.stop()`, plus any stretch the queue ran
/// dry while the node kept playing (`appendScheduled`; a clip queued while
/// the node is paused starts where it will resume). `playerTime(forNodeTime:)`
/// counts SOURCE frames consumed by the node — the time-pitch unit pulls
/// frames faster at higher rates — so the position read each frame is in the
/// clip's own media seconds and windows never need re-deriving on speed
/// changes. A clip Kokoro spoke faster (`Clip.compression`) is that much
/// shorter in media time; wall time divides it back out (`wallSeconds`).
@MainActor
final class WordKaraokeState {

    struct Clip {
        let start: TimeInterval      // media-timeline offset of the clip's first frame
        let duration: TimeInterval   // the clip's own seconds, at the pace it was spoken
        let windows: [WordWindow]    // empty for silence / skipped sentences
        /// How much shorter than 1x it was spoken (`SynthesizedAudio.nativeSpeed`):
        /// its wall time at speed r is duration × compression / r.
        var compression: Double = 1.0
    }

    /// Fires ~30×/s while the ticker runs; the controller maps time → word.
    var onTick: (() -> Void)?

    /// Last (sentence, word) pair pushed to `currentWord`; publishing only on
    /// change keeps per-frame SwiftUI/TextKit work at zero.
    var lastPublished: (sentence: Int, word: Int) = (-1, -1)

    private(set) var clips: [Int: Clip] = [:]
    private var scheduledSeconds: TimeInterval = 0
    private var ticker: FrameTicker?

    /// The playhead a paused node stopped at, where it resumes: set by
    /// `PlaybackController.pauseNode`, cleared on resume and by `reset`.
    var pausedPlayhead: TimeInterval?

    func clip(for sentence: Int) -> Clip? { clips[sentence] }

    /// Record a clip at the current end of the gapless schedule, or at
    /// `playhead` when that is later: a queue that ran dry (synthesis slower
    /// than speech) leaves the node playing silence, so the clip starts where
    /// the playhead has got to, and every later clip lines up behind it. Must
    /// be called in scheduling order (it is: `scheduleClip` is the only caller).
    func appendScheduled(sentence: Int, duration: TimeInterval, windows: [WordWindow],
                         playhead: TimeInterval? = nil, compression: Double = 1.0) {
        let start = max(scheduledSeconds, playhead ?? 0)
        clips[sentence] = Clip(start: start, duration: duration, windows: windows, compression: compression)
        scheduledSeconds = start + duration
    }

    /// A buffer that belongs to no sentence (the compression switch's one
    /// frame): later clips start after it.
    func appendGap(_ seconds: TimeInterval) {
        scheduledSeconds += max(seconds, 0)
    }

    /// Wall seconds the node takes from media time `from` to `to` at speed
    /// `rate`: each clip's stretch at its own compression, and any stretch
    /// no clip covers (a dry spell, a marker) at `gapCompression`.
    func wallSeconds(from: TimeInterval, to: TimeInterval, rate: Double, gapCompression: Double) -> TimeInterval {
        guard to > from, rate > 0 else { return 0 }
        var wall = 0.0, covered = 0.0
        for clip in clips.values {
            let overlap = min(to, clip.start + clip.duration) - max(from, clip.start)
            guard overlap > 0 else { continue }
            wall += overlap * clip.compression
            covered += overlap
        }
        wall += max(0, (to - from) - covered) * gapCompression
        return wall / rate
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
        pausedPlayhead = nil
        lastPublished = (-1, -1)
        stopLink()
    }

    // MARK: Frame ticker

    func startLink() {
        guard ticker == nil else { return }
        // 30 fps is plenty for word-boundary resolution and halves the wakeups.
        let ticker = FrameTicker(framesPerSecond: 30) { [weak self] in self?.tick() }
        ticker.start()
        self.ticker = ticker
    }

    func stopLink() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let onTick else {
            stopLink()   // owner gone: stop ticking
            return
        }
        onTick()
    }
}

// MARK: - PlaybackController integration

extension PlaybackController {

    /// Called once from `init` — wires the frame ticker back into the controller.
    func configureWordTiming() {
        wordTiming.onTick = { [weak self] in self?.wordTimingTick() }
    }

    /// Hook from `status.didSet` and `wordHighlightEnabled.didSet`: the ticker
    /// runs only while audio actually plays AND the word tint is on — its sole
    /// consumer. (Lock-screen elapsed time rides the once-per-sentence
    /// `currentSentence` heartbeat, not this link.) Pausing freezes the
    /// highlight on the last word (web behavior); seeks and stops clear it via
    /// the `currentSentence`/`reset` paths.
    func wordTimingStatusChanged(_ status: PlayerStatus) {
        if status == .playing, wordHighlightEnabled {
            wordTiming.startLink()
        } else {
            wordTiming.stopLink()
        }
    }

    /// Hook from `scheduleClip`, right after a buffer is handed to the player:
    /// records the clip's slot in the timeline (gapless, unless the queue ran
    /// dry first: then at `schedulingPlayhead`) and lays its word
    /// windows out over the clip's exact duration. Silence / skipped sentences
    /// get an empty window list so no word ever lights up for them.
    func wordTimingRecordScheduled(sentence: Int,
                                   frameLength: AVAudioFrameCount,
                                   sampleRate: Double,
                                   compression: Double = 1.0) {
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
        // Playing, inside a pause's ramp (the node still runs) or paused (it
        // resumes where it stopped), a clip after a dry stretch starts at
        // the node's playhead, so Back's 3 s rule (R14), the sleep landing
        // (R19) and the word tint read what was really heard.
        wordTiming.appendScheduled(sentence: sentence, duration: duration, windows: windows,
                                   playhead: schedulingPlayhead, compression: compression)
    }

    /// The media time being heard: the render clock less what the output has
    /// still to present (`latency` wall seconds, pulled at `timePitchRate`).
    /// The sentence advances when its audio is heard (`.dataPlayedBack`),
    /// so the word tint reads the same clock, never ahead of the voice by
    /// a latency that grows with speed (a Bluetooth route's ~0.2 s).
    nonisolated static func heardMediaSeconds(rendered: TimeInterval,
                                              latency: TimeInterval,
                                              timePitchRate: Double) -> TimeInterval {
        guard latency.isFinite, latency > 0, timePitchRate.isFinite, timePitchRate > 0 else { return rendered }
        return rendered - latency * timePitchRate
    }

    /// Ticker body: heard media time − clip start → word index,
    /// published ONLY on change. O(log words) per frame, zero allocation.
    private func wordTimingTick() {
        guard status == .playing else { return }
        let sentence = currentSentence
        guard sentence >= 0,
              let clip = wordTiming.clip(for: sentence),
              !clip.windows.isEmpty,
              let rendered = playerMediaSeconds else { return }

        let lag = outputLag
        let now = Self.heardMediaSeconds(rendered: rendered, latency: lag.latency, timePitchRate: lag.timePitchRate)
        let index = WordTimingEstimator.wordIndex(at: now - clip.start, in: clip.windows)
        if wordTiming.lastPublished != (sentence, index) {
            wordTiming.lastPublished = (sentence, index)
            updateCurrentWord(index)
        }
        wordTiming.prune(before: sentence)
    }
}
