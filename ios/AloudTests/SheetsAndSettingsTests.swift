import SwiftUI
import XCTest
@testable import Aloud

/// Batch B5 of the iPhone parity plan: one text-size step rule for every
/// control (P039), Settings' rows saying their values (P040) and the Voice
/// & speed sheet's opening detent (P034), and the license texts both apps
/// ship (R2-20). The shared parts run on both hosts; the iPhone's own views
/// only on the iOS host.
final class SheetsAndSettingsTests: XCTestCase {

    // MARK: - P039: one step rule

    /// The iPhone's A−/A+ and VoiceOver adjust and the Mac's commands step
    /// through `ReaderTextSize.stepped`: one step each way, nil at the ends.
    func testTextSizeStepsStopAtBothEnds() {
        XCTAssertEqual(ReaderTextSize.stepped(from: 2, bigger: true), 3)
        XCTAssertEqual(ReaderTextSize.points(forStep: 2), 19)
        XCTAssertEqual(ReaderTextSize.points(forStep: 3), 21, "an adjust up from 19 pt lands on 21 pt")
        XCTAssertEqual(ReaderTextSize.stepped(from: 2, bigger: false), 1)
        XCTAssertNil(ReaderTextSize.stepped(from: 0, bigger: false), "16 pt is the smallest")
        let last = ReaderTextSize.steps.count - 1
        XCTAssertEqual(ReaderTextSize.points(forStep: last), 40)
        XCTAssertNil(ReaderTextSize.stepped(from: last, bigger: true), "40 pt is the largest")
        XCTAssertEqual(ReaderTextSize.stepped(from: last - 1, bigger: true), last)
        // A stored value out of range reads as its nearest end first.
        XCTAssertEqual(ReaderTextSize.stepped(from: 12, bigger: false), last - 1)
        XCTAssertNil(ReaderTextSize.stepped(from: 12, bigger: true))
        XCTAssertEqual(ReaderTextSize.stepped(from: -3, bigger: true), 1)
    }

    /// The size readout as shown and as VoiceOver says it.
    func testTextSizeReadsInPointsAndSaysPoint() {
        XCTAssertEqual(AppearanceCopy.points(19), "19 pt")
        XCTAssertEqual(AppearanceCopy.spokenPoints(19), "19 point")
        XCTAssertEqual(AppearanceCopy.spokenPoints(40), "40 point")
        XCTAssertEqual(AppearanceCopy.textSize, "Text size")
        XCTAssertEqual(AppearanceCopy.appearance, "Appearance")
    }

    // MARK: - P040: the rows say their values

    func testTheAppearanceSummaryNamesSizeAndScheme() {
        XCTAssertEqual(AppearanceCopy.summary(points: 19, appearance: .dark), "19 pt \u{00B7} Dark")
        XCTAssertEqual(AppearanceCopy.summary(points: 23, appearance: .system), "23 pt \u{00B7} System")
        XCTAssertEqual(AppearanceCopy.summary(points: 16, appearance: .light), "16 pt \u{00B7} Light")
        XCTAssertEqual(AppearanceCopy.spokenSummary(points: 19, appearance: .dark), "19 point, Dark appearance")
        for preference in AppearancePreference.allCases {
            XCTAssertFalse(AppearanceCopy.spokenSummary(points: 19, appearance: preference).contains("\u{00B7}"),
                           "VoiceOver would read the middle dot aloud")
        }
    }

    #if os(iOS)
    /// R2-17: the reader sheets close with one button, named Close; Voice
    /// Control also answers to the Aa sheet's old Done.
    func testTheReaderSheetsCloseWithOneNamedButton() {
        XCTAssertEqual(SheetCopy.close, "Close")
        XCTAssertEqual(SheetCopy.closeInputLabels, ["Close", "Done"])
    }

