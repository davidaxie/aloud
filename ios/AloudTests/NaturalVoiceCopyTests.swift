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
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt, "Download 353 MB on cellular?")
        #else
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt, "Download 353 MB on a metered connection?")
        #endif
        XCTAssertEqual(NaturalVoiceCopy.privacyLine,
                       "Downloads once from Hugging Face. Nothing about you is sent.")
    }

    /// C1: the lines that name the device or its network come from the
    /// platform's copy, and on the iPhone read exactly as they always have.
    /// The iPhone prompt's message is the privacy line alone, since
    /// "cellular" already names the network; the Mac's names it first.
    func testDeviceLinesComeFromThePlatformCopy() {
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt, DeviceCopy.meteredPrompt)
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, DeviceCopy.waitingForNetwork)
        XCTAssertEqual(NaturalVoiceCopy.unsupported,
                       "The natural voice needs \(DeviceNoun.withArticle) with more memory.")
        #if os(iOS)
        XCTAssertNil(DeviceCopy.meteredDetail)
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage,
                       "Downloads once from Hugging Face. Nothing about you is sent.")
        #else
        XCTAssertEqual(DeviceCopy.meteredDetail, "Your Mac is using a Personal Hotspot or Low Data Mode.")
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage,
                       "Your Mac is using a Personal Hotspot or Low Data Mode. "
                       + "Downloads once from Hugging Face. Nothing about you is sent.")
        #endif
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
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.unsupported,
                       "The natural voice needs an iPhone with more memory.")
        #else
        XCTAssertEqual(NaturalVoiceCopy.unsupported,
                       "The natural voice needs a Mac with more memory.")
        #endif
    }

    // MARK: - R21

    func testDownloadStateCopy() {
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, "Download paused · waiting for Wi-Fi")
        #else
        XCTAssertEqual(NaturalVoiceCopy.waitingForWiFi, "Download paused · waiting for Wi-Fi or Ethernet")
        #endif
        XCTAssertEqual(NaturalVoiceCopy.installed, "Natural voice installed")
    }

    /// Where the installed voice lives: the iPhone's words, and the Mac's
    /// (PRD M17), through `DeviceCopy`.
    func testInstalledSizeNamesTheDevice() {
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on device · works offline")
        #else
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on this Mac · works offline")
        #endif
    }

    /// M17: the Mac's not-installed card says to download before the
    /// flight, or with no usable path to connect first. The iPhone's card
    /// has no such line, so it reads as it always has.
    func testPromoDetailIsTheMacsOnly() {
        XCTAssertEqual(NaturalVoiceCopy.beforeFlight,
                       "Download before you fly. After that, everything works offline.")
        #if os(iOS)
        XCTAssertFalse(PlatformVoiceSetup.preparesForFlight)
        XCTAssertNil(DeviceCopy.connectToDownload)
        XCTAssertNil(NaturalVoiceCopy.promoDetail(offline: false))
        XCTAssertNil(NaturalVoiceCopy.promoDetail(offline: true))
        #else
        XCTAssertTrue(PlatformVoiceSetup.preparesForFlight)
        XCTAssertEqual(DeviceCopy.connectToDownload, "Connect to the internet to download.")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: false),
                       "Download before you fly. After that, everything works offline.")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: true), "Connect to the internet to download.")
        #endif
    }

    /// The installed card's remove action asks first; on the Mac its
    /// title ends in an ellipsis, as a Mac button that opens a
    /// confirmation does. The iPhone's reads as it always has.
    func testRemoveDownloadTitle() {
        #if os(iOS)
        XCTAssertEqual(DeviceCopy.removeDownload, "Remove Download")
        #else
        XCTAssertEqual(DeviceCopy.removeDownload, "Remove Download\u{2026}")
        #endif
    }

    /// M10: the link to more System voices is the Mac's alone, with its
    /// pane; the iPhone's Listening view shows neither.
    func testAddSystemVoicesIsTheMacsOnly() {
        #if os(iOS)
        XCTAssertNil(DeviceCopy.addSystemVoices)
        XCTAssertNil(PlatformVoiceSetup.addVoicesURL)
        XCTAssertFalse(PlatformVoiceSetup.namesResolvedSystemVoice)
        #else
        XCTAssertEqual(DeviceCopy.addSystemVoices, "Add voices in System Settings\u{2026}")
        XCTAssertNotNil(PlatformVoiceSetup.addVoicesURL)
        XCTAssertTrue(PlatformVoiceSetup.namesResolvedSystemVoice)
        #endif
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
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi),
                       "Download paused, waiting for Wi-Fi")
        #else
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingForWiFi),
                       "Download paused, waiting for Wi-Fi or Ethernet")
        #endif
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
