import AVFoundation
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

    /// J007: after an attempt staged a file, the prompt names what is left.
    func testTheCellularPromptNamesTheSizeLeft() {
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: true, size: "28 MB"), "Download 28 MB on cellular?")
        #else
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: true, size: "28 MB"),
                       "Download 28 MB on a metered connection?")
        #endif
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: false, size: "28 MB"),
                       "Download 28 MB on a metered connection?")
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: true, size: ModelManager.downloadSizeText),
                       NaturalVoiceCopy.cellularPrompt)
    }

    /// H006: "on cellular?" only over cellular. A costly Wi-Fi (Low Data
    /// Mode, another phone's Personal Hotspot) is asked about as metered,
    /// the message names it, and its wait never says Wi-Fi is missing.
    func testACostlyWiFiIsNeverCalledCellular() {
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: true), NaturalVoiceCopy.cellularPrompt)
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage(onCellular: true), NaturalVoiceCopy.cellularPromptMessage)
        XCTAssertEqual(NaturalVoiceCopy.cellularPrompt(onCellular: false), "Download 353 MB on a metered connection?")
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage(onCellular: false),
                       "This Wi-Fi is a Personal Hotspot or uses Low Data Mode. "
                       + "Downloads once from Hugging Face. Nothing about you is sent.")
        #else
        XCTAssertEqual(NaturalVoiceCopy.cellularPromptMessage(onCellular: false), NaturalVoiceCopy.cellularPromptMessage)
        #endif
        XCTAssertEqual(NaturalVoiceCopy.waitingOnMeteredNetwork, "Download paused \u{00B7} Low Data Mode or hotspot")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.waitingOnMeteredNetwork),
                       "Download paused, Low Data Mode or hotspot")
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

    /// Where the installed voice lives: "on this iPhone" as the Mac's card
    /// says "on this Mac" (PRD M17, P040), through `DeviceCopy`.
    func testInstalledSizeNamesTheDevice() {
        #if os(iOS)
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on this iPhone · works offline")
        XCTAssertEqual(NaturalVoiceCopy.onDevice(ModelManager.downloadSizeText), "353 MB on this iPhone · works offline")
        #else
        XCTAssertEqual(NaturalVoiceCopy.onDevice("353 MB"), "353 MB on this Mac · works offline")
        #endif
    }

    /// M17: the Mac's not-installed card says to download before the
    /// flight, or with no usable path to connect first. P036: the iPhone's
    /// card says what the voice is and that it works offline, online or
    /// not, since it watches no path before a Download (M4).
    func testPromoDetailSaysWhatTheDownloadIsFor() {
        XCTAssertEqual(NaturalVoiceCopy.beforeFlight,
                       "Download before you fly. After that, everything works offline.")
        #if os(iOS)
        let promise = "Sounds like a person reading. Works offline once downloaded."
        XCTAssertFalse(PlatformVoiceSetup.preparesForFlight)
        XCTAssertNil(DeviceCopy.connectToDownload)
        XCTAssertEqual(DeviceCopy.naturalVoicePromise, promise)
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: false), promise)
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: true), promise)
        #else
        XCTAssertTrue(PlatformVoiceSetup.preparesForFlight)
        XCTAssertNil(DeviceCopy.naturalVoicePromise)
        XCTAssertEqual(DeviceCopy.connectToDownload, "Connect to the internet to download.")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: false),
                       "Download before you fly. After that, everything works offline.")
        XCTAssertEqual(NaturalVoiceCopy.promoDetail(offline: true), "Connect to the internet to download.")
        #endif
    }

    /// P040: Settings' Voice & speed row names the natural voice while it
    /// could be installed, with its size, and says it without the dot.
    func testNaturalVoiceAvailableLine() {
        XCTAssertEqual(NaturalVoiceCopy.available, "Natural voice available · 353 MB")
        XCTAssertEqual(NaturalVoiceCopy.spoken(NaturalVoiceCopy.available), "Natural voice available, 353 MB")
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
    /// pane. P035: both name the System voice; the iPhone, with no link to
    /// its pane, says where voices come from in a plain line instead.
    func testAddSystemVoicesIsTheMacsOnly() {
        XCTAssertTrue(PlatformVoiceSetup.namesResolvedSystemVoice)
        XCTAssertEqual(AVSpeechEngine(mutesOutput: true).defaultVoice.subtitle, DeviceCopy.systemVoiceFallback,
                       "the row's subtitle until it names its voice")
        #if os(iOS)
        XCTAssertNil(DeviceCopy.addSystemVoices)
        XCTAssertNil(PlatformVoiceSetup.addVoicesURL)
        XCTAssertEqual(DeviceCopy.systemVoiceFallback, "Built into iOS")
        // The pane iOS 26 renamed: the hint names the one this OS shows.
        if #available(iOS 26, *) {
            XCTAssertEqual(DeviceCopy.systemVoicesHint,
                           "More voices: Settings \u{203A} Accessibility \u{203A} Read & Speak \u{203A} Voices")
        } else {
            XCTAssertEqual(DeviceCopy.systemVoicesHint,
                           "More voices: Settings \u{203A} Accessibility \u{203A} Spoken Content \u{203A} Voices")
        }
        #else
        XCTAssertEqual(DeviceCopy.addSystemVoices, "Add voices in System Settings\u{2026}")
        XCTAssertNotNil(PlatformVoiceSetup.addVoicesURL)
        XCTAssertEqual(DeviceCopy.systemVoiceFallback, "Built-in fallback")
        XCTAssertNil(DeviceCopy.systemVoicesHint)
        #endif
    }

    /// P035, from a fake installed list ranked as synthesis ranks it: the
    /// System row names the voice it will speak in, says that name after
    /// its own, and shows the hint only below a premium voice (iPhone).
    func testTheSystemRowNamesItsVoiceAndHintsBelowPremium() {
        typealias Candidate = AVSpeechEngine.VoiceCandidate
        func resolved(_ voices: [Candidate]) -> (name: String, quality: AVSpeechSynthesisVoiceQuality)? {
            voices.min { AVSpeechEngine.ranks($0, above: $1) }
                .map { (name: AVSpeechEngine.displayName(of: $0), quality: AVSpeechEngine.quality(of: $0)) }
        }
        let hint = DeviceCopy.systemVoicesHint

        let enhanced = resolved([Candidate(name: "Fred", language: "en-US", quality: 1),
                                 Candidate(name: "Samantha", language: "en-US", quality: 2),
                                 Candidate(name: "Am\u{00E9}lie", language: "fr-CA", quality: 3)])
        XCTAssertEqual(enhanced?.name, "Samantha (Enhanced)")
        XCTAssertEqual(enhanced?.quality, .enhanced)
        let label = ListeningView.accessibilityLabel(name: "System voice", subtitle: enhanced?.name ?? "",
                                                     origin: "", spokenOrigin: "")
        XCTAssertEqual(label, "System voice, Samantha (Enhanced)", "the spoken label names the voice")

        let premium = resolved([Candidate(name: "Samantha", language: "en-US", quality: 2),
                                Candidate(name: "Ava", language: "en-US", quality: 3)])
        XCTAssertEqual(premium?.name, "Ava (Premium)")
        XCTAssertEqual(premium?.quality, .premium)

        let plain = resolved([Candidate(name: "Samantha", language: "en-US", quality: 1)])
        XCTAssertEqual(plain?.name, "Samantha")
        XCTAssertEqual(plain?.quality, .default)

        XCTAssertFalse(ListeningView.showsSystemVoicesHint(hint, quality: .premium), "nothing better to get")
        XCTAssertFalse(ListeningView.showsSystemVoicesHint(nil, quality: .default), "no hint, no line")
        #if os(iOS)
        XCTAssertTrue(ListeningView.showsSystemVoicesHint(hint, quality: .enhanced))
        XCTAssertTrue(ListeningView.showsSystemVoicesHint(hint, quality: .default))
        XCTAssertTrue(ListeningView.showsSystemVoicesHint(hint, quality: nil), "no installed voice to name")
        #else
        XCTAssertFalse(ListeningView.showsSystemVoicesHint(hint, quality: .enhanced), "the Mac has its link")
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
