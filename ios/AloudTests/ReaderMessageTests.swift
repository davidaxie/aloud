import XCTest
@testable import Aloud

/// R11's state matrix: the chapter line shows at most one message, by
/// precedence stop > notice > offer > download progress > waiting for Wi-Fi
/// > preparing voice > position, and the chip slot above the player shows at
/// most one chip, Undo jump over Follow the voice. The two slots read
/// disjoint inputs, so neither can change what the other shows.
final class ReaderMessageTests: XCTestCase {

    private let michael = PlaybackNotice.nowReadingIn(voiceName: "Michael")

    private let stops: [StopReason?] = [nil] + StopReason.allCases.map(Optional.some)
    private var notices: [PlaybackNotice?] { [nil, michael, .skippedSentence] }
    private let modelStates: [ModelManager.ModelState] = [
        .notInstalled, .downloading(0.42), .waitingForWiFi(0.3), .failed(.interrupted), .installed,
    ]
    private let offscreen: [ReaderFollowDirection?] = [nil, .up, .down]

    /// Spelled out case by case, independently of `resolve`.
    private func expectedMessage(stop: StopReason?, notice: PlaybackNotice?, offerVisible: Bool,
                                 modelState: ModelManager.ModelState, isPreparingVoice: Bool) -> ReaderMessage? {
        if let stop { return .stopped(stop) }
        if let notice { return .notice(notice) }
        if offerVisible { return .naturalVoiceOffer }
        if modelState == .downloading(0.42) { return .downloadProgress(0.42) }
        if modelState == .waitingForWiFi(0.3) { return .downloadWaiting(NaturalVoiceCopy.waitingForWiFi) }
        if isPreparingVoice { return .preparingVoice }
        return nil
    }

    private func expectedChip(canUndoJump: Bool, voiceOffscreen: ReaderFollowDirection?) -> ReaderChip? {
        if canUndoJump { return .undoJump }
        if let voiceOffscreen { return .followVoice(voiceOffscreen) }
        return nil
    }

