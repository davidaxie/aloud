import Foundation

// "Where you stopped" (PlaceHistory.swift): the controller times each
// listening session and reports its end through `onPlaceStop`. A session
// opens at the first audio that is the listener's own — never a voice
// sample — and closes at every way listening ends: leaving active playback
// (pause, every `stop(because:)`, a route pause, an interruption, an
// error), a jump far enough to offer Undo while it plays (and that Undo),
// switching books, closing the book and quitting while it plays.
// The book playing to its end leaves no place: Finished already says where
// it is. iOS ending the app mid-speech is recovered from the live marker at
// the next launch (`takeRecoveredPlaceStop`).
//
// The stop's sentence is the one `onProgress` just saved, so the newest
// place is where the book reopens.

extension PlaybackController {

    /// From the status didSet: the first `.playing` opens a session, and
    /// leaving active playback for anything but the end of the book closes
    /// it with a stop.
    func placeStatusChanged(from oldValue: PlayerStatus) {
        if status == .playing { beginPlaceSession() }
        let wasActive = oldValue == .playing || oldValue == .buffering
        if wasActive, !isActive { endPlaceSession(reporting: status != .ended) }
    }

    /// Opens a session when the listener's own audio is playing and none is
    /// open. Also called where a voice sample becomes playback, since the
    /// status never changes there.
    func beginPlaceSession() {
        guard placeSession == nil, status == .playing, isListenerPlaying,
              let document, currentSentence >= 0 else { return }
        placeSession = PlaceSession(documentID: document.id,
                                    startSentence: currentSentence,
                                    startedAt: Date(),
                                    startUptime: MonotonicClock.now)
    }

    /// Closes the open session, reporting where it ended. Called while
    /// `document` still names the book that was playing (a book switch and
    /// unload call it before letting go), so a stop never names the
    /// incoming book.
    func endPlaceSession(reporting: Bool = true) {
        guard let session = placeSession else { return }
        placeSession = nil
        guard reporting, session.documentID == document?.id,
              let content, content.sentences.indices.contains(currentSentence) else { return }
        let stop = PlaceStop(documentID: session.documentID,
                             contentHash: content.contentHash,
                             sentence: currentSentence,
                             excerpt: PlaceHistory.excerpt(of: content.sentences[currentSentence].text),
                             startSentence: session.startSentence,
                             startedAt: session.startedAt,
                             stoppedAt: Date(),
                             listenedSeconds: max(MonotonicClock.now - session.startUptime, 0),
                             movedAway: session.movedAway)
        lastPlaceStop = stop
        onPlaceStop?(stop)
    }

    /// A boundary inside the pause ramp moved the playhead after the stop
    /// was reported: report it again at the new sentence, which the
    /// same-place rule folds into the first, so the newest place still
    /// equals the saved progress.
    func placeStopMovedByPauseRamp() {
        guard !isActive, let last = lastPlaceStop, last.documentID == document?.id,
              last.sentence != currentSentence,
              let content, content.sentences.indices.contains(currentSentence) else { return }
        let moved = last.moved(to: currentSentence,
                               excerpt: PlaceHistory.excerpt(of: content.sentences[currentSentence].text))
        lastPlaceStop = moved
        onPlaceStop?(moved)
    }

    /// The session iOS ended at the last launch, once; nil after.
    func takeRecoveredPlaceStop() -> PlaceStop? {
        defer { recoveredPlaceStop = nil }
        return recoveredPlaceStop
    }
}
