import XCTest
@testable import Aloud

/// R11's fixed copy table, exactly as the PRD spells it, and the spoken form
/// VoiceOver hears. Plus the persisted stop and live-session values.
@MainActor
final class PlaybackCopyTests: XCTestCase {

    private static let notices: [PlaybackNotice] = [
        .fellBackToSystem, .nowReadingIn(voiceName: "Michael"), .backedUp(sentences: 2),
        .skippedSentence, .coolingDown,
    ]

    // MARK: - Visible text

    func testEveryStoppedReasonReadsExactly() {
        let expected: [StopReason: String] = [
            .headphonesDisconnected: "Paused · headphones disconnected",
            .interrupted: "Paused by a call or another app",
            .sleepTimer: "Paused by sleep timer",
            .playbackError: "Playback stopped · tap to try again",
            .tooHot: "Paused · iPhone is too hot",
            .closedByIOS: "Stopped when iOS closed Aloud",
        ]
        XCTAssertEqual(Set(expected.keys), Set(StopReason.allCases), "one row per reason")
        for reason in StopReason.allCases {
            XCTAssertEqual(reason.text, expected[reason], "\(reason)")
        }
    }

    func testEveryNoticeReadsExactly() {
        XCTAssertEqual(PlaybackNotice.fellBackToSystem.text, "Natural voice unavailable · using System")
        XCTAssertEqual(PlaybackNotice.nowReadingIn(voiceName: "Michael").text, "Now reading in Michael")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 2).text, "Backed up 2 sentences")
        XCTAssertEqual(PlaybackNotice.skippedSentence.text, "Skipped a sentence the voice couldn't read")
        XCTAssertEqual(PlaybackNotice.coolingDown.text, "Using the System voice while iPhone cools")
        XCTAssertEqual(PlaybackNotice.displaySeconds, 8)
    }

    func testBackedUpCountsItsSentences() {
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 1).text, "Backed up 1 sentence")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 2).text, "Backed up 2 sentences")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 4).text, "Backed up 4 sentences")
    }

    func testTheApostropheIsPlainASCII() {
        XCTAssertTrue(PlaybackNotice.skippedSentence.text.contains("'"))
        XCTAssertFalse(PlaybackNotice.skippedSentence.text.contains("\u{2019}"))
    }

    /// Worded by ListeningEstimate from the rewind itself (R25); the words
    /// are unchanged.
    func testStopCopy() {
        XCTAssertEqual(StopCopy.rewindMinutes, 5)
        XCTAssertEqual(StopCopy.backFiveMinutes, "Back 5 min")
        XCTAssertEqual(StopCopy.backFiveMinutesSpoken, "Back 5 minutes")
        XCTAssertEqual(StopCopy.backFiveMinutesHint, "Plays from 5 minutes earlier")
    }

    // MARK: - Spoken text

    func testSpokenTextNeverSaysTheMiddleDot() {
        let spoken = StopReason.allCases.map(\.spokenText) + Self.notices.map(\.spokenText)
        for line in spoken {
            XCTAssertFalse(line.contains("·"), "'\(line)'")
        }
        XCTAssertEqual(StopReason.headphonesDisconnected.spokenText, "Paused, headphones disconnected")
        XCTAssertEqual(StopReason.playbackError.spokenText, "Playback stopped, tap to try again")
        XCTAssertEqual(StopReason.tooHot.spokenText, "Paused, iPhone is too hot")
        XCTAssertEqual(StopReason.sleepTimer.spokenText, "Paused by sleep timer")
        XCTAssertEqual(PlaybackNotice.fellBackToSystem.spokenText, "Natural voice unavailable, using System")
    }

    func testSpokenFormTrimsATrailingEllipsis() {
        XCTAssertEqual(PlaybackCopy.spoken("Preparing voice…"), "Preparing voice")
        XCTAssertEqual(PlaybackCopy.spoken("Downloading natural voice · 42%"), "Downloading natural voice, 42%")
        XCTAssertEqual(PlaybackCopy.spoken("Paused by sleep timer"), "Paused by sleep timer")
    }

    func testNoCopyCarriesAnErrorDescription() {
        let all = StopReason.allCases.flatMap { [$0.text, $0.spokenText] }
            + Self.notices.flatMap { [$0.text, $0.spokenText] }
        for line in all {
            XCTAssertFalse(line.contains("Error Domain"), "'\(line)'")
        }
    }

    // MARK: - Persisted values

    func testStopAndLiveSessionRoundTripThroughJSON() throws {
        let stop = PlaybackStop(reason: .sleepTimer, documentID: UUID())
        let decodedStop = try JSONDecoder().decode(PlaybackStop.self, from: JSONEncoder().encode(stop))
        XCTAssertEqual(decodedStop, stop)

        let session = LiveSession(documentID: UUID(), sentenceIndex: 7,
                                  wallClock: Date(timeIntervalSinceReferenceDate: 1_000))
        let decodedSession = try JSONDecoder().decode(LiveSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decodedSession, session)
    }

    func testTheStopStoreKeepsOneSlotAndAOneShotMarker() {
        let defaults = PlaybackTestRig.freshDefaults()
        let store = PlaybackStopStore(defaults: defaults)
        XCTAssertNil(store.load())
        XCTAssertNil(store.takeLiveSession())

        let first = PlaybackStop(reason: .interrupted, documentID: UUID())
        let second = PlaybackStop(reason: .tooHot, documentID: UUID())
        store.save(first)
        store.save(second)
        XCTAssertEqual(store.load(), second, "one app-wide slot")

        let session = LiveSession(documentID: UUID(), sentenceIndex: 3,
                                  wallClock: Date(timeIntervalSinceReferenceDate: 2_000))
        store.markLive(session)
        XCTAssertEqual(store.takeLiveSession(), session)
        XCTAssertNil(store.takeLiveSession(), "taking the marker removes it")

        store.markLive(session)
        store.clearAll()
        XCTAssertNil(store.load())
        XCTAssertNil(store.takeLiveSession())

        defaults.set(Data("not json".utf8), forKey: PlaybackStopStore.stopKey)
        XCTAssertNil(store.load(), "an undecodable stop reads as none")
    }

    func testStoreKeys() {
        XCTAssertEqual(PlaybackStopStore.stopKey, "aloud.playback.stop.v1")
        XCTAssertEqual(PlaybackStopStore.liveSessionKey, "aloud.playback.liveSession.v1")
    }
}
