import XCTest

/// Aloud on a plane (M4's airplane acceptance, M17): under `-uitest-offline`
/// the network path reads as unsatisfied and every request is refused, and
/// still the Library, Classics and a book open and reach "playing" in the
/// System voice; Settings › Voice & speed shows the natural-voice card's
/// honest offline state ("Connect to the internet to download.", Download
/// disabled); R5's offer never appears past 60 s of listening, though it
/// does once a path exists (the control); and the natural voice, read
/// from `/Users/Shared/AloudKokoroModel` through `-uitest-kokoro-model-path`
/// so nothing downloads, reaches "playing" in Michael and keeps reading.
///
/// No test clicks Download, a voice row or "Add voices in System
/// Settings…", and keys go only through `press(_:in:)`. Every launch goes
/// through `XCUIApplication.aloud`, so it is muted; autoplay only where a
/// book must be speaking. Runs only in the consented `AloudMacUI` scheme.
/// The manual half, on the Release build with Wi-Fi off, is
/// docs/mac-airplane-check.md.
final class OfflineMacUITests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    /// No path and no request, as on a plane.
    private static let offline = ["-uitest-offline"]

    /// The pre-placed natural voice (testing §2.6), filled once by
    /// ios/tools/fetch_kokoro_model.sh; the Debug entitlement's one
    /// read-only exception.
    private static let modelDirectory = "/Users/Shared/AloudKokoroModel"

    /// Two seconds short of R5's minute: a little playback crosses it.
    private static let almostAMinute = ["-uitest-listened-seconds", "58"]

    private static let connectToDownload = "Connect to the internet to download."
    private static let installedDetail = "353 MB on this Mac \u{00B7} works offline"
    private static let addVoices = "Add voices in System Settings\u{2026}"
    private static let offerText = "Natural voice \u{00B7} 353 MB, once"

    // MARK: - Helpers

    private func launch(_ arguments: [String], allowAutoplay: Bool = false) -> MacSuite {
        let app = XCUIApplication.aloud(arguments, allowAutoplay: allowAutoplay)
        self.app = app
        launchAloud(app)
        return MacSuite(app: app)
    }

    private func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        root.descendants(matching: .any)[identifier].firstMatch
    }

    /// Whether `element` reads `text`: a SwiftUI Text carries it as its
    /// label, an AppKit field as its value.
    private func reads(_ element: XCUIElement, _ text: String, in suite: MacSuite) -> Bool {
        element.exists && (element.label == text || suite.text(element) == text)
    }

    /// The Voice & speed tab of the Settings window ⌘, opens; nil when it
    /// doesn't show. A Settings tab is a toolbar button, a radio button or
    /// a tab by the macOS version, and a click on the selected one is
    /// harmless.
    private func openVoiceAndSpeed(_ suite: MacSuite) -> XCUIElement? {
        press(.settings, in: suite.app)
        let window = suite.settingsWindow
        guard window.waitForExistence(timeout: 10) else { return nil }
        _ = window.toolbars.firstMatch.waitForExistence(timeout: 5)
        let tab = "Voice & speed"
        let tabs = [window.toolbars.buttons[tab], window.buttons[tab], window.radioButtons[tab], window.tabs[tab]]
        tabs.map(\.firstMatch).first(where: \.exists)?.click()
        return element("settings.tab.listening", in: window).waitForExistence(timeout: 5) ? window : nil
    }

    /// The voice chip's name: "System" or "Michael" (its label leads with
    /// the voice's short name).
    private func chipVoice(_ suite: MacSuite) -> String {
        let chip = suite.app.buttons["player.listening"].firstMatch
        guard chip.exists else { return "" }
        return chip.label.components(separatedBy: ",").first ?? ""
    }

    private func isOfferShown(_ suite: MacSuite) -> Bool {
        suite.element("naturalVoice.offer").exists
    }

    // MARK: - The System voice

    /// The empty Library, Classics with its bundled sections, and a search
    /// hit that one click adds, opens and plays: none of it needs a path.
    func testTheLibraryClassicsAndABookPlayOfflineInTheSystemVoice() {
        let suite = launch(MacSuite.fresh + Self.offline, allowAutoplay: true)
        XCTAssertTrue(suite.element("library.featured").waitForExistence(timeout: 20), "the Library opens")
        let more = suite.element("library.moreClassics")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()

        XCTAssertTrue(suite.element("bookshelf.list").waitForExistence(timeout: 10), "Classics opens")
        let sections = suite.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bookshelf.section.'"))
        XCTAssertTrue(suite.poll(timeout: 10) { sections.count > 0 }, "the bundled shelf shows its sections")

        suite.focusClassicsSearch(self, typing: "pride")
        XCTAssertEqual(suite.fieldText, "pride", "⌘F focuses the search field and it takes the typing")
        let top = suite.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bookshelf.row.'")).firstMatch
        XCTAssertTrue(suite.poll(timeout: 5) { top.exists && top.identifier == "bookshelf.row.1342" },
                      "Pride and Prejudice comes first, got '\(top.exists ? top.identifier : "no rows")'")
        top.click()

        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 90),
                      "the classic plays offline, got '\(suite.playValue ?? "nil")'")
        XCTAssertTrue(suite.pageText.exists, "the page shows the bundled text")
        XCTAssertEqual(chipVoice(suite), "System", "with no model, the System voice reads")
        XCTAssertEqual(suite.modals, 0, "nothing apologises for being offline")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - The natural-voice card

    /// M17's offline state: the line says what to do first, Download can't
    /// be pressed, and the promise of a download that can't start is gone.
    /// The System voice's "Add voices in System Settings…" stays (never
    /// clicked: it opens System Settings).
    func testSettingsShowsTheOfflineCard() {
        let suite = launch(MacSuite.fresh + Self.offline)
        XCTAssertTrue(suite.element("library.featured").waitForExistence(timeout: 20), "the Library opens")
        guard let window = openVoiceAndSpeed(suite) else { return XCTFail("⌘, shows Voice & speed") }

        let line = element("model.offline", in: window)
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the card knows there is no path")
        XCTAssertTrue(reads(line, Self.connectToDownload, in: suite), "got '\(line.label)' '\(suite.text(line))'")
        XCTAssertFalse(element("model.beforeFlight", in: window).exists, "no promise of a download that can't start")

        let title = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                            Self.offerText, Self.offerText)).firstMatch
        XCTAssertTrue(title.exists, "the card still names the voice and its size")
        let download = element("model.download", in: window)
        XCTAssertTrue(download.exists, "the card keeps its Download")
        XCTAssertFalse(download.isEnabled, "Download is disabled offline")
        for identifier in ["model.progress", "model.waiting", "model.failure"] {
            XCTAssertFalse(element(identifier, in: window).exists, "\(identifier): nothing started")
        }

        let addVoices = element("listening.addVoices", in: window)
        XCTAssertTrue(addVoices.exists, "the System voice's voices are a link away")
        XCTAssertTrue(reads(addVoices, Self.addVoices, in: suite), "got '\(addVoices.label)'")
        // Alerts and sheets only: the Settings window itself may read as a
        // dialog.
        XCTAssertEqual(suite.app.alerts.count + suite.app.sheets.count, 0, "nothing apologises for being offline")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - R5's offer

    /// Past the minute (58 s preset, then 20 s of playback), the offer
    /// never shows in the chapter line or on the Continue card: offline it
    /// could only fail. Each new sentence folds the time listened in, and
    /// the pause at the end folds in the rest, so the minute is surely
    /// behind it when it is checked again.
    func testTheOfferNeverAppearsOffline() {
        let suite = launch(MacSuite.firstClassicReader + Self.almostAMinute + Self.offline, allowAutoplay: true)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "the reader opens")
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60), "the book plays, got '\(suite.playValue ?? "nil")'")
        let start = suite.playhead ?? 0

        XCTAssertFalse(suite.poll(timeout: 20) { isOfferShown(suite) }, "no offer offline while reading")
        XCTAssertGreaterThan(suite.playhead ?? 0, start, "the book read on, sentence by sentence")
        XCTAssertTrue(["playing", "buffering"].contains(suite.playValue ?? ""), "still reading")
        suite.play.click()
        XCTAssertTrue(suite.waitForPlay(["paused"], timeout: 10), "one click pauses")
        XCTAssertFalse(suite.poll(timeout: 3) { isOfferShown(suite) }, "no offer offline, even past the minute")

        XCTAssertTrue(suite.backToLibrary(self), "⌘[ walks back to the Library")
        let card = suite.element("library.continue")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the book is the Continue card")
        XCTAssertFalse(card.label.contains("Natural voice") || suite.text(card).contains("Natural voice"),
                       "the card doesn't offer it either, got '\(suite.text(card))'")
        XCTAssertFalse(isOfferShown(suite))
        XCTAssertEqual(suite.beeps, 0)
    }

    /// The control: the same launch with a path (a fixed costly one, so no
    /// monitor starts and no request is made) shows the offer, so the
    /// offline test above can't pass for want of a minute. Download is
    /// never clicked.
    func testTheOfferAppearsOnceAPathExists() {
        let suite = launch(MacSuite.firstClassicReader + Self.almostAMinute + ["-uitest-expensive-network"],
                           allowAutoplay: true)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "the reader opens")
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 60), "the book plays, got '\(suite.playValue ?? "nil")'")
        XCTAssertTrue(suite.poll(timeout: 30) { isOfferShown(suite) }, "with a path, the offer comes after the minute")
        let offer = suite.element("naturalVoice.offer")
        XCTAssertTrue(offer.label.hasPrefix(Self.offerText) || suite.text(offer).hasPrefix(Self.offerText),
                      "got '\(offer.label)'")
        XCTAssertTrue(["playing", "buffering"].contains(suite.playValue ?? ""), "the offer never stops playback")
        XCTAssertEqual(suite.beeps, 0)
    }

    // MARK: - The natural voice

    /// Installed before the flight, Michael is the voice; Settings says
    /// it's on this Mac and works offline; and Play reads in Michael with
    /// no path, warm-up included, and goes on reading (a synthesis failure
    /// would fall back to the System voice and rename the chip).
    func testTheNaturalVoiceReadsOffline() throws {
        for name in ["model.onnx", "voices.bin"] {
            let path = Self.modelDirectory + "/" + name
            try XCTSkipUnless(FileManager.default.isReadableFile(atPath: path),
                              "\(path) is missing or unreadable: run ios/tools/fetch_kokoro_model.sh "
                                + "(353 MB, with the owner's OK)")
        }
        // Not `MacSuite.fresh`: its temporary model directory wins over the
        // seeded one, and the model would read as absent.
        let suite = launch(["-uitest-reset-library", "-uitest-reset-voice-pref", "-uitest-reset-natural-voice-offer",
                            "-uitest-kokoro-model-path", Self.modelDirectory,
                            "-uitest-seed-first-classic", "-uitest-open-first-doc"] + Self.offline)
        XCTAssertTrue(suite.play.waitForExistence(timeout: 30), "the reader opens")
        XCTAssertTrue(suite.poll(timeout: 10) { chipVoice(suite) == "Michael" },
                      "with the model installed, Michael reads, got '\(chipVoice(suite))' (a damaged seed reads "
                        + "System: rerun ios/tools/fetch_kokoro_model.sh)")

        guard let window = openVoiceAndSpeed(suite) else { return XCTFail("⌘, shows Voice & speed") }
        let detail = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                             Self.installedDetail, Self.installedDetail)).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the card says '\(Self.installedDetail)'")
        XCTAssertTrue(element("model.remove", in: window).exists, "installed, it offers Remove Download…")
        XCTAssertTrue(element("voice.kokoro:am_michael", in: window).exists, "the natural voices are listed")
        for identifier in ["model.download", "model.offline", "model.beforeFlight"] {
            XCTAssertFalse(element(identifier, in: window).exists, "\(identifier): nothing left to download")
        }
        press(.closeWindow, in: suite.app)
        XCTAssertTrue(suite.poll(timeout: 5) { !suite.settingsWindow.exists }, "⌘W closes Settings")

        XCTAssertEqual(suite.playValue, "paused", "a UI-test launch never autoplays")
        suite.play.click()
        XCTAssertTrue(suite.waitForPlay(["playing"], timeout: 120),
                      "Michael reads offline, warm-up included, got '\(suite.playValue ?? "nil")'")
        XCTAssertEqual(chipVoice(suite), "Michael", "still the natural voice")

        let start = suite.playhead ?? 0
        XCTAssertTrue(suite.poll(timeout: 30) { (suite.playhead ?? 0) > start }, "and it goes on to the next sentence")
        XCTAssertTrue(["playing", "buffering"].contains(suite.playValue ?? ""), "still reading")
        XCTAssertEqual(chipVoice(suite), "Michael", "no fallback to the System voice")
        XCTAssertFalse(isOfferShown(suite), "installed, there is nothing to offer")
        XCTAssertEqual(suite.modals, 0)
        XCTAssertEqual(suite.beeps, 0)
    }
}
