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

    /// The Mac's table differs in the device and the lines `DeviceCopy`
    /// words per platform; each is pinned letter for letter (M12).
    func testEveryStoppedReasonReadsExactly() {
        #if os(iOS)
        let expected: [StopReason: String] = [
            .headphonesDisconnected: "Paused · headphones disconnected",
            .interrupted: "Paused by a call or another app",
            .sleepTimer: "Paused by sleep timer",
            .playbackError: "Playback stopped · tap to try again",
            .tooHot: "Paused · iPhone is too hot",
            .closedByIOS: "Stopped when iOS closed Aloud",
            .macSlept: "Paused · iPhone went to sleep",
        ]
        #else
        let expected: [StopReason: String] = [
            .headphonesDisconnected: "Paused · headphones disconnected",
            .interrupted: "Paused by a call or another app",
            .sleepTimer: "Paused by sleep timer",
            .playbackError: "Playback stopped",
            .tooHot: "Paused · your Mac is too hot",
            .closedByIOS: "Stopped when Aloud quit unexpectedly",
            .macSlept: "Paused · your Mac went to sleep",
        ]
        #endif
        XCTAssertEqual(Set(expected.keys), Set(StopReason.allCases), "one row per reason")
        for reason in StopReason.allCases {
            XCTAssertEqual(reason.text, expected[reason], "\(reason)")
        }
    }

    /// C1: the device in a stop or notice is `DeviceNoun`'s, and a line
    /// worded per platform is `DeviceCopy`'s, so the Mac's copy changes in
    /// one file.
    func testPlatformWordingComesFromDeviceNoun() {
        XCTAssertEqual(StopReason.closedByIOS.text, DeviceCopy.closedUnexpectedly)
        XCTAssertEqual(StopReason.tooHot.text, "Paused · \(DeviceNoun.subject) is too hot")
        XCTAssertEqual(StopReason.macSlept.text, "Paused · \(DeviceNoun.subject) went to sleep")
        XCTAssertEqual(PlaybackNotice.coolingDown.text, "Using the System voice while \(DeviceNoun.subject) cools")
    }

    func testEveryNoticeReadsExactly() {
        XCTAssertEqual(PlaybackNotice.fellBackToSystem.text, "Natural voice unavailable · using System")
        XCTAssertEqual(PlaybackNotice.nowReadingIn(voiceName: "Michael").text, "Now reading in Michael")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 2).text, "Backed up 2 sentences")
        XCTAssertEqual(PlaybackNotice.skippedSentence.text, "Skipped a sentence the voice couldn\u{2019}t read")
        #if os(iOS)
        XCTAssertEqual(PlaybackNotice.coolingDown.text, "Using the System voice while iPhone cools")
        #else
        XCTAssertEqual(PlaybackNotice.coolingDown.text, "Using the System voice while your Mac cools")
        #endif
        XCTAssertEqual(PlaybackNotice.displaySeconds, 8)
    }

    func testBackedUpCountsItsSentences() {
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 1).text, "Backed up 1 sentence")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 2).text, "Backed up 2 sentences")
        XCTAssertEqual(PlaybackNotice.backedUp(sentences: 4).text, "Backed up 4 sentences")
    }

    /// R2-33: copy sets typographer's marks, so the notice's apostrophe is
    /// the right single quote, never the typewriter one.
    func testTheApostropheIsTypographic() {
        XCTAssertTrue(PlaybackNotice.skippedSentence.text.contains("\u{2019}"))
        XCTAssertFalse(PlaybackNotice.skippedSentence.text.contains("'"))
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
        #if os(iOS)
        XCTAssertEqual(StopReason.playbackError.spokenText, "Playback stopped, tap to try again")
        XCTAssertEqual(StopReason.tooHot.spokenText, "Paused, iPhone is too hot")
        XCTAssertEqual(StopReason.macSlept.spokenText, "Paused, iPhone went to sleep")
        #else
        XCTAssertEqual(StopReason.playbackError.spokenText, "Playback stopped")
        XCTAssertEqual(StopReason.tooHot.spokenText, "Paused, your Mac is too hot")
        XCTAssertEqual(StopReason.macSlept.spokenText, "Paused, your Mac went to sleep")
        #endif
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

    /// The persisted names: a stop saved before the Mac work (or by the
    /// other platform) still reads back.
    func testStopReasonRawValuesAreStable() throws {
        XCTAssertEqual(StopReason.closedByIOS.rawValue, "closedByIOS")
        XCTAssertEqual(StopReason.macSlept.rawValue, "macSlept")
        let saved = Data(#"{"reason":"closedByIOS","documentID":"6B1F4E2A-3C5D-4E6F-8A9B-0C1D2E3F4A5B"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackStop.self, from: saved).reason, .closedByIOS)
    }

    func testStoreKeys() {
        XCTAssertEqual(PlaybackStopStore.stopKey, "aloud.playback.stop.v1")
        XCTAssertEqual(PlaybackStopStore.liveSessionKey, "aloud.playback.liveSession.v1")
    }
}