    /// The rows' spoken labels: the title first, so Voice Control still
    /// matches it, then the value in words.
    func testTheSettingsRowsSayTheirValuesAfterTheirTitles() {
        XCTAssertEqual(SettingsView.appearanceRowSpokenLabel(points: 19, appearance: .dark),
                       "Text & appearance, 19 point, Dark appearance")
        XCTAssertEqual(SettingsView.appearanceRowSpokenLabel(points: 21, appearance: .system),
                       "Text & appearance, 21 point, System appearance")

        let system = AVSpeechEngine(mutesOutput: true).defaultVoice
        XCTAssertEqual(SettingsView.listeningRowSpokenLabel(voice: system, rate: 1), "Voice & speed, System, 1×",
                       "no natural-voice line, nothing more said")
        let line = SettingsView.naturalVoiceLine(supported: true, state: .notInstalled)
        XCTAssertEqual(line, "Natural voice available \u{00B7} 353 MB")
        XCTAssertEqual(SettingsView.listeningRowSpokenLabel(voice: system, rate: 1, naturalVoice: line),
                       "Voice & speed, System, 1×, Natural voice available, 353 MB")
    }

    /// The natural voice's line shows only where it could be installed and
    /// nothing is fetching it: never while a download is under way or waits
    /// for Wi-Fi, when the pushed card says so.
    func testTheNaturalVoiceLineShowsOnlyWhileItCouldBeInstalled() {
        XCTAssertNotNil(SettingsView.naturalVoiceLine(supported: true, state: .notInstalled))
        XCTAssertNotNil(SettingsView.naturalVoiceLine(supported: true, state: .failed(.interrupted)),
                        "a failed download can be tried again")
        XCTAssertNil(SettingsView.naturalVoiceLine(supported: true, state: .downloading(0.4)), "on its way")
        XCTAssertNil(SettingsView.naturalVoiceLine(supported: true, state: .waitingForWiFi(0.4)),
                     "paused for Wi-Fi")
        XCTAssertNil(SettingsView.naturalVoiceLine(supported: true, state: .installed), "already installed")
        XCTAssertNil(SettingsView.naturalVoiceLine(supported: false, state: .notInstalled), "it can't run here")
    }

    // MARK: - P034: the Voice & speed sheet

    /// The sheet opens at 60% of the screen, so the page and its sentence
    /// stay in view above it, and drags up to the full list. Two detents,
    /// so the system indicator (VoiceOver's resize control) stays.
    func testTheVoiceSheetOpensAtSixtyPercentAndGrowsToLarge() {
        XCTAssertEqual(ListeningSheet.openingDetent, .fraction(0.6))
        XCTAssertEqual(ListeningSheet.detents, [.fraction(0.6), .large])
    }
    #endif

    // MARK: - R2-20: the license texts ship in both apps

    /// R2-20: every component's license text ships in the app bundle (both
    /// apps' Resources/Licenses), and is the license it names. Hosted on
    /// both apps, never in the iPhone-only lint suite, so a Licenses folder
    /// missing from either app's bundle fails here.
    func testEveryLicenseTextShipsInTheBundle() throws {
        let expected = ["sherpa-onnx": ["Apache License", "Version 2.0, January 2004"],
                        "ONNX Runtime": ["MIT License", "Copyright (c) Microsoft Corporation",
                                         "Permission is hereby granted"],
                        "Kokoro voice model": ["Apache License", "Version 2.0, January 2004"],
                        "espeak-ng": ["GNU GENERAL PUBLIC LICENSE", "Version 3, 29 June 2007"]]
        XCTAssertEqual(Set(LicensesView.entries.map(\.id)), Set(expected.keys))
        for entry in LicensesView.entries {
            XCTAssertNotNil(entry.textResource, "\(entry.id) ships its license's text")
            let url = try XCTUnwrap(LicensesView.licenseTextURL(for: entry), "\(entry.id)'s text is in Bundle.main")
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in expected[entry.id] ?? [] {
                XCTAssertTrue(text.contains(needle), "\(entry.id): \(needle)")
            }
            XCTAssertFalse(LicenseText.paragraphs(of: text).isEmpty, entry.id)
        }
    }

    /// R2-20: a license file's hard line breaks reflow into paragraphs.
    func testALicenseTextReflowsIntoParagraphs() {
        XCTAssertEqual(LicenseText.paragraphs(of: "MIT License\n\nPermission is\n  granted,\r\nfree.\n\n\n"),
                       ["MIT License", "Permission is granted, free."])
    }
}
