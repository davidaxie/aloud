import XCTest
@testable import Aloud

/// R15: a sentence tap plays from it in any state; chapter, search and scrub
/// picks keep play or pause; a jump that loses your place (a tap of more
/// than 3 sentences, any pick that moves) offers "Undo jump" for 10 s, and
/// Undo restores the sentence and play state it came from.
@MainActor
final class UndoJumpTests: XCTestCase {

    private func pausedRig(at sentence: Int = 10, wordsPerSentence: Int = 3) -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 40, wordsPerSentence: wordsPerSentence)
        rig.loadDefault(at: sentence)
        return rig
    }

    /// Plays a 4-sentence book from its last sentence to `.ended`.
    private func endedRig() async throws -> PlaybackTestRig {
        let rig = PlaybackTestRig(sentences: 4, clipDuration: 0.1)
        rig.loadDefault(at: 3)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()
        let ended = await rig.waitUntil(5) { rig.controller.status == .ended }
        XCTAssertTrue(ended)
        return rig
    }

    // MARK: - The rule

    func testOffersUndoTable() {
        let offers = PlaybackController.offersUndo(origin:from:to:)
        XCTAssertFalse(offers(.sentence, 10, 13), "a 3-sentence tap is nearby")
        XCTAssertTrue(offers(.sentence, 10, 14))
        XCTAssertTrue(offers(.sentence, 10, 6))
        XCTAssertFalse(offers(.sentence, 10, 7))
        XCTAssertFalse(offers(.sentence, 10, 10))
        for origin in [JumpOrigin.chapter, .searchResult, .scrub] {
            XCTAssertTrue(offers(origin, 10, 11), "\(origin)")
            XCTAssertTrue(offers(origin, 10, 9), "\(origin)")
            XCTAssertFalse(offers(origin, 10, 10), "\(origin): no move, nothing to undo")
        }
        XCTAssertTrue(JumpOrigin.sentence.startsPlayback)
        XCTAssertFalse(JumpOrigin.chapter.startsPlayback)
        XCTAssertFalse(JumpOrigin.searchResult.startsPlayback)
        XCTAssertFalse(JumpOrigin.scrub.startsPlayback)
        XCTAssertEqual(UndoableJump.displaySeconds, 10)
        XCTAssertEqual(UndoableJump.tapThreshold, 3)
    }

    // MARK: - Taps play

    func testATapPlaysFromTheTargetWhilePaused() {
        let rig = pausedRig()
        rig.controller.jump(to: 20, origin: .sentence)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.currentSentence, 20)
    }

    func testATapPlaysFromTheTargetWhilePlaying() async throws {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 0.5)
        rig.loadDefault(at: 10)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        rig.controller.jump(to: 25, origin: .sentence)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.currentSentence, 25)
    }

    func testATapPlaysFromTheTargetAfterTheEnd() async throws {
        let rig = try await endedRig()
        rig.controller.jump(to: 1, origin: .sentence)
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.currentSentence, 1)
    }

    // MARK: - Picks keep play or pause

    func testAChapterJumpWhilePausedStaysPausedAndOffersUndo() throws {
        let rig = pausedRig()
        let serial = rig.controller.jumpSerial

        rig.controller.jump(to: 30, origin: .chapter)

        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.currentSentence, 30)
        let offer = try XCTUnwrap(rig.controller.undoableJump)
        XCTAssertEqual(offer.documentID, rig.document.id)
        XCTAssertEqual(offer.fromSentence, 10)
        XCTAssertEqual(offer.fromStatus, .paused)
        XCTAssertEqual(offer.toSentence, 30)
        XCTAssertEqual(rig.controller.jumpSerial, serial + 1)
        XCTAssertEqual(offer.serial, rig.controller.jumpSerial)
    }

    func testAPickOfTheCurrentSentenceOnlyBumpsTheSerial() {
        let rig = pausedRig()
        rig.controller.play()   // buffering: playback intended
        rig.clearRecordings()
        let serial = rig.controller.jumpSerial

        rig.controller.jump(to: 10, origin: .chapter)

        XCTAssertFalse(rig.events.contains(.stopped), "no restart")
        XCTAssertTrue(rig.statuses.isEmpty, "no transition")
        XCTAssertEqual(rig.controller.jumpSerial, serial + 1, "the reader still scrolls to it")
        XCTAssertNil(rig.controller.undoableJump)
    }

    // MARK: - Undo

    func testUndoRestoresThePausedSentence() {
        let rig = pausedRig()
        let serial = rig.controller.jumpSerial
        rig.controller.jump(to: 30, origin: .searchResult)

        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertNil(rig.controller.undoableJump)
        XCTAssertEqual(rig.controller.jumpSerial, serial + 2, "the jump and the undo")
    }

    func testUndoAfterATapThatStartedPlaybackRestoresThePause() {
        let rig = pausedRig()
        rig.controller.jump(to: 30, origin: .sentence)
        XCTAssertTrue(rig.controller.isActive)

        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertEqual(rig.controller.status, .paused)
    }

    func testUndoRestoresPlayback() {
        let rig = pausedRig()
        rig.controller.play()   // buffering counts as playing for the restore
        rig.controller.jump(to: 30, origin: .chapter)
        XCTAssertTrue(rig.controller.isActive, "a pick keeps playing")

        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.currentSentence, 10)
        XCTAssertTrue(rig.controller.isActive)
    }

    func testUndoRestoresTheEnd() async throws {
        let rig = try await endedRig()
        rig.controller.jump(to: 0, origin: .chapter)
        XCTAssertEqual(rig.controller.status, .paused)
        XCTAssertEqual(rig.controller.undoableJump?.fromStatus, .ended)

        rig.controller.undoJump()

        XCTAssertEqual(rig.controller.status, .ended)
        XCTAssertEqual(rig.controller.currentSentence, 3)
        XCTAssertEqual(rig.progress.last?.fraction, 1.0, "the book reads Finished again")
    }

    // MARK: - What keeps, merges and replaces an offer

    func testANearbyTapOffersNothingAndKeepsALiveOffer() throws {
        let fresh = pausedRig()
        fresh.controller.jump(to: 12, origin: .sentence)
        XCTAssertNil(fresh.controller.undoableJump)

        let rig = pausedRig()
        rig.controller.jump(to: 30, origin: .chapter)
        let offer = try XCTUnwrap(rig.controller.undoableJump)
        rig.controller.jump(to: 32, origin: .sentence)
        XCTAssertEqual(rig.controller.undoableJump, offer)

        rig.controller.skip(seconds: 15)
        XCTAssertEqual(rig.controller.undoableJump, offer, "a skip never clears it either")
    }

    func testConsecutiveScrubJumpsMergeToTheFirstOrigin() throws {
        let rig = pausedRig()
        rig.controller.jump(to: 20, origin: .scrub)
        rig.controller.jump(to: 25, origin: .scrub)
        rig.controller.jump(to: 28, origin: .scrub)

        let offer = try XCTUnwrap(rig.controller.undoableJump)
        XCTAssertEqual(offer.fromSentence, 10)
        XCTAssertEqual(offer.toSentence, 28)

        rig.controller.undoJump()
        XCTAssertEqual(rig.controller.currentSentence, 10)
    }

    func testMovingBetweenJumpsReplacesTheOffer() throws {
        let rig = pausedRig(wordsPerSentence: 10)
        rig.controller.jump(to: 20, origin: .chapter)
        rig.controller.skip(seconds: 15)
        let moved = rig.controller.currentSentence
        XCTAssertNotEqual(moved, 20)

        rig.controller.jump(to: 35, origin: .chapter)

        let offer = try XCTUnwrap(rig.controller.undoableJump)
        XCTAssertEqual(offer.fromSentence, moved)
        XCTAssertEqual(offer.toSentence, 35)
    }

    func testListeningBetweenJumpsReplacesTheOffer() async throws {
        let rig = PlaybackTestRig(sentences: 40, clipDuration: 0.25)
        rig.loadDefault(at: 10)
        rig.controller.play()
        try await rig.waitUntilPlayingOrSkip()

        rig.controller.jump(to: 20, origin: .chapter)
        let listened = await rig.waitUntil(3) { rig.controller.currentSentence >= 21 }
        XCTAssertTrue(listened)
        let heard = rig.controller.currentSentence
        rig.controller.jump(to: 35, origin: .chapter)

        let offer = try XCTUnwrap(rig.controller.undoableJump)
        XCTAssertEqual(offer.fromSentence, heard)
        XCTAssertEqual(offer.fromStatus, .playing)
    }

    func testTheOfferExpires() async {
        let rig = pausedRig()
        rig.controller.undoJumpLifetime = 0.05
        rig.controller.jump(to: 30, origin: .chapter)
        XCTAssertNotNil(rig.controller.undoableJump)

        let expired = await rig.waitUntil(1) { rig.controller.undoableJump == nil }
        XCTAssertTrue(expired)
    }

    func testAnotherBookClearsTheOffer() {
        let rig = pausedRig()
        rig.controller.jump(to: 30, origin: .chapter)
        rig.controller.load(document: PlaybackTestRig.makeDocument(hash: "other", sentences: 8),
                            content: PlaybackTestRig.makeContent(hash: "other", count: 8))
        XCTAssertNil(rig.controller.undoableJump)

        let unloaded = pausedRig()
        unloaded.controller.jump(to: 30, origin: .chapter)
        unloaded.controller.unload()
        XCTAssertNil(unloaded.controller.undoableJump)
    }

    // MARK: - Assistive tech (R1-39)

    private func offersAnnounced(_ rig: PlaybackTestRig) -> Int {
        rig.announcements.filter { $0 == UndoJumpCopy.available }.count
    }

    /// A scrub that opens an offer says so once, after the scrub's own
    /// value; scrubbing on extends that offer and says nothing more. A move
    /// between jumps opens a new offer, said again.
    func testAnOfferIsAnnouncedOnceWhenItOpens() throws {
        let rig = pausedRig(wordsPerSentence: 10)
        rig.clearRecordings()
        rig.controller.jump(to: 20, origin: .scrub)
        XCTAssertNotNil(rig.controller.undoableJump)
        XCTAssertEqual(offersAnnounced(rig), 1, "\(rig.announcements)")

        rig.controller.jump(to: 25, origin: .scrub)
        XCTAssertEqual(rig.controller.undoableJump?.fromSentence, 10, "the same offer, extended")
        XCTAssertEqual(offersAnnounced(rig), 1, "an extended offer says nothing more")

        rig.controller.skip(seconds: 15)
        rig.controller.jump(to: 35, origin: .chapter)
        XCTAssertEqual(offersAnnounced(rig), 2, "a new place to go back to")
    }

    /// A nearby tap offers nothing, so it says nothing.
    func testNoOfferNoAnnouncement() {
        let rig = pausedRig()
        rig.clearRecordings()
        rig.controller.jump(to: 12, origin: .sentence)
        XCTAssertNil(rig.controller.undoableJump)
        XCTAssertEqual(offersAnnounced(rig), 0)
    }

    /// With VoiceOver or Switch Control running, the offer outlives the
    /// usual 10 s (30 s in the app; both shortened here) and still expires.
    func testAssistiveTechKeepsTheOfferUpLonger() async throws {
        let rig = pausedRig()
        XCTAssertEqual(rig.controller.undoJumpLifetime, UndoableJump.displaySeconds)
        XCTAssertEqual(UndoableJump.displaySeconds, 10)
        XCTAssertEqual(rig.controller.assistiveUndoJumpLifetime, 30)
        rig.controller.undoJumpLifetime = 0.05
        rig.controller.assistiveUndoJumpLifetime = 0.5
        rig.controller.assistiveTechRunning = { true }

        rig.controller.jump(to: 30, origin: .chapter)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(rig.controller.undoableJump, "outlives the usual lifetime")
        let expired = await rig.waitUntil(2) { rig.controller.undoableJump == nil }
        XCTAssertTrue(expired, "and expires by its own")
    }
}