    func testStateMatrix() {
        var checked = 0
        // Per message-input combination, every message seen across the chip
        // inputs (and the reverse): exactly one each means the slots are
        // independent.
        var messagesByInput: [String: Set<String>] = [:]
        var chipsByInput: [String: Set<String>] = [:]

        for stop in stops {
            for notice in notices {
                for offerVisible in [false, true] {
                    for modelState in modelStates {
                        for isPreparingVoice in [false, true] {
                            let messageKey = "\(String(describing: stop)) \(String(describing: notice)) "
                                + "offer \(offerVisible) \(modelState) preparing \(isPreparingVoice)"
                            for canUndoJump in [false, true] {
                                for voiceOffscreen in offscreen {
                                    let chipKey = "undo \(canUndoJump) offscreen \(String(describing: voiceOffscreen))"
                                    let message = ReaderMessage.resolve(stop: stop,
                                                                        notice: notice,
                                                                        offerVisible: offerVisible,
                                                                        modelState: modelState,
                                                                        isPreparingVoice: isPreparingVoice)
                                    let chip = ReaderChip.resolve(canUndoJump: canUndoJump,
                                                                  voiceOffscreen: voiceOffscreen)
                                    XCTAssertEqual(message,
                                                   expectedMessage(stop: stop, notice: notice,
                                                                   offerVisible: offerVisible,
                                                                   modelState: modelState,
                                                                   isPreparingVoice: isPreparingVoice),
                                                   "\(messageKey), \(chipKey)")
                                    XCTAssertEqual(chip,
                                                   expectedChip(canUndoJump: canUndoJump,
                                                                voiceOffscreen: voiceOffscreen),
                                                   "\(messageKey), \(chipKey)")
                                    messagesByInput[messageKey, default: []].insert(String(describing: message))
                                    chipsByInput[chipKey, default: []].insert(String(describing: chip))
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        // 8 stops (with the Mac's sleep) × 3 notices × 2 offers × 5 model
        // states × 2 preparing × 2 undo × 3 follow.
        XCTAssertEqual(checked, 2880)
        XCTAssertEqual(messagesByInput.count, 480)
        XCTAssertEqual(chipsByInput.count, 6)
        for (input, messages) in messagesByInput {
            XCTAssertEqual(messages.count, 1, "the chip inputs changed the message for \(input): \(messages)")
        }
        for (input, chips) in chipsByInput {
            XCTAssertEqual(chips.count, 1, "the message inputs changed the chip for \(input): \(chips)")
        }
    }

    func testSpotChecks() {
        // A stop outranks everything, even a fresh notice.
        XCTAssertEqual(ReaderMessage.resolve(stop: .headphonesDisconnected, notice: michael, offerVisible: true,
                                             modelState: .downloading(0.5), isPreparingVoice: true),
                       .stopped(.headphonesDisconnected))
        // Waiting for Wi-Fi sits with download progress, above preparing.
        XCTAssertEqual(ReaderMessage.resolve(stop: nil, notice: nil, offerVisible: false,
                                             modelState: .waitingForWiFi(0.6), isPreparingVoice: true),
                       .downloadWaiting(NaturalVoiceCopy.waitingForWiFi))
        // F021: a run allowed onto cellular waits for any connection, and
        // the line says so, as the download card does.
        let anyConnection = ReaderMessage.resolve(stop: nil, notice: nil, offerVisible: false,
                                                  modelState: .waitingForWiFi(0.6),
                                                  waitingLine: NaturalVoiceCopy.waitingForConnection,
                                                  isPreparingVoice: false)
        XCTAssertEqual(anyConnection, .downloadWaiting(NaturalVoiceCopy.waitingForConnection))
        XCTAssertEqual(anyConnection?.text, "Download paused · waiting for a connection")
        XCTAssertEqual(anyConnection?.spokenText, "Download paused, waiting for a connection")
        XCTAssertEqual(anyConnection?.slotKey, "download")
        // Failures show on the card (and the space line in the offer), never here.
        for failure in ModelManager.DownloadFailure.allCases {
            XCTAssertNil(ReaderMessage.resolve(stop: nil, notice: nil, offerVisible: false,
                                               modelState: .failed(failure), isPreparingVoice: false),
                         "\(failure)")
        }
        // Nothing to say: the line shows the position.
        XCTAssertNil(ReaderMessage.resolve(stop: nil, notice: nil, offerVisible: false,
                                           modelState: .installed, isPreparingVoice: false))
    }

    func testText() {
        XCTAssertEqual(ReaderMessage.stopped(.sleepTimer).text, "Paused by sleep timer")
        #if os(iOS)
        XCTAssertEqual(ReaderMessage.stopped(.playbackError).text, "Playback stopped · tap to try again")
        #else
        XCTAssertEqual(ReaderMessage.stopped(.playbackError).text, "Playback stopped")
        #endif
        for reason in StopReason.allCases {
            XCTAssertEqual(ReaderMessage.stopped(reason).text, reason.text)
            XCTAssertEqual(ReaderMessage.stopped(reason).spokenText, reason.spokenText)
        }
        XCTAssertEqual(ReaderMessage.notice(michael).text, "Now reading in Michael")
        XCTAssertEqual(ReaderMessage.naturalVoiceOffer.text, NaturalVoiceCopy.offer)
        XCTAssertEqual(ReaderMessage.downloadProgress(0.42).text, "Downloading natural voice · 42%")
        #if os(iOS)
        XCTAssertEqual(ReaderMessage.downloadWaiting(NaturalVoiceCopy.waitingForWiFi).text, "Download paused · waiting for Wi-Fi")
        #else
        XCTAssertEqual(ReaderMessage.downloadWaiting(NaturalVoiceCopy.waitingForWiFi).text, "Download paused · waiting for Wi-Fi or Ethernet")
        #endif
        XCTAssertEqual(ReaderMessage.preparingVoice.text, "Preparing voice…")
    }

    func testSpokenTextDropsTheMiddleDot() {
        let messages: [ReaderMessage] = StopReason.allCases.map { .stopped($0) } + [
            .notice(michael), .notice(.fellBackToSystem), .notice(.backedUp(sentences: 2)),
            .notice(.skippedSentence), .notice(.coolingDown),
            .naturalVoiceOffer, .downloadProgress(0.42), .downloadWaiting(NaturalVoiceCopy.waitingForWiFi), .preparingVoice,
        ]
        for message in messages {
            XCTAssertFalse(message.spokenText.contains("·"), "\(message): \(message.spokenText)")
            XCTAssertFalse(message.spokenText.hasSuffix("…"), "\(message): \(message.spokenText)")
        }
        #if os(iOS)
        XCTAssertEqual(ReaderMessage.stopped(.playbackError).spokenText, "Playback stopped, tap to try again")
        XCTAssertEqual(ReaderMessage.downloadWaiting(NaturalVoiceCopy.waitingForWiFi).spokenText, "Download paused, waiting for Wi-Fi")
        #else
        XCTAssertEqual(ReaderMessage.stopped(.playbackError).spokenText, "Playback stopped")
        XCTAssertEqual(ReaderMessage.downloadWaiting(NaturalVoiceCopy.waitingForWiFi).spokenText, "Download paused, waiting for Wi-Fi or Ethernet")
        #endif
        XCTAssertEqual(ReaderMessage.preparingVoice.spokenText, "Preparing voice")
    }

    func testSlotKeys() {
        let stopKeys = StopReason.allCases.map { ReaderMessage.stopped($0).slotKey }
        XCTAssertEqual(Set(stopKeys).count, StopReason.allCases.count, "each stop reason crossfades on its own")
        XCTAssertEqual(stopKeys, StopReason.allCases.map { "stopped.\($0.rawValue)" })

        XCTAssertEqual(ReaderMessage.downloadProgress(0.1).slotKey,
                       ReaderMessage.downloadProgress(0.9).slotKey,
                       "Progress ticks must not animate the slot")
        XCTAssertEqual(ReaderMessage.downloadWaiting(NaturalVoiceCopy.waitingForWiFi).slotKey, ReaderMessage.downloadProgress(0.5).slotKey,
                       "Pausing for Wi-Fi is the same download line")
        XCTAssertEqual(ReaderMessage.notice(michael).slotKey, ReaderMessage.notice(.skippedSentence).slotKey)

        let others = [ReaderMessage.notice(michael), .naturalVoiceOffer, .downloadProgress(0.5), .preparingVoice]
            .map(\.slotKey)
        XCTAssertEqual(others, ["notice", "offer", "download", "preparing"])
        let all = stopKeys + others
        XCTAssertEqual(Set(all).count, all.count, "slot keys never collide")
        XCTAssertFalse(all.contains("position"), "\"position\" is reserved for the nil slot")
    }

    /// R1-44: a line set on its row's foot (the iPhone bar) lifts its ink
    /// 4pt off the foot, less as the ink nearly fills the 44pt row, and not
    /// at all once it is a row tall: the ink never rises past the row's
    /// top and the row never grows.
    func testTheFootLiftNeverGrowsTheRow() {
        XCTAssertEqual(ReaderMessageLine.rowHeight, 44)
        XCTAssertEqual(ReaderMessageLine.footInset, 4)
        XCTAssertEqual(ReaderMessageLine.footLift(inkHeight: 18), 4, "one line at the default size")
        XCTAssertEqual(ReaderMessageLine.footLift(inkHeight: 40), 4)
        XCTAssertEqual(ReaderMessageLine.footLift(inkHeight: 42), 2)
        XCTAssertEqual(ReaderMessageLine.footLift(inkHeight: 44), 0)
        XCTAssertEqual(ReaderMessageLine.footLift(inkHeight: 90), 0, "a stacked line fills its own row")
        for height in stride(from: CGFloat(0), through: 100, by: 0.5) {
            let lift = ReaderMessageLine.footLift(inkHeight: height)
            XCTAssertGreaterThanOrEqual(lift, 0)
            XCTAssertLessThanOrEqual(height + lift, max(ReaderMessageLine.rowHeight, height), "\(height) pt of ink")
        }
    }
}
