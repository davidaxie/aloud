import Foundation
import MediaPlayer   // for the info keys only

/// What the lock screen, Control Center and the Dynamic Island are told
/// (R23), as one pure value, so every rule is unit-tested without the
/// system's info center.
///
/// - The timeline is the in-app scrub span: the chapter in chaptered text,
///   the whole document for PDFs and chapterless text.
/// - Time is 1x media time at the shared 165 wpm. The rate rides on
///   `playbackRate` while playing (0 otherwise), so (duration - elapsed) /
///   rate is the in-app time left and the system extrapolates between
///   updates at the right speed. A sentence still buffering counts as
///   playing, as the in-app circle shows Pause: the lock screen's button
///   and the Mac's transport state (read from the rate) agree with it, and
///   the push when its audio starts re-anchors the system's clock.
/// - Elapsed counts the heard part of the current sentence, never past its
///   end, and equals duration at the end of the book.
/// - The artist is the author, else "Aloud"; the album is the chapter
///   line's title, and only in chaptered text.
struct NowPlayingSnapshot: Equatable {
    static let fallbackArtist = "Aloud"

    let title: String
    let artist: String
    let album: String?
    let span: ClosedRange<Int>?
    let duration: TimeInterval?
    let elapsed: TimeInterval?
    let playbackRate: Double
    /// Buffering publishes the playing rate too; this keeps the two apart,
    /// so the push when the audio starts re-anchors the elapsed time the
    /// system ran on while the sentence was still being made.
    let isBuffering: Bool

    /// `navigation` nil (not built yet) gives identity only: title, artist
    /// and rate. `sentenceElapsed` is real seconds heard of `sentence`.
    init(title: String, author: String?, navigation: ReaderNavigation?, sentence: Int,
         status: PlayerStatus, rate: Double, sentenceElapsed: TimeInterval) {
        self.title = title
        self.artist = Self.artist(for: author)
        self.playbackRate = status == .playing || status == .buffering ? rate : 0
        self.isBuffering = status == .buffering
        guard let navigation else {
            album = nil
            span = nil
            duration = nil
            elapsed = nil
            return
        }

        let position = max(sentence, 0)
        let span = navigation.scrubSpan(at: position)
        self.span = span
        let line = navigation.positionLine(at: position, rate: rate, documentTitle: title)
        if case .chapter = line.kind {
            album = line.title
        } else {
            album = nil
        }

        let spanWords = navigation.wordsRemaining(from: span.lowerBound, through: span.upperBound)
        guard spanWords > 0 else {
            // No words, no timeline: the system would draw a scrubber over nothing.
            duration = nil
            elapsed = nil
            return
        }
        let duration = Self.seconds(words: spanWords)
        self.duration = duration
        if status == .ended {
            elapsed = duration
            return
        }
        let current = min(max(position, span.lowerBound), span.upperBound)
        let start = navigation.secondsIntoSpan(of: current, in: span, rate: 1)
        // Real seconds heard become media seconds at `rate`, capped at the
        // sentence's own length so a stale clock never runs into the next one.
        let heardSeconds = sentenceElapsed.isFinite ? max(sentenceElapsed, 0) : 0
        let sentenceLength = Self.seconds(words: navigation.wordsRemaining(from: current, through: current))
        elapsed = min(start + min(heardSeconds * rate, sentenceLength), duration)
    }

    /// The trimmed author, or "Aloud" when there is none.
    static func artist(for author: String?) -> String {
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallbackArtist : trimmed
    }

    /// The sentence START nearest `position` (1x seconds into `span`): a
    /// lock-screen scrub lands where a sentence begins. Negative, non-finite
    /// and past-the-end positions clamp into the span.
    static func sentence(atElapsed position: TimeInterval, in span: ClosedRange<Int>,
                         navigation: ReaderNavigation) -> Int {
        let total = seconds(words: navigation.wordsRemaining(from: span.lowerBound, through: span.upperBound))
        let fraction = total > 0 && position.isFinite ? position / total : 0
        return navigation.sentence(atFraction: fraction, in: span)
    }

    /// Built fresh on every push, so a key the snapshot no longer has (an
    /// album after leaving chaptered text, times before navigation lands)
    /// is never left behind. The manager adds the artwork.
    var nowPlayingInfo: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration, let elapsed {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        return info
    }

    /// 1x listening time for `words` at the shared spoken rate.
    private static func seconds(words: Int) -> TimeInterval {
        Double(words) / LibraryDocument.spokenWordsPerMinute * 60
    }
}
