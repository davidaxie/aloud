import XCTest
@testable import Aloud

/// R5/R8/R21 copy, verbatim from the PRD. Every surface reads these constants.
final class NaturalVoiceCopyTests: XCTestCase {

    func testOffer() {
        XCTAssertEqual(NaturalVoiceCopy.offer, "Natural voice · 353 MB, once")
        XCTAssertEqual(NaturalVoiceCopy.download, "Download")
        XCTAssertEqual(NaturalVoiceCopy.notNow, "Not now")
    }

    func testCellularPromptAndPrivacyLine() {
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt, "Download 353 MB on cellular?")
        XCTAssertEqual(NaturalVoiceCopy.privacyLine,
                       "Downloads once from Hugging Face. Nothing about you is sent.")
    }

    func testDownloadingTruncatesAndClamps() {
        XCTAssertEqual(NaturalVoiceCopy.downloading(0.42), "Downloading natural voice · 42%")
        XCTAssertTrue(NaturalVoiceCopy.downloading(0.999).hasSuffix("99%"),
                      "Never claims 100% before the files are in place")
        XCTAssertEqual(NaturalVoiceCopy.downloading(0), "Downloading natural voice · 0%")
        XCTAssertEqual(NaturalVoiceCopy.downloading(1.2), "Downloading natural voice · 100%")
        XCTAssertEqual(NaturalVoiceCopy.downloading(-0.1), "Downloading natural voice · 0%")
    }

    func testUnsupported() {
        XCTAssertEqual(NaturalVoiceCopy.unsupported,
                       "The natural voice needs an iPhone with more memory.")
    }

    // MARK: - R21

    func testDownloadStateCopy() {
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, "Download paused · waiting for Wi-Fi")
        XCTAssertEqual(NaturalVoiceCopy.installed, "Natural voice installed")
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on device · works offline")
    }

    /// M3: shown while files already on disk are hashed.
    func testVerifyingCopy() {
        XCTAssertEqual(NaturalVoiceCopy.verifying, "Checking voice files\u{2026}")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.verifying), "Checking voice files")
    }

    func testFailureParts() {
        let space = NaturalVoiceCopy.failure(.notEnoughSpace)
        XCTAssertEqual(space.status, "Not enough space")
        XCTAssertEqual(space.detail, "need 707 MB free")
        XCTAssertFalse(space.detailIsAction, "Nothing to tap until there is room")
        let interrupted = NaturalVoiceCopy.failure(.interrupted)
        XCTAssertEqual(interrupted.status, "Download failed")
        XCTAssertEqual(interrupted.detail, "Try again")
        XCTAssertTrue(interrupted.detailIsAction)
        let damaged = NaturalVoiceCopy.failure(.damaged)
        XCTAssertEqual(damaged.status, "Voice files damaged")
        XCTAssertEqual(damaged.detail, "Download again")
        XCTAssertTrue(damaged.detailIsAction)
    }

    func testFailureLines() {
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.notEnoughSpace), "Not enough space · need 707 MB free")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.interrupted), "Download failed · Try again")
        XCTAssertEqual(NaturalVoiceCopy.failureLine(.damaged), "Voice files damaged · Download again")
    }

    /// One line for the offer row and the Continue card (R5). After a
    /// failed space check it says so and still names the voice (R21).
    func testOfferLineNamesTheVoiceAfterASpaceFailure() {
        XCTAssertEqual(NaturalVoiceCopy.offerLine(modelState: .failed(.notEnoughSpace)),
                       "Natural voice · not enough space · need 707 MB free")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.offerLine(modelState: .failed(.notEnoughSpace))),
                       "Natural voice, not enough space, need 707 MB free")
        let others: [ModelManager.ModelState] = [.notInstalled, .downloading(0.4), .waitingForWiFi(0.4), .installed,
                                                 .failed(.interrupted), .failed(.damaged)]
        for state in others {
            XCTAssertEqual(NaturalVoiceCopy.offerLine(modelState: state), NaturalVoiceCopy.offer, "\(state)")
        }
    }

    func testSpokenForms() {
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi),
                       "Download paused, waiting for Wi-Fi")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(.notEnoughSpace)),
                       "Not enough space, need 707 MB free")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(.interrupted)),
                       "Download failed, Try again")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.failureLine(.damaged)),
                       "Voice files damaged, Download again")
    }

    func testNowReadingInNotice() {
        XCTAssertEqual(PlaybackNotice.nowReadingIn(voiceName: "Michael").text,
                       "Now reading in Michael")
    }
}
